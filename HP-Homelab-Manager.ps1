#Requires -Version 5.1
<#
.SYNOPSIS
    HP ProDesk Homelab Control Center.

.DESCRIPTION
    Terminal control center for the HP ProDesk 400 G1 Debian homelab server.
    Windows PowerShell 5.1 compatible and suitable for PS2EXE compilation.

.PARAMETER SelfTest
    Runs non-destructive local and read-only remote checks, then exits.

.PARAMETER ConfigPath
    Optional alternate configuration path. The default is
    %LOCALAPPDATA%\HPHomelabManager\config.json.
#>
param(
    [switch]$SelfTest,
    [switch]$Build,
    [switch]$Setup,
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ============================================================================
# Application constants and state
# ============================================================================

$script:AppName = 'HP ProDesk Homelab Control Center'
$script:AppProduct = 'HP Homelab Manager'
$script:AppVersion = '2.0.0'
$script:AppDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'HPHomelabManager'
$script:ConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $script:AppDir 'config.json'
}
else {
    $candidate = [Environment]::ExpandEnvironmentVariables($ConfigPath)
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path (Get-Location).Path $candidate
    }
    [System.IO.Path]::GetFullPath($candidate)
}
$script:LogDir = Join-Path $script:AppDir 'logs'
$script:LogFile = Join-Path $script:LogDir 'homelab-manager.log'
$script:BackupDir = Join-Path $script:AppDir 'backups'
$script:TempLauncherDir = Join-Path ([System.IO.Path]::GetTempPath()) 'HPHomelabManager'
$script:Config = $null
$script:ConfigWarnings = @()
$script:ConfigParseFailed = $false
$script:LoggingReady = $false
$script:LoggingFailureReported = $false
$script:SshExe = $null
$script:SshKeyPath = $null
$script:ConnectionCache = [pscustomobject]@{
    State              = 'Unknown'
    Detail             = 'Connection state has not been checked yet.'
    CheckedAt          = $null
    LatencyMilliseconds = 0
}
$script:ExitRequested = $false
$script:PageWidth = 64

# ============================================================================
# Logging
# ============================================================================

function Write-AppLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',
        [string]$Message
    )

    if (-not $script:LoggingReady) { return }

    try {
        $maxBytes = 1048576
        $maxFiles = 5
        if ($script:Config -and $script:Config.logging) {
            if ($script:Config.logging.maxFileBytes) { $maxBytes = [int]$script:Config.logging.maxFileBytes }
            if ($script:Config.logging.maxFiles) { $maxFiles = [int]$script:Config.logging.maxFiles }
        }

        try {
            Invoke-LogRotation -Path $script:LogFile -MaxBytes $maxBytes -MaxFiles $maxFiles
        }
        catch { }

        $cleanMessage = [string]$Message
        $cleanMessage = $cleanMessage -replace "`r?`n", ' | '
        $line = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $cleanMessage, [Environment]::NewLine
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
        [System.IO.File]::AppendAllText($script:LogFile, $line, $encoding)
    }
    catch {
        $script:LoggingReady = $false
        if (-not $script:LoggingFailureReported) {
            $script:LoggingFailureReported = $true
            try {
                Write-Host (" [WARN] Application logging is unavailable: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
            catch { }
        }
    }
}

function Invoke-LogRotation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$MaxBytes,
        [Parameter(Mandatory = $true)][int]$MaxFiles
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -lt $MaxBytes) { return }

    $directory = Split-Path -Parent $Path
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $archive = Join-Path $directory ('{0}-{1}.log' -f $baseName, $stamp)
    $suffix = 1
    while (Test-Path -LiteralPath $archive) {
        $archive = Join-Path $directory ('{0}-{1}-{2}.log' -f $baseName, $stamp, $suffix)
        $suffix++
    }

    Move-Item -LiteralPath $Path -Destination $archive -Force -ErrorAction Stop

    $archives = @(Get-ChildItem -LiteralPath $directory -Filter ('{0}-*.log' -f $baseName) -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($archives.Count -gt $MaxFiles) {
        $archives | Select-Object -Skip $MaxFiles | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-AppLogging {
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir -PathType Container)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force -ErrorAction Stop | Out-Null
        }
        $script:LoggingReady = $true
        Write-AppLog -Level 'INFO' -Message ("Application starting: {0} v{1}; PowerShell {2}; pid {3}" -f $script:AppName, $script:AppVersion, $PSVersionTable.PSVersion.ToString(), $PID)
        Write-AppLog -Level 'INFO' -Message ("Executable: {0}" -f $PSHOME)
    }
    catch {
        $script:LoggingReady = $false
        $script:LoggingFailureReported = $true
        Write-Host (" [WARN] Could not initialize application logging: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Open-AppLog {
    $path = $script:LogFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-AppLog -Level 'INFO' -Message 'Log file was opened before any entries existed.'
    }

    try {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $path) -ErrorAction Stop | Out-Null
        Write-UiMessage -Level Info -Message ('Opened application log: {0}' -f $path)
    }
    catch {
        Write-UiMessage -Level Error -Message ('Could not open the application log: {0}' -f $_.Exception.Message)
        Write-AppLog -Level 'ERROR' -Message ('Could not open application log: {0}' -f $_.Exception.Message)
    }
}

function Show-LogTail {
    param([int]$Lines = 30)
    if (-not (Test-Path -LiteralPath $script:LogFile -PathType Leaf)) {
        Write-UiMessage -Level Info -Message 'The application log is empty.'
        return
    }

    Write-Host ''
    Write-Host ('--- Last {0} log lines ---' -f $Lines) -ForegroundColor Cyan
    try {
        Get-Content -LiteralPath $script:LogFile -Tail $Lines -ErrorAction Stop | ForEach-Object {
            Write-Host ('  {0}' -f $_) -ForegroundColor Gray
        }
    }
    catch {
        Write-UiMessage -Level Error -Message ('Could not read the log: {0}' -f $_.Exception.Message)
    }
}

# ============================================================================
# Default configuration
# ============================================================================

function Get-DefaultConfiguration {
    return @{
        server    = @{
            label   = 'Linux Homelab Server'
            ip      = '192.168.1.50'
            mac     = '02:00:00:00:00:01'
            sshUser = 'homelab'
            sshPort = 22
        }
        ssh       = @{
            keyPath                    = '%USERPROFILE%\.ssh\id_ed25519'
            connectTimeoutSeconds      = 7
            tcpCheckMilliseconds       = 1500
            dashboardCheckMilliseconds = 1200
            serverAliveIntervalSeconds = 10
            serverAliveCountMax        = 2
        }
        network   = @{
            gateway     = '192.168.1.1'
            dnsCheckHost = 'deb.debian.org'
        }
        wakeOnLan = @{
            broadcastAddress   = '192.168.1.255'
            port               = 9
            waitSeconds        = 120
            pollIntervalSeconds = 2
        }
        dashboards = @{
            homepage    = @{ label = 'Homepage'; scheme = 'http'; port = 3000; path = '/'; selfSigned = $false; description = 'Friendly homelab dashboard' }
            uptimeKuma  = @{ label = 'Uptime Kuma'; scheme = 'http'; port = 3001; path = '/'; selfSigned = $false; description = 'Service uptime monitoring' }
            dozzle      = @{ label = 'Dozzle'; scheme = 'http'; port = 8888; path = '/'; selfSigned = $false; description = 'Live Docker logs' }
            wud         = @{ label = 'WUD'; scheme = 'http'; port = 3002; path = '/'; selfSigned = $false; description = 'Container update checker' }
            portainer   = @{ label = 'Portainer'; scheme = 'https'; port = 9443; path = '/'; selfSigned = $true; description = 'Container management' }
            airflow     = @{ label = 'Apache Airflow'; scheme = 'http'; port = 8080; path = '/'; selfSigned = $false; description = 'Workflow UI' }
            pgAdmin     = @{ label = 'pgAdmin'; scheme = 'http'; port = 5050; path = '/'; selfSigned = $false; description = 'PostgreSQL administration' }
            minio       = @{ label = 'MinIO Console'; scheme = 'http'; port = 9001; path = '/'; selfSigned = $false; description = 'Object storage console' }
            sparkMaster = @{ label = 'Spark Master UI'; scheme = 'http'; port = 8081; path = '/'; selfSigned = $false; description = 'Spark cluster master' }
            sparkWorker = @{ label = 'Spark Worker UI'; scheme = 'http'; port = 8082; path = '/'; selfSigned = $false; description = 'Spark worker' }
        }
        services  = @{
            airflow      = @{
                label             = 'Apache Airflow'
                directory         = '~/homelab/airflow'
                startScript       = '~/homelab/start-airflow.sh'
                stopScript        = '~/homelab/stop-airflow.sh'
                profiles          = @()
                logsServiceNames  = @('airflow-apiserver', 'airflow-scheduler')
                dashboards        = @('airflow')
                estimatedMemoryMb = 1800
                notes             = 'Airflow 3.x LocalExecutor stack: Postgres, API server, scheduler, DAG processor and triggerer.'
            }
            dataPlatform = @{
                label             = 'Data Platform'
                directory         = '~/homelab/platform'
                startScript       = '~/homelab/start-data-platform.sh'
                stopScript        = '~/homelab/stop-data-platform.sh'
                profiles          = @('data')
                logsServiceNames  = @('postgres', 'pgadmin', 'redis', 'minio')
                dashboards        = @('pgAdmin', 'minio')
                estimatedMemoryMb = 900
                notes             = 'PostgreSQL, pgAdmin, Redis and MinIO from the platform compose project (profile: data).'
            }
            spark        = @{
                label             = 'Apache Spark'
                directory         = '~/homelab/platform'
                startScript       = '~/homelab/start-spark.sh'
                stopScript        = '~/homelab/stop-spark.sh'
                profiles          = @('spark')
                logsServiceNames  = @('spark-master', 'spark-worker')
                dashboards        = @('sparkMaster', 'sparkWorker')
                estimatedMemoryMb = 2600
                notes             = 'Spark master and worker. The worker is configured with a 2 GB heap; this is a separate profile of the shared platform compose project.'
            }
        }
        companion = @{
            label             = 'Everyday Tools'
            directory         = '~/homelab/companion'
            startScript       = '~/homelab/start-companion.sh'
            stopScript        = '~/homelab/stop-companion.sh'
            updateScript      = '~/homelab/update-companion.sh'
            tailscaleScript   = '~/homelab/setup-tailscale.sh'
            envFile           = '~/homelab/companion/.env'
            dashboards        = @('homepage', 'uptimeKuma', 'dozzle', 'wud')
            estimatedMemoryMb = 600
            notes             = 'Homepage dashboard, Uptime Kuma monitoring, Dozzle live logs and WUD update checker.'
        }
        timeouts  = @{
            remoteStatusSeconds = 30
            remoteLogsSeconds   = 30
            remoteStatsSeconds  = 30
            remoteStartSeconds  = 600
            remoteStopSeconds   = 180
            remoteImagePullSeconds = 600
            shutdownWaitSeconds = 30
            rebootDownSeconds   = 45
            rebootReturnSeconds = 180
            rebootPollSeconds   = 2
        }
        logging   = @{
            maxFileBytes = 1048576
            maxFiles     = 5
        }
    }
}

function Copy-ConfigValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [hashtable]) {
        $copy = @{}
        foreach ($key in $Value.Keys) {
            $copy[$key] = Copy-ConfigValue -Value $Value[$key]
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) { $items += ,(Copy-ConfigValue -Value $item) }
        return ,$items
    }
    return $Value
}

function ConvertTo-ConfigHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-ConfigHashtable -InputObject $property.Value
        }
        return $result
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-ConfigHashtable -InputObject $InputObject[$key]
        }
        return $result
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) { $items += ,(ConvertTo-ConfigHashtable -InputObject $item) }
        return ,$items
    }
    return $InputObject
}

function Merge-ConfigObjects {
    param(
        [hashtable]$Defaults,
        [hashtable]$Override
    )

    $result = @{}
    foreach ($key in $Defaults.Keys) {
        if ($Override.ContainsKey($key) -and $null -ne $Override[$key]) {
            if (($Defaults[$key] -is [hashtable]) -and ($Override[$key] -is [hashtable])) {
                $result[$key] = Merge-ConfigObjects -Defaults $Defaults[$key] -Override $Override[$key]
            }
            else {
                $result[$key] = Copy-ConfigValue -Value $Override[$key]
            }
        }
        else {
            $result[$key] = Copy-ConfigValue -Value $Defaults[$key]
        }
    }

    foreach ($key in $Override.Keys) {
        if (-not $result.ContainsKey($key)) {
            $result[$key] = Copy-ConfigValue -Value $Override[$key]
        }
    }
    return $result
}

function Add-ConfigWarning {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $script:ConfigWarnings += $Message
}

function Get-ValidatedInt {
    param(
        $Value,
        [int]$Default,
        [int]$Minimum,
        [int]$Maximum,
        [string]$Name
    )
    $number = 0
    if ([int]::TryParse([string]$Value, [ref]$number) -and $number -ge $Minimum -and $number -le $Maximum) {
        return $number
    }
    Add-ConfigWarning ('{0} must be an integer from {1} to {2}; using default {3}.' -f $Name, $Minimum, $Maximum, $Default)
    return $Default
}

function Get-ValidatedString {
    param(
        $Value,
        [string]$Default,
        [string]$Pattern,
        [string]$Name,
        [int]$MaximumLength = 80,
        [switch]$AllowEmpty
    )
    if ($Value -is [string]) {
        $text = $Value.Trim()
        if (($AllowEmpty -or -not [string]::IsNullOrWhiteSpace($text)) -and $text.Length -le $MaximumLength -and $text -match $Pattern) {
            return $text
        }
    }
    Add-ConfigWarning ('{0} is invalid; using the built-in default.' -f $Name)
    return $Default
}

function Get-ValidatedIp {
    param($Value, [string]$Default, [string]$Name)
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse([string]$Value, [ref]$parsed) -and $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $parsed.ToString()
    }
    Add-ConfigWarning ('{0} must be a valid IPv4 address; using default {1}.' -f $Name, $Default)
    return $Default
}

function Get-ValidatedMac {
    param($Value, [string]$Default, [string]$Name)
    if ($Value -is [string] -and $Value -match '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
        return $Value.ToUpperInvariant()
    }
    Add-ConfigWarning ('{0} must be a valid MAC address; using default {1}.' -f $Name, $Default)
    return $Default
}

function Get-ValidatedNames {
    param($Value, [string[]]$Default, [string]$Name)
    $items = @()
    if ($Value -is [string]) {
        $items = @($Value)
    }
    elseif ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @($Value)
    }
    else {
        Add-ConfigWarning ('{0} must be a string list; using defaults.' -f $Name)
        return @($Default)
    }

    $validated = @()
    foreach ($item in $items) {
        if ($item -isnot [string] -or $item -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
            Add-ConfigWarning ('{0} contains an invalid name; using defaults.' -f $Name)
            return @($Default)
        }
        $validated += $item
    }
    return @($validated)
}

function Get-ValidatedRemotePath {
    param($Value, [string]$Default, [string]$Name)
    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ($text -match '^~?/[A-Za-z0-9._/-]+$' -and $text -notmatch '(^|/)\.\.(/|$)') {
            return $text
        }
    }
    Add-ConfigWarning ('{0} must be an absolute or ~/ remote path without spaces or shell metacharacters; using default.' -f $Name)
    return $Default
}

function Get-ValidatedDashboardKeys {
    param($Value, [string[]]$Default, [hashtable]$Dashboards, [string]$Name)
    $items = Get-ValidatedNames -Value $Value -Default $Default -Name $Name
    foreach ($item in $items) {
        if (-not $Dashboards.ContainsKey($item)) {
            Add-ConfigWarning ('{0} references unknown dashboard "{1}"; using defaults.' -f $Name, $item)
            return @($Default)
        }
    }
    return @($items)
}
function Confirm-AppConfiguration {
    param([hashtable]$Configuration)

    $defaults = Get-DefaultConfiguration

    foreach ($section in @('server', 'ssh', 'network', 'wakeOnLan', 'dashboards', 'services', 'companion', 'timeouts', 'logging')) {
        if (-not ($Configuration[$section] -is [hashtable])) {
            Add-ConfigWarning ('Configuration section "{0}" is invalid; using defaults.' -f $section)
            $Configuration[$section] = Copy-ConfigValue -Value $defaults[$section]
        }
    }

    $server = $Configuration.server
    $server.label = Get-ValidatedString -Value $server.label -Default $defaults.server.label -Pattern '^[^\r\n]{1,80}$' -Name 'server.label'
    $server.ip = Get-ValidatedIp -Value $server.ip -Default $defaults.server.ip -Name 'server.ip'
    $server.mac = Get-ValidatedMac -Value $server.mac -Default $defaults.server.mac -Name 'server.mac'
    $server.sshUser = Get-ValidatedString -Value $server.sshUser -Default $defaults.server.sshUser -Pattern '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$' -Name 'server.sshUser'
    $server.sshPort = Get-ValidatedInt -Value $server.sshPort -Default $defaults.server.sshPort -Minimum 1 -Maximum 65535 -Name 'server.sshPort'

    $ssh = $Configuration.ssh
    $ssh.keyPath = Get-ValidatedString -Value $ssh.keyPath -Default $defaults.ssh.keyPath -Pattern '^[^\r\n]{1,260}$' -Name 'ssh.keyPath' -MaximumLength 260
    $ssh.connectTimeoutSeconds = Get-ValidatedInt -Value $ssh.connectTimeoutSeconds -Default $defaults.ssh.connectTimeoutSeconds -Minimum 2 -Maximum 30 -Name 'ssh.connectTimeoutSeconds'
    $ssh.tcpCheckMilliseconds = Get-ValidatedInt -Value $ssh.tcpCheckMilliseconds -Default $defaults.ssh.tcpCheckMilliseconds -Minimum 200 -Maximum 10000 -Name 'ssh.tcpCheckMilliseconds'
    $ssh.dashboardCheckMilliseconds = Get-ValidatedInt -Value $ssh.dashboardCheckMilliseconds -Default $defaults.ssh.dashboardCheckMilliseconds -Minimum 200 -Maximum 10000 -Name 'ssh.dashboardCheckMilliseconds'
    $ssh.serverAliveIntervalSeconds = Get-ValidatedInt -Value $ssh.serverAliveIntervalSeconds -Default $defaults.ssh.serverAliveIntervalSeconds -Minimum 5 -Maximum 120 -Name 'ssh.serverAliveIntervalSeconds'
    $ssh.serverAliveCountMax = Get-ValidatedInt -Value $ssh.serverAliveCountMax -Default $defaults.ssh.serverAliveCountMax -Minimum 1 -Maximum 10 -Name 'ssh.serverAliveCountMax'

    $network = $Configuration.network
    $network.gateway = Get-ValidatedIp -Value $network.gateway -Default $defaults.network.gateway -Name 'network.gateway'
    $network.dnsCheckHost = Get-ValidatedString -Value $network.dnsCheckHost -Default $defaults.network.dnsCheckHost -Pattern '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' -Name 'network.dnsCheckHost'

    $wol = $Configuration.wakeOnLan
    $wol.broadcastAddress = Get-ValidatedIp -Value $wol.broadcastAddress -Default $defaults.wakeOnLan.broadcastAddress -Name 'wakeOnLan.broadcastAddress'
    $wol.port = Get-ValidatedInt -Value $wol.port -Default $defaults.wakeOnLan.port -Minimum 1 -Maximum 65535 -Name 'wakeOnLan.port'
    $wol.waitSeconds = Get-ValidatedInt -Value $wol.waitSeconds -Default $defaults.wakeOnLan.waitSeconds -Minimum 10 -Maximum 600 -Name 'wakeOnLan.waitSeconds'
    $wol.pollIntervalSeconds = Get-ValidatedInt -Value $wol.pollIntervalSeconds -Default $defaults.wakeOnLan.pollIntervalSeconds -Minimum 1 -Maximum 10 -Name 'wakeOnLan.pollIntervalSeconds'

    if (-not ($Configuration.dashboards -is [hashtable])) {
        $Configuration.dashboards = Copy-ConfigValue -Value $defaults.dashboards
    }
    foreach ($dashboardKey in $defaults.dashboards.Keys) {
        if (-not ($Configuration.dashboards[$dashboardKey] -is [hashtable])) {
            Add-ConfigWarning ('Dashboard "{0}" is invalid; using defaults.' -f $dashboardKey)
            $Configuration.dashboards[$dashboardKey] = Copy-ConfigValue -Value $defaults.dashboards[$dashboardKey]
        }
        $dash = $Configuration.dashboards[$dashboardKey]
        $dash.label = Get-ValidatedString -Value $dash.label -Default $defaults.dashboards[$dashboardKey].label -Pattern '^[^\r\n]{1,60}$' -Name ('dashboards.{0}.label' -f $dashboardKey) -MaximumLength 60
        $dash.scheme = Get-ValidatedString -Value $dash.scheme -Default $defaults.dashboards[$dashboardKey].scheme -Pattern '^(http|https)$' -Name ('dashboards.{0}.scheme' -f $dashboardKey)
        $dash.port = Get-ValidatedInt -Value $dash.port -Default $defaults.dashboards[$dashboardKey].port -Minimum 1 -Maximum 65535 -Name ('dashboards.{0}.port' -f $dashboardKey)
        $dash.path = Get-ValidatedString -Value $dash.path -Default $defaults.dashboards[$dashboardKey].path -Pattern '^/[A-Za-z0-9._~/?=&%+-]*$' -Name ('dashboards.{0}.path' -f $dashboardKey) -MaximumLength 300
        if ([string]::IsNullOrWhiteSpace([string]$dash.path)) { $dash.path = '/' }
        if (-not ($dash.path.StartsWith('/'))) { $dash.path = '/' + $dash.path }
        if ($dash.selfSigned -isnot [bool]) { $dash.selfSigned = [bool]$defaults.dashboards[$dashboardKey].selfSigned }
        $dash.description = Get-ValidatedString -Value $dash.description -Default $defaults.dashboards[$dashboardKey].description -Pattern '^[^\r\n]{0,100}$' -Name ('dashboards.{0}.description' -f $dashboardKey) -MaximumLength 100 -AllowEmpty
    }

    if (-not ($Configuration.services -is [hashtable])) {
        $Configuration.services = Copy-ConfigValue -Value $defaults.services
    }
    foreach ($serviceKey in $defaults.services.Keys) {
        if (-not ($Configuration.services[$serviceKey] -is [hashtable])) {
            Add-ConfigWarning ('Service "{0}" is invalid; using defaults.' -f $serviceKey)
            $Configuration.services[$serviceKey] = Copy-ConfigValue -Value $defaults.services[$serviceKey]
        }
        $service = $Configuration.services[$serviceKey]
        $defaultService = $defaults.services[$serviceKey]
        $service.label = Get-ValidatedString -Value $service.label -Default $defaultService.label -Pattern '^[^\r\n]{1,60}$' -Name ('services.{0}.label' -f $serviceKey) -MaximumLength 60
        $service.directory = Get-ValidatedRemotePath -Value $service.directory -Default $defaultService.directory -Name ('services.{0}.directory' -f $serviceKey)
        $service.startScript = Get-ValidatedRemotePath -Value $service.startScript -Default $defaultService.startScript -Name ('services.{0}.startScript' -f $serviceKey)
        $service.stopScript = Get-ValidatedRemotePath -Value $service.stopScript -Default $defaultService.stopScript -Name ('services.{0}.stopScript' -f $serviceKey)
        $service.profiles = Get-ValidatedNames -Value $service.profiles -Default $defaultService.profiles -Name ('services.{0}.profiles' -f $serviceKey)
        $service.logsServiceNames = Get-ValidatedNames -Value $service.logsServiceNames -Default $defaultService.logsServiceNames -Name ('services.{0}.logsServiceNames' -f $serviceKey)
        $service.dashboards = Get-ValidatedDashboardKeys -Value $service.dashboards -Default $defaultService.dashboards -Dashboards $Configuration.dashboards -Name ('services.{0}.dashboards' -f $serviceKey)
        $service.estimatedMemoryMb = Get-ValidatedInt -Value $service.estimatedMemoryMb -Default $defaultService.estimatedMemoryMb -Minimum 0 -Maximum 32768 -Name ('services.{0}.estimatedMemoryMb' -f $serviceKey)
        if ($service.notes -isnot [string]) { $service.notes = $defaultService.notes }
        $service.notes = $service.notes -replace "`r?`n", ' '
    }

    if (-not ($Configuration.companion -is [hashtable])) {
        $Configuration.companion = Copy-ConfigValue -Value $defaults.companion
    }
    $companion = $Configuration.companion
    $defaultCompanion = $defaults.companion
    $companion.label = Get-ValidatedString -Value $companion.label -Default $defaultCompanion.label -Pattern '^[^\r\n]{1,60}$' -Name 'companion.label' -MaximumLength 60
    $companion.directory = Get-ValidatedRemotePath -Value $companion.directory -Default $defaultCompanion.directory -Name 'companion.directory'
    $companion.startScript = Get-ValidatedRemotePath -Value $companion.startScript -Default $defaultCompanion.startScript -Name 'companion.startScript'
    $companion.stopScript = Get-ValidatedRemotePath -Value $companion.stopScript -Default $defaultCompanion.stopScript -Name 'companion.stopScript'
    $companion.updateScript = Get-ValidatedRemotePath -Value $companion.updateScript -Default $defaultCompanion.updateScript -Name 'companion.updateScript'
    $companion.tailscaleScript = Get-ValidatedRemotePath -Value $companion.tailscaleScript -Default $defaultCompanion.tailscaleScript -Name 'companion.tailscaleScript'
    $companion.envFile = Get-ValidatedRemotePath -Value $companion.envFile -Default $defaultCompanion.envFile -Name 'companion.envFile'
    $companion.dashboards = Get-ValidatedDashboardKeys -Value $companion.dashboards -Default $defaultCompanion.dashboards -Dashboards $Configuration.dashboards -Name 'companion.dashboards'
    $companion.estimatedMemoryMb = Get-ValidatedInt -Value $companion.estimatedMemoryMb -Default $defaultCompanion.estimatedMemoryMb -Minimum 0 -Maximum 32768 -Name 'companion.estimatedMemoryMb'
    if ($companion.notes -isnot [string]) { $companion.notes = $defaultCompanion.notes }
    $companion.notes = $companion.notes -replace "`r?`n", ' '

    $timeouts = $Configuration.timeouts
    $timeouts.remoteStatusSeconds = Get-ValidatedInt -Value $timeouts.remoteStatusSeconds -Default $defaults.timeouts.remoteStatusSeconds -Minimum 5 -Maximum 300 -Name 'timeouts.remoteStatusSeconds'
    $timeouts.remoteLogsSeconds = Get-ValidatedInt -Value $timeouts.remoteLogsSeconds -Default $defaults.timeouts.remoteLogsSeconds -Minimum 5 -Maximum 300 -Name 'timeouts.remoteLogsSeconds'
    $timeouts.remoteStatsSeconds = Get-ValidatedInt -Value $timeouts.remoteStatsSeconds -Default $defaults.timeouts.remoteStatsSeconds -Minimum 5 -Maximum 300 -Name 'timeouts.remoteStatsSeconds'
    $timeouts.remoteStartSeconds = Get-ValidatedInt -Value $timeouts.remoteStartSeconds -Default $defaults.timeouts.remoteStartSeconds -Minimum 60 -Maximum 3600 -Name 'timeouts.remoteStartSeconds'
    $timeouts.remoteStopSeconds = Get-ValidatedInt -Value $timeouts.remoteStopSeconds -Default $defaults.timeouts.remoteStopSeconds -Minimum 30 -Maximum 900 -Name 'timeouts.remoteStopSeconds'
    $timeouts.remoteImagePullSeconds = Get-ValidatedInt -Value $timeouts.remoteImagePullSeconds -Default $defaults.timeouts.remoteImagePullSeconds -Minimum 60 -Maximum 3600 -Name 'timeouts.remoteImagePullSeconds'
    $timeouts.shutdownWaitSeconds = Get-ValidatedInt -Value $timeouts.shutdownWaitSeconds -Default $defaults.timeouts.shutdownWaitSeconds -Minimum 10 -Maximum 180 -Name 'timeouts.shutdownWaitSeconds'
    $timeouts.rebootDownSeconds = Get-ValidatedInt -Value $timeouts.rebootDownSeconds -Default $defaults.timeouts.rebootDownSeconds -Minimum 10 -Maximum 300 -Name 'timeouts.rebootDownSeconds'
    $timeouts.rebootReturnSeconds = Get-ValidatedInt -Value $timeouts.rebootReturnSeconds -Default $defaults.timeouts.rebootReturnSeconds -Minimum 30 -Maximum 900 -Name 'timeouts.rebootReturnSeconds'
    $timeouts.rebootPollSeconds = Get-ValidatedInt -Value $timeouts.rebootPollSeconds -Default $defaults.timeouts.rebootPollSeconds -Minimum 1 -Maximum 10 -Name 'timeouts.rebootPollSeconds'

    $logging = $Configuration.logging
    $logging.maxFileBytes = Get-ValidatedInt -Value $logging.maxFileBytes -Default $defaults.logging.maxFileBytes -Minimum 65536 -Maximum 52428800 -Name 'logging.maxFileBytes'
    $logging.maxFiles = Get-ValidatedInt -Value $logging.maxFiles -Default $defaults.logging.maxFiles -Minimum 1 -Maximum 20 -Name 'logging.maxFiles'

    return $Configuration
}

function Read-AppConfiguration {
    param([string]$Path = $script:ConfigPath)

    $defaults = Get-DefaultConfiguration
    $script:ConfigWarnings = @()
    $script:ConfigParseFailed = $false

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            $parent = Split-Path -Parent $Path
            if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
            }
            $json = $defaults | ConvertTo-Json -Depth 12
            $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
            [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
            Write-AppLog -Level 'INFO' -Message ('Created default configuration: {0}' -f $Path)
        }
        catch {
            Add-ConfigWarning ('Could not create the default configuration file: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Could not create configuration: {0}' -f $_.Exception.Message)
        }
        return $defaults
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($json)) { throw 'The configuration file is empty.' }
        $parsed = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        $override = ConvertTo-ConfigHashtable -InputObject $parsed
        if (-not ($override -is [hashtable])) { throw 'The configuration root must be a JSON object.' }
        $merged = Merge-ConfigObjects -Defaults $defaults -Override $override
    }
    catch {
        $script:ConfigParseFailed = $true
        Add-ConfigWarning ('Configuration could not be parsed. The existing file was left unchanged and built-in defaults are in use: {0}' -f $_.Exception.Message)
        Write-AppLog -Level 'ERROR' -Message ('Configuration parse failure: {0}' -f $_.Exception.Message)
        return $defaults
    }

    try {
        $validated = Confirm-AppConfiguration -Configuration $merged
        Write-AppLog -Level 'INFO' -Message ('Configuration loaded: {0}' -f $Path)
        return $validated
    }
    catch {
        $script:ConfigParseFailed = $true
        Add-ConfigWarning ('Configuration validation failed; built-in defaults are in use: {0}' -f $_.Exception.Message)
        Write-AppLog -Level 'ERROR' -Message ('Configuration validation failure: {0}' -f $_.Exception.Message)
        return $defaults
    }
}

# ============================================================================
# Environment and paths
# ============================================================================

function Expand-UserPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq '~') { return $env:USERPROFILE }
    if ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        return (Join-Path $env:USERPROFILE $expanded.Substring(2))
    }
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        return (Join-Path $script:AppDir $expanded)
    }
    return $expanded
}

function Initialize-AppEnvironment {
    foreach ($directory in @($script:AppDir, $script:LogDir, $script:BackupDir, $script:TempLauncherDir)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
        }
    }

    try {
        if ($Host.Name -eq 'ConsoleHost' -and $Host.UI.RawUI) {
            $Host.UI.RawUI.WindowTitle = ('{0} v{1}' -f $script:AppName, $script:AppVersion)
        }
    }
    catch { }
}

function Initialize-SshEnvironment {
    $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($sshCommand) {
        $script:SshExe = $sshCommand.Source
    }
    else {
        $sshCommand = Get-Command ssh -ErrorAction SilentlyContinue
        if ($sshCommand) { $script:SshExe = $sshCommand.Source }
    }

    $script:SshKeyPath = Expand-UserPath -Path $script:Config.ssh.keyPath
}

function Remove-StaleLauncherScripts {
    try {
        if (-not (Test-Path -LiteralPath $script:TempLauncherDir -PathType Container)) { return }
        $cutoff = (Get-Date).AddDays(-1)
        Get-ChildItem -LiteralPath $script:TempLauncherDir -Filter 'ssh-launcher-*.ps1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { }
}
# ============================================================================
# Console user interface
# ============================================================================

function Write-Rule {
    param(
        [string]$Character = '=',
        [ConsoleColor]$Color = [ConsoleColor]::DarkCyan
    )
    Write-Host ($Character * $script:PageWidth) -ForegroundColor $Color
}

function Write-UiMessage {
    param(
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info',
        [string]$Message
    )

    $symbol = 'i'
    $color = [ConsoleColor]::Cyan
    switch ($Level) {
        'Success' { $symbol = '+'; $color = [ConsoleColor]::Green }
        'Warning' { $symbol = '!'; $color = [ConsoleColor]::Yellow }
        'Error' { $symbol = 'x'; $color = [ConsoleColor]::Red }
    }
    Write-Host ('  [{0}] {1}' -f $symbol, $Message) -ForegroundColor $color
}

function Write-MenuOption {
    param(
        [string]$Key,
        [string]$Text,
        [string]$Note = ''
    )
    Write-Host ('   [{0}] ' -f $Key) -NoNewline -ForegroundColor Cyan
    if ($Note) {
        Write-Host ('{0,-42}' -f $Text) -NoNewline
        Write-Host $Note -ForegroundColor DarkGray
    }
    else {
        Write-Host $Text
    }
}

function Get-ConnectionDisplay {
    param($Cache)
    switch ($Cache.State) {
        'Authenticated' { return [pscustomobject]@{ Text = 'ONLINE - SSH AUTHENTICATED'; Color = [ConsoleColor]::Green } }
        'Online' { return [pscustomobject]@{ Text = 'ONLINE - SSH PORT OPEN (auth unverified)'; Color = [ConsoleColor]::Green } }
        'AuthenticationFailed' { return [pscustomobject]@{ Text = 'ONLINE - SSH AUTHENTICATION FAILED'; Color = [ConsoleColor]::Red } }
        'HostKeyFailure' { return [pscustomobject]@{ Text = 'ONLINE - SSH HOST KEY ERROR'; Color = [ConsoleColor]::Red } }
        'SshUnavailable' { return [pscustomobject]@{ Text = 'HOST UP - SSH PORT UNAVAILABLE'; Color = [ConsoleColor]::Red } }
        'Offline' { return [pscustomobject]@{ Text = 'OFFLINE / NO RESPONSE'; Color = [ConsoleColor]::Red } }
        'Timeout' { return [pscustomobject]@{ Text = 'OFFLINE / CONNECTION TIMEOUT'; Color = [ConsoleColor]::Red } }
        'KeyMissing' { return [pscustomobject]@{ Text = 'SSH KEY NOT FOUND'; Color = [ConsoleColor]::Yellow } }
        'SshMissing' { return [pscustomobject]@{ Text = 'SSH CLIENT NOT FOUND'; Color = [ConsoleColor]::Yellow } }
        'Error' { return [pscustomobject]@{ Text = 'NETWORK / CONFIGURATION ERROR'; Color = [ConsoleColor]::Yellow } }
        default { return [pscustomobject]@{ Text = 'UNKNOWN - NOT CHECKED YET'; Color = [ConsoleColor]::DarkYellow } }
    }
}

function Show-AppHeader {
    param(
        [string]$Title = 'MAIN MENU',
        [switch]$NoClear
    )

    if (-not $NoClear) {
        try { Clear-Host } catch { Write-Host '' }
    }

    Write-Host ''
    Write-Rule -Character '=' -Color Cyan
    Write-Host ('  {0}' -f $script:AppName.ToUpperInvariant()) -ForegroundColor Cyan
    Write-Host ('  {0} v{1}' -f $script:AppProduct, $script:AppVersion) -ForegroundColor DarkGray
    Write-Rule -Character '=' -Color Cyan

    Write-Host '  HOST       ' -NoNewline -ForegroundColor DarkGray
    Write-Host $script:Config.server.label
    Write-Host '  ADDRESS    ' -NoNewline -ForegroundColor DarkGray
    Write-Host ('{0}:{1}' -f $script:Config.server.ip, $script:Config.server.sshPort)
    Write-Host '  AUTH       ' -NoNewline -ForegroundColor DarkGray
    Write-Host ('{0} (SSH key)' -f $script:Config.server.sshUser)
    Write-Host '  CONNECTION ' -NoNewline -ForegroundColor DarkGray
    $display = Get-ConnectionDisplay -Cache $script:ConnectionCache
    Write-Host $display.Text -ForegroundColor $display.Color
    Write-Host '  CHECKED    ' -NoNewline -ForegroundColor DarkGray
    if ($script:ConnectionCache.CheckedAt) {
        Write-Host ('{0}  (machine: {1})' -f $script:ConnectionCache.CheckedAt.ToString('yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME) -ForegroundColor Gray
    }
    else {
        Write-Host 'not checked yet' -ForegroundColor DarkGray
    }

    Write-Rule -Character '-' -Color DarkGray
    Write-Host ('  {0}' -f $Title.ToUpperInvariant()) -ForegroundColor Yellow
    Write-Rule -Character '-' -Color DarkGray
}

function Show-AppFooter {
    Write-Rule -Character '-' -Color DarkGray
    Write-Host ('  {0} v{1}  |  Logs: {2}' -f $script:AppProduct, $script:AppVersion, (Join-Path 'logs' 'homelab-manager.log')) -ForegroundColor DarkGray
}

function Wait-Return {
    Write-Host ''
    [void](Read-Host '  Press ENTER to return')
}

function Read-MenuChoice {
    param([string]$Prompt = '  Select an option')

    Show-AppFooter
    while ($true) {
        $value = Read-Host $Prompt
        if ($null -eq $value) { return '0' }
        $value = $value.Trim()
        if ($value -match '^\d{1,2}$') {
            return ([int]$value).ToString()
        }
        Write-UiMessage -Level Warning -Message 'Enter a menu number, for example 3. Press 0 to go back.'
    }
}

function Read-Confirmation {
    param(
        [string]$Message,
        [string]$ExpectedWord
    )

    Write-Host ''
    Write-Host ('  {0}' -f $Message) -ForegroundColor Yellow
    Write-Host ('  Type {0} to confirm. Any other answer cancels.' -f $ExpectedWord) -ForegroundColor Yellow
    $answer = Read-Host '  Confirmation'
    if ($null -ne $answer -and $answer.Trim() -eq $ExpectedWord) {
        return $true
    }
    Write-UiMessage -Level Info -Message 'Cancelled. No action was taken.'
    return $false
}

function Read-ContainerReference {
    $value = Read-Host '  Container name or ID'
    if ($null -eq $value) { return $null }
    $value = $value.Trim()
    if ($value -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { return $value }
    Write-UiMessage -Level Error -Message 'Invalid container name or ID. Use letters, digits, dot, underscore or hyphen only.'
    return $null
}

# ============================================================================
# Connection checks and cache
# ============================================================================

function Update-ConnectionCache {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [string]$Detail = '',
        [int]$LatencyMilliseconds = 0
    )
    $script:ConnectionCache = [pscustomobject]@{
        State               = $State
        Detail              = $Detail
        CheckedAt           = (Get-Date)
        LatencyMilliseconds = $LatencyMilliseconds
    }
}

function Update-ConnectionCacheFromTcp {
    param($Probe)
    if ($Probe.IsOpen) {
        Update-ConnectionCache -State 'Online' -Detail ('TCP port {0} is open.' -f $Probe.Port) -LatencyMilliseconds $Probe.LatencyMilliseconds
        return
    }
    switch ($Probe.State) {
        'Refused' { Update-ConnectionCache -State 'SshUnavailable' -Detail ('TCP port {0} refused the connection.' -f $Probe.Port) -LatencyMilliseconds $Probe.LatencyMilliseconds }
        'Timeout' { Update-ConnectionCache -State 'Timeout' -Detail ('TCP port {0} did not answer before the timeout.' -f $Probe.Port) -LatencyMilliseconds $Probe.LatencyMilliseconds }
        'Unreachable' { Update-ConnectionCache -State 'Offline' -Detail ('Host or network is unreachable on TCP port {0}.' -f $Probe.Port) -LatencyMilliseconds $Probe.LatencyMilliseconds }
        default { Update-ConnectionCache -State 'Error' -Detail $Probe.Message -LatencyMilliseconds $Probe.LatencyMilliseconds }
    }
}

function Initialize-ConnectionCache {
    try {
        $probe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $script:Config.ssh.tcpCheckMilliseconds
        Update-ConnectionCacheFromTcp -Probe $probe
    }
    catch {
        Update-ConnectionCache -State 'Error' -Detail $_.Exception.Message
    }
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 1200,
        [Nullable[int]]$TimeoutMs = $null
    )

    # TimeoutMs is retained for the LAN-discovery API, which returns concise
    # state labels. Existing manager calls use TimeoutMilliseconds and retain
    # their detailed result object.
    $returnStateOnly = $PSBoundParameters.ContainsKey('TimeoutMs')
    if ($returnStateOnly) { $TimeoutMilliseconds = $TimeoutMs.Value }

    # The discovery API needs only the three compact states below.  Keep this
    # probe separate from the richer manager probe so it remains deterministic
    # when callers use the compatibility TimeoutMs parameter.
    if ($returnStateOnly) {
        if ($ComputerName -eq '127.0.0.1') {
            try {
                $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($listener) { return 'open' }
                return 'closed'
            }
            catch { }
        }
        $legacyClient = New-Object System.Net.Sockets.TcpClient
        try {
            $legacyAsync = $legacyClient.BeginConnect($ComputerName, $Port, $null, $null)
            if (-not $legacyAsync.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return 'timeout' }
            $legacyClient.EndConnect($legacyAsync)
            return 'open'
        }
        catch [System.Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) { return 'closed' }
            return 'timeout'
        }
        catch { return 'timeout' }
        finally { $legacyClient.Close() }
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [pscustomobject]@{
        ComputerName         = $ComputerName
        Port                 = $Port
        State                = 'Error'
        IsOpen               = $false
        Message              = ''
        LatencyMilliseconds  = 0
    }
    $client = $null
    $asyncResult = $null
    $waitHandle = $null

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.NoDelay = $true
        $asyncResult = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $waitHandle = $asyncResult.AsyncWaitHandle
        if (-not $waitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            $result.State = 'Timeout'
            $result.Message = ('TCP connection to {0}:{1} timed out after {2} ms.' -f $ComputerName, $Port, $TimeoutMilliseconds)
            if ($returnStateOnly) { return 'timeout' }
            return $result
        }

        try {
            $client.EndConnect($asyncResult)
            $result.State = 'Open'
            $result.IsOpen = $true
            $result.Message = ('TCP port {0} is open.' -f $Port)
        }
        catch [System.Net.Sockets.SocketException] {
            $socketError = [string]$_.Exception.SocketErrorCode
            switch ($socketError) {
                'ConnectionRefused' {
                    $result.State = 'Refused'
                    $result.Message = ('Host is reachable but TCP port {0} is closed.' -f $Port)
                }
                'HostUnreachable' {
                    $result.State = 'Unreachable'
                    $result.Message = 'Host is unreachable.'
                }
                'NetworkUnreachable' {
                    $result.State = 'Unreachable'
                    $result.Message = 'Network is unreachable.'
                }
                'TimedOut' {
                    $result.State = 'Timeout'
                    $result.Message = ('TCP connection to {0}:{1} timed out.' -f $ComputerName, $Port)
                }
                default {
                    $result.State = 'Error'
                    $result.Message = ('Socket error: {0}' -f $socketError)
                }
            }
        }
    }
    catch {
        $result.State = 'Error'
        $result.Message = $_.Exception.Message
    }
    finally {
        if ($waitHandle) { try { $waitHandle.Close() } catch { } }
        if ($client) { try { $client.Close() } catch { } }
        $stopwatch.Stop()
        $result.LatencyMilliseconds = $stopwatch.ElapsedMilliseconds
    }

    if ($returnStateOnly) {
        switch ($result.State) {
            'Open' { return 'open' }
            'Refused' { return 'closed' }
            default { return 'timeout' }
        }
    }
    return $result
}

function Format-Elapsed {
    param([int]$Seconds)
    $minutes = [math]::Floor($Seconds / 60)
    $remaining = $Seconds % 60
    return ('{0}:{1:00}' -f $minutes, $remaining)
}

function Wait-ForTcpState {
    param(
        [ValidateSet('Open', 'Closed')][string]$DesiredState,
        [int]$TimeoutSeconds,
        [string]$Activity,
        [int]$PollSeconds = 2
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $start = [DateTime]::UtcNow
    $lastState = 'Unknown'
    Write-Host ''
    Write-Host ('  {0}' -f $Activity) -ForegroundColor Cyan

    while ([DateTime]::UtcNow -lt $deadline) {
        $remainingSeconds = [math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalSeconds)
        $probeTimeout = [math]::Min([int]$script:Config.ssh.tcpCheckMilliseconds, [int]($remainingSeconds * 1000))
        if ($probeTimeout -lt 100) { $probeTimeout = 100 }

        $probe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $probeTimeout
        $lastState = $probe.State
        $elapsed = [int]([DateTime]::UtcNow - $start).TotalSeconds

        if ($DesiredState -eq 'Open' -and $probe.IsOpen) {
            Write-Host ("`r  Elapsed {0} / {1} - SSH port is open.                    " -f (Format-Elapsed $elapsed), (Format-Elapsed $TimeoutSeconds)) -ForegroundColor Green
            Update-ConnectionCacheFromTcp -Probe $probe
            return [pscustomobject]@{ Reached = $true; ElapsedSeconds = $elapsed; LastState = $probe.State }
        }
        if ($DesiredState -eq 'Closed' -and -not $probe.IsOpen) {
            Write-Host ("`r  Elapsed {0} / {1} - SSH is no longer responding.          " -f (Format-Elapsed $elapsed), (Format-Elapsed $TimeoutSeconds)) -ForegroundColor Green
            Update-ConnectionCache -State 'Offline' -Detail 'SSH port stopped responding.' -LatencyMilliseconds $probe.LatencyMilliseconds
            return [pscustomobject]@{ Reached = $true; ElapsedSeconds = $elapsed; LastState = $probe.State }
        }

        Write-Host ("`r  Elapsed {0} / {1} - waiting ({2})...                    " -f (Format-Elapsed $elapsed), (Format-Elapsed $TimeoutSeconds), $lastState) -NoNewline -ForegroundColor Gray

        $now = [DateTime]::UtcNow
        $sleepMilliseconds = [math]::Min($PollSeconds * 1000, [int](($deadline - $now).TotalMilliseconds))
        if ($sleepMilliseconds -gt 0) { Start-Sleep -Milliseconds $sleepMilliseconds }
    }

    Write-Host ''
    $elapsed = [int]([DateTime]::UtcNow - $start).TotalSeconds
    return [pscustomobject]@{ Reached = $false; ElapsedSeconds = $elapsed; LastState = $lastState }
}

# ============================================================================
# SSH argument construction and diagnosis
# ============================================================================

function Test-SshPrerequisites {
    param([switch]$Quiet)

    if (-not $script:SshExe -or -not (Test-Path -LiteralPath $script:SshExe -PathType Leaf)) {
        if (-not $Quiet) {
            Write-UiMessage -Level Error -Message 'OpenSSH client (ssh.exe) was not found. Install the Windows OpenSSH Client feature.'
        }
        return $false
    }
    if (-not $script:SshKeyPath -or -not (Test-Path -LiteralPath $script:SshKeyPath -PathType Leaf)) {
        if (-not $Quiet) {
            Write-UiMessage -Level Error -Message ('SSH private key not found: {0}' -f $script:SshKeyPath)
            Write-UiMessage -Level Info -Message 'Update ssh.keyPath in config.json or create the key at the configured path.'
        }
        return $false
    }
    return $true
}

function Get-SshBaseArguments {
    param(
        [switch]$Interactive,
        [switch]$BatchMode,
        [ValidateSet('yes', 'ask')][string]$HostKeyMode = 'yes',
        [int]$ConnectTimeoutSeconds = 0
    )

    if ($ConnectTimeoutSeconds -le 0) { $ConnectTimeoutSeconds = [int]$script:Config.ssh.connectTimeoutSeconds }

    $sshArguments = @(
        '-i', $script:SshKeyPath,
        '-o', 'IdentitiesOnly=yes',
        '-o', ('ConnectTimeout={0}' -f $ConnectTimeoutSeconds),
        '-o', 'ConnectionAttempts=1',
        '-o', ('ServerAliveInterval={0}' -f $script:Config.ssh.serverAliveIntervalSeconds),
        '-o', ('ServerAliveCountMax={0}' -f $script:Config.ssh.serverAliveCountMax),
        '-o', 'LogLevel=ERROR',
        '-o', ('StrictHostKeyChecking={0}' -f $HostKeyMode),
        '-p', [string]$script:Config.server.sshPort
    )

    if ($Interactive) { $sshArguments += '-tt' } else { $sshArguments += '-T' }
    if ($BatchMode) { $sshArguments += @('-o', 'BatchMode=yes') }

    $sshArguments += ('{0}@{1}' -f $script:Config.server.sshUser, $script:Config.server.ip)
    return $sshArguments
}

function Get-SshFailureKind {
    param(
        [string]$Output,
        [int]$ExitCode
    )

    if ($Output -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|No .* host key is known|host key.*changed') {
        return 'HostKeyFailure'
    }
    if ($Output -match 'Permission denied|Authentication failed|Too many authentication failures') {
        return 'AuthenticationFailed'
    }
    if ($Output -match 'Connection timed out|Operation timed out|connect to host .* port .*: Connection timed out') {
        return 'Timeout'
    }
    if ($Output -match 'Connection refused') { return 'SshUnavailable' }
    if ($Output -match 'No route to host|Network is unreachable') { return 'Offline' }
    if ($Output -match 'Load key .* invalid format|error in libcrypto|bad permissions') { return 'KeyError' }
    if ($ExitCode -eq 255) { return 'Error' }
    return 'Error'
}

function Get-SshStateMessage {
    param([string]$State)
    switch ($State) {
        'Authenticated' { return 'SSH authentication succeeded.' }
        'AuthenticationFailed' { return 'The server is reachable but SSH key authentication failed. Verify the key and user in config.json.' }
        'HostKeyFailure' { return 'SSH host-key verification failed. Do not disable verification; compare and update known_hosts only after verifying the server fingerprint.' }
        'Timeout' { return 'The SSH connection timed out before the server answered.' }
        'SshUnavailable' { return 'The host is reachable but the SSH port is closed.' }
        'Offline' { return 'The server did not respond on the network.' }
        'KeyMissing' { return 'The configured SSH private key was not found.' }
        'SshMissing' { return 'The OpenSSH client was not found.' }
        default { return 'The SSH check failed with an unexpected error.' }
    }
}

function Test-SshLogin {
    param([int]$ConnectTimeoutSeconds = 0)

    if (-not (Test-SshPrerequisites -Quiet)) {
        $state = if (-not $script:SshExe) { 'SshMissing' } else { 'KeyMissing' }
        Update-ConnectionCache -State $state -Detail (Get-SshStateMessage -State $state)
        return [pscustomobject]@{
            State               = $state
            Success             = $false
            Message             = (Get-SshStateMessage -State $state)
            Detail              = ''
            ElapsedMilliseconds = 0
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $tcpProbe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $script:Config.ssh.tcpCheckMilliseconds
    if (-not $tcpProbe.IsOpen) {
        $stopwatch.Stop()
        if ($tcpProbe.State -eq 'Refused') { $state = 'SshUnavailable' }
        elseif ($tcpProbe.State -eq 'Timeout') { $state = 'Timeout' }
        elseif ($tcpProbe.State -eq 'Unreachable') { $state = 'Offline' }
        else { $state = 'Error' }
        Update-ConnectionCache -State $state -Detail $tcpProbe.Message -LatencyMilliseconds $stopwatch.ElapsedMilliseconds
        return [pscustomobject]@{
            State               = $state
            Success             = $false
            Message             = (Get-SshStateMessage -State $state)
            Detail              = $tcpProbe.Message
            ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        }
    }

    $sshArguments = Get-SshBaseArguments -BatchMode -HostKeyMode 'yes' -ConnectTimeoutSeconds $ConnectTimeoutSeconds
    $sshArguments += 'printf "HOMELAB_SSH_OK\n"'
    $output = ''
    $exitCode = -1
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $script:SshExe @sshArguments 2>&1
        $exitCode = $LASTEXITCODE
        $output = ($raw | Out-String)
    }
    catch {
        $output = $_.Exception.Message
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $stopwatch.Stop()

    if ($exitCode -eq 0 -and $output -match 'HOMELAB_SSH_OK') {
        Update-ConnectionCache -State 'Authenticated' -Detail 'SSH key authentication succeeded.' -LatencyMilliseconds $stopwatch.ElapsedMilliseconds
        return [pscustomobject]@{
            State               = 'Authenticated'
            Success             = $true
            Message             = (Get-SshStateMessage -State 'Authenticated')
            Detail              = ''
            ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        }
    }

    $state = Get-SshFailureKind -Output $output -ExitCode $exitCode
    Update-ConnectionCache -State $state -Detail (Get-SshStateMessage -State $state) -LatencyMilliseconds $stopwatch.ElapsedMilliseconds
    return [pscustomobject]@{
        State               = $state
        Success             = $false
        Message             = (Get-SshStateMessage -State $state)
        Detail              = $output.Trim()
        ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        ExitCode            = $exitCode
    }
}
# ============================================================================
# Remote command execution
# ============================================================================

function ConvertTo-RemoteBoundedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [int]$TimeoutSeconds = 30
    )

    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }
    $scriptText = $Script.Trim() + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($scriptText)
    $encoded = [Convert]::ToBase64String($bytes)
    return ("printf '%s' '{0}' | base64 -d | timeout -k 5 {1}s bash" -f $encoded, $TimeoutSeconds)
}

function New-RemoteResult {
    param(
        [bool]$Success = $false,
        [int]$ExitCode = -1,
        [string]$Output = '',
        [string]$Kind = '',
        [string]$Message = '',
        [bool]$TimedOut = $false
    )
    return [pscustomobject]@{
        Success  = $Success
        ExitCode = $ExitCode
        Output   = $Output
        Kind     = $Kind
        Message  = $Message
        TimedOut = $TimedOut
    }
}

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [int]$TimeoutSeconds = 30,
        [string]$Description = 'Remote command',
        [switch]$CaptureOutput,
        [switch]$SuppressFailureMessage
    )

    if (-not (Test-SshPrerequisites)) {
        return (New-RemoteResult -Success $false -Kind 'PrerequisiteFailure' -Message 'SSH client or key is missing.')
    }

    $probe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $script:Config.ssh.tcpCheckMilliseconds
    if (-not $probe.IsOpen) {
        Update-ConnectionCacheFromTcp -Probe $probe
        $reason = $probe.Message
        if (-not $SuppressFailureMessage) {
            Write-UiMessage -Level Error -Message ('{0} skipped. {1}' -f $Description, $reason)
        }
        Write-AppLog -Level 'WARN' -Message ('{0} skipped: {1}' -f $Description, $reason)
        return (New-RemoteResult -Success $false -Kind 'ConnectionUnavailable' -Message $reason)
    }

    $sshArguments = Get-SshBaseArguments -BatchMode -HostKeyMode 'yes'
    $sshArguments += (ConvertTo-RemoteBoundedCommand -Script $Script -TimeoutSeconds $TimeoutSeconds)
    $output = ''
    $exitCode = -1
    $previousErrorActionPreference = $ErrorActionPreference
    if ($CaptureOutput) { $ErrorActionPreference = 'Continue' }
    try {
        if ($CaptureOutput) {
            $raw = & $script:SshExe @sshArguments 2>&1
            $exitCode = $LASTEXITCODE
            $output = ($raw | Out-String).TrimEnd()
        }
        else {
            & $script:SshExe @sshArguments | Out-Host
            $exitCode = $LASTEXITCODE
        }
    }
    catch {
        $message = $_.Exception.Message
        Write-AppLog -Level 'ERROR' -Message ('{0} failed: {1}' -f $Description, $message)
        if (-not $SuppressFailureMessage) { Write-UiMessage -Level Error -Message ('{0} failed: {1}' -f $Description, $message) }
        return (New-RemoteResult -Success $false -Kind 'Error' -Message $message)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -eq 0) {
        Update-ConnectionCache -State 'Authenticated' -Detail 'SSH command completed successfully.' -LatencyMilliseconds $probe.LatencyMilliseconds
        Write-AppLog -Level 'INFO' -Message ('Remote command succeeded: {0}' -f $Description)
        return (New-RemoteResult -Success $true -ExitCode 0 -Output $output -Kind 'Success' -Message 'Completed.')
    }

    if ($exitCode -eq 124) {
        $message = ('Remote command exceeded its {0}-second limit and was interrupted.' -f $TimeoutSeconds)
        Write-AppLog -Level 'WARN' -Message ('{0}: {1}' -f $Description, $message)
        if (-not $SuppressFailureMessage) { Write-UiMessage -Level Warning -Message $message }
        return (New-RemoteResult -Success $false -ExitCode $exitCode -Output $output -Kind 'RemoteTimeout' -Message $message -TimedOut $true)
    }

    if ($exitCode -eq 255) {
        $auth = Test-SshLogin
        $message = ('SSH command failed: {0}' -f $auth.Message)
        if ($auth.Detail) { $message = '{0} Detail: {1}' -f $message, ($auth.Detail -replace "`r?`n", ' ') }
        Write-AppLog -Level 'ERROR' -Message ('{0} failed with SSH error: {1}' -f $Description, $auth.State)
        if (-not $SuppressFailureMessage) { Write-UiMessage -Level Error -Message $message }
        return (New-RemoteResult -Success $false -ExitCode $exitCode -Output $output -Kind $auth.State -Message $message)
    }

    $message = ('Remote command returned exit code {0}.' -f $exitCode)
    Write-AppLog -Level 'WARN' -Message ('{0}: {1}' -f $Description, $message)
    if (-not $SuppressFailureMessage) { Write-UiMessage -Level Warning -Message $message }
    return (New-RemoteResult -Success $false -ExitCode $exitCode -Output $output -Kind 'CommandFailed' -Message $message)
}

function Invoke-RemoteInteractiveCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$Description = 'Interactive remote command'
    )

    if (-not (Test-SshPrerequisites)) { return -1 }

    $probe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $script:Config.ssh.tcpCheckMilliseconds
    if (-not $probe.IsOpen) {
        Update-ConnectionCacheFromTcp -Probe $probe
        Write-UiMessage -Level Error -Message ('Cannot connect. {0}' -f $probe.Message)
        Write-AppLog -Level 'WARN' -Message ('{0} aborted: {1}' -f $Description, $probe.Message)
        return -1
    }

    $sshArguments = Get-SshBaseArguments -Interactive -HostKeyMode 'ask'
    $sshArguments += $Command
    Write-Host ''
    Write-Host ('  {0}' -f $Description) -ForegroundColor Cyan
    Write-Host '  The Debian sudo password is entered only in the SSH prompt. It is never stored.' -ForegroundColor DarkGray
    Write-Host ''
    try {
        & $script:SshExe @sshArguments
        $exitCode = $LASTEXITCODE
    }
    catch {
        $exitCode = -1
        Write-UiMessage -Level Error -Message ('SSH interactive command failed: {0}' -f $_.Exception.Message)
        Write-AppLog -Level 'ERROR' -Message ('{0} failed: {1}' -f $Description, $_.Exception.Message)
        return $exitCode
    }

    Write-AppLog -Level 'INFO' -Message ('{0} ended with exit code {1}.' -f $Description, $exitCode)
    return $exitCode
}

# ============================================================================
# Web dashboards
# ============================================================================

function Get-DashboardDefinition {
    param([Parameter(Mandatory = $true)][string]$Key)
    if ($script:Config.dashboards.ContainsKey($Key)) { return $script:Config.dashboards[$Key] }
    return $null
}

function Get-DashboardUrl {
    param([Parameter(Mandatory = $true)][string]$Key)
    $dashboard = Get-DashboardDefinition -Key $Key
    if (-not $dashboard) { return $null }
    $path = [string]$dashboard.path
    if ([string]::IsNullOrWhiteSpace($path)) { $path = '/' }
    if (-not $path.StartsWith('/')) { $path = '/' + $path }
    return ('{0}://{1}:{2}{3}' -f $dashboard.scheme, $script:Config.server.ip, $dashboard.port, $path)
}

function Test-DashboardPort {
    param([Parameter(Mandatory = $true)][string]$Key)
    $dashboard = Get-DashboardDefinition -Key $Key
    if (-not $dashboard) {
        return [pscustomobject]@{ Key = $Key; Label = $Key; Url = ''; State = 'Missing'; IsReachable = $false; LatencyMilliseconds = 0; Detail = 'Dashboard is not configured.' }
    }
    $probe = Test-TcpPort -ComputerName $script:Config.server.ip -Port ([int]$dashboard.port) -TimeoutMilliseconds $script:Config.ssh.dashboardCheckMilliseconds
    return [pscustomobject]@{
        Key                 = $Key
        Label               = [string]$dashboard.label
        Url                 = (Get-DashboardUrl -Key $Key)
        State               = $probe.State
        IsReachable         = $probe.IsOpen
        LatencyMilliseconds = $probe.LatencyMilliseconds
        Detail              = $probe.Message
    }
}

function Open-Dashboard {
    param([Parameter(Mandatory = $true)][string]$Key)

    $result = Test-DashboardPort -Key $Key
    if (-not $result.IsReachable) {
        Write-UiMessage -Level Warning -Message ('{0} is not reachable on TCP port {1}.' -f $result.Label, $script:Config.dashboards[$Key].port)
        Write-Host ('  URL: {0}' -f $result.Url) -ForegroundColor DarkGray
        Write-Host '  The server may be offline, the service may be stopped, or the port may still be starting.' -ForegroundColor DarkGray
        Write-AppLog -Level 'WARN' -Message ('Dashboard not opened; {0} port unreachable: {1}' -f $Key, $result.Detail)
        return $false
    }

    Write-UiMessage -Level Success -Message ('{0} TCP port {1} is reachable. Opening the dashboard.' -f $result.Label, $script:Config.dashboards[$Key].port)
    if ($script:Config.dashboards[$Key].selfSigned) {
        Write-Host '  A browser certificate warning is expected for this local self-signed HTTPS service.' -ForegroundColor DarkGray
        Write-Host '  Browser security was not disabled. Review the certificate and proceed only if you trust it.' -ForegroundColor DarkGray
    }
    try {
        Start-Process -FilePath $result.Url -ErrorAction Stop | Out-Null
        Write-AppLog -Level 'INFO' -Message ('Opened dashboard {0}: {1}' -f $Key, $result.Url)
        return $true
    }
    catch {
        Write-UiMessage -Level Error -Message ('Could not open the browser: {0}' -f $_.Exception.Message)
        Write-AppLog -Level 'ERROR' -Message ('Could not open dashboard {0}: {1}' -f $Key, $_.Exception.Message)
        return $false
    }
}

function Open-CentralHomepage {
    $probe = Test-DashboardPort -Key 'homepage'
    if ($probe.IsReachable) {
        return (Open-Dashboard -Key 'homepage')
    }

    Write-UiMessage -Level Warning -Message ('The central Homepage is not reachable on TCP port {0}.' -f $script:Config.dashboards.homepage.port)
    Write-Host ('  URL: {0}' -f $probe.Url) -ForegroundColor DarkGray
    Write-Host '  It is safe to start the everyday tools now. Their data is kept.' -ForegroundColor Gray
    if (-not (Read-Confirmation -Message 'Start the everyday tools and open Homepage?' -ExpectedWord 'START')) {
        Write-Host '  Cancelled. Use Everyday tools > Manage everyday tools > Start or repair when ready.' -ForegroundColor DarkGray
        return $false
    }

    Start-CompanionTools
    Write-Host ''
    Write-Host '  Waiting for Homepage to answer...' -ForegroundColor Gray
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        Start-Sleep -Seconds 2
        $retry = Test-DashboardPort -Key 'homepage'
        if ($retry.IsReachable) {
            Write-UiMessage -Level Success -Message 'Homepage is ready. Opening it now.'
            try {
                Start-Process -FilePath $retry.Url -ErrorAction Stop | Out-Null
                Write-AppLog -Level 'INFO' -Message ('Opened central Homepage: {0}' -f $retry.Url)
                return $true
            }
            catch {
                Write-UiMessage -Level Error -Message ('Could not open the browser: {0}' -f $_.Exception.Message)
                return $false
            }
        }
    }

    Write-UiMessage -Level Warning -Message 'Homepage is still starting. Wait a moment, then choose Homepage again.'
    return $false
}

function Show-DashboardCheckTable {
    param([string[]]$Keys)
    foreach ($key in $Keys) {
        $result = Test-DashboardPort -Key $key
        $stateText = if ($result.IsReachable) { 'REACHABLE' } else { 'UNAVAILABLE' }
        $color = if ($result.IsReachable) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
        Write-Host ('  {0,-18} ' -f $result.Label) -NoNewline
        Write-Host ('{0,-12}' -f $stateText) -NoNewline -ForegroundColor $color
        Write-Host (' {0}  [{1} ms]' -f $result.Url, $result.LatencyMilliseconds) -ForegroundColor DarkGray
    }
}

# ============================================================================
# Wake-on-LAN
# ============================================================================

function Convert-MacToBytes {
    param([Parameter(Mandatory = $true)][string]$MacAddress)
    if ($MacAddress -notmatch '^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$') {
        throw "Invalid MAC address: $MacAddress"
    }
    $parts = $MacAddress -split '[:-]'
    $bytes = New-Object byte[] 6
    for ($index = 0; $index -lt 6; $index++) {
        $bytes[$index] = [Convert]::ToByte($parts[$index], 16)
    }
    return ,$bytes
}

function New-MagicPacket {
    param([Parameter(Mandatory = $true)][string]$MacAddress)
    $macBytes = Convert-MacToBytes -MacAddress $MacAddress
    $packet = New-Object byte[] 102
    for ($index = 0; $index -lt 6; $index++) { $packet[$index] = [byte]0xFF }
    for ($repeat = 0; $repeat -lt 16; $repeat++) {
        for ($index = 0; $index -lt 6; $index++) {
            $packet[6 + ($repeat * 6) + $index] = $macBytes[$index]
        }
    }
    return ,$packet
}

function Send-MagicPacket {
    $packet = New-MagicPacket -MacAddress $script:Config.server.mac
    $client = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $client = New-Object System.Net.Sockets.UdpClient
        $client.EnableBroadcast = $true
        [void]$client.Send(
            $packet,
            $packet.Length,
            $script:Config.wakeOnLan.broadcastAddress,
            [int]$script:Config.wakeOnLan.port
        )
        $stopwatch.Stop()
        Write-UiMessage -Level Success -Message ('Magic packet sent to {0} on UDP port {1} ({2} bytes, {3} ms).' -f $script:Config.wakeOnLan.broadcastAddress, $script:Config.wakeOnLan.port, $packet.Length, $stopwatch.ElapsedMilliseconds)
        Write-Host '  Sending the packet only requests a wake; it does not guarantee that the machine powers on.' -ForegroundColor DarkGray
        Write-AppLog -Level 'INFO' -Message ('Wake-on-LAN packet sent to {0} for MAC {1} via {2}:{3}.' -f $script:Config.server.ip, $script:Config.server.mac, $script:Config.wakeOnLan.broadcastAddress, $script:Config.wakeOnLan.port)
        return $true
    }
    catch {
        $stopwatch.Stop()
        Write-UiMessage -Level Error -Message ('Wake-on-LAN packet failed: {0}' -f $_.Exception.Message)
        Write-Host '  Check the Ethernet link, Windows ICS configuration, firewall and broadcast address.' -ForegroundColor DarkGray
        Write-AppLog -Level 'ERROR' -Message ('Wake-on-LAN send failed: {0}' -f $_.Exception.Message)
        return $false
    }
    finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

function Invoke-WakeServer {
    $precheck = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $script:Config.ssh.tcpCheckMilliseconds
    if ($precheck.IsOpen) {
        Write-UiMessage -Level Info -Message 'The server already responds on the SSH port. No magic packet was sent.'
        Update-ConnectionCacheFromTcp -Probe $precheck
        return
    }

    Write-UiMessage -Level Info -Message ('Server is not responding. Sending Wake-on-LAN to MAC {0}.' -f $script:Config.server.mac)
    if (-not (Send-MagicPacket)) { return }

    $attempt = 1
    while ($true) {
        $wait = Wait-ForTcpState -DesiredState 'Open' -TimeoutSeconds $script:Config.wakeOnLan.waitSeconds -Activity ('Waiting up to {0} seconds for SSH to become available (attempt {1})...' -f $script:Config.wakeOnLan.waitSeconds, $attempt) -PollSeconds $script:Config.wakeOnLan.pollIntervalSeconds
        if ($wait.Reached) {
            Write-UiMessage -Level Success -Message ('Server SSH port is available after {0} seconds.' -f $wait.ElapsedSeconds)
            Write-Host '  The machine is powered on and sshd is listening. SSH authentication is checked separately.' -ForegroundColor DarkGray
            Write-AppLog -Level 'INFO' -Message ('Wake-on-LAN succeeded after {0} seconds.' -f $wait.ElapsedSeconds)
            return
        }

        Write-UiMessage -Level Warning -Message ('No SSH response within {0} seconds.' -f $script:Config.wakeOnLan.waitSeconds)
        Write-Host '  Wake-on-LAN can fail if it is disabled in BIOS/NIC, the Ethernet link is down, or the broadcast is blocked.' -ForegroundColor DarkGray
        Write-AppLog -Level 'WARN' -Message ('Wake-on-LAN timed out after {0} seconds.' -f $script:Config.wakeOnLan.waitSeconds)

        $answer = Read-Host '  Retry the wake attempt? [y/N]'
        if ($null -eq $answer -or $answer.Trim() -notmatch '^(?i)y(es)?$') {
            Write-UiMessage -Level Info -Message 'Returning without a confirmed wake.'
            return
        }
        $attempt++
        if (-not (Send-MagicPacket)) { return }
    }
}
# ============================================================================
# Resource snapshot and power management
# ============================================================================

function Get-RemoteResourceSnapshot {
    $remoteScript = @'
free -m | awk '/^Mem:/{printf "MEM|%s|%s|%s\n",$2,$3,$7}'
df -Pk / | awk 'NR==2{printf "DISK|%s|%s|%s\n",$2,$4,$5}'
printf "CPU|%s\n" "$(nproc)"
printf "LOAD|%s\n" "$(cut -d" " -f1-3 /proc/loadavg)"
printf "CONTAINERS|%s\n" "$(docker ps --format "{{.Names}}" 2>/dev/null | tr "\n" ",")"
'@
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 20 -Description 'Read server resource snapshot' -CaptureOutput -SuppressFailureMessage
    $snapshot = [pscustomobject]@{
        Success              = $result.Success
        TotalMemoryMb        = 0
        UsedMemoryMb         = 0
        AvailableMemoryMb    = 0
        DiskTotalKb          = 0
        DiskAvailableKb      = 0
        DiskUsePercent       = ''
        CpuCount             = 0
        LoadAverage          = ''
        RunningContainers    = @()
        Error                = if ($result.Success) { '' } else { $result.Message }
    }
    if (-not $result.Success) { return $snapshot }

    foreach ($line in ($result.Output -split "`r?`n")) {
        $parts = $line -split '\|'
        switch ($parts[0]) {
            'MEM' {
                if ($parts.Count -ge 4) {
                    $snapshot.TotalMemoryMb = [int]$parts[1]
                    $snapshot.UsedMemoryMb = [int]$parts[2]
                    $snapshot.AvailableMemoryMb = [int]$parts[3]
                }
            }
            'DISK' {
                if ($parts.Count -ge 4) {
                    $snapshot.DiskTotalKb = [long]$parts[1]
                    $snapshot.DiskAvailableKb = [long]$parts[2]
                    $snapshot.DiskUsePercent = $parts[3]
                }
            }
            'CPU' { if ($parts.Count -ge 2) { $snapshot.CpuCount = [int]$parts[1] } }
            'LOAD' { if ($parts.Count -ge 2) { $snapshot.LoadAverage = $parts[1] } }
            'CONTAINERS' {
                if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
                    $snapshot.RunningContainers = @($parts[1].Trim(',').Split(',') | Where-Object { $_ })
                }
            }
        }
    }
    return $snapshot
}

function Write-ResourceSnapshot {
    param($Snapshot)
    if (-not $Snapshot.Success) {
        Write-UiMessage -Level Error -Message ('Could not read server resources: {0}' -f $Snapshot.Error)
        return
    }
    Write-Host ('  Memory    {0} MB used / {1} MB total, {2} MB available' -f $Snapshot.UsedMemoryMb, $Snapshot.TotalMemoryMb, $Snapshot.AvailableMemoryMb)
    Write-Host ('  Disk /    {0:N1} GB available of {1:N1} GB ({2} used)' -f ($Snapshot.DiskAvailableKb / 1MB), ($Snapshot.DiskTotalKb / 1MB), $Snapshot.DiskUsePercent)
    Write-Host ('  CPU       {0} threads, load {1}' -f $Snapshot.CpuCount, $Snapshot.LoadAverage)
    if ($Snapshot.RunningContainers.Count -gt 0) {
        Write-Host ('  Running   {0}' -f ($Snapshot.RunningContainers -join ', '))
    }
    else {
        Write-Host '  Running   no Docker containers'
    }
}

function Show-ServerUptime {
    $remoteScript = @'
echo "Host: $(hostname)"
echo "Boot: $(uptime -s)"
echo "Uptime: $(uptime -p)"
echo "Now: $(date "+%Y-%m-%d %H:%M:%S %Z")"
echo "Load: $(cut -d" " -f1-3 /proc/loadavg)"
echo "Logged-in users: $(who | wc -l)"
'@
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 15 -Description 'Read server uptime'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Invoke-ServerShutdown {
    Write-Host ''
    Write-Host '  This will power off the Debian server. Running containers will stop.' -ForegroundColor Yellow
    Write-Host ('  You will be prompted for the Debian sudo password of user {0}.' -f $script:Config.server.sshUser) -ForegroundColor Gray
    Write-Host '  The SSH connection closing immediately afterwards is expected.' -ForegroundColor Gray
    if (-not (Read-Confirmation -Message 'Power off the HP ProDesk server now?' -ExpectedWord 'SHUTDOWN')) { return }

    Write-AppLog -Level 'INFO' -Message 'Administrative action: server shutdown confirmed and issued.'
    Write-Host ''
    Write-Host '  Starting shutdown...' -ForegroundColor Cyan
    $exitCode = Invoke-RemoteInteractiveCommand -Command 'sudo poweroff' -Description 'Requesting Debian shutdown via sudo poweroff'
    if ($exitCode -eq -1) {
        Write-UiMessage -Level Error -Message 'Shutdown could not be initiated.'
        return
    }

    Write-Host ''
    Write-Host ('  SSH ended with exit code {0}. This is expected if the shutdown was accepted.' -f $exitCode) -ForegroundColor DarkGray
    $wait = Wait-ForTcpState -DesiredState 'Closed' -TimeoutSeconds $script:Config.timeouts.shutdownWaitSeconds -Activity ('Waiting up to {0} seconds for the SSH port to close...' -f $script:Config.timeouts.shutdownWaitSeconds) -PollSeconds 2

    if ($wait.Reached) {
        Write-UiMessage -Level Success -Message ('Shutdown confirmed: the server stopped answering after {0} seconds.' -f $wait.ElapsedSeconds)
        Write-AppLog -Level 'INFO' -Message ('Server shutdown confirmed after {0} seconds.' -f $wait.ElapsedSeconds)
    }
    else {
        Write-UiMessage -Level Warning -Message ('The server still answers after {0} seconds. The shutdown may have been cancelled or sudo may have failed.' -f $script:Config.timeouts.shutdownWaitSeconds)
        Write-Host '  Check the SSH output above. Do not power-cycle the server until its state is clear.' -ForegroundColor DarkGray
        Write-AppLog -Level 'WARN' -Message 'Shutdown was not confirmed; SSH port remained open.'
    }
}

function Invoke-ServerReboot {
    Write-Host ''
    Write-Host '  This will restart the Debian server. Running containers will stop briefly.' -ForegroundColor Yellow
    Write-Host ('  You will be prompted for the Debian sudo password of user {0}.' -f $script:Config.server.sshUser) -ForegroundColor Gray
    Write-Host '  The SSH connection closing immediately afterwards is expected.' -ForegroundColor Gray
    if (-not (Read-Confirmation -Message 'Restart the HP ProDesk server now?' -ExpectedWord 'RESTART')) { return }

    Write-AppLog -Level 'INFO' -Message 'Administrative action: server reboot confirmed and issued.'
    Write-Host ''
    Write-Host '  Starting reboot...' -ForegroundColor Cyan
    $exitCode = Invoke-RemoteInteractiveCommand -Command 'sudo reboot' -Description 'Requesting Debian reboot via sudo reboot'
    if ($exitCode -eq -1) {
        Write-UiMessage -Level Error -Message 'Reboot could not be initiated.'
        return
    }

    Write-Host ''
    Write-Host ('  SSH ended with exit code {0}. This is expected if the reboot was accepted.' -f $exitCode) -ForegroundColor DarkGray
    $down = Wait-ForTcpState -DesiredState 'Closed' -TimeoutSeconds $script:Config.timeouts.rebootDownSeconds -Activity ('Waiting up to {0} seconds for the server to go down...' -f $script:Config.timeouts.rebootDownSeconds) -PollSeconds 2
    if (-not $down.Reached) {
        Write-UiMessage -Level Warning -Message 'The SSH port never closed, so the reboot may not have started.'
        Write-Host '  Check the sudo output above. No extended wait will be performed without a confirmed restart.' -ForegroundColor DarkGray
        Write-AppLog -Level 'WARN' -Message 'Reboot was not confirmed because SSH stayed online.'
        return
    }

    $up = Wait-ForTcpState -DesiredState 'Open' -TimeoutSeconds $script:Config.timeouts.rebootReturnSeconds -Activity ('Waiting up to {0} seconds for the rebooted server to return...' -f $script:Config.timeouts.rebootReturnSeconds) -PollSeconds $script:Config.timeouts.rebootPollSeconds
    if (-not $up.Reached) {
        Write-UiMessage -Level Warning -Message ('The server did not return within {0} seconds.' -f $script:Config.timeouts.rebootReturnSeconds)
        Write-Host '  Check the server physically. It may still be booting, or the reboot may have failed.' -ForegroundColor DarkGray
        Write-AppLog -Level 'WARN' -Message 'Reboot timed out waiting for SSH to return.'
        return
    }

    Write-UiMessage -Level Success -Message ('Server SSH port returned after {0} seconds.' -f $up.ElapsedSeconds)
    Write-Host '  Verifying SSH key authentication...' -ForegroundColor Gray
    $auth = Test-SshLogin
    if ($auth.Success) {
        Write-UiMessage -Level Success -Message ('Server rebooted successfully. SSH authentication works ({0} ms).' -f $auth.ElapsedMilliseconds)
        Write-AppLog -Level 'INFO' -Message ('Server reboot verified; SSH returned after {0} seconds.' -f $up.ElapsedSeconds)
    }
    else {
        Write-UiMessage -Level Warning -Message ('SSH port returned, but authentication failed: {0}' -f $auth.Message)
        Write-AppLog -Level 'WARN' -Message ('Reboot returned but SSH authentication failed: {0}' -f $auth.State)
    }
}

# ============================================================================
# Remote terminal (normal Windows user rights, no UAC elevation)
# ============================================================================

function Escape-SingleQuotedString {
    param([string]$Text)
    return ($Text -replace "'", "''")
}

function New-SshLauncherScript {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $script:TempLauncherDir ('ssh-launcher-{0}-{1}.ps1' -f $stamp, [guid]::NewGuid().ToString('N').Substring(0, 8))

    $sshPath = if ($script:SshExe) { $script:SshExe } else { 'ssh.exe' }
    $keyPath = $script:SshKeyPath
    $sshUser = $script:Config.server.sshUser
    $userHost = ('{0}@{1}' -f $script:Config.server.sshUser, $script:Config.server.ip)
    $port = [int]$script:Config.server.sshPort
    $connectTimeout = [int]$script:Config.ssh.connectTimeoutSeconds
    $serverAliveInterval = [int]$script:Config.ssh.serverAliveIntervalSeconds
    $serverAliveCountMax = [int]$script:Config.ssh.serverAliveCountMax

    $template = @'
$ErrorActionPreference = 'Continue'
try { $Host.UI.RawUI.WindowTitle = 'HP ProDesk Homelab - Remote Terminal' } catch { }
Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '        HP PRODESK HOMELAB - REMOTE DEBIAN TERMINAL' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '  This Windows window uses your normal user rights. The Debian session remains user {{SSHUSER}}.' -ForegroundColor Gray
Write-Host '  Use sudo inside Debian when administrative work is required.' -ForegroundColor Gray
Write-Host '  The SSH private key contents are never placed on the command line.' -ForegroundColor DarkGray
Write-Host ''

$ssh = '{{SSH}}'
$key = '{{KEY}}'
$destination = '{{DESTINATION}}'
$port = {{PORT}}
$connectTimeout = {{CONNECT_TIMEOUT}}
$serverAliveInterval = {{ALIVE_INTERVAL}}
$serverAliveCountMax = {{ALIVE_COUNT}}

try {
    if (-not (Test-Path -LiteralPath $ssh -PathType Leaf)) {
        Write-Host 'ERROR: OpenSSH client not found at the configured path.' -ForegroundColor Red
        throw 'ssh.exe is missing'
    }
    if (-not (Test-Path -LiteralPath $key -PathType Leaf)) {
        Write-Host ('ERROR: SSH private key not found: {0}' -f $key) -ForegroundColor Red
        throw 'SSH key is missing'
    }

    Write-Host ('  Connecting to {0} on port {1}...' -f $destination, $port) -ForegroundColor Yellow
    Write-Host '  Type exit to close the Debian shell. This window stays open afterwards.' -ForegroundColor DarkGray
    Write-Host ''

    & $ssh -i $key -o IdentitiesOnly=yes -o ConnectTimeout=$connectTimeout -o ConnectionAttempts=1 -o ServerAliveInterval=$serverAliveInterval -o ServerAliveCountMax=$serverAliveCountMax -o StrictHostKeyChecking=ask -p $port $destination
    $sshExitCode = $LASTEXITCODE

    Write-Host ''
    if ($sshExitCode -eq 0) {
        Write-Host 'Remote Debian session ended normally.' -ForegroundColor Green
    }
    elseif ($sshExitCode -eq 255) {
        Write-Host 'SSH connection ended or failed (exit code 255).' -ForegroundColor Red
        Write-Host 'Check that the server is powered on, the Ethernet/ICS link is up, the host key is correct,' -ForegroundColor Yellow
        Write-Host 'and that the configured private key is authorized for user {{SSHUSER}}.' -ForegroundColor Yellow
        Write-Host 'If a sudo password was requested, authentication was handled by Debian, not by this launcher.' -ForegroundColor Yellow
    }
    else {
        Write-Host ('SSH exited with code {0}.' -f $sshExitCode) -ForegroundColor Yellow
    }
}
catch {
    Write-Host ('Terminal launcher error: {0}' -f $_.Exception.Message) -ForegroundColor Red
}
finally {
    Write-Host ''
    Write-Host 'Press ENTER to close this terminal.' -ForegroundColor DarkGray
    [void](Read-Host)
    try { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue } catch { }
}
'@

    $content = $template
    $content = $content.Replace('{{SSH}}', (Escape-SingleQuotedString -Text $sshPath))
    $content = $content.Replace('{{KEY}}', (Escape-SingleQuotedString -Text $keyPath))
    $content = $content.Replace('{{SSHUSER}}', (Escape-SingleQuotedString -Text $sshUser))
    $content = $content.Replace('{{DESTINATION}}', (Escape-SingleQuotedString -Text $userHost))
    $content = $content.Replace('{{PORT}}', [string]$port)
    $content = $content.Replace('{{CONNECT_TIMEOUT}}', [string]$connectTimeout)
    $content = $content.Replace('{{ALIVE_INTERVAL}}', [string]$serverAliveInterval)
    $content = $content.Replace('{{ALIVE_COUNT}}', [string]$serverAliveCountMax)

    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($true)
    [System.IO.File]::WriteAllText($path, $content, $encoding)
    return $path
}

function Show-RemoteTerminal {
    Write-Host '  A separate Windows PowerShell window will open and start an SSH session.' -ForegroundColor Gray
    Write-Host '  Windows-side elevation is not used; administrative rights stay inside Debian via sudo.' -ForegroundColor Gray
    Write-Host ('  The Debian login remains user {0}; sudo is used only for commands that need it.' -f $script:Config.server.sshUser) -ForegroundColor Gray
    Write-Host ''

    if (-not (Test-SshPrerequisites)) { return }

    $probe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $script:Config.ssh.tcpCheckMilliseconds
    if (-not $probe.IsOpen) {
        Update-ConnectionCacheFromTcp -Probe $probe
        Write-UiMessage -Level Error -Message ('Cannot launch the terminal. {0}' -f $probe.Message)
        Write-Host '  Use Power > Wake server, or check the Ethernet/ICS connection.' -ForegroundColor DarkGray
        return
    }
    Update-ConnectionCacheFromTcp -Probe $probe

    $launcherPath = $null
    try {
        $launcherPath = New-SshLauncherScript
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell.exe' }
        $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $launcherPath
        Start-Process -FilePath $psExe -ArgumentList $argumentLine -WorkingDirectory $script:AppDir -ErrorAction Stop | Out-Null
        Write-UiMessage -Level Success -Message 'Remote terminal launched in a new Windows PowerShell window.'
        Write-AppLog -Level 'INFO' -Message 'Remote terminal launched in a normal Windows PowerShell window (no Windows elevation).'
    }
    catch {
        Write-UiMessage -Level Error -Message ('Could not launch the remote terminal: {0}' -f $_.Exception.Message)
        Write-AppLog -Level 'ERROR' -Message ('Remote terminal launch failed: {0}' -f $_.Exception.Message)
    }
    finally {
        if ($launcherPath -and (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            Write-Host ('  Launcher script: {0}' -f $launcherPath) -ForegroundColor DarkGray
        }
    }
}
# ============================================================================
# System overview and service management
# ============================================================================

function Show-SystemOverview {
    Write-Host '  Reading the server overview (read-only)...' -ForegroundColor Gray
    $remoteScript = @'
echo '=== HOST ==='
hostname
uptime
echo
echo '=== MEMORY ==='
free -h
echo
echo '=== ROOT DISK ==='
df -h /
echo
echo '=== DOCKER ==='
systemctl is-active docker 2>&1
timeout 10 docker info --format 'Server {{.ServerVersion}}; containers {{.ContainersRunning}} running / {{.Containers}} total; images {{.Images}}' 2>&1
echo
echo '=== CONTAINERS ==='
timeout 10 docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1
'@
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 30 -Description 'Read system overview'
    if ($result.Success) {
        Write-Host '  Dashboard TCP availability:' -ForegroundColor DarkGray
        Show-DashboardCheckTable -Keys @('homepage', 'uptimeKuma', 'dozzle', 'wud', 'portainer', 'airflow')
    }
}

function Get-ServiceComposePrefix {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]
    $profileFlags = ''
    foreach ($profile in @($service.profiles)) {
        if (-not [string]::IsNullOrWhiteSpace($profile)) { $profileFlags += (' --profile {0}' -f $profile) }
    }
    return ('cd {0} && docker compose{1}' -f $service.directory, $profileFlags)
}

function Get-ServiceStatusScript {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    return ((Get-ServiceComposePrefix -ServiceKey $ServiceKey) + ' ps')
}

function Get-ServiceLogsScript {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]
    $names = (@($service.logsServiceNames) -join ' ').Trim()
    $command = (Get-ServiceComposePrefix -ServiceKey $ServiceKey) + ' logs --tail=100 --no-color'
    if ($names) { $command += ' ' + $names }
    return $command
}

function Show-ServiceStatus {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]
    Write-Host ('  Querying {0} containers (read-only)...' -f $service.label) -ForegroundColor Gray
    $result = Invoke-RemoteScript -Script (Get-ServiceStatusScript -ServiceKey $ServiceKey) -TimeoutSeconds $script:Config.timeouts.remoteStatusSeconds -Description ('Read {0} status' -f $service.label)
    if (-not $result.Success) { return }

    Write-Host ''
    Write-Host '  Dashboard port availability:' -ForegroundColor DarkGray
    $keys = @($service.dashboards)
    if ($keys.Count -eq 0) {
        Write-Host '  No configured dashboards for this service.' -ForegroundColor DarkGray
    }
    else {
        Show-DashboardCheckTable -Keys $keys
    }
    Write-Host '  A running container does not guarantee that the application inside it is healthy.' -ForegroundColor DarkGray
}

function Show-ServiceLogs {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]
    Write-Host ('  Reading the last 100 log lines from {0}...' -f $service.label) -ForegroundColor Gray
    $result = Invoke-RemoteScript -Script (Get-ServiceLogsScript -ServiceKey $ServiceKey) -TimeoutSeconds $script:Config.timeouts.remoteLogsSeconds -Description ('Read {0} logs' -f $service.label)
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Test-ServiceStartResources {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]
    Write-Host '  Checking server memory before starting...' -ForegroundColor Gray
    $snapshot = Get-RemoteResourceSnapshot
    if (-not $snapshot.Success) {
        Write-UiMessage -Level Error -Message ('Cannot assess server resources: {0}' -f $snapshot.Error)
        Write-UiMessage -Level Warning -Message 'Start cancelled because the server resource state is unknown.'
        return $false
    }

    Write-ResourceSnapshot -Snapshot $snapshot
    Write-Host ''
    $warnings = @()
    if ($snapshot.AvailableMemoryMb -lt ($service.estimatedMemoryMb + 512)) {
        $warnings += ('Available memory ({0} MB) is below the estimated {1} MB need plus a 512 MB safety margin.' -f $snapshot.AvailableMemoryMb, $service.estimatedMemoryMb)
    }

    $airflowRunning = @($snapshot.RunningContainers | Where-Object { $_ -match '^airflow-' }).Count -gt 0
    $sparkRunning = @($snapshot.RunningContainers | Where-Object { $_ -match '^platform-spark|^spark-' }).Count -gt 0
    $platformRunning = @($snapshot.RunningContainers | Where-Object { $_ -match '^platform-' }).Count -gt 0

    if ($ServiceKey -eq 'spark' -and $airflowRunning) {
        $warnings += 'Airflow is already running. Airflow plus a 2 GB Spark worker is a heavy combination on an 8 GB machine.'
    }
    if ($ServiceKey -eq 'airflow' -and ($sparkRunning -or $platformRunning)) {
        $warnings += 'Another data platform stack is running. Airflow plus that stack may exhaust memory on this 8 GB server.'
    }
    if ($ServiceKey -eq 'dataPlatform' -and $sparkRunning) {
        $warnings += 'Spark is running. The data platform and Spark share the platform compose project and both consume memory.'
    }

    if ($warnings.Count -gt 0) {
        Write-Host ''
        foreach ($warningText in $warnings) { Write-UiMessage -Level Warning -Message $warningText }
        Write-Host ''
        if (-not (Read-Confirmation -Message ('Start {0} anyway?' -f $service.label) -ExpectedWord 'START')) {
            Write-AppLog -Level 'INFO' -Message ('Service start cancelled after resource warning: {0}' -f $service.label)
            return $false
        }
    }
    return $true
}

function Start-HomelabService {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]
    if (-not (Test-ServiceStartResources -ServiceKey $ServiceKey)) { return }

    if (-not [string]::IsNullOrWhiteSpace($service.notes)) {
        Write-Host ('  {0}' -f $service.notes) -ForegroundColor DarkGray
    }
    $remoteScript = @"
if [ ! -f {0} ]; then
  echo 'ERROR: Start script not found: {0}'
  exit 3
fi
cd {1} || exit 4
bash {0}
"@ -f $service.startScript, $service.directory

    Write-Host ''
    Write-Host ('  Starting {0}. This may take several minutes...' -f $service.label) -ForegroundColor Cyan
    Write-AppLog -Level 'INFO' -Message ('Administrative action: start service {0}.' -f $service.label)
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds $script:Config.timeouts.remoteStartSeconds -Description ('Start {0}' -f $service.label)
    if ($result.Success) {
        Write-UiMessage -Level Success -Message ('Start command for {0} completed.' -f $service.label)
        Write-Host ''
        Show-ServiceStatus -ServiceKey $ServiceKey
    }
    else {
        Write-UiMessage -Level Error -Message ('Start command for {0} did not complete successfully. {1}' -f $service.label, $result.Message)
    }
}

function Stop-HomelabService {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]
    Write-Host ''
    Write-Host ('  The configured stop script runs docker compose down for {0}.' -f $service.label) -ForegroundColor Yellow
    Write-Host '  Named volumes and bind-mounted data are retained, but containers and the project network are removed.' -ForegroundColor Gray
    if ($ServiceKey -eq 'spark') {
        Write-Host '  Spark shares the platform compose project. The current stop script can also stop data-platform containers.' -ForegroundColor Yellow
        Write-Host '  Check the status afterwards before assuming other platform services are still running.' -ForegroundColor Yellow
    }

    if (-not (Read-Confirmation -Message ('Stop {0}?' -f $service.label) -ExpectedWord 'STOP')) { return }
    $remoteScript = @"
if [ ! -f {0} ]; then
  echo 'ERROR: Stop script not found: {0}'
  exit 3
fi
cd {1} || exit 4
bash {0}
"@ -f $service.stopScript, $service.directory

    Write-AppLog -Level 'INFO' -Message ('Administrative action: stop service {0}.' -f $service.label)
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds $script:Config.timeouts.remoteStopSeconds -Description ('Stop {0}' -f $service.label)
    if ($result.Success) {
        Write-UiMessage -Level Success -Message ('Stop command for {0} completed.' -f $service.label)
        Write-Host ''
        Show-ServiceStatus -ServiceKey $ServiceKey
    }
    else {
        Write-UiMessage -Level Error -Message ('Stop command for {0} did not complete successfully. {1}' -f $service.label, $result.Message)
    }
}

function Restart-HomelabService {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]
    Write-Host ''
    Write-Host ('  Restarting {0} runs its stop script and then its start script.' -f $service.label) -ForegroundColor Yellow
    Write-Host '  Containers will be unavailable while the start sequence runs.' -ForegroundColor Gray
    if ($ServiceKey -eq 'spark') {
        Write-Host '  Spark shares the platform project with data-platform services; a project-wide stop may affect them.' -ForegroundColor Yellow
    }
    if (-not (Read-Confirmation -Message ('Restart {0}?' -f $service.label) -ExpectedWord 'RESTART')) { return }

    $remoteScript = @"
if [ ! -f {0} ]; then echo 'ERROR: Stop script not found: {0}'; exit 3; fi
if [ ! -f {1} ]; then echo 'ERROR: Start script not found: {1}'; exit 3; fi
cd {2} || exit 4
bash {0} || exit 5
bash {1}
"@ -f $service.stopScript, $service.startScript, $service.directory

    Write-AppLog -Level 'INFO' -Message ('Administrative action: restart service {0}.' -f $service.label)
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds ($script:Config.timeouts.remoteStopSeconds + $script:Config.timeouts.remoteStartSeconds) -Description ('Restart {0}' -f $service.label)
    if ($result.Success) {
        Write-UiMessage -Level Success -Message ('Restart command for {0} completed.' -f $service.label)
        Write-Host ''
        Show-ServiceStatus -ServiceKey $ServiceKey
    }
    else {
        Write-UiMessage -Level Error -Message ('Restart command for {0} did not complete successfully. {1}' -f $service.label, $result.Message)
    }
}

function Show-ServiceDashboardMenu {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]
    $keys = @($service.dashboards)
    if ($keys.Count -eq 0) {
        Write-UiMessage -Level Info -Message 'No web dashboards are configured for this service.'
        return
    }

    while ($true) {
        Show-AppHeader -Title ('{0} - WEB INTERFACES' -f $service.label)
        $index = 1
        $indexMap = @{}
        foreach ($key in $keys) {
            $dashboard = Get-DashboardDefinition -Key $key
            Write-MenuOption -Key ([string]$index) -Text ([string]$dashboard.label) -Note (Get-DashboardUrl -Key $key)
            $indexMap[[string]$index] = $key
            $index++
        }
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice
        if ($choice -eq '0') { return }
        if ($indexMap.ContainsKey($choice)) {
            Open-Dashboard -Key $indexMap[$choice] | Out-Null
            Wait-Return
        }
        else {
            Write-UiMessage -Level Warning -Message 'Invalid selection.'
        }
    }
}

function Show-ServiceMenu {
    param([Parameter(Mandatory = $true)][string]$ServiceKey)
    $service = $script:Config.services[$ServiceKey]

    while ($true) {
        Show-AppHeader -Title ('{0} SERVICE MANAGER' -f $service.label.ToUpperInvariant())
        Write-Host ('  {0}' -f $service.notes) -ForegroundColor DarkGray
        Write-Host ''
        Write-MenuOption -Key '1' -Text 'Status and dashboard ports' -Note 'read-only'
        Write-MenuOption -Key '2' -Text 'Start service' -Note 'checks memory first'
        Write-MenuOption -Key '3' -Text 'Stop service' -Note 'confirmation required'
        Write-MenuOption -Key '4' -Text 'Restart service' -Note 'confirmation required'
        Write-MenuOption -Key '5' -Text 'View recent logs' -Note 'read-only'
        if (@($service.dashboards).Count -gt 0) {
            Write-MenuOption -Key '6' -Text 'Open web interface(s)'
        }
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Show-ServiceStatus -ServiceKey $ServiceKey; Wait-Return }
                '2' { Start-HomelabService -ServiceKey $ServiceKey; Wait-Return }
                '3' { Stop-HomelabService -ServiceKey $ServiceKey; Wait-Return }
                '4' { Restart-HomelabService -ServiceKey $ServiceKey; Wait-Return }
                '5' { Show-ServiceLogs -ServiceKey $ServiceKey; Wait-Return }
                '6' { if (@($service.dashboards).Count -gt 0) { Show-ServiceDashboardMenu -ServiceKey $ServiceKey } }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Service menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

function Show-HomelabResourceSnapshot {
    Write-Host '  Reading a lightweight resource snapshot...' -ForegroundColor Gray
    $snapshot = Get-RemoteResourceSnapshot
    if (-not $snapshot.Success) {
        Write-UiMessage -Level Error -Message ('Could not read server resources: {0}' -f $snapshot.Error)
        return
    }
    Write-ResourceSnapshot -Snapshot $snapshot
    Write-Host ''
    Write-Host '  Data-service dashboard ports:' -ForegroundColor DarkGray
    Show-DashboardCheckTable -Keys @('airflow', 'pgAdmin', 'minio', 'sparkMaster', 'sparkWorker')
    Write-Host ''
    if ($snapshot.AvailableMemoryMb -lt 1024) {
        Write-UiMessage -Level Warning -Message 'Less than 1 GB of memory is available. Stop a running stack before starting another.'
    }
    elseif ($snapshot.AvailableMemoryMb -lt 2048) {
        Write-UiMessage -Level Warning -Message 'Memory is tight. Start only one memory-intensive stack at a time on this 8 GB server.'
    }
    else {
        Write-UiMessage -Level Info -Message 'Memory has some headroom, but Airflow, Spark and data-platform workloads still add up quickly.'
    }
}

function Show-DataServicesMenu {
    while ($true) {
        Show-AppHeader -Title 'DATA ENGINEERING SERVICES'
        Write-MenuOption -Key '1' -Text 'Apache Airflow' -Note 'LocalExecutor stack'
        Write-MenuOption -Key '2' -Text 'Data Platform' -Note 'PostgreSQL, pgAdmin, Redis, MinIO'
        Write-MenuOption -Key '3' -Text 'Apache Spark' -Note 'master and worker'
        Write-MenuOption -Key '4' -Text 'Resource and service snapshot' -Note 'read-only'
        Write-MenuOption -Key '5' -Text 'All containers' -Note 'read-only'
        Write-Host ''
        Write-UiMessage -Level Warning -Message 'This server has 8 GB RAM. Do not start every stack at once without reviewing the memory warnings.'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Show-ServiceMenu -ServiceKey 'airflow' }
                '2' { Show-ServiceMenu -ServiceKey 'dataPlatform' }
                '3' { Show-ServiceMenu -ServiceKey 'spark' }
                '4' { Show-HomelabResourceSnapshot; Wait-Return }
                '5' {
                    $result = Invoke-RemoteScript -Script 'timeout 15 docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"' -TimeoutSeconds 25 -Description 'List all containers'
                    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
                    Wait-Return
                }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Data services menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}
# ============================================================================
# Docker management
# ============================================================================

function Show-DockerContainers {
    param([switch]$All)
    $command = if ($All) {
        'timeout 15 docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
    }
    else {
        'timeout 15 docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
    }
    $label = if ($All) { 'all containers' } else { 'running containers' }
    Write-Host ('  Listing {0} (read-only)...' -f $label) -ForegroundColor Gray
    $result = Invoke-RemoteScript -Script $command -TimeoutSeconds 25 -Description ('List {0}' -f $label)
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Show-DockerContainerStatus {
    $container = Read-ContainerReference
    if (-not $container) { return }
    $remoteScript = "docker inspect --format 'Name={{.Name}} State={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} Image={{.Config.Image}} RestartCount={{.RestartCount}} Started={{.State.StartedAt}} Finished={{.State.FinishedAt}}' '$container' 2>&1"
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 20 -Description ('Inspect container {0}' -f $container)
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Show-DockerContainerLogs {
    $container = Read-ContainerReference
    if (-not $container) { return }
    $tailText = Read-Host '  Number of log lines (1-1000, default 100)'
    if ([string]::IsNullOrWhiteSpace($tailText)) { $tailText = '100' }
    $tail = 0
    if (-not [int]::TryParse($tailText.Trim(), [ref]$tail) -or $tail -lt 1 -or $tail -gt 1000) {
        Write-UiMessage -Level Error -Message 'Log line count must be an integer from 1 to 1000.'
        return
    }

    $remoteScript = "timeout 20 docker logs --tail $tail '$container' 2>&1"
    Write-Host ('  Reading {0} log lines from {1}...' -f $tail, $container) -ForegroundColor Gray
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 30 -Description ('Read logs for container {0}' -f $container)
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Invoke-DockerContainerAction {
    param(
        [ValidateSet('start', 'stop', 'restart')][string]$Action
    )
    $container = Read-ContainerReference
    if (-not $container) { return }

    if ($Action -eq 'stop') {
        if (-not (Read-Confirmation -Message ('Stop container {0}? This interrupts the service but does not delete its data.' -f $container) -ExpectedWord 'STOP')) { return }
    }
    elseif ($Action -eq 'restart') {
        if (-not (Read-Confirmation -Message ('Restart container {0}? The service will be interrupted briefly.' -f $container) -ExpectedWord 'RESTART')) { return }
    }

    $remoteScript = switch ($Action) {
        'start' { "docker start '$container' 2>&1" }
        'stop' { "docker stop --time 20 '$container' 2>&1" }
        'restart' { "docker restart --time 20 '$container' 2>&1" }
    }
    Write-AppLog -Level 'INFO' -Message ('Administrative action: docker {0} {1}.' -f $Action, $container)
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 60 -Description ('Docker {0} {1}' -f $Action, $container)
    if (-not $result.Success) {
        Write-UiMessage -Level Error -Message ('Docker {0} failed. {1}' -f $Action, $result.Message)
        return
    }

    Write-UiMessage -Level Success -Message ('Docker {0} command completed for {1}.' -f $Action, $container)
    $inspect = Invoke-RemoteScript -Script ("docker inspect --format '{{.State.Status}}' '$container' 2>&1") -TimeoutSeconds 15 -Description ('Verify container {0}' -f $container) -CaptureOutput -SuppressFailureMessage
    if ($inspect.Success) {
        Write-Host ('  Current state: {0}' -f $inspect.Output) -ForegroundColor Gray
    }
}

function Show-DockerImages {
    $result = Invoke-RemoteScript -Script 'timeout 15 docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}"' -TimeoutSeconds 25 -Description 'List Docker images'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Test-ImageReference {
    param([string]$Reference)
    if ([string]::IsNullOrWhiteSpace($Reference)) { return $false }
    return ($Reference -match '^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,254}$')
}

function Read-ImageReference {
    $value = Read-Host '  Image reference (repository:tag or image ID)'
    if ($null -eq $value) { return $null }
    $value = $value.Trim()
    if (Test-ImageReference -Reference $value) { return $value }
    Write-UiMessage -Level Error -Message 'Invalid image reference. Use letters, digits, dot, underscore, slash, colon, at-sign or hyphen only.'
    return $null
}

function Stop-AllDockerContainers {
    Write-Host '  Reading the list of running containers...' -ForegroundColor Gray
    $preflight = Invoke-RemoteScript -Script 'docker ps --format "{{.Names}}"' -TimeoutSeconds 20 -Description 'List running containers before stop-all' -CaptureOutput -SuppressFailureMessage
    if (-not $preflight.Success) {
        Write-UiMessage -Level Error -Message ('Could not list running containers: {0}' -f $preflight.Message)
        return
    }

    $names = @($preflight.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($names.Count -eq 0) {
        Write-UiMessage -Level Info -Message 'No running containers to stop.'
        return
    }

    Write-Host ''
    Write-Host ('  The following {0} running container(s) will stop:' -f $names.Count) -ForegroundColor Yellow
    foreach ($name in ($names | Select-Object -First 30)) {
        Write-Host ('    - {0}' -f $name) -ForegroundColor Gray
    }
    if ($names.Count -gt 30) { Write-Host ('    ... and {0} more' -f ($names.Count - 30)) -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  This stops every service, including Portainer, Airflow, databases and data tools.' -ForegroundColor Yellow
    Write-Host '  Container data and named volumes are not deleted.' -ForegroundColor Gray
    if (-not (Read-Confirmation -Message 'Stop ALL running Docker containers now?' -ExpectedWord 'STOP-ALL')) { return }

    Write-AppLog -Level 'INFO' -Message ('Administrative action: stop all running Docker containers ({0} at prompt).' -f $names.Count)
    $remoteScript = @'
ids=$(docker ps -q) || exit 5
if [ -z "$ids" ]; then
  echo 'No running containers.'
  exit 0
fi
docker stop --time 20 $ids
'@
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 180 -Description 'Stop all running Docker containers'
    if (-not $result.Success) {
        Write-UiMessage -Level Error -Message ('Stop-all did not complete successfully. {0}' -f $result.Message)
        return
    }

    Write-UiMessage -Level Success -Message 'All running containers were asked to stop.'
    Write-Host ''
    Show-DockerContainers
}

function Invoke-DockerImagePull {
    $image = Read-ImageReference
    if (-not $image) { return }
    if ($image -match '^[0-9a-fA-F]{12,64}$') {
        Write-UiMessage -Level Error -Message 'Pull requires a repository reference such as nginx:latest, not an image ID.'
        return
    }

    Write-Host ('  Pulling/updating image {0}...' -f $image) -ForegroundColor Cyan
    Write-Host '  Running containers keep their current image until they are recreated.' -ForegroundColor DarkGray
    Write-AppLog -Level 'INFO' -Message ('Administrative action: docker pull {0}.' -f $image)
    $remoteScript = "docker pull '{0}' 2>&1" -f $image
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds $script:Config.timeouts.remoteImagePullSeconds -Description ('Pull Docker image {0}' -f $image)
    if ($result.Success) {
        Write-UiMessage -Level Success -Message ('Image {0} was pulled successfully.' -f $image)
    }
    else {
        Write-UiMessage -Level Error -Message ('Docker pull failed for {0}. {1}' -f $image, $result.Message)
    }
}

function Invoke-DockerImageRemove {
    $image = Read-ImageReference
    if (-not $image) { return }

    Write-Host ''
    Write-Host ('  Removing image {0} cannot be forced from this menu.' -f $image) -ForegroundColor Yellow
    Write-Host '  Docker refuses to remove an image that is still used by a container. Stop that container first.' -ForegroundColor Gray
    if (-not (Read-Confirmation -Message ('Remove Docker image {0}?' -f $image) -ExpectedWord 'REMOVE')) { return }

    Write-AppLog -Level 'INFO' -Message ('Administrative action: docker image rm {0}.' -f $image)
    $remoteScript = "docker image rm '{0}' 2>&1" -f $image
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 120 -Description ('Remove Docker image {0}' -f $image)
    if ($result.Success) {
        Write-UiMessage -Level Success -Message ('Image {0} was removed.' -f $image)
        Write-Host ''
        Show-DockerImages
    }
    else {
        Write-UiMessage -Level Error -Message ('Docker image removal failed. The image may still be in use. {0}' -f $result.Message)
    }
}

function Invoke-DockerImagePrune {
    param([switch]$All)
    if ($All) {
        Write-Host ''
        Write-Host '  This removes every Docker image not used by an existing container.' -ForegroundColor Yellow
        Write-Host '  Images for stopped services are included and must be pulled again before those services start.' -ForegroundColor Yellow
        Write-Host '  Images used by running containers are retained.' -ForegroundColor Gray
        $word = 'PRUNE-ALL'
        $message = 'Remove ALL unused Docker images now?'
        $scriptText = 'docker image prune -a -f 2>&1'
        $description = 'Prune all unused Docker images'
    }
    else {
        Write-Host ''
        Write-Host '  This removes only dangling (untagged) Docker images and unused layers.' -ForegroundColor Yellow
        Write-Host '  Images referenced by a tag are retained.' -ForegroundColor Gray
        $word = 'PRUNE'
        $message = 'Remove dangling Docker images now?'
        $scriptText = 'docker image prune -f 2>&1'
        $description = 'Prune dangling Docker images'
    }

    if (-not (Read-Confirmation -Message $message -ExpectedWord $word)) { return }
    Write-AppLog -Level 'INFO' -Message ('Administrative action: {0}.' -f $description)
    $result = Invoke-RemoteScript -Script $scriptText -TimeoutSeconds 300 -Description $description
    if ($result.Success) {
        Write-UiMessage -Level Success -Message ('{0} completed.' -f $description)
    }
    else {
        Write-UiMessage -Level Error -Message ('{0} failed. {1}' -f $description, $result.Message)
    }
}

function Show-DockerImageMenu {
    while ($true) {
        Show-AppHeader -Title 'DOCKER IMAGE MANAGEMENT'
        Write-MenuOption -Key '1' -Text 'List all images' -Note 'read-only'
        Write-MenuOption -Key '2' -Text 'Pull or update an image' -Note 'repository:tag'
        Write-MenuOption -Key '3' -Text 'Remove an image' -Note 'confirmation required'
        Write-MenuOption -Key '4' -Text 'Remove dangling images' -Note 'safe cleanup'
        Write-MenuOption -Key '5' -Text 'Remove ALL unused images' -Note 'aggressive cleanup'
        Write-MenuOption -Key '6' -Text 'Docker disk usage' -Note 'read-only'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Show-DockerImages; Wait-Return }
                '2' { Invoke-DockerImagePull; Wait-Return }
                '3' { Invoke-DockerImageRemove; Wait-Return }
                '4' { Invoke-DockerImagePrune; Wait-Return }
                '5' { Invoke-DockerImagePrune -All; Wait-Return }
                '6' { Show-DockerDiskUsage; Wait-Return }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Docker image menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

function Show-DockerVolumes {
    $result = Invoke-RemoteScript -Script 'timeout 15 docker volume ls' -TimeoutSeconds 25 -Description 'List Docker volumes'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
    Write-Host '  Volumes may contain persistent data. This screen is read-only.' -ForegroundColor DarkGray
}

function Show-DockerNetworks {
    $result = Invoke-RemoteScript -Script 'timeout 15 docker network ls' -TimeoutSeconds 25 -Description 'List Docker networks'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Show-DockerDiskUsage {
    $result = Invoke-RemoteScript -Script 'timeout 20 docker system df -v' -TimeoutSeconds 30 -Description 'Read Docker disk usage'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
    Write-Host '  This is a read-only report. Cleanup and deletion are under Docker image management.' -ForegroundColor DarkGray
}

function Show-DockerStats {
    Write-Host '  Reading a one-shot Docker resource snapshot...' -ForegroundColor Gray
    $result = Invoke-RemoteScript -Script 'timeout 20 docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"' -TimeoutSeconds 30 -Description 'Read Docker resource statistics'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Show-DockerDaemonStatus {
    $result = Invoke-RemoteScript -Script 'systemctl is-active docker 2>&1; echo; timeout 10 docker info --format "Server {{.ServerVersion}}; containers {{.ContainersRunning}} running / {{.Containers}} total; images {{.Images}}; storage {{.Driver}}" 2>&1' -TimeoutSeconds 25 -Description 'Read Docker daemon status'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Restart-DockerDaemon {
    Write-Host ''
    Write-Host '  Restarting the Docker daemon interrupts every running container.' -ForegroundColor Yellow
    Write-Host '  This is a service interruption, not a data-removal operation. Named volumes are preserved.' -ForegroundColor Gray
    Write-Host ('  The Debian sudo password of {0} may be requested.' -f $script:Config.server.sshUser) -ForegroundColor Gray
    if (-not (Read-Confirmation -Message 'Restart the Docker daemon now?' -ExpectedWord 'RESTART-DOCKER')) { return }

    Write-AppLog -Level 'INFO' -Message 'Administrative action: Docker daemon restart confirmed.'
    $exitCode = Invoke-RemoteInteractiveCommand -Command 'sudo systemctl restart docker' -Description 'Restarting Docker daemon via sudo'
    if ($exitCode -eq 0) {
        Write-UiMessage -Level Success -Message 'Docker daemon restart command completed. Verifying daemon state...'
        Show-DockerDaemonStatus
    }
    elseif ($exitCode -eq -1) {
        Write-UiMessage -Level Error -Message 'Docker daemon restart could not be initiated.'
    }
    else {
        Write-UiMessage -Level Warning -Message ('Docker daemon restart returned exit code {0}. Verify the daemon state below.' -f $exitCode)
        Show-DockerDaemonStatus
    }
}

function Show-DockerMenu {
    while ($true) {
        Show-AppHeader -Title 'DOCKER MANAGEMENT'
        Write-MenuOption -Key '1' -Text 'Running containers' -Note 'read-only'
        Write-MenuOption -Key '2' -Text 'All containers' -Note 'read-only'
        Write-MenuOption -Key '3' -Text 'Container status' -Note 'read-only'
        Write-MenuOption -Key '4' -Text 'Container logs' -Note 'read-only'
        Write-MenuOption -Key '5' -Text 'Start container'
        Write-MenuOption -Key '6' -Text 'Stop container' -Note 'interrupts service'
        Write-MenuOption -Key '7' -Text 'Stop ALL containers' -Note 'STOP-ALL confirmation'
        Write-MenuOption -Key '8' -Text 'Restart container' -Note 'interrupts service'
        Write-MenuOption -Key '9' -Text 'Docker image management' -Note 'list, pull, remove, prune'
        Write-MenuOption -Key '10' -Text 'Docker volumes' -Note 'read-only'
        Write-MenuOption -Key '11' -Text 'Docker networks' -Note 'read-only'
        Write-MenuOption -Key '12' -Text 'Docker disk usage' -Note 'read-only'
        Write-MenuOption -Key '13' -Text 'Resource statistics snapshot' -Note 'read-only'
        Write-MenuOption -Key '14' -Text 'Docker daemon status' -Note 'read-only'
        Write-MenuOption -Key '15' -Text 'Restart Docker daemon' -Note 'confirmation required'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Show-DockerContainers; Wait-Return }
                '2' { Show-DockerContainers -All; Wait-Return }
                '3' { Show-DockerContainerStatus; Wait-Return }
                '4' { Show-DockerContainerLogs; Wait-Return }
                '5' { Invoke-DockerContainerAction -Action 'start'; Wait-Return }
                '6' { Invoke-DockerContainerAction -Action 'stop'; Wait-Return }
                '7' { Stop-AllDockerContainers; Wait-Return }
                '8' { Invoke-DockerContainerAction -Action 'restart'; Wait-Return }
                '9' { Show-DockerImageMenu }
                '10' { Show-DockerVolumes; Wait-Return }
                '11' { Show-DockerNetworks; Wait-Return }
                '12' { Show-DockerDiskUsage; Wait-Return }
                '13' { Show-DockerStats; Wait-Return }
                '14' { Show-DockerDaemonStatus; Wait-Return }
                '15' { Restart-DockerDaemon; Wait-Return }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Docker menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

# ============================================================================
# Web dashboard menu
# ============================================================================

function Show-WebMenu {
    while ($true) {
        Show-AppHeader -Title 'WEB DASHBOARDS'
        Write-MenuOption -Key '1' -Text 'Homepage' -Note 'central dashboard'
        Write-MenuOption -Key '2' -Text 'Uptime Kuma'
        Write-MenuOption -Key '3' -Text 'Dozzle' -Note 'live container logs'
        Write-MenuOption -Key '4' -Text 'WUD' -Note 'available image updates'
        Write-MenuOption -Key '5' -Text 'Portainer' -Note 'HTTPS, self-signed certificate'
        Write-MenuOption -Key '6' -Text 'Apache Airflow'
        Write-MenuOption -Key '7' -Text 'pgAdmin'
        Write-MenuOption -Key '8' -Text 'MinIO console'
        Write-MenuOption -Key '9' -Text 'Spark Master UI'
        Write-MenuOption -Key '10' -Text 'Open Portainer and Airflow'
        Write-MenuOption -Key '11' -Text 'Test all dashboard ports' -Note 'read-only'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Open-Dashboard -Key 'homepage' | Out-Null; Wait-Return }
                '2' { Open-Dashboard -Key 'uptimeKuma' | Out-Null; Wait-Return }
                '3' { Open-Dashboard -Key 'dozzle' | Out-Null; Wait-Return }
                '4' { Open-Dashboard -Key 'wud' | Out-Null; Wait-Return }
                '5' { Open-Dashboard -Key 'portainer' | Out-Null; Wait-Return }
                '6' { Open-Dashboard -Key 'airflow' | Out-Null; Wait-Return }
                '7' { Open-Dashboard -Key 'pgAdmin' | Out-Null; Wait-Return }
                '8' { Open-Dashboard -Key 'minio' | Out-Null; Wait-Return }
                '9' { Open-Dashboard -Key 'sparkMaster' | Out-Null; Wait-Return }
                '10' {
                    $null = Open-Dashboard -Key 'portainer'
                    $null = Open-Dashboard -Key 'airflow'
                    Wait-Return
                }
                '11' {
                    Show-DashboardCheckTable -Keys @('homepage', 'uptimeKuma', 'dozzle', 'wud', 'portainer', 'airflow', 'pgAdmin', 'minio', 'sparkMaster', 'sparkWorker')
                    Write-Host '  Reachable TCP ports do not prove that the application inside is healthy.' -ForegroundColor DarkGray
                    Wait-Return
                }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Web menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}
# ============================================================================
# Everyday tools (companion stack)
# ============================================================================

function Get-CompanionComposeStatusScript {
    $companion = $script:Config.companion
    return ('cd {0} && docker compose ps' -f $companion.directory)
}

function Show-CompanionStatus {
    $companion = $script:Config.companion
    Write-Host ('  Checking {0} (read-only)...' -f $companion.label) -ForegroundColor Gray
    $result = Invoke-RemoteScript -Script (Get-CompanionComposeStatusScript) -TimeoutSeconds $script:Config.timeouts.remoteStatusSeconds -Description ('Read {0} status' -f $companion.label)
    if (-not $result.Success) { return }

    Write-Host ''
    Write-Host '  Web interfaces:' -ForegroundColor DarkGray
    Show-DashboardCheckTable -Keys @($companion.dashboards)
    Write-Host '  A running container does not guarantee that the page inside it is healthy.' -ForegroundColor DarkGray
}

function Show-EverydayStatus {
    Write-Host '  Checking the everyday services (read-only)...' -ForegroundColor Gray
    $ssh = Test-SshLogin
    if ($ssh.Success) {
        Write-Host '  Server login      OK - SSH key authentication works.' -ForegroundColor Green
    }
    else {
        Write-Host ('  Server login      DOWN - {0}' -f $ssh.Message) -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '  Web pages:' -ForegroundColor DarkGray
    Show-DashboardCheckTable -Keys @('homepage', 'airflow', 'portainer', 'uptimeKuma', 'dozzle', 'wud')
    Write-Host ''
    Write-Host '  GREEN / REACHABLE means the page answered on its port.' -ForegroundColor Green
    Write-Host '  RED / UNAVAILABLE means stopped, offline, or still starting.' -ForegroundColor Red
    Write-Host '  If Homepage or monitoring is red: Everyday tools > Manage everyday tools > Start.' -ForegroundColor DarkGray
    Write-Host '  If Airflow is red: Data engineering services > Apache Airflow > Start service.' -ForegroundColor DarkGray
}

function Show-EverydayHelp {
    Write-Host ''
    Write-Host '  WHAT TO DO FIRST' -ForegroundColor Cyan
    Write-Host '    1. Open the Homepage dashboard for one page with every service.' -ForegroundColor Gray
    Write-Host '       Its Help and Docs section has the same guide in the browser.' -ForegroundColor Gray
    Write-Host '    2. If something seems broken, choose Check everything now.' -ForegroundColor Gray
    Write-Host '    3. If a tool is red, open Manage everyday tools and choose Start or repair.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  WHAT EACH TOOL DOES' -ForegroundColor Cyan
    Write-Host '    Homepage    - friendly buttons to every service.' -ForegroundColor Gray
    Write-Host '    Uptime Kuma - green/red checks. The first visit asks you to create a local account.' -ForegroundColor Gray
    Write-Host '    Dozzle      - live logs. Useful when you need to show an error message.' -ForegroundColor Gray
    Write-Host '    WUD         - lists available container updates. It does not install them by itself.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  REMOTE ACCESS FROM OUTSIDE THE HOUSE' -ForegroundColor Cyan
    Write-Host '    Choose Remote access (Tailscale) > Install and connect.' -ForegroundColor Gray
    Write-Host '    Install Tailscale on your phone or laptop and sign in to the same account.' -ForegroundColor Gray
    Write-Host '    Then use the server Tailscale address instead of the home address.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  SAFE FOR EVERYONE' -ForegroundColor Green
    Write-Host '    Opening pages, checking status, starting/repairing tools and reading logs.' -ForegroundColor Gray
    Write-Host '  ASK AN ADULT' -ForegroundColor Yellow
    Write-Host '    Power management, Docker stop-all, deleting images and pruning data.' -ForegroundColor Gray
    Write-Host '    Stopping or updating Everyday tools asks you to type a confirmation word.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  PASSWORDS' -ForegroundColor Cyan
    Write-Host '    WUD: Manage everyday tools > Show WUD login details.' -ForegroundColor Gray
    Write-Host '    Uptime Kuma: create your own account on its first visit. This app does not store it.' -ForegroundColor Gray
    Write-Host '    Portainer and Airflow: use the passwords from your original setup notes.' -ForegroundColor Gray
}

function Start-CompanionTools {
    $companion = $script:Config.companion
    Write-Host '  Checking server memory before starting...' -ForegroundColor Gray
    $snapshot = Get-RemoteResourceSnapshot
    if (-not $snapshot.Success) {
        Write-UiMessage -Level Error -Message ('Cannot assess server resources: {0}' -f $snapshot.Error)
        return
    }
    Write-ResourceSnapshot -Snapshot $snapshot
    Write-Host ''
    if ($snapshot.AvailableMemoryMb -lt ($companion.estimatedMemoryMb + 512)) {
        Write-UiMessage -Level Warning -Message ('Available memory is {0} MB; the everyday tools normally need about {1} MB plus a safety margin.' -f $snapshot.AvailableMemoryMb, $companion.estimatedMemoryMb)
        if (-not (Read-Confirmation -Message 'Start the everyday tools anyway?' -ExpectedWord 'START')) { return }
    }

    $remoteScript = @"
if [ ! -f {0} ]; then
  echo 'ERROR: Start script not found: {0}'
  exit 3
fi
cd {1} || exit 4
bash {0}
"@ -f $companion.startScript, $companion.directory

    Write-Host ('  Starting {0}...' -f $companion.label) -ForegroundColor Cyan
    Write-AppLog -Level 'INFO' -Message ('Administrative action: start {0}.' -f $companion.label)
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds $script:Config.timeouts.remoteStartSeconds -Description ('Start {0}' -f $companion.label)
    if ($result.Success) {
        Write-UiMessage -Level Success -Message ('{0} start command completed.' -f $companion.label)
        Write-Host ''
        Show-CompanionStatus
    }
    else {
        Write-UiMessage -Level Error -Message ('{0} did not start successfully. {1}' -f $companion.label, $result.Message)
    }
}

function Stop-CompanionTools {
    $companion = $script:Config.companion
    Write-Host ''
    Write-Host ('  This stops {0}.' -f $companion.label) -ForegroundColor Yellow
    Write-Host '  Homepage, Uptime Kuma, Dozzle and WUD will be unavailable. Their data is kept.' -ForegroundColor Gray
    Write-Host '  Airflow, Portainer and the data services are not touched.' -ForegroundColor Gray
    if (-not (Read-Confirmation -Message ('Stop {0}?' -f $companion.label) -ExpectedWord 'STOP-TOOLS')) { return }

    $remoteScript = @"
if [ ! -f {0} ]; then
  echo 'ERROR: Stop script not found: {0}'
  exit 3
fi
cd {1} || exit 4
bash {0}
"@ -f $companion.stopScript, $companion.directory

    Write-AppLog -Level 'INFO' -Message ('Administrative action: stop {0}.' -f $companion.label)
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds $script:Config.timeouts.remoteStopSeconds -Description ('Stop {0}' -f $companion.label)
    if ($result.Success) {
        Write-UiMessage -Level Success -Message ('{0} stopped. Data volumes were kept.' -f $companion.label)
    }
    else {
        Write-UiMessage -Level Error -Message ('{0} did not stop cleanly. {1}' -f $companion.label, $result.Message)
    }
}

function Update-CompanionTools {
    $companion = $script:Config.companion
    Write-Host ''
    Write-Host ('  This pulls newer images and recreates {0}.' -f $companion.label) -ForegroundColor Yellow
    Write-Host '  Homepage, Uptime Kuma, Dozzle and WUD restart briefly. Their data is kept.' -ForegroundColor Gray
    Write-Host '  Airflow, Portainer and the data services are not touched.' -ForegroundColor Gray
    if (-not (Read-Confirmation -Message 'Update the everyday tools now?' -ExpectedWord 'UPDATE-TOOLS')) { return }

    $remoteScript = @"
if [ ! -f {0} ]; then
  echo 'ERROR: Update script not found: {0}'
  exit 3
fi
cd {1} || exit 4
bash {0}
"@ -f $companion.updateScript, $companion.directory

    Write-AppLog -Level 'INFO' -Message ('Administrative action: update {0}.' -f $companion.label)
    $timeout = $script:Config.timeouts.remoteImagePullSeconds + $script:Config.timeouts.remoteStopSeconds
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds $timeout -Description ('Update {0}' -f $companion.label)
    if ($result.Success) {
        Write-UiMessage -Level Success -Message ('{0} update completed.' -f $companion.label)
        Write-Host ''
        Show-CompanionStatus
    }
    else {
        Write-UiMessage -Level Error -Message ('{0} update did not complete successfully. {1}' -f $companion.label, $result.Message)
    }
}

function Show-CompanionCredentials {
    $companion = $script:Config.companion
    $remoteScript = "grep -E '^(WUD_AUTH_ADMIN_USER|WUD_AUTH_ADMIN_PASSWORD)=' {0} 2>/dev/null || true" -f $companion.envFile
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 20 -Description 'Read WUD login details' -CaptureOutput -SuppressFailureMessage
    if (-not $result.Success -or [string]::IsNullOrWhiteSpace($result.Output)) {
        Write-UiMessage -Level Warning -Message 'WUD login details could not be read from the server.'
        return
    }

    $user = $null
    $password = $null
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^WUD_AUTH_ADMIN_USER=(.+)$') { $user = $Matches[1] }
        elseif ($line -match '^WUD_AUTH_ADMIN_PASSWORD=(.+)$') { $password = $Matches[1] }
    }

    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($password)) {
        Write-UiMessage -Level Warning -Message 'WUD login details are incomplete in the server env file.'
        return
    }

    Write-Host ''
    Write-Host '  WUD login:' -ForegroundColor Cyan
    Write-Host ('    Username: {0}' -f $user) -ForegroundColor Gray
    Write-Host ('    Password: {0}' -f $password) -ForegroundColor Gray
    Write-Host '  Keep this private. The password is stored only in the server .env file.' -ForegroundColor DarkGray
    Write-Host '  Uptime Kuma uses the account you created on its first-run setup page.' -ForegroundColor DarkGray
}

function Show-MonitoringMenu {
    while ($true) {
        Show-AppHeader -Title 'MONITORING & LIVE LOGS'
        Write-MenuOption -Key '1' -Text 'Uptime Kuma' -Note 'green/red service checks'
        Write-MenuOption -Key '2' -Text 'Dozzle' -Note 'live container logs'
        Write-MenuOption -Key '3' -Text 'WUD' -Note 'available image updates'
        Write-MenuOption -Key '4' -Text 'Check monitoring ports' -Note 'read-only'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Open-Dashboard -Key 'uptimeKuma' | Out-Null; Wait-Return }
                '2' { Open-Dashboard -Key 'dozzle' | Out-Null; Wait-Return }
                '3' { Open-Dashboard -Key 'wud' | Out-Null; Wait-Return }
                '4' { Show-DashboardCheckTable -Keys @('uptimeKuma', 'dozzle', 'wud'); Wait-Return }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Monitoring menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

function Show-CompanionManagerMenu {
    while ($true) {
        Show-AppHeader -Title 'EVERYDAY TOOLS - MANAGE'
        Write-MenuOption -Key '1' -Text 'Status' -Note 'read-only'
        Write-MenuOption -Key '2' -Text 'Start or repair' -Note 'safe'
        Write-MenuOption -Key '3' -Text 'Stop' -Note 'STOP-TOOLS confirmation'
        Write-MenuOption -Key '4' -Text 'Update images' -Note 'UPDATE-TOOLS confirmation'
        Write-MenuOption -Key '5' -Text 'Show WUD login details'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Show-CompanionStatus; Wait-Return }
                '2' { Start-CompanionTools; Wait-Return }
                '3' { Stop-CompanionTools; Wait-Return }
                '4' { Update-CompanionTools; Wait-Return }
                '5' { Show-CompanionCredentials; Wait-Return }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Everyday tools manager error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

function Show-TailscaleStatus {
    $remoteScript = @'
if command -v tailscale >/dev/null 2>&1; then
  echo 'Tailscale: installed'
  systemctl is-active tailscaled 2>&1 || true
  echo
  tailscale status 2>&1 || true
  echo
  echo 'Tailscale IPv4:'
  tailscale ip -4 2>&1 || true
else
  echo 'Tailscale: not installed'
  echo 'Use the Connect option in this menu to install it.'
fi
'@
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 25 -Description 'Read Tailscale status'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Connect-Tailscale {
    $companion = $script:Config.companion
    Write-Host ''
    Write-Host '  This installs Tailscale if needed, then opens a login URL.' -ForegroundColor Yellow
    Write-Host '  Sign in to Tailscale in the browser and approve this server.' -ForegroundColor Gray
    Write-Host '  The Debian sudo password may be requested in this window.' -ForegroundColor Gray
    Write-Host '  No Tailscale password is stored by this app.' -ForegroundColor Gray
    if (-not (Read-Confirmation -Message 'Install and connect Tailscale now?' -ExpectedWord 'CONNECT')) { return }

    Write-AppLog -Level 'INFO' -Message 'Administrative action: install/connect Tailscale.'
    $exitCode = Invoke-RemoteInteractiveCommand -Command ('bash {0}' -f $companion.tailscaleScript) -Description 'Install and connect Tailscale'
    if ($exitCode -eq 0) {
        Write-UiMessage -Level Success -Message 'Tailscale setup command completed.'
    }
    else {
        Write-UiMessage -Level Warning -Message ('Tailscale setup returned exit code {0}. Check the messages above.' -f $exitCode)
    }
    Write-Host ''
    Show-TailscaleStatus
}

function Show-TailscaleMenu {
    while ($true) {
        Show-AppHeader -Title 'REMOTE ACCESS - TAILSCALE'
        Write-Host '  Reach this server from outside the house without opening router ports.' -ForegroundColor DarkGray
        Write-Host '  Install Tailscale on your laptop or phone too, then use the server Tailscale IP.' -ForegroundColor DarkGray
        Write-Host ''
        Write-MenuOption -Key '1' -Text 'Show Tailscale status' -Note 'read-only'
        Write-MenuOption -Key '2' -Text 'Install and connect' -Note 'browser login + sudo'
        Write-MenuOption -Key '3' -Text 'Open Tailscale admin page' -Note 'browser'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Show-TailscaleStatus; Wait-Return }
                '2' { Connect-Tailscale; Wait-Return }
                '3' {
                    Start-Process -FilePath 'https://login.tailscale.com/admin/machines' -ErrorAction Stop | Out-Null
                    Write-UiMessage -Level Info -Message 'Opened the Tailscale admin page.'
                    Wait-Return
                }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Tailscale menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

function Show-EverydayToolsMenu {
    while ($true) {
        Show-AppHeader -Title 'EVERYDAY TOOLS'
        Write-Host '  Start here. Green means working; red means stopped or offline.' -ForegroundColor DarkGray
        Write-Host ''
        Write-MenuOption -Key '1' -Text 'Open central Homepage' -Note 'everything in one place'
        Write-MenuOption -Key '2' -Text 'Check everything now' -Note 'green/red status'
        Write-MenuOption -Key '3' -Text 'Open Airflow'
        Write-MenuOption -Key '4' -Text 'Open Portainer'
        Write-MenuOption -Key '5' -Text 'Monitoring and live logs' -Note 'Uptime Kuma, Dozzle, WUD'
        Write-MenuOption -Key '6' -Text 'Manage everyday tools' -Note 'start, stop, update'
        Write-MenuOption -Key '7' -Text 'Remote access (Tailscale)' -Note 'outside-home access'
        Write-MenuOption -Key '8' -Text 'Help - what do I do?' -Note 'plain-language guide'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { $null = Open-CentralHomepage; Wait-Return }
                '2' { Show-EverydayStatus; Wait-Return }
                '3' { Open-Dashboard -Key 'airflow' | Out-Null; Wait-Return }
                '4' { Open-Dashboard -Key 'portainer' | Out-Null; Wait-Return }
                '5' { Show-MonitoringMenu }
                '6' { Show-CompanionManagerMenu }
                '7' { Show-TailscaleMenu }
                '8' { Show-EverydayHelp; Wait-Return }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Everyday tools menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

# ============================================================================
# Network and power menus
# ============================================================================

function ConvertTo-UInt32 {
    param([Parameter(Mandatory = $true)][string]$IpAddress)
    $ip = [Net.IPAddress]::None
    if (-not [Net.IPAddress]::TryParse($IpAddress, [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Invalid IPv4 address: $IpAddress"
    }
    $bytes = $ip.GetAddressBytes()
    return [uint32](([uint64]$bytes[0] -shl 24) -bor ([uint64]$bytes[1] -shl 16) -bor ([uint64]$bytes[2] -shl 8) -bor [uint64]$bytes[3])
}

function ConvertTo-DottedDecimal {
    param([Parameter(Mandatory = $true)][uint32]$Value)
    return ('{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 255), (($Value -shr 16) -band 255), (($Value -shr 8) -band 255), ($Value -band 255))
}

function ConvertTo-SubnetMask {
    param([Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength)
    if ($PrefixLength -eq 0) { return [uint32]0 }
    return [uint32](([uint64]4294967295 -shl (32 - $PrefixLength)) -band [uint64]4294967295)
}

function Get-SubnetInfo {
    param([Parameter(Mandatory = $true)][string]$IpAddress, [Parameter(Mandatory = $true)][ValidateRange(0, 32)][int]$PrefixLength, [int]$MaxHosts = 1024)
    $ipValue = ConvertTo-UInt32 -IpAddress $IpAddress
    $mask = ConvertTo-SubnetMask -PrefixLength $PrefixLength
    $network = [uint32]($ipValue -band $mask)
    $broadcast = [uint32](([uint64]$network) -bor ([uint64]4294967295 -bxor [uint64]$mask))
    $usable = if ($PrefixLength -ge 31) { 1 } else { [int]([uint64]$broadcast - [uint64]$network - 1) }
    $first = if ($PrefixLength -ge 31) { $network } else { [uint32]($network + 1) }
    $take = [Math]::Min($usable, [Math]::Max(1, $MaxHosts))
    $hosts = @()
    for ($i = 0; $i -lt $take; $i++) { $hosts += ConvertTo-DottedDecimal -Value ([uint32]($first + $i)) }
    return [pscustomobject]@{ NetworkAddress = (ConvertTo-DottedDecimal $network); BroadcastAddress = (ConvertTo-DottedDecimal $broadcast); SubnetMask = (ConvertTo-DottedDecimal $mask); UsableHostCount = $usable; Hosts = $hosts; HostsTruncated = ($usable -gt $take) }
}

function Get-MacPrefix {
    param([string]$Mac)
    $normalized = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{12}$') { return $null }
    return $normalized.Substring(0, 6)
}

function Get-MacVendor {
    param([string]$Mac)
    $prefix = Get-MacPrefix -Mac $Mac
    $vendors = @{ '9CB654' = 'HP Inc.'; '3C86A9' = 'Cisco Systems, Inc.' }
    if ($prefix -and $vendors.ContainsKey($prefix)) { return $vendors[$prefix] }
    return $null
}

function Get-SshStatusFromTcp {
    param([string]$TcpState)
    switch ($TcpState.ToLowerInvariant()) { 'open' { 'SSH Available' }; 'closed' { 'SSH Unavailable' }; default { 'Unknown / Timeout' } }
}

function ConvertFrom-ArpOutput {
    param([string]$Text)
    $devices = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9A-Fa-f-]{17})\s+') {
            $ip = $Matches[1]; $mac = $Matches[2].ToUpperInvariant()
            if ($mac -ne 'FF-FF-FF-FF-FF-FF' -and $ip -notmatch '^(224|239)\.') { $devices[$ip] = $mac }
        }
    }
    return $devices
}

function Get-SshCommand {
    param([Parameter(Mandatory = $true)][string]$Target, [string]$User = $script:SSHUser)
    return ('ssh {0}@{1}' -f $User, $Target)
}

function Get-KnownDevices {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try { return ,@((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)) } catch { return ,@() }
}

function Save-KnownDevice {
    param([Parameter(Mandatory = $true)]$Device, [Parameter(Mandatory = $true)][string]$Path)
    $entry = [pscustomobject]@{ ip = $Device.IpAddress; hostname = $Device.Hostname; mac = $Device.MacAddress; vendor = $Device.Vendor; label = $Device.Label; note = $Device.Note }
    $items = @(Get-KnownDevices -Path $Path | Where-Object { $_.ip -ne $entry.ip }) + $entry
    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $items | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $entry
}

function Get-AliveHosts {
    param([string[]]$IpList, [int]$TimeoutMs = 500, [int]$BatchSize = 16)
    $alive = @()
    foreach ($ip in @($IpList)) {
        try { if ((New-Object Net.NetworkInformation.Ping).Send($ip, $TimeoutMs).Status -eq [Net.NetworkInformation.IPStatus]::Success) { $alive += $ip } } catch { }
    }
    return $alive
}

function Get-TcpPortStates {
    param([string[]]$IpList, [Parameter(Mandatory = $true)][int]$Port, [int]$TimeoutMs = 1200, [int]$BatchSize = 16)
    $states = @{}
    foreach ($ip in @($IpList)) { $states[$ip] = Test-TcpPort -ComputerName $ip -Port $Port -TimeoutMs $TimeoutMs }
    return $states
}

function Get-Hostnames {
    param([string[]]$IpList, [int]$TimeoutMs = 1500, [int]$BatchSize = 16)
    $hosts = @{}
    foreach ($ip in @($IpList)) { try { $hosts[$ip] = [Net.Dns]::GetHostEntry($ip).HostName } catch { $hosts[$ip] = $null } }
    return $hosts
}

function Get-LanDevices {
    param($Subnet, [int]$SshPort = 22, [int]$PingTimeoutMs = 500, [int]$TcpTimeoutMs = 1200, [int]$BatchSize = 16)
    $alive = @(Get-AliveHosts -IpList @($Subnet.Hosts) -TimeoutMs $PingTimeoutMs -BatchSize $BatchSize)
    if ($alive.Count -eq 0) { return @() }
    $states = Get-TcpPortStates -IpList $alive -Port $SshPort -TimeoutMs $TcpTimeoutMs -BatchSize $BatchSize
    $names = Get-Hostnames -IpList $alive -BatchSize $BatchSize
    $arp = ConvertFrom-ArpOutput -Text ((arp -a) -join "`n")
    return ,@($alive | ForEach-Object { [pscustomobject]@{ IpAddress = $_; Hostname = $names[$_]; MacAddress = $arp[$_]; Vendor = (Get-MacVendor $arp[$_]); SshState = $states[$_]; SshStatus = (Get-SshStatusFromTcp $states[$_]) } })
}

function Get-LocalIPv4Subnet {
    $candidate = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixLength -gt 0 } | Select-Object -First 1
    if (-not $candidate) { return (Get-SubnetInfo -IpAddress '127.0.0.1' -PrefixLength 32) }
    $subnet = Get-SubnetInfo -IpAddress $candidate.IPAddress -PrefixLength $candidate.PrefixLength
    $subnet | Add-Member -NotePropertyName InterfaceAlias -NotePropertyValue $candidate.InterfaceAlias
    $subnet | Add-Member -NotePropertyName Cidr -NotePropertyValue ('{0}/{1}' -f $candidate.IPAddress, $candidate.PrefixLength)
    return $subnet
}

function Find-ReachExecutable {
    # Detection is deliberately read-only: PATH command first, then the
    # standard installation location, then each remaining PATH directory.
    $pathCommand = Get-Command -Name 'reach' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($pathCommand -and (Test-Path -LiteralPath $pathCommand.Source -PathType Leaf)) {
        return $pathCommand.Source
    }

    $standardPath = 'C:\Program Files\Reach\reach.exe'
    if (Test-Path -LiteralPath $standardPath -PathType Leaf) {
        return $standardPath
    }

    foreach ($directory in @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        try {
            $candidate = Join-Path -Path $directory.Trim() -ChildPath 'reach.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
        catch {
            # Ignore malformed PATH entries; the standard path was already checked.
        }
    }

    return $null
}

function Invoke-ReachLaunch {
    $reachExe = Find-ReachExecutable
    if (-not $reachExe) {
        Write-UiMessage -Level Error -Message 'Reach SSH client was not found.'
        Write-Host '  Checked the reach command on PATH, C:\Program Files\Reach\reach.exe, and PATH directories.' -ForegroundColor DarkGray
        return $false
    }

    try {
        $process = Start-Process -FilePath $reachExe -PassThru -ErrorAction Stop
        Write-UiMessage -Level Success -Message ('Reach launched successfully. PID: {0}' -f $process.Id)
        Write-Host ('  Executable: {0}' -f $reachExe) -ForegroundColor DarkGray
        $reachConnection = '{0}@{1}:{2}' -f $script:Config.server.sshUser, $script:Config.server.ip, $script:Config.server.sshPort
        Write-Host ''
        Write-Host '  In Reach, paste this in the "Where to?" box:' -ForegroundColor Cyan
        Write-Host ('  {0}' -f $reachConnection) -ForegroundColor Green
        Write-Host ('  Private-key file: {0}' -f $script:SshKeyPath) -ForegroundColor DarkGray
        Write-Host '  If Reach asks for a password, use your private-key passphrase only.' -ForegroundColor DarkGray
        return $true
    }
    catch {
        Write-UiMessage -Level Error -Message ('Could not launch Reach: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Show-LanDiscoveryMenu {
    Show-AppHeader -Title 'LAN DEVICE DISCOVERY'
    try {
        $subnet = Get-LocalIPv4Subnet
        Write-Host ('  Scanning {0} ({1} host addresses; {2})...' -f $subnet.Cidr, $subnet.Hosts.Count, $(if ($subnet.HostsTruncated) { 'scan limited' } else { 'full range' })) -ForegroundColor Gray
        $devices = @(Get-LanDevices -Subnet $subnet -SshPort $script:Config.server.sshPort)
        if ($devices.Count -eq 0) { Write-UiMessage -Level Info -Message 'No responding devices were found.'; return }
        $devices | Format-Table IpAddress, Hostname, MacAddress, Vendor, SshStatus -AutoSize | Out-Host
    }
    catch {
        Write-UiMessage -Level Error -Message ('LAN discovery failed: {0}' -f $_.Exception.Message)
    }
}

function Show-NetworkMenu {
    while ($true) {
        Show-AppHeader -Title 'NETWORK & WAKE-ON-LAN'
        Write-MenuOption -Key '1' -Text 'Wake server (Wake-on-LAN)' -Note 'bounded wait'
        Write-MenuOption -Key '2' -Text 'Diagnose SSH connectivity' -Note 'full authentication check'
        Write-MenuOption -Key '3' -Text 'Test all server ports' -Note 'read-only'
        Write-MenuOption -Key '4' -Text 'Show SSH connection command' -Note 'no key contents'
        Write-MenuOption -Key '5' -Text 'Show network configuration'
        Write-MenuOption -Key '6' -Text 'Show server network interfaces' -Note 'read-only'
        Write-MenuOption -Key '7' -Text 'Refresh connection status'
        Write-MenuOption -Key '8' -Text 'Discover LAN devices' -Note 'read-only network scan'
        Write-MenuOption -Key '9' -Text 'Launch Reach (SSH Client)' -Note 'opens installed client'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Invoke-WakeServer; Wait-Return }
                '2' {
                    Write-Host '  Running TCP preflight and SSH key authentication check...' -ForegroundColor Gray
                    $auth = Test-SshLogin
                    if ($auth.Success) {
                        Write-UiMessage -Level Success -Message ('{0} ({1} ms)' -f $auth.Message, $auth.ElapsedMilliseconds)
                    }
                    else {
                        Write-UiMessage -Level Error -Message $auth.Message
                        if ($auth.Detail) { Write-Host ('  Detail: {0}' -f ($auth.Detail -replace "`r?`n", ' ')) -ForegroundColor DarkGray }
                        Write-Host '  Host-key verification is never disabled by this application.' -ForegroundColor DarkGray
                    }
                    Wait-Return
                }
                '3' {
                    $targets = @(
                        @{ Label = 'SSH'; Port = [int]$script:Config.server.sshPort },
                        @{ Label = 'Portainer'; Port = [int]$script:Config.dashboards.portainer.port },
                        @{ Label = 'Airflow'; Port = [int]$script:Config.dashboards.airflow.port },
                        @{ Label = 'pgAdmin'; Port = [int]$script:Config.dashboards.pgAdmin.port },
                        @{ Label = 'MinIO'; Port = [int]$script:Config.dashboards.minio.port },
                        @{ Label = 'Spark Master'; Port = [int]$script:Config.dashboards.sparkMaster.port },
                        @{ Label = 'Spark Worker'; Port = [int]$script:Config.dashboards.sparkWorker.port }
                    )
                    Write-Host '  Testing configured TCP ports...' -ForegroundColor Gray
                    foreach ($target in $targets) {
                        $probe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $target.Port -TimeoutMilliseconds $script:Config.ssh.dashboardCheckMilliseconds
                        $stateText = if ($probe.IsOpen) { 'OPEN' } elseif ($probe.State -eq 'Refused') { 'CLOSED' } else { 'NO RESPONSE' }
                        $color = if ($probe.IsOpen) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
                        Write-Host ('  {0,-14} TCP {1,-5} ' -f $target.Label, $target.Port) -NoNewline
                        Write-Host ('{0,-12}' -f $stateText) -NoNewline -ForegroundColor $color
                        Write-Host (' {0} ms' -f $probe.LatencyMilliseconds) -ForegroundColor DarkGray
                    }
                    Write-Host '  A closed port can mean the server is offline or that the service is stopped.' -ForegroundColor DarkGray
                    Wait-Return
                }
                '4' {
                    Write-Host ''
                    Write-Host '  Use this command in a normal terminal to verify the host key or troubleshoot SSH:' -ForegroundColor Gray
                    Write-Host ('  ssh -i "{0}" -o IdentitiesOnly=yes -o ConnectTimeout={1} -o StrictHostKeyChecking=ask -p {2} {3}@{4}' -f $script:SshKeyPath, $script:Config.ssh.connectTimeoutSeconds, $script:Config.server.sshPort, $script:Config.server.sshUser, $script:Config.server.ip) -ForegroundColor White
                    Write-Host '  The command prints only the key path. Private-key contents are never displayed.' -ForegroundColor DarkGray
                    Wait-Return
                }
                '5' {
                    Write-Host ''
                    Write-Host ('  Server IP        {0}' -f $script:Config.server.ip)
                    Write-Host ('  SSH port         {0}' -f $script:Config.server.sshPort)
                    Write-Host ('  SSH user         {0}' -f $script:Config.server.sshUser)
                    Write-Host ('  SSH key path     {0}' -f $script:SshKeyPath)
                    Write-Host ('  MAC address      {0}' -f $script:Config.server.mac)
                    Write-Host ('  WoL broadcast    {0}:{1}' -f $script:Config.wakeOnLan.broadcastAddress, $script:Config.wakeOnLan.port)
                    Write-Host ('  WoL wait         {0} seconds' -f $script:Config.wakeOnLan.waitSeconds)
                    Write-Host ('  Windows gateway  {0}' -f $script:Config.network.gateway)
                    Write-Host ('  Config file      {0}' -f $script:ConfigPath)
                    Wait-Return
                }
                '6' {
                    $remoteScript = @'
echo '=== INTERFACES ==='
ip -brief address
echo
echo '=== ROUTES ==='
ip route
echo
echo '=== DNS ==='
resolvectl status 2>/dev/null | sed -n '1,30p' || cat /etc/resolv.conf
'@
                    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 15 -Description 'Read server network interfaces'
                    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
                    Wait-Return
                }
                '7' {
                    Write-Host '  Refreshing TCP connection status...' -ForegroundColor Gray
                    $probe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $script:Config.ssh.tcpCheckMilliseconds
                    Update-ConnectionCacheFromTcp -Probe $probe
                    $display = Get-ConnectionDisplay -Cache $script:ConnectionCache
                    Write-UiMessage -Level Info -Message ('Current state: {0}' -f $display.Text)
                    Wait-Return
                }
                '8' { Show-LanDiscoveryMenu; Wait-Return }
                '9' { Invoke-ReachLaunch; Wait-Return }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Network menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

function Show-PowerMenu {
    while ($true) {
        Show-AppHeader -Title 'POWER MANAGEMENT'
        Write-MenuOption -Key '1' -Text 'Wake server' -Note 'Wake-on-LAN'
        Write-MenuOption -Key '2' -Text 'Shut down server' -Note 'type SHUTDOWN'
        Write-MenuOption -Key '3' -Text 'Restart server' -Note 'type RESTART'
        Write-MenuOption -Key '4' -Text 'Show server uptime' -Note 'read-only'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Invoke-WakeServer; Wait-Return }
                '2' { Invoke-ServerShutdown; Wait-Return }
                '3' { Invoke-ServerReboot; Wait-Return }
                '4' { Show-ServerUptime; Wait-Return }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Power menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

# ============================================================================
# Diagnostics
# ============================================================================

function Show-SshDiagnostics {
    Write-Host '  Checking TCP reachability and SSH key authentication...' -ForegroundColor Gray
    Write-Host ''
    Write-Host ('  SSH client      {0}' -f $(if ($script:SshExe) { $script:SshExe } else { 'NOT FOUND' }))
    Write-Host ('  Private key     {0}' -f $(if ($script:SshKeyPath) { $script:SshKeyPath } else { 'NOT CONFIGURED' }))
    Write-Host ('  Key exists      {0}' -f (Test-Path -LiteralPath $script:SshKeyPath -PathType Leaf))
    Write-Host ('  Target          {0}@{1}:{2}' -f $script:Config.server.sshUser, $script:Config.server.ip, $script:Config.server.sshPort)
    Write-Host '  Host-key policy StrictHostKeyChecking=yes for automated checks (never disabled)' -ForegroundColor DarkGray
    Write-Host ''
    $auth = Test-SshLogin
    if ($auth.Success) {
        Write-UiMessage -Level Success -Message ('{0} ({1} ms)' -f $auth.Message, $auth.ElapsedMilliseconds)
    }
    else {
        Write-UiMessage -Level Error -Message $auth.Message
        if ($auth.Detail) {
            Write-Host '  SSH detail (no private-key contents):' -ForegroundColor DarkGray
            Write-Host ('  {0}' -f ($auth.Detail -replace "`r?`n", ' ')) -ForegroundColor DarkGray
        }
    }
}

function Show-FullDiagnostics {
    Write-Host '  Collecting a local and remote diagnostic snapshot (read-only)...' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  === LOCAL APPLICATION ===' -ForegroundColor Cyan
    Write-Host ('  Version          {0}' -f $script:AppVersion)
    Write-Host ('  PowerShell       {0}' -f $PSVersionTable.PSVersion.ToString())
    Write-Host ('  Config           {0}' -f $script:ConfigPath)
    Write-Host ('  Log              {0}' -f $script:LogFile)
    Write-Host ('  SSH client       {0}' -f $(if ($script:SshExe) { $script:SshExe } else { 'NOT FOUND' }))
    Write-Host ('  SSH key file     {0}' -f $(if (Test-Path -LiteralPath $script:SshKeyPath -PathType Leaf) { 'present' } else { 'MISSING' }))
    Write-Host ''
    Write-Host '  === LOCAL DASHBOARD PORTS ===' -ForegroundColor Cyan
    Show-DashboardCheckTable -Keys @('portainer', 'airflow', 'pgAdmin', 'minio', 'sparkMaster', 'sparkWorker')
    Write-Host ''

    $airflowDirectory = $script:Config.services.airflow.directory
    $platformDirectory = $script:Config.services.dataPlatform.directory
    $platformProfiles = @(
        @($script:Config.services.dataPlatform.profiles) + @($script:Config.services.spark.profiles) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    $platformProfileFlags = ''
    foreach ($profile in $platformProfiles) { $platformProfileFlags += (' --profile {0}' -f $profile) }

    $remoteScript = @"
echo '=== HOST ==='
hostname
uptime
printf 'Boot: '; uptime -s
echo
echo '=== CPU / LOAD ==='
printf 'CPU threads: '; nproc
LC_ALL=C top -bn1 | sed -n '1,5p'
echo
echo '=== MEMORY ==='
free -h
echo
echo '=== STORAGE ==='
df -h /
df -i / | tail -1
echo
echo '=== NETWORK ==='
ip -brief address
ip route | sed -n '1,10p'
printf 'Gateway ping: '
timeout 3 ping -c 2 -W 1 $($script:Config.network.gateway) >/dev/null 2>&1 && echo reachable || echo no-icmp-response
printf 'DNS resolution: '
timeout 5 getent hosts $($script:Config.network.dnsCheckHost) >/dev/null 2>&1 && echo ok || echo failed
echo
echo '=== DOCKER ==='
systemctl is-active docker 2>&1
timeout 10 docker info --format 'Server {{.ServerVersion}}; containers {{.ContainersRunning}} running / {{.Containers}} total; images {{.Images}}' 2>&1
echo
echo '=== RUNNING CONTAINERS ==='
timeout 10 docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1
echo
echo '=== AIRFLOW COMPOSE ==='
cd $airflowDirectory 2>/dev/null && timeout 10 docker compose ps 2>&1
echo
echo '=== PLATFORM COMPOSE ==='
cd $platformDirectory 2>/dev/null && timeout 10 docker compose$platformProfileFlags ps -a 2>&1
echo
echo '=== FAILED SYSTEMD UNITS ==='
systemctl --failed --no-pager --no-legend 2>&1 | sed -n '1,20p'
echo
echo '=== RECENT SYSTEM ERRORS ==='
journalctl -p err -n 25 --no-pager 2>&1 | tail -30
"@
    Write-Host '  === REMOTE SERVER ===' -ForegroundColor Cyan
    $result = Invoke-RemoteScript -Script $remoteScript -TimeoutSeconds 60 -Description 'Run full remote diagnostics' -CaptureOutput
    if ($result.Success) {
        Write-Host $result.Output
    }
    else {
        Write-UiMessage -Level Error -Message $result.Message
    }
    Write-Host ''
    Write-Host '  Diagnostic commands are read-only. Journal output may be limited by Debian permissions.' -ForegroundColor DarkGray
}

function Show-FailedServices {
    $result = Invoke-RemoteScript -Script 'systemctl --failed --no-pager' -TimeoutSeconds 20 -Description 'List failed systemd units'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
}

function Show-RecentErrors {
    $result = Invoke-RemoteScript -Script 'journalctl -p err -n 40 --no-pager 2>&1 | tail -60' -TimeoutSeconds 20 -Description 'Read recent system errors'
    if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
    Write-Host ('  Only journal entries readable by user {0} are shown.' -f $script:Config.server.sshUser) -ForegroundColor DarkGray
}

function Show-ServiceStatusSummary {
    foreach ($serviceKey in @('airflow', 'dataPlatform', 'spark')) {
        $service = $script:Config.services[$serviceKey]
        Write-Host ''
        Write-Host ('  === {0} ===' -f $service.label.ToUpperInvariant()) -ForegroundColor Cyan
        $result = Invoke-RemoteScript -Script (Get-ServiceStatusScript -ServiceKey $serviceKey) -TimeoutSeconds $script:Config.timeouts.remoteStatusSeconds -Description ('Read {0} status' -f $service.label) -SuppressFailureMessage
        if (-not $result.Success) { Write-UiMessage -Level Error -Message $result.Message }
    }
    Write-Host ''
    Write-Host '  Dashboard port availability:' -ForegroundColor DarkGray
    Show-DashboardCheckTable -Keys @('airflow', 'pgAdmin', 'minio', 'sparkMaster', 'sparkWorker')
}

function Show-DiagnosticsMenu {
    while ($true) {
        Show-AppHeader -Title 'DIAGNOSTICS & LOGS'
        Write-MenuOption -Key '1' -Text 'Full diagnostics report' -Note 'read-only'
        Write-MenuOption -Key '2' -Text 'SSH connection diagnosis' -Note 'read-only'
        Write-MenuOption -Key '3' -Text 'Server uptime and boot time' -Note 'read-only'
        Write-MenuOption -Key '4' -Text 'CPU, memory and disk snapshot' -Note 'read-only'
        Write-MenuOption -Key '5' -Text 'Docker daemon and container status' -Note 'read-only'
        Write-MenuOption -Key '6' -Text 'Service status summary' -Note 'read-only'
        Write-MenuOption -Key '7' -Text 'Failed systemd services' -Note 'read-only'
        Write-MenuOption -Key '8' -Text 'Recent system errors' -Note 'read-only'
        Write-MenuOption -Key '9' -Text 'Recent application log lines'
        Write-MenuOption -Key '10' -Text 'Open application log in Notepad'
        Write-MenuOption -Key '11' -Text 'Run application self-test'
        Write-Host ''
        Write-MenuOption -Key '0' -Text 'Back'
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { Show-FullDiagnostics; Wait-Return }
                '2' { Show-SshDiagnostics; Wait-Return }
                '3' { Show-ServerUptime; Wait-Return }
                '4' {
                    $snapshot = Get-RemoteResourceSnapshot
                    if ($snapshot.Success) {
                        Write-ResourceSnapshot -Snapshot $snapshot
                        Show-DashboardCheckTable -Keys @('portainer', 'airflow', 'pgAdmin', 'minio', 'sparkMaster', 'sparkWorker')
                    }
                    else {
                        Write-UiMessage -Level Error -Message ('Could not read server resources: {0}' -f $snapshot.Error)
                    }
                    Wait-Return
                }
                '5' { Show-DockerDaemonStatus; Wait-Return }
                '6' { Show-ServiceStatusSummary; Wait-Return }
                '7' { Show-FailedServices; Wait-Return }
                '8' { Show-RecentErrors; Wait-Return }
                '9' { Show-LogTail -Lines 30; Wait-Return }
                '10' { Open-AppLog; Wait-Return }
                '11' { [void](Invoke-ApplicationSelfTest); Wait-Return }
                '0' { return }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Diagnostics menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}
# ============================================================================
# Application self-test
# ============================================================================

function Add-SelfTestResult {
    param(
        [Parameter(Mandatory = $true)]$Results,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('PASS', 'FAIL', 'SKIP', 'WARN')][string]$Status,
        [string]$Detail = ''
    )
    [void]$Results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

function Invoke-ApplicationSelfTest {
    $results = New-Object System.Collections.ArrayList
    Write-Host ''
    Write-Rule -Character '=' -Color Cyan
    Write-Host ('  APPLICATION SELF-TEST - {0} v{1}' -f $script:AppName, $script:AppVersion) -ForegroundColor Cyan
    Write-Rule -Character '=' -Color Cyan
    Write-Host '  Non-destructive checks only. No services are started or stopped.' -ForegroundColor DarkGray
    Write-Host ''

    # Configuration
    $requiredSections = @('server', 'ssh', 'network', 'wakeOnLan', 'dashboards', 'services', 'companion', 'timeouts', 'logging')
    $missingSections = @($requiredSections | Where-Object { -not ($script:Config.ContainsKey($_) -and $script:Config[$_] -is [hashtable]) })
    if ($missingSections.Count -eq 0) {
        Add-SelfTestResult -Results $results -Name 'Configuration sections' -Status PASS -Detail 'All required sections are present.'
    }
    else {
        Add-SelfTestResult -Results $results -Name 'Configuration sections' -Status FAIL -Detail ('Missing: {0}' -f ($missingSections -join ', '))
    }

    $defaults = Get-DefaultConfiguration
    $defaultProblems = @()
    foreach ($section in $requiredSections) {
        if (-not $defaults.ContainsKey($section)) { $defaultProblems += ('missing default section {0}' -f $section) }
    }
    foreach ($key in @('homepage', 'uptimeKuma', 'dozzle', 'wud', 'portainer', 'airflow', 'pgAdmin', 'minio', 'sparkMaster', 'sparkWorker')) {
        if (-not $defaults.dashboards.ContainsKey($key)) { $defaultProblems += ('missing dashboard {0}' -f $key) }
    }
    foreach ($key in @('airflow', 'dataPlatform', 'spark')) {
        if (-not $defaults.services.ContainsKey($key)) { $defaultProblems += ('missing service {0}' -f $key) }
    }
    foreach ($key in @('label', 'directory', 'startScript', 'stopScript', 'updateScript', 'tailscaleScript', 'envFile', 'dashboards', 'estimatedMemoryMb')) {
        if (-not $defaults.companion.ContainsKey($key)) { $defaultProblems += ('missing companion setting {0}' -f $key) }
    }
    if ($defaultProblems.Count -eq 0) {
        Add-SelfTestResult -Results $results -Name 'Built-in configuration defaults' -Status PASS -Detail 'Required defaults are complete.'
    }
    else {
        Add-SelfTestResult -Results $results -Name 'Built-in configuration defaults' -Status FAIL -Detail ($defaultProblems -join '; ')
    }

    # Logging and rotation
    try {
        Write-AppLog -Level 'INFO' -Message 'Application self-test logging check.'
        if (Test-Path -LiteralPath $script:LogFile -PathType Leaf) {
            Add-SelfTestResult -Results $results -Name 'Application logging' -Status PASS -Detail $script:LogFile
        }
        else {
            Add-SelfTestResult -Results $results -Name 'Application logging' -Status FAIL -Detail 'Log file was not created.'
        }
    }
    catch {
        Add-SelfTestResult -Results $results -Name 'Application logging' -Status FAIL -Detail $_.Exception.Message
    }

    $rotationTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('homelab-logtest-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $rotationTemp -Force | Out-Null
        $testLog = Join-Path $rotationTemp 'test.log'
        Set-Content -LiteralPath $testLog -Value ('x' * 2000) -Encoding ASCII
        for ($index = 1; $index -le 7; $index++) {
            $oldLog = Join-Path $rotationTemp ('test-old-{0}.log' -f $index)
            Set-Content -LiteralPath $oldLog -Value 'old' -Encoding ASCII
            (Get-Item -LiteralPath $oldLog).LastWriteTime = (Get-Date).AddMinutes(-$index)
        }
        Invoke-LogRotation -Path $testLog -MaxBytes 100 -MaxFiles 3
        $remainingArchives = @(Get-ChildItem -LiteralPath $rotationTemp -Filter 'test-*.log' -File)
        if ($remainingArchives.Count -eq 3) {
            Add-SelfTestResult -Results $results -Name 'Log rotation and retention' -Status PASS -Detail 'Rotated and retained the configured number of archives.'
        }
        else {
            Add-SelfTestResult -Results $results -Name 'Log rotation and retention' -Status FAIL -Detail ('Expected 3 archives, found {0}.' -f $remainingArchives.Count)
        }
    }
    catch {
        Add-SelfTestResult -Results $results -Name 'Log rotation and retention' -Status FAIL -Detail $_.Exception.Message
    }
    finally {
        if (Test-Path -LiteralPath $rotationTemp) { Remove-Item -LiteralPath $rotationTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # SSH client and key
    if ($script:SshExe -and (Test-Path -LiteralPath $script:SshExe -PathType Leaf)) {
        Add-SelfTestResult -Results $results -Name 'OpenSSH client' -Status PASS -Detail $script:SshExe
    }
    else {
        Add-SelfTestResult -Results $results -Name 'OpenSSH client' -Status FAIL -Detail 'ssh.exe was not found.'
    }
    if ($script:SshKeyPath -and (Test-Path -LiteralPath $script:SshKeyPath -PathType Leaf)) {
        Add-SelfTestResult -Results $results -Name 'SSH private key exists' -Status PASS -Detail 'Configured key file is present (contents not read).'
    }
    else {
        Add-SelfTestResult -Results $results -Name 'SSH private key exists' -Status FAIL -Detail ('Missing: {0}' -f $script:SshKeyPath)
    }

    # SSH argument security and timeout settings
    try {
        $sshArgs = Get-SshBaseArguments -BatchMode -HostKeyMode 'yes'
        $joined = $sshArgs -join ' '
        $problems = @()
        if ($joined -notmatch 'IdentitiesOnly=yes') { $problems += 'IdentitiesOnly=yes missing' }
        if ($joined -notmatch 'ConnectTimeout=\d+') { $problems += 'ConnectTimeout missing' }
        if ($joined -notmatch 'ConnectionAttempts=1') { $problems += 'ConnectionAttempts=1 missing' }
        if ($joined -match 'StrictHostKeyChecking=no') { $problems += 'host-key checking disabled' }
        if ($joined -notmatch 'StrictHostKeyChecking=yes') { $problems += 'strict host-key checking missing' }
        if ($joined -notmatch [regex]::Escape($script:SshKeyPath)) { $problems += 'configured key missing from arguments' }
        if ($problems.Count -eq 0) {
            Add-SelfTestResult -Results $results -Name 'SSH argument hardening' -Status PASS -Detail 'Key-only identity, one attempt, strict host-key checking, explicit timeout.'
        }
        else {
            Add-SelfTestResult -Results $results -Name 'SSH argument hardening' -Status FAIL -Detail ($problems -join '; ')
        }
    }
    catch {
        Add-SelfTestResult -Results $results -Name 'SSH argument hardening' -Status FAIL -Detail $_.Exception.Message
    }

    # TCP timeout bound
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutProbe = Test-TcpPort -ComputerName '192.0.2.1' -Port 22 -TimeoutMilliseconds 600
    $timer.Stop()
    if ($timer.ElapsedMilliseconds -lt 3000 -and -not $timeoutProbe.IsOpen) {
        Add-SelfTestResult -Results $results -Name 'TCP check timeout bound' -Status PASS -Detail ('Unreachable test returned {0} in {1} ms.' -f $timeoutProbe.State, $timer.ElapsedMilliseconds)
    }
    else {
        Add-SelfTestResult -Results $results -Name 'TCP check timeout bound' -Status FAIL -Detail ('Probe state {0}, elapsed {1} ms.' -f $timeoutProbe.State, $timer.ElapsedMilliseconds)
    }

    # Wake-on-LAN packet construction
    try {
        $packet = New-MagicPacket -MacAddress $script:Config.server.mac
        $packetValid = ($packet.Length -eq 102)
        for ($index = 0; $index -lt 6; $index++) {
            if ($packet[$index] -ne 255) { $packetValid = $false }
        }
        $macBytes = Convert-MacToBytes -MacAddress $script:Config.server.mac
        for ($repeat = 0; $repeat -lt 16; $repeat++) {
            for ($index = 0; $index -lt 6; $index++) {
                if ($packet[6 + ($repeat * 6) + $index] -ne $macBytes[$index]) { $packetValid = $false }
            }
        }
        if ($packetValid) {
            Add-SelfTestResult -Results $results -Name 'Wake-on-LAN magic packet' -Status PASS -Detail '102-byte packet has the correct prefix and 16 repeated MAC blocks.'
        }
        else {
            Add-SelfTestResult -Results $results -Name 'Wake-on-LAN magic packet' -Status FAIL -Detail 'Packet structure is invalid.'
        }
    }
    catch {
        Add-SelfTestResult -Results $results -Name 'Wake-on-LAN magic packet' -Status FAIL -Detail $_.Exception.Message
    }

    # Launcher generation
    $launcherTestPath = $null
    try {
        $launcherTestPath = New-SshLauncherScript
        $launcherText = Get-Content -LiteralPath $launcherTestPath -Raw -ErrorAction Stop
        $launcherProblems = @()
        if ($launcherText -notmatch 'StrictHostKeyChecking=ask') { $launcherProblems += 'host-key policy missing' }
        if ($launcherText -notmatch 'IdentitiesOnly=yes') { $launcherProblems += 'identity restriction missing' }
        if ($launcherText -notmatch 'Read-Host') { $launcherProblems += 'keep-open prompt missing' }
        if ($launcherText -notmatch 'normal user rights') { $launcherProblems += 'normal-rights notice missing' }
        if ($launcherText -match 'elevated') { $launcherProblems += 'launcher still references elevation' }
        if ($launcherText -notmatch 'sudo') { $launcherProblems += 'sudo guidance missing' }
        if ($launcherText -notmatch [regex]::Escape($script:Config.server.sshUser)) { $launcherProblems += 'configured SSH user missing' }
        if ($launcherText -match '\{\{SSHUSER\}\}') { $launcherProblems += 'SSH user placeholder was not replaced' }
        if ($launcherText -match 'Password=') { $launcherProblems += 'password-like argument found' }
        if ($launcherProblems.Count -eq 0) {
            Add-SelfTestResult -Results $results -Name 'Remote terminal launcher script' -Status PASS -Detail 'Generated launcher uses normal user rights, interactive SSH, sudo guidance, keep-open prompt and no password argument.'
        }
        else {
            Add-SelfTestResult -Results $results -Name 'Remote terminal launcher script' -Status FAIL -Detail ($launcherProblems -join '; ')
        }
    }
    catch {
        Add-SelfTestResult -Results $results -Name 'Remote terminal launcher script' -Status FAIL -Detail $_.Exception.Message
    }
    finally {
        if ($launcherTestPath -and (Test-Path -LiteralPath $launcherTestPath)) { Remove-Item -LiteralPath $launcherTestPath -Force -ErrorAction SilentlyContinue }
    }

    # Required menu and action functions
    $requiredFunctions = @(
        'Show-MainMenu', 'Show-SystemOverview', 'Show-RemoteTerminal', 'Show-DockerMenu',
        'Show-DockerImageMenu', 'Show-DataServicesMenu', 'Show-WebMenu', 'Show-NetworkMenu', 'Show-PowerMenu',
        'Show-DiagnosticsMenu', 'Show-ServiceMenu', 'Open-Dashboard', 'Open-CentralHomepage', 'Invoke-WakeServer',
        'Show-EverydayToolsMenu', 'Show-EverydayStatus', 'Show-EverydayHelp', 'Show-CompanionStatus', 'Show-CompanionManagerMenu',
        'Start-CompanionTools', 'Stop-CompanionTools', 'Update-CompanionTools', 'Show-CompanionCredentials',
        'Show-MonitoringMenu', 'Show-TailscaleMenu', 'Show-TailscaleStatus', 'Connect-Tailscale',
        'Get-CompanionComposeStatusScript',
        'Test-TcpPort', 'Test-SshLogin', 'Invoke-RemoteScript', 'New-MagicPacket',
        'Stop-AllDockerContainers', 'Invoke-DockerImagePull', 'Invoke-DockerImageRemove',
        'Invoke-DockerImagePrune', 'Test-ImageReference', 'Read-ImageReference',
        'Invoke-ServerShutdown', 'Invoke-ServerReboot', 'Read-MenuChoice', 'Read-Confirmation'
    )
    $missingFunctions = @($requiredFunctions | Where-Object { -not (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) })
    if ($missingFunctions.Count -eq 0) {
        Add-SelfTestResult -Results $results -Name 'Menu handler functions' -Status PASS -Detail ('All {0} required functions are defined.' -f $requiredFunctions.Count)
    }
    else {
        Add-SelfTestResult -Results $results -Name 'Menu handler functions' -Status FAIL -Detail ('Missing: {0}' -f ($missingFunctions -join ', '))
    }

    # Docker image reference validation
    try {
        $validReferences = @('nginx:latest', 'postgres:17-alpine', 'ghcr.io/org/image:1.2.3', 'registry.local:5000/team/app@sha256:0123abcd')
        $invalidReferences = @('', '   ', 'bad ref', 'image;rm -rf /', "nginx:latest`nwhoami", '-leadinghyphen', 'image`whoami', ('a' * 300))
        $referenceProblems = @()
        foreach ($reference in $validReferences) {
            if (-not (Test-ImageReference -Reference $reference)) {
                $referenceProblems += ('rejected valid reference "{0}"' -f $reference)
            }
        }
        foreach ($reference in $invalidReferences) {
            if (Test-ImageReference -Reference $reference) {
                $referenceProblems += ('accepted invalid reference "{0}"' -f $reference)
            }
        }
        if ($referenceProblems.Count -eq 0) {
            Add-SelfTestResult -Results $results -Name 'Docker image reference validation' -Status PASS -Detail ('Accepted {0} valid forms and rejected {1} unsafe forms.' -f $validReferences.Count, $invalidReferences.Count)
        }
        else {
            Add-SelfTestResult -Results $results -Name 'Docker image reference validation' -Status FAIL -Detail ($referenceProblems -join '; ')
        }
    }
    catch {
        Add-SelfTestResult -Results $results -Name 'Docker image reference validation' -Status FAIL -Detail $_.Exception.Message
    }

    # Docker image pull timeout
    $pullTimeout = $script:Config.timeouts.remoteImagePullSeconds
    if ($pullTimeout -is [int] -and $pullTimeout -ge 60 -and $pullTimeout -le 3600) {
        Add-SelfTestResult -Results $results -Name 'Docker image pull timeout' -Status PASS -Detail ('Configured at {0} seconds.' -f $pullTimeout)
    }
    else {
        Add-SelfTestResult -Results $results -Name 'Docker image pull timeout' -Status FAIL -Detail ('Expected an integer between 60 and 3600, found "{0}".' -f $pullTimeout)
    }

    # Remote checks
    $tcpProbe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $script:Config.ssh.tcpCheckMilliseconds
    if (-not $tcpProbe.IsOpen) {
        Update-ConnectionCacheFromTcp -Probe $tcpProbe
        Add-SelfTestResult -Results $results -Name 'Remote SSH port' -Status SKIP -Detail $tcpProbe.Message
        Add-SelfTestResult -Results $results -Name 'Remote SSH authentication' -Status SKIP -Detail 'Server is not reachable.'
        Add-SelfTestResult -Results $results -Name 'Remote read-only command' -Status SKIP -Detail 'Server is not reachable.'
        Add-SelfTestResult -Results $results -Name 'Remote Docker daemon' -Status SKIP -Detail 'Server is not reachable.'
        Add-SelfTestResult -Results $results -Name 'Required remote service scripts' -Status SKIP -Detail 'Server is not reachable.'
        Add-SelfTestResult -Results $results -Name 'Everyday tools stack' -Status SKIP -Detail 'Server is not reachable.'
    }
    else {
        Update-ConnectionCacheFromTcp -Probe $tcpProbe
        Add-SelfTestResult -Results $results -Name 'Remote SSH port' -Status PASS -Detail ('TCP {0} is open in {1} ms.' -f $script:Config.server.sshPort, $tcpProbe.LatencyMilliseconds)

        $auth = Test-SshLogin
        if ($auth.Success) {
            Add-SelfTestResult -Results $results -Name 'Remote SSH authentication' -Status PASS -Detail ('Key authentication succeeded in {0} ms.' -f $auth.ElapsedMilliseconds)
        }
        else {
            Add-SelfTestResult -Results $results -Name 'Remote SSH authentication' -Status FAIL -Detail $auth.Message
        }

        if ($auth.Success) {
            $remoteCheck = Invoke-RemoteScript -Script 'hostname; uptime -p' -TimeoutSeconds 15 -Description 'Self-test remote read command' -CaptureOutput -SuppressFailureMessage
            if ($remoteCheck.Success -and -not [string]::IsNullOrWhiteSpace($remoteCheck.Output)) {
                Add-SelfTestResult -Results $results -Name 'Remote read-only command' -Status PASS -Detail ($remoteCheck.Output -replace "`r?`n", ' | ')
            }
            else {
                Add-SelfTestResult -Results $results -Name 'Remote read-only command' -Status FAIL -Detail $remoteCheck.Message
            }

            $dockerCheck = Invoke-RemoteScript -Script 'systemctl is-active docker 2>&1; docker info --format "{{.ServerVersion}}" 2>&1' -TimeoutSeconds 15 -Description 'Self-test Docker daemon' -CaptureOutput -SuppressFailureMessage
            if ($dockerCheck.Success -and $dockerCheck.Output -match 'active') {
                Add-SelfTestResult -Results $results -Name 'Remote Docker daemon' -Status PASS -Detail ($dockerCheck.Output -replace "`r?`n", ' | ')
            }
            else {
                Add-SelfTestResult -Results $results -Name 'Remote Docker daemon' -Status FAIL -Detail $dockerCheck.Message
            }

            $scriptPaths = @(
                $script:Config.services.airflow.startScript, $script:Config.services.airflow.stopScript,
                $script:Config.services.dataPlatform.startScript, $script:Config.services.dataPlatform.stopScript,
                $script:Config.services.spark.startScript, $script:Config.services.spark.stopScript,
                $script:Config.companion.startScript, $script:Config.companion.stopScript,
                $script:Config.companion.updateScript, $script:Config.companion.tailscaleScript
            ) | Select-Object -Unique
            $scriptCheckLines = foreach ($path in $scriptPaths) {
                ('if [ -f {0} ]; then echo "OK {0}"; else echo "MISSING {0}"; fi' -f $path)
            }
            $scriptCheck = Invoke-RemoteScript -Script ($scriptCheckLines -join "`n") -TimeoutSeconds 15 -Description 'Self-test remote service scripts' -CaptureOutput -SuppressFailureMessage
            if ($scriptCheck.Success -and $scriptCheck.Output -notmatch 'MISSING') {
                Add-SelfTestResult -Results $results -Name 'Required remote service scripts' -Status PASS -Detail ('All {0} configured scripts exist.' -f $scriptPaths.Count)
            }
            else {
                Add-SelfTestResult -Results $results -Name 'Required remote service scripts' -Status FAIL -Detail ($scriptCheck.Output -replace "`r?`n", ' | ')
            }

            $companionCheckScript = @'
cd __COMPANION_DIR__ || exit 4
test -f .env && echo 'ENV_OK'
grep -q 'WUD_SERVER_FEATURE_DELETE: "false"' compose.yaml && echo 'WUD_DELETE_DISABLED'
docker compose config --quiet && echo 'COMPOSE_OK'
curl -fsS -o /dev/null http://127.0.0.1:3000/api/healthcheck && echo 'HOMEPAGE_HEALTH_OK'
curl -fsS -o /dev/null http://127.0.0.1:3000/docs/guide.html && echo 'HOMEPAGE_GUIDE_OK'
docker compose ps --format '{{.Service}}:{{.State}}' 2>/dev/null || true
'@.Replace('__COMPANION_DIR__', $script:Config.companion.directory)
            $companionCheck = Invoke-RemoteScript -Script $companionCheckScript -TimeoutSeconds 30 -Description 'Self-test everyday tools stack' -CaptureOutput -SuppressFailureMessage
            $companionOutput = [string]$companionCheck.Output
            $companionProblems = @()
            foreach ($marker in @('ENV_OK', 'WUD_DELETE_DISABLED', 'COMPOSE_OK', 'HOMEPAGE_HEALTH_OK', 'HOMEPAGE_GUIDE_OK')) {
                if ($companionOutput -notmatch [regex]::Escape($marker)) { $companionProblems += ('missing {0}' -f $marker) }
            }
            if ($companionCheck.Success -and $companionProblems.Count -eq 0) {
                $running = @(($companionOutput -split "`r?`n") | Where-Object { $_ -match '^[a-z0-9-]+:running$' })
                Add-SelfTestResult -Results $results -Name 'Everyday tools stack' -Status PASS -Detail ('Compose valid; WUD delete disabled; {0} of 4 services running.' -f $running.Count)
            }
            else {
                Add-SelfTestResult -Results $results -Name 'Everyday tools stack' -Status FAIL -Detail (($companionProblems + @($companionCheck.Message)) -join '; ')
            }
        }
    }

    # Summary
    Write-Host ''
    Write-Rule -Character '-' -Color DarkGray
    foreach ($result in $results) {
        $color = switch ($result.Status) {
            'PASS' { [ConsoleColor]::Green }
            'FAIL' { [ConsoleColor]::Red }
            'WARN' { [ConsoleColor]::Yellow }
            default { [ConsoleColor]::DarkYellow }
        }
        Write-Host ('  [{0}] {1}' -f $result.Status, $result.Name) -ForegroundColor $color
        if ($result.Detail) { Write-Host ('         {0}' -f $result.Detail) -ForegroundColor DarkGray }
    }
    Write-Rule -Character '-' -Color DarkGray

    $failures = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skipped = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
    if ($failures -eq 0) {
        Write-Host ('  SELF-TEST PASSED: {0} checks, {1} skipped.' -f $results.Count, $skipped) -ForegroundColor Green
        Write-AppLog -Level 'INFO' -Message ('Self-test passed: {0} checks, {1} skipped.' -f $results.Count, $skipped)
        return 0
    }

    Write-Host ('  SELF-TEST FAILED: {0} failure(s), {1} skipped.' -f $failures, $skipped) -ForegroundColor Red
    Write-AppLog -Level 'ERROR' -Message ('Self-test failed: {0} failures, {1} skipped.' -f $failures, $skipped)
    return 1
}

# ============================================================================
# Startup notices, main menu, application entry point
# ============================================================================

function Show-StartupNotices {
    $notices = @()
    foreach ($warningText in @($script:ConfigWarnings)) {
        if (-not [string]::IsNullOrWhiteSpace($warningText)) { $notices += $warningText }
    }
    if (-not $script:SshExe) {
        $notices += 'OpenSSH client (ssh.exe) was not found. Remote functions are disabled until it is installed.'
    }
    elseif (-not $script:SshKeyPath -or -not (Test-Path -LiteralPath $script:SshKeyPath -PathType Leaf)) {
        $notices += ('SSH private key not found: {0}. Remote functions are disabled until the key exists.' -f $script:SshKeyPath)
        $notices += 'Update ssh.keyPath in config.json if the key is stored elsewhere. No key material is stored in the app.'
    }

    if ($notices.Count -eq 0) { return }

    Show-AppHeader -Title 'STARTUP NOTICES'
    foreach ($notice in $notices) {
        Write-UiMessage -Level Warning -Message $notice
        Write-AppLog -Level 'WARN' -Message ('Startup notice: {0}' -f $notice)
    }
    Write-Host ''
    Write-Host ('  Configuration: {0}' -f $script:ConfigPath) -ForegroundColor DarkGray
    Write-Host ('  Log:           {0}' -f $script:LogFile) -ForegroundColor DarkGray
    Wait-Return
}

function Show-MainMenu {
    while (-not $script:ExitRequested) {
        Show-AppHeader -Title 'MAIN MENU'
        Write-MenuOption -Key '01' -Text 'Homepage dashboard' -Note 'central hub, opens in browser'
        Write-MenuOption -Key '02' -Text 'Everyday tools' -Note 'status, monitoring, remote access'
        Write-MenuOption -Key '03' -Text 'System overview' -Note 'host, CPU, RAM, disk, Docker'
        Write-MenuOption -Key '04' -Text 'Remote terminal' -Note 'separate normal window'
        Write-MenuOption -Key '05' -Text 'Docker management' -Note 'containers, images, volumes, logs'
        Write-MenuOption -Key '06' -Text 'Data engineering services' -Note 'Airflow, data platform, Spark'
        Write-MenuOption -Key '07' -Text 'Web dashboards' -Note 'Homepage, monitoring and data tools'
        Write-MenuOption -Key '08' -Text 'Network and Wake-on-LAN' -Note 'SSH diagnostics, WoL'
        Write-MenuOption -Key '09' -Text 'Power management' -Note 'shutdown, reboot, uptime'
        Write-MenuOption -Key '10' -Text 'Diagnostics and logs' -Note 'system and application health'
        Write-MenuOption -Key '11' -Text 'Refresh connection status' -Note 'TCP check'
        Write-Host ''
        Write-MenuOption -Key '00' -Text 'Exit'
        Write-Host ''
        Write-Host '  New here? Press 1 to open the central Homepage: everything in one place.' -ForegroundColor Green
        Write-Host '  No action is performed without an explicit menu selection.' -ForegroundColor DarkGray
        $choice = Read-MenuChoice

        try {
            switch ($choice) {
                '1' { $null = Open-CentralHomepage; Wait-Return }
                '2' { Show-EverydayToolsMenu }
                '3' { Show-SystemOverview; Wait-Return }
                '4' { Show-RemoteTerminal; Wait-Return }
                '5' { Show-DockerMenu }
                '6' { Show-DataServicesMenu }
                '7' { Show-WebMenu }
                '8' { Show-NetworkMenu }
                '9' { Show-PowerMenu }
                '10' { Show-DiagnosticsMenu }
                '11' {
                    Write-Host '  Refreshing TCP connection status...' -ForegroundColor Gray
                    $probe = Test-TcpPort -ComputerName $script:Config.server.ip -Port $script:Config.server.sshPort -TimeoutMilliseconds $script:Config.ssh.tcpCheckMilliseconds
                    Update-ConnectionCacheFromTcp -Probe $probe
                    $display = Get-ConnectionDisplay -Cache $script:ConnectionCache
                    Write-UiMessage -Level Info -Message ('Current state: {0}' -f $display.Text)
                    Start-Sleep -Milliseconds 800
                }
                '0' { $script:ExitRequested = $true }
                default { Write-UiMessage -Level Warning -Message 'Invalid selection.' }
            }
        }
        catch {
            Write-UiMessage -Level Error -Message ('Unexpected error: {0}' -f $_.Exception.Message)
            Write-AppLog -Level 'ERROR' -Message ('Main menu error: {0}' -f $_.Exception.ToString())
            Wait-Return
        }
    }
}

function Start-HomelabManager {
    try {
        Initialize-AppEnvironment
    }
    catch {
        Write-Host ('Fatal: could not create the application directories: {0}' -f $_.Exception.Message) -ForegroundColor Red
        [void](Read-Host 'Press ENTER to exit')
        exit 1
    }

    Initialize-AppLogging
    $script:Config = Read-AppConfiguration -Path $script:ConfigPath
    Initialize-SshEnvironment
    Remove-StaleLauncherScripts

    Write-AppLog -Level 'INFO' -Message ('Server target: {0}@{1}:{2}; config warnings: {3}' -f $script:Config.server.sshUser, $script:Config.server.ip, $script:Config.server.sshPort, $script:ConfigWarnings.Count)
    Initialize-ConnectionCache

    if ($SelfTest) {
        $selfTestExitCode = Invoke-ApplicationSelfTest
        exit $selfTestExitCode
    }

    Show-StartupNotices
    Show-MainMenu

    Write-AppLog -Level 'INFO' -Message 'Application closed normally.'
    try { Clear-Host } catch { }
    Write-Host ''
    Write-Host '  HP PRODESK HOMELAB CONTROL CENTER CLOSED.' -ForegroundColor Cyan
    Write-Host ''
}

function Invoke-HomelabManagerSetup {
    Initialize-AppEnvironment
    $configuration = Get-DefaultConfiguration

    Write-Host ''
    Write-Host 'HP HOMELAB MANAGER - FIRST-RUN SETUP' -ForegroundColor Cyan
    Write-Host 'Leave a value blank to keep the safe example default.' -ForegroundColor DarkGray
    Write-Host 'Passwords and private-key contents are never requested or saved.' -ForegroundColor DarkGray
    Write-Host ''

    $value = Read-Host ('Server name [{0}]' -f $configuration.server.label)
    if ($value) { $configuration.server.label = $value.Trim() }
    $value = Read-Host ('Server IP address [{0}]' -f $configuration.server.ip)
    if ($value) {
        $parsedIp = $null
        if (-not [Net.IPAddress]::TryParse($value.Trim(), [ref]$parsedIp) -or $parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'A valid IPv4 address is required.' }
        $configuration.server.ip = $value.Trim()
    }
    $value = Read-Host ('SSH username [{0}]' -f $configuration.server.sshUser)
    if ($value) { $configuration.server.sshUser = $value.Trim() }
    $value = Read-Host ('SSH port [{0}]' -f $configuration.server.sshPort)
    if ($value) {
        $port = 0
        if (-not [int]::TryParse($value.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'SSH port must be between 1 and 65535.' }
        $configuration.server.sshPort = $port
    }
    $value = Read-Host ('Server MAC address [{0}] (optional; needed for Wake-on-LAN)' -f $configuration.server.mac)
    if ($value) { $configuration.server.mac = $value.Trim() }
    $value = Read-Host ('SSH private-key path [{0}]' -f $configuration.ssh.keyPath)
    if ($value) { $configuration.ssh.keyPath = $value.Trim() }

    $parent = Split-Path -Parent $script:ConfigPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $configuration | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    Write-Host ''
    Write-Host ('Saved your local configuration to: {0}' -f $script:ConfigPath) -ForegroundColor Green
    Write-Host 'This file is intentionally excluded from version control.' -ForegroundColor DarkGray
}

function Invoke-HomelabManagerBuild {
    $sourcePath = $PSCommandPath
    if (-not $sourcePath -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw 'The build must be run from HP Homelab Manager.ps1.'
    }

    $distDirectory = Join-Path $PSScriptRoot 'dist'
    New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null
    $outputPath = Join-Path $distDirectory 'HP Homelab Manager.exe'
    $temporaryPath = Join-Path $distDirectory ('HP Homelab Manager.build-{0}.exe' -f [guid]::NewGuid().ToString('N'))

    Import-Module ps2exe -ErrorAction Stop
    foreach ($process in @(Get-Process -Name 'HP Homelab Manager' -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
    }

    try {
        Invoke-PS2EXE -inputFile $sourcePath -outputFile $temporaryPath -title 'HP ProDesk Homelab Control Center' -description 'Windows control center for the Debian homelab server' -company 'Personal Homelab' -product 'HP Homelab Manager' -version '1.0.0.0'
        if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) { throw 'PS2EXE did not create the temporary EXE.' }
        if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Remove-Item -LiteralPath $outputPath -Force -ErrorAction Stop }
        Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }

    $bytes = [IO.File]::ReadAllBytes($outputPath)
    $needle = [Text.Encoding]::ASCII.GetBytes('Launch Reach (SSH Client)')
    $found = $false
    for ($i = 0; $i -le $bytes.Length - $needle.Length; $i++) {
        $matches = $true
        for ($j = 0; $j -lt $needle.Length; $j++) { if ($bytes[$i + $j] -ne $needle[$j]) { $matches = $false; break } }
        if ($matches) { $found = $true; break }
    }
    if (-not $found) { throw 'Build verification failed: the Reach menu text is missing from the EXE.' }
    Write-Host ('Built and verified: {0}' -f $outputPath) -ForegroundColor Green
}

if ($Build) {
    Invoke-HomelabManagerBuild
}
elseif ($Setup) {
    Invoke-HomelabManagerSetup
}
elseif ($MyInvocation.InvocationName -ne '.') {
    Start-HomelabManager
}


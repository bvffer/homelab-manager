#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$InstallPs2Exe,
    [switch]$Configure,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'

Write-Host 'Homelab Manager - prerequisite check' -ForegroundColor Cyan
Write-Host ('PowerShell: {0}' -f $PSVersionTable.PSVersion)

$ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $ssh) { $ssh = Get-Command ssh -ErrorAction SilentlyContinue }
if ($ssh) {
    Write-Host ('OpenSSH client: found at {0}' -f $ssh.Source) -ForegroundColor Green
}
else {
    Write-Host 'OpenSSH client: not found. Install the Windows OpenSSH Client optional feature, then rerun this script.' -ForegroundColor Yellow
}

$ps2exe = Get-Module -ListAvailable -Name ps2exe | Select-Object -First 1
if ($ps2exe) {
    Write-Host ('PS2EXE: found ({0})' -f $ps2exe.Version) -ForegroundColor Green
}
elseif ($InstallPs2Exe) {
    Write-Host 'Installing PS2EXE for the current user...' -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
}
else {
    Write-Host 'PS2EXE: not found. Run .\Install.ps1 -InstallPs2Exe if you want to build an EXE.' -ForegroundColor Yellow
}

if ($Configure) { & (Join-Path $PSScriptRoot 'Setup.ps1') }
if ($Build) { & (Join-Path $PSScriptRoot 'Build.ps1') }

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'Homelab-Manager.ps1'

if (-not (Test-Path -LiteralPath $source)) { throw 'Main source file is missing.' }

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ('Parser errors: ' + (($errors | ForEach-Object Message) -join '; ')) }

. $source
$defaults = Get-DefaultConfiguration
if ($defaults.server.ip -ne '192.168.1.50') { throw 'The public example IP is not the expected generic value.' }
if ($defaults.server.sshUser -ne 'homelab') { throw 'The public example SSH user is not generic.' }
if ($defaults.server.mac -ne '02:00:00:00:00:01') { throw 'The public example MAC is not generic.' }

$content = Get-Content -LiteralPath $source -Raw
foreach ($forbidden in @(('192.168.' + '137.'), ('9C:B6:' + '54:'), ('C:\Users\' + 'pc'))) {
    if ($content -match [regex]::Escape($forbidden)) { throw "Personal-value pattern found: $forbidden" }
}

Write-Host 'Repository checks passed.' -ForegroundColor Green

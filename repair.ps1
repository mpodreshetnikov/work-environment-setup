#Requires -Version 5.1
param([string]$Root=(Join-Path $env:LOCALAPPDATA 'WorkEnvironmentSetup\AiVpn'))
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) { throw 'Use elevated 64-bit Windows PowerShell 5.1 for repair, or bootstrap.ps1 -Repair.' }
& (Join-Path $PSScriptRoot 'install.ps1') -Root $Root -Repair

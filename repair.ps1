#Requires -Version 5.1
param([string]$Root=(Join-Path $env:LOCALAPPDATA 'WorkEnvironmentSetup\AiVpn'))
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'install.ps1') -Root $Root -Repair

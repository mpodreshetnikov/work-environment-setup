#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$V2rayRoot,
    [string]$CoreConfigPath,
    [ValidateSet('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli')]
    [string[]]$Apps=@('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli'),
    [switch]$IncludeEndpoint
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Run this plan in 64-bit Windows PowerShell.' }
Import-Module (Join-Path $PSScriptRoot 'src\Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\V2rayProfile.psm1') -Force
$snapshot=Get-WesVpnSnapshot -V2rayRoot $V2rayRoot -CoreConfigPath $CoreConfigPath
$inventory=@(Get-WesApplicationInventory -Scopes $Apps)
$view=[ordered]@{
    Mode='ReadOnlyPlan'
    SystemSettingsChanged=$false
    DeploymentImplemented=$true
    ReleaseStatus='Local validation in progress; clean installation and bootstrap are not yet verified'
    Applications=@($inventory | ForEach-Object { [ordered]@{Scope=$_.Scope;Kind=$_.Kind;ExecutableCount=@($_.Executables).Count;TagPatterns=@($_.TagPatterns)} })
    Vpn=[ordered]@{Root=$snapshot.V2rayRoot;Source=$snapshot.Source;Protocol=$snapshot.Outbound.protocol;TunEnabled=$snapshot.TunEnabled;XrayFound=(Test-Path -LiteralPath $snapshot.XrayPath)}
    ApplicationAutostart=$false
    ExternalCommandToolsRestricted=$false
}
if($IncludeEndpoint) { $view.Vpn.Server=$snapshot.Outbound.settings.vnext[0].address;$view.Vpn.Port=$snapshot.Outbound.settings.vnext[0].port }
$view | ConvertTo-Json -Depth 8

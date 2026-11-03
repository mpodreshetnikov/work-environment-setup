#Requires -Version 5.1
#Requires -RunAsAdministrator
param([string]$Root=(Join-Path $env:LOCALAPPDATA 'WorkEnvironmentSetup\AiVpn'),[string]$LegacyGuardRoot,[string]$LegacyProxyUrl='http://127.0.0.1:10819')
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {throw 'Use elevated 64-bit Windows PowerShell 5.1.'}
foreach($module in @('PrivateState','NotificationIntegration')) {Import-Module (Join-Path $PSScriptRoot ('src\'+$module+'.psm1')) -Force}
if($LegacyGuardRoot) {
    Install-WesNotificationIntegration -Root (Join-Path $LegacyGuardRoot 'notifications') -Kind Legacy -GuardScript (Join-Path $LegacyGuardRoot 'ClaudeVpnGuard.ps1') -ProxyUrl $LegacyProxyUrl -MachineRegistration
} else {
    $state=Read-WesInstallationState $Root
    if($state.Status -ne 'Installed' -or 'CodexDesktop' -notin @($state.Applications.Scope)) {throw 'A completed Codex Desktop VPN installation is required.'}
    Install-WesNotificationIntegration -Root (Join-Path $Root 'notifications') -LaunchScript (Join-Path $Root 'runtime\Desktop.ps1') -MachineRegistration
}

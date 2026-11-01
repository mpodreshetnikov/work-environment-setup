#Requires -Version 5.1
param([string]$Root=(Join-Path $env:LOCALAPPDATA 'WorkEnvironmentSetup\AiVpn'))
$ErrorActionPreference='Stop'
$modules=if(Test-Path (Join-Path $PSScriptRoot 'src')) { Join-Path $PSScriptRoot 'src' } else { Join-Path $Root 'runtime' }
foreach($module in @('PrivateState','Runtime','NetworkProtection','Discovery','LaunchPlan')) { Import-Module (Join-Path $modules ($module+'.psm1')) -Force }
$state=Read-WesInstallationState $Root
if($state.Status -ne 'Installed') { throw 'Installation is incomplete or removed.' }
$ready=Get-WesRuntimeReadiness $Root
foreach($saved in @($state.Applications)) {
    $receipt=Assert-WesNetworkProtection -Root $Root -Scope $saved.Scope
    $current=@(Get-WesApplicationInventory -Scopes @($saved.Scope))[0]
    foreach($file in @($current.Executables)) { if((Resolve-WesCanonicalPath $file) -notin @($receipt.Programs)) { throw 'An application update needs repair before guarded launch.' } }
    $null=Get-WesNativeLaunchCommand -Saved $saved -Current $current
}
$identity=Get-WesInstallationIdentity
$task=Get-ScheduledTask -TaskName $identity.V2rayTaskName -ErrorAction Stop
if($task.Principal.RunLevel -ne 'Highest' -or $task.Actions.Execute -ne (Join-Path $state.Vpn.V2rayRoot 'v2rayN.exe')) { throw 'The elevated v2rayN logon task changed.' }
[pscustomobject]@{Status='Passed';Applications=@($state.Applications.Scope);PinnedProxy=$ready.ProxyUrl;VpnAutostart=$true;AiApplicationAutostart=$false;RealApplicationMessage='Requires manual verification';Reboot='Requires manual verification'}

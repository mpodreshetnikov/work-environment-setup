#Requires -Version 5.1
#Requires -RunAsAdministrator
param([string]$Root=(Join-Path $env:LOCALAPPDATA 'WorkEnvironmentSetup\AiVpn'),[switch]$PurgePrivateState)
$ErrorActionPreference='Stop'
$modules=if(Test-Path (Join-Path $PSScriptRoot 'src')) { Join-Path $PSScriptRoot 'src' } else { Join-Path $Root 'runtime' }
foreach($module in @('PrivateState','Maintenance')) { Import-Module (Join-Path $modules ($module+'.psm1')) -Force }
$full=Initialize-WesPrivateDirectory -Path $Root
$state=Read-WesInstallationState $full
Assert-WesApplicationsClosed @($state.Applications)
Remove-WesOwnedSettings $full
Stop-WesOwnedProxy $full
if($PurgePrivateState) {
    $protected=@([IO.Path]::GetPathRoot($full),$env:USERPROFILE,$env:LOCALAPPDATA,$env:SystemRoot)
    if($full -in $protected -or -not (Test-WesPrivateDirectory $full) -or @(Get-ChildItem -LiteralPath $full -Force -Recurse | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count) { throw 'Refusing to recursively remove this private directory.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
Write-Output 'Owned firewall rules, WFP filters, AppID policies, shortcuts, profile blocks and VPN logon task removed. v2rayN and AI applications remain installed.'

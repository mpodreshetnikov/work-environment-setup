param([Parameter(Mandatory=$true)][ValidateSet('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli')][string]$Scope)
$ErrorActionPreference='Stop'
$WarningPreference='SilentlyContinue'
$ProgressPreference='SilentlyContinue'
$root=Split-Path $PSScriptRoot
$plan=@{Success=$false;Scope=$Scope;Error='VPN launch check failed.'}
try {
    foreach($module in @('PrivateState','Discovery','Runtime','LaunchPlan','NetworkProtection')) { Import-Module (Join-Path $PSScriptRoot ($module+'.psm1')) -ErrorAction Stop }
    $state=Read-WesInstallationState $root
    if($state.Status -ne 'Installed') { throw 'Installation is incomplete or under maintenance. Run verification or repair.' }
    $saved=@($state.Applications | Where-Object Scope -eq $Scope)
    if($saved.Count -ne 1) { throw 'This application was not selected during installation.' }
    $protection=Assert-WesNetworkProtection -Root $root -Scope $Scope
    $current=@(Get-WesApplicationInventory -Scopes @($Scope))
    foreach($executable in @($current[0].Executables)) {
        if((Resolve-WesCanonicalPath $executable) -notin @($protection.Programs)) { throw 'An application update needs protection refresh. Run repair before launching.' }
    }
    $command=Get-WesNativeLaunchCommand -Saved $saved[0] -Current $current[0]
    $ready=Get-WesRuntimeReadiness $root
    $plan=@{Success=$true;Scope=$Scope;ProxyUrl=$ready.ProxyUrl;Command=$command;DisableGpu=[bool]$state.DisableGpu}
} catch {
    # Do not serialize exception objects, source lines, or native config output.
    $plan.Error=$_.Exception.Message
}
$bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $plan -Depth 8 -Compress))
$stream=[Console]::OpenStandardOutput();$stream.Write($bytes,0,$bytes.Length);$stream.Flush()

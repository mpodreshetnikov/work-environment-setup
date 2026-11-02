#Requires -Version 5.1
[CmdletBinding()]
param([string]$V2rayRoot,[string]$CoreConfigPath,[string]$TunInterfaceAlias,
    [ValidateSet('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli')][string[]]$Apps=@('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli'),
    [string]$Root=(Join-Path $env:LOCALAPPDATA 'WorkEnvironmentSetup\AiVpn'),
    [ValidateRange(1024,65535)][int]$ProxyPort=20080,[uint16[]]$AdditionalDeniedProxyPorts=@(),
    [switch]$DisableGpu,[switch]$Repair,[string]$ExpectedOwnerSid)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use 64-bit Windows PowerShell 5.1.' }
if([Environment]::OSVersion.Version.Build -lt 26100 -or -not (Test-Path (Join-Path $env:SystemRoot 'System32\CiTool.exe'))) { throw 'Windows 11 24H2 or later is required for AppID policy removal without a reboot.' }
$administrator=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $administrator) { throw 'Run install.ps1 from an elevated Windows PowerShell, or use bootstrap.ps1 for UAC elevation.' }
$moduleRoot=if(Test-Path (Join-Path $PSScriptRoot 'src')) { Join-Path $PSScriptRoot 'src' } else { Join-Path $PSScriptRoot 'runtime' }
foreach($module in @('PrivateState','Discovery','V2rayProfile','ProxyPreparation','LaunchPreparation','Runtime','NetworkProtection','SystemIntegration','Maintenance')) { Import-Module (Join-Path $moduleRoot ($module+'.psm1')) -Force }
if($ExpectedOwnerSid -and $ExpectedOwnerSid -ne (Get-WesOwnerSid)) { throw 'UAC switched to another Windows account. Installation was not applied.' }
$rootPath=[IO.Path]::GetFullPath($Root)
$existingPath=Join-Path $rootPath 'installation.private.json'
$existing=$null
if(Test-Path -LiteralPath $existingPath) {
    $existing=Read-WesInstallationState $rootPath
    if(-not $Repair) {
        if($existing.Status -ne 'Installed') { throw 'An unfinished installation exists. Run repair.ps1 or uninstall.ps1.' }
        & (Join-Path $PSScriptRoot 'verify.ps1') -Root $rootPath
        if(-not $?) { throw 'Existing installation verification failed.' }
        Write-Output 'Already installed. No profile, credentials, firewall rules, or shortcuts were changed.'
        return
    }
    $Apps=@($existing.Applications.Scope);$V2rayRoot=$existing.Vpn.V2rayRoot;$TunInterfaceAlias=$existing.Vpn.TunInterfaceAlias
    $ProxyPort=[int]$existing.Vpn.ProxyPort;$DisableGpu=[bool]$existing.DisableGpu
    foreach($role in @('Claude','Codex')) {
        $receiptPath=Join-Path $rootPath ($role.ToLowerInvariant()+'-protection.private.json')
        if(Test-Path -LiteralPath $receiptPath) { $AdditionalDeniedProxyPorts+=@((Read-WesPrivateJson $receiptPath).DeniedProxyPorts) }
    }
} elseif($Repair) { throw 'There is no installation to repair.' }
if(Get-NetFirewallRule -Group 'AI VPN Guard - source address enforcement' -ErrorAction SilentlyContinue) { throw 'The earlier ClaudeVpnGuard prototype is installed. Migration must be completed explicitly before applying this installer.' }
$inventory=@(Get-WesApplicationInventory -Scopes $Apps)
Assert-WesApplicationsClosed $inventory
$snapshot=Get-WesVpnSnapshot -V2rayRoot $V2rayRoot -CoreConfigPath $CoreConfigPath
if(-not $snapshot.TunEnabled) { throw 'Enable TUN for the intended v2rayN profile before installation.' }
if($existing -and $snapshot.ProfileId -ne $existing.Vpn.ProfileId) { throw 'Repair cannot repin another profile. Restore the original selected profile first.' }
if(-not $TunInterfaceAlias) {
    $candidates=@(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and ($_.Name -match '(?i)sing.?box|v2ray|^tun' -or $_.InterfaceDescription -match '(?i)sing.?tun|sing.?box') })
    if($candidates.Count -ne 1) { throw 'Cannot identify one active v2rayN TUN interface. Pass -TunInterfaceAlias explicitly.' }
    $TunInterfaceAlias=$candidates[0].Name
}
$owner=Get-WesOwnerSid
$state=[pscustomobject]@{SchemaVersion=1;OwnerSid=$owner;Status='Preparing';DisableGpu=[bool]$DisableGpu;Applications=$inventory;
    Vpn=[pscustomobject]@{V2rayRoot=$snapshot.V2rayRoot;GuiConfigPath=$snapshot.GuiConfigPath;ProfileId=$snapshot.ProfileId;TunInterfaceAlias=$TunInterfaceAlias;ProxyPort=$ProxyPort}}
Assert-WesVpnReady $state
if(-not $existing -and (Get-NetTCPConnection -State Listen -LocalPort $ProxyPort -ErrorAction SilentlyContinue)) { throw 'The pinned proxy port is occupied. Choose another -ProxyPort.' }
$rootPath=Initialize-WesPrivateDirectory -Path $rootPath -ExpectedOwnerSid $owner
if($existing) {
    # Validate the pinned files before removing any protection. Repair never imports new VPN credentials.
    $null=Get-WesVerifiedProxy $rootPath
    Assert-WesApplicationsClosed @($existing.Applications)
    Remove-WesOwnedSettings $rootPath
    foreach($name in @('claude-protection.private.json','codex-protection.private.json','integration.private.json')) {
        $path=Join-Path $rootPath $name
        if(Test-Path -LiteralPath $path) { Move-Item -LiteralPath $path -Destination ($path+'.removed-'+[guid]::NewGuid().ToString('N')) }
    }
}
Write-WesPrivateJson (Join-Path $rootPath 'installation.private.json') $state
try {
    foreach($name in @('install.ps1','verify.ps1','repair.ps1','uninstall.ps1')) {
        $source=Join-Path $PSScriptRoot $name;$destination=Join-Path $rootPath $name
        if($source -ne $destination) { Copy-Item -LiteralPath $source -Destination $destination }
    }
    $state.Applications=@(Initialize-WesLaunchRuntime -Root $rootPath -Applications $inventory -Repair:$Repair)
    Write-WesPrivateJson (Join-Path $rootPath 'installation.private.json') $state
    if(-not $existing) { $null=Initialize-WesPinnedProxy -Root $rootPath -Snapshot $snapshot -Port $ProxyPort }
    # Prove the encrypted path before installing restrictions or changing startup integration.
    $null=Get-WesRuntimeReadiness $rootPath
    $ports=@(10808,10814)+@($AdditionalDeniedProxyPorts)
    $savedGui=Get-Content -LiteralPath $snapshot.GuiConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($inbound in @($savedGui.Inbound)) { if($inbound.PSObject.Properties['LocalPort']) { $ports+=@([int]$inbound.LocalPort) } }
    $ports=[uint16[]]@($ports | Where-Object { $_ -gt 0 -and $_ -ne $ProxyPort } | Sort-Object -Unique)
    foreach($role in @('Claude','Codex')) { $null=Install-WesRoleProtection -Root $rootPath -Role $role -Applications $state.Applications -DeniedProxyPorts $ports }
    $null=Install-WesSystemIntegration -Root $rootPath -State $state
    $state.Status='Installed';Write-WesPrivateJson (Join-Path $rootPath 'installation.private.json') $state
    & (Join-Path $PSScriptRoot 'verify.ps1') -Root $rootPath
    Write-Output 'Installed. Open a new terminal, or launch Claude VPN / Codex VPN. AI applications were not started.'
} catch {
    $failure=$_.Exception.Message
    try { Remove-WesOwnedSettings $rootPath;Stop-WesOwnedProxy $rootPath } catch { $failure+=' Automatic rollback was incomplete. Keep the private directory and run uninstall.ps1 as administrator.' }
    throw $failure
}

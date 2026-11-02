Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'PrivateState.psm1')

function Initialize-WesWfpType {
    if(-not ('WorkEnvironmentSetup.WfpProtection' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'native\WfpProtection.cs') }
}

function Get-WesBlockedSourceAddresses {
    return @('0.0.0.0-126.255.255.255','128.0.0.0-255.255.255.255','::-::','::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
}

function Add-WesTagDllFastPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    [xml]$document=Get-Content -LiteralPath $Path
    if($document.SiPolicy.PolicyType -ne 'AppID Tagging Policy') { throw 'Only an AppID tagging policy may be installed.' }
    $id='ID_ALLOW_DLL_WES';$ns=$document.DocumentElement.NamespaceURI
    $rule=$document.CreateElement('FileRule',$ns)
    foreach($pair in @{Type='Match';ID=$id;FriendlyName='Skip DLL evaluation for process tagging';FileName='*.dll';MinimumFileVersion='0.0.0.0'}.GetEnumerator()) { $rule.SetAttribute($pair.Key,$pair.Value) }
    $null=$document.SiPolicy.FileRules.AppendChild($rule)
    $refs=$document.SelectSingleNode("//*[local-name()='SigningScenario' and @Value='12']/*[local-name()='ProductSigners']/*[local-name()='FileRulesRef']")
    if(-not $refs) { throw 'Tagging policy has no user-mode file rule references.' }
    $reference=$document.CreateElement('FileRuleRef',$ns);$reference.SetAttribute('RuleID',$id);$null=$refs.AppendChild($reference)
    $document.Save($Path)
}

function Remove-WesRoleProtection {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Receipt)
    Initialize-WesWfpType
    if(@($Receipt.FilterKeys).Count) { [WorkEnvironmentSetup.WfpProtection]::RemoveBlocks([guid]$Receipt.Sublayer,[string[]]$Receipt.FilterKeys) }
    foreach($name in @($Receipt.RuleNames)) {
        if(Get-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction Stop }
    }
    if($Receipt.PolicyDeployed) {
        & (Join-Path $env:SystemRoot 'System32\CiTool.exe') --remove-policy $Receipt.PolicyId --json | Out-Null
        if($LASTEXITCODE) {
            # CiTool reports an error when recovery repeats an already completed
            # removal. Accept that case only after a successful authoritative
            # enumeration proves that the exact policy is absent.
            $output=@(& (Join-Path $env:SystemRoot 'System32\CiTool.exe') --list-policies --json)
            if($LASTEXITCODE) { throw 'Could not verify AppID policy removal. Keep the installation state and retry removal as administrator.' }
            $listed=($output -join "`n") | ConvertFrom-Json
            if(-not $listed.PSObject.Properties['Policies'] -or -not $listed.PSObject.Properties['OperationResult'] -or $listed.OperationResult -ne 0) { throw 'Could not verify AppID policy removal: unexpected CiTool result.' }
            $policyId=[guid]$Receipt.PolicyId
            foreach($policy in @($listed.Policies)) {
                if(-not $policy.PSObject.Properties['PolicyID']) { throw 'Could not verify AppID policy removal: missing policy identity.' }
                if([guid]$policy.PolicyID -eq $policyId) { throw 'Could not remove the owned AppID tagging policy. Keep the installation state and retry removal as administrator.' }
            }
            $active=Join-Path $env:SystemRoot ('System32\CodeIntegrity\CiPolicies\Active\'+$policyId.ToString('B')+'.cip')
            if(Test-Path -LiteralPath $active) { throw 'The owned AppID policy file remains after removal. Keep the installation state.' }
        }
    }
}

function Install-WesRoleProtection {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][ValidateSet('Claude','Codex')][string]$Role,
        [Parameter(Mandatory=$true)][object[]]$Applications,[Parameter(Mandatory=$true)][uint16[]]$DeniedProxyPorts)
    $identity=Get-WesInstallationIdentity;$settings=$identity.Roles[$Role]
    $path=Join-Path $Root ($Role.ToLowerInvariant()+'-protection.private.json')
    if((Test-Path -LiteralPath $path) -or (Get-NetFirewallRule -Group $settings.FirewallGroup -ErrorAction SilentlyContinue)) { throw 'Protection already exists or an unfinished installation needs removal.' }
    $selected=@($Applications | Where-Object { if($Role -eq 'Claude') { $_.Scope -like 'Claude*' } else { $_.Scope -like 'Codex*' } })
    if(-not $selected.Count) { return }
    $programs=@($selected.Executables | Sort-Object -Unique)
    $patterns=@($selected.TagPatterns | Sort-Object -Unique)
    $receipt=[ordered]@{SchemaVersion=1;OwnerSid=$identity.OwnerSid;Role=$Role;Status='Installing';Tag=$settings.Tag;Group=$settings.FirewallGroup;
        PolicyId=$null;PolicyDeployed=$false;PolicyHash=$null;Sublayer=$settings.Sublayer;FilterKeys=@();RuleNames=@();RuleSelectors=@();Programs=$programs;DeniedProxyPorts=@($DeniedProxyPorts)}
    try {
        Write-WesPrivateJson $path $receipt
        $rules=@();foreach($pattern in $patterns) { $rules+=New-CIPolicyRule -FilePathRule $pattern }
        $xml=Join-Path $Root ($Role+'Tags.xml');$cip=Join-Path $Root ($Role+'Tags.cip')
        New-CIPolicy -Rules $rules -FilePath $xml -AppIdTaggingPolicy -AppIdTaggingKey $settings.Tag -AppIdTaggingValue 'Protected' | Out-Null
        foreach($option in @(0,16,18)) { Set-RuleOption -FilePath $xml -Option $option }
        Set-CIPolicyIdInfo -FilePath $xml -ResetPolicyID -PolicyName ($identity.NamePrefix+' '+$Role) -AppIdTaggingPolicy | Out-Null
        Add-WesTagDllFastPath $xml
        [xml]$document=Get-Content -LiteralPath $xml
        $receipt.PolicyId=[string]$document.SiPolicy.PolicyID
        ConvertFrom-CIPolicy -XmlFilePath $xml -BinaryFilePath $cip | Out-Null
        $receipt.PolicyHash=(Get-FileHash -LiteralPath $cip -Algorithm SHA256).Hash
        Write-WesPrivateJson $path $receipt
        & (Join-Path $env:SystemRoot 'System32\CiTool.exe') --update-policy $cip --json | Out-Null
        if($LASTEXITCODE) { throw 'AppID tagging policy deployment failed.' }
        $receipt.PolicyDeployed=$true;Write-WesPrivateJson $path $receipt
        $selectors=@(@{PolicyAppId=$settings.Tag})
        foreach($program in $programs) { $selectors+=@{Program=$program} }
        $number=0
        foreach($selector in $selectors) {
            $name=$identity.NamePrefix+'-'+$Role+'-direct-'+$number;$number++
            New-NetFirewallRule -PolicyStore PersistentStore -Name $name -DisplayName ($Role+' VPN: deny non-loopback traffic') -Group $settings.FirewallGroup -Direction Outbound -Action Block -Enabled True -Profile Any -LocalUser ('D:(A;;CC;;;'+$identity.OwnerSid+')') -LocalAddress (Get-WesBlockedSourceAddresses) @selector | Out-Null
            $receipt.RuleNames+=@($name);$receipt.RuleSelectors+=@(@{Name=$name;Program=$selector['Program'];PolicyAppId=$selector['PolicyAppId']});Write-WesPrivateJson $path $receipt
        }
        Initialize-WesWfpType
        $receipt.FilterKeys=@([WorkEnvironmentSetup.WfpProtection]::InstallBlocks($settings.Tag,$identity.OwnerSid,[string[]]$programs,$DeniedProxyPorts,[guid]$settings.Sublayer))
        $receipt.Status='Installed';Write-WesPrivateJson $path $receipt
        return [pscustomobject]$receipt
    } catch {
        $failure=$_.Exception.Message
        try { Remove-WesRoleProtection ([pscustomobject]$receipt);$receipt.Status='RolledBack' }
        catch { $receipt.Status='RollbackRequired';$failure+=' Rollback needs administrator attention; do not delete private state.' }
        Write-WesPrivateJson $path $receipt
        throw $failure
    }
}

function Assert-WesNetworkProtection {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][ValidateSet('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli')][string]$Scope)
    $role=if($Scope -like 'Claude*') {'Claude'} else {'Codex'}
    $identity=Get-WesInstallationIdentity;$settings=$identity.Roles[$role]
    $receipt=Read-WesPrivateJson (Join-Path $Root ($role.ToLowerInvariant()+'-protection.private.json'))
    if($receipt.Status -ne 'Installed' -or $receipt.OwnerSid -ne $identity.OwnerSid -or $receipt.Tag -ne $settings.Tag -or $receipt.Sublayer -ne $settings.Sublayer) { throw 'Network protection is incomplete. Run verification or repair.' }
    if(@(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object Enabled -ne 'True').Count) { throw 'Windows Firewall is disabled for one or more profiles.' }
    $policyFile=Join-Path $env:SystemRoot ('System32\CodeIntegrity\CiPolicies\Active\'+$receipt.PolicyId+'.cip')
    if(-not (Test-Path -LiteralPath $policyFile) -or (Get-FileHash -LiteralPath $policyFile -Algorithm SHA256).Hash -ne $receipt.PolicyHash) { throw 'The installed AppID tagging policy is missing or changed.' }
    if(@($receipt.RuleNames).Count -ne @($receipt.Programs).Count+1) { throw 'Firewall protection manifest is incomplete.' }
    # Batch CIM queries: per-executable round trips can exceed the CLI startup timeout.
    $active=@(Get-NetFirewallRule -PolicyStore ActiveStore -Group $settings.FirewallGroup -ErrorAction Stop)
    $byName=@{};$byAddress=@{};$byApplication=@{};$bySecurity=@{}
    foreach($item in $active) { $byName[$item.Name]=$item }
    foreach($item in @($active | Get-NetFirewallAddressFilter)) { $byAddress[$item.InstanceID]=$item }
    foreach($item in @($active | Get-NetFirewallApplicationFilter)) { $byApplication[$item.InstanceID]=$item }
    foreach($item in @($active | Get-NetFirewallSecurityFilter)) { $bySecurity[$item.InstanceID]=$item }
    foreach($name in @($receipt.RuleNames)) {
        if(-not $byName.ContainsKey($name) -or -not $byAddress.ContainsKey($name) -or -not $byApplication.ContainsKey($name) -or -not $bySecurity.ContainsKey($name)) { throw 'An application firewall rule or filter is missing.' }
        $rule=$byName[$name]
        if($rule.Enabled -ne 'True' -or $rule.Action -ne 'Block' -or $rule.Direction -ne 'Outbound' -or $rule.Group -ne $settings.FirewallGroup) { throw 'An application firewall rule is missing or disabled.' }
        $addresses=@($byAddress[$name].LocalAddress | Sort-Object)
        # Windows normalizes a single-address range, such as ::-::, to ::.
        $expected=@(Get-WesBlockedSourceAddresses | ForEach-Object { if($_ -eq '::-::') {'::'} else {$_} } | Sort-Object)
        if(($addresses -join '|') -ne ($expected -join '|')) { throw 'An application firewall address filter changed.' }
        $security=$bySecurity[$name]
        if($security.LocalUser -notlike ('*'+$identity.OwnerSid+'*')) { throw 'An application firewall user filter changed.' }
        $selector=@($receipt.RuleSelectors | Where-Object Name -eq $name)
        $application=$byApplication[$name]
        if($selector.Count -ne 1 -or ($selector[0].Program -and $application.Program -ne $selector[0].Program) -or ($selector[0].PolicyAppId -and $rule.PolicyAppId -ne $selector[0].PolicyAppId)) { throw 'An application firewall executable filter changed.' }
    }
    Initialize-WesWfpType
    if(@($receipt.FilterKeys).Count -ne (2*(@($receipt.Programs).Count+1)*@($receipt.DeniedProxyPorts).Count)) { throw 'Alternate-proxy filter manifest is incomplete.' }
    if(-not [WorkEnvironmentSetup.WfpProtection]::VerifyBlocks([guid]$settings.Sublayer,[string[]]$receipt.FilterKeys)) { throw 'Alternate-proxy blocking filters are missing or changed.' }
    return $receipt
}

Export-ModuleMember -Function Install-WesRoleProtection,Remove-WesRoleProtection,Assert-WesNetworkProtection,Initialize-WesWfpType,Get-WesBlockedSourceAddresses

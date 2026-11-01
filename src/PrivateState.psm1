Set-StrictMode -Version 2

function Get-WesOwnerSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-WesInstallationIdentity {
    [CmdletBinding()]
    param([string]$OwnerSid=(Get-WesOwnerSid))
    $null=[Security.Principal.SecurityIdentifier]::new($OwnerSid)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $bytes=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('work-environment-setup|ai-vpn|'+$OwnerSid)) }
    finally { $sha.Dispose() }
    $hash=([BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant()).Substring(0,12)
    $roles=[ordered]@{}
    foreach($role in @('Claude','Codex')) {
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $digest=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('work-environment-setup|ai-vpn|'+$OwnerSid+'|'+$role)) }
        finally { $sha.Dispose() }
        $roles[$role]=[pscustomobject]@{Tag=('WesAiVpn_'+$hash+'_'+$role);FirewallGroup=('WES AI VPN '+$hash+' '+$role);Sublayer=([guid]::new([byte[]]$digest[0..15])).ToString()}
    }
    return [pscustomobject]@{OwnerSid=$OwnerSid;Id=$hash;NamePrefix=('WesAiVpn-'+$hash);V2rayTaskName=('WesAiVpn-'+$hash+'-v2rayN');Roles=$roles}
}

function Test-WesPrivateDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path,[string]$OwnerSid=(Get-WesOwnerSid))
    if(-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $item=Get-Item -LiteralPath $Path -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $acl=Get-Acl -LiteralPath $Path
    if(-not $acl.AreAccessRulesProtected) { return $false }
    $allowed=@($OwnerSid,'S-1-5-18','S-1-5-32-544')
    $found=@{}
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) {
            $sid=$rule.IdentityReference.Value
            if($sid -notin $allowed) { return $false }
            if(($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) { $found[$sid]=$true }
        }
    }
    foreach($sid in $allowed) { if(-not $found.ContainsKey($sid)) { return $false } }
    return $true
}

function Test-WesPrivateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path,[string]$OwnerSid=(Get-WesOwnerSid))
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item=Get-Item -LiteralPath $Path -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $acl=[IO.File]::GetAccessControl($item.FullName,[Security.AccessControl.AccessControlSections]::Access)
    $allowed=@($OwnerSid,'S-1-5-18','S-1-5-32-544');$found=@{}
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) {
            $sid=$rule.IdentityReference.Value
            if($sid -notin $allowed) { return $false }
            if(($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) { $found[$sid]=$true }
        }
    }
    foreach($sid in $allowed) { if(-not $found.ContainsKey($sid)) { return $false } }
    return $true
}

function Protect-WesPrivateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Private file must be a regular file.' }
    $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @((Get-WesOwnerSid),'S-1-5-18','S-1-5-32-544')) {
        $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow')
        $acl.AddAccessRule($rule)
    }
    [IO.File]::SetAccessControl($item.FullName,$acl)
}

function Read-WesPrivateJson {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not (Test-WesPrivateDirectory (Split-Path ([IO.Path]::GetFullPath($Path)))) -or -not (Test-WesPrivateFile $Path)) { throw 'Private JSON file has unsafe permissions or is missing.' }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-WesPrivateJson {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Value)
    $full=[IO.Path]::GetFullPath($Path)
    $parent=Split-Path $full
    if(-not (Test-WesPrivateDirectory -Path $parent)) { throw 'Refusing to write private state into a directory with unsafe ACLs.' }
    if(Test-Path -LiteralPath $full) {
        if(-not (Test-WesPrivateFile $full)) { throw 'Refusing to preserve unsafe permissions on an existing private file.' }
    }
    $temporary=Join-Path $parent ('.wes-write-'+[guid]::NewGuid().ToString()+'.tmp')
    try {
        [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 80),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($full)) { [IO.File]::Replace($temporary,$full,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$full) }
    } finally { if([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Initialize-WesPrivateDirectory {
    [CmdletBinding()]
    param([string]$Path=(Join-Path $env:LOCALAPPDATA 'WorkEnvironmentSetup\AiVpn'),[string]$ExpectedOwnerSid=(Get-WesOwnerSid))
    $owner=Get-WesOwnerSid
    if($owner -ne $ExpectedOwnerSid) { throw 'Elevation switched to another account. Run installation as the intended Windows user.' }
    $full=[IO.Path]::GetFullPath($Path)
    $marker=Join-Path $full '.wes-owner.json'
    if(Test-Path -LiteralPath $full) {
        $item=Get-Item -LiteralPath $full -Force
        if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Private state root is not a regular directory.' }
        if(Test-Path -LiteralPath $marker) {
            $existing=Read-WesPrivateJson $marker
            if($existing.Product -ne 'work-environment-setup.ai-vpn' -or $existing.OwnerSid -ne $owner) { throw 'Private directory belongs to another installation or user.' }
            if(-not (Test-WesPrivateDirectory $full)) { throw 'Existing private directory has unsafe ACLs. Repair permissions explicitly.' }
            return $full
        }
        if(@(Get-ChildItem -LiteralPath $full -Force).Count) { throw 'Refusing to adopt a nonempty directory without an installation marker.' }
    } else { New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop | Out-Null }
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @($owner,'S-1-5-18','S-1-5-32-544')) {
        $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $full -AclObject $acl -ErrorAction Stop
    Write-WesPrivateJson -Path $marker -Value @{Product='work-environment-setup.ai-vpn';SchemaVersion=1;OwnerSid=$owner}
    return $full
}

function Read-WesInstallationState {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root)
    if(-not (Test-WesPrivateDirectory $Root)) { throw 'Private installation directory has unsafe ACLs.' }
    $path=Join-Path $Root 'installation.private.json'
    $state=Read-WesPrivateJson $path
    if($state.SchemaVersion -ne 1 -or $state.OwnerSid -ne (Get-WesOwnerSid)) { throw 'Installation state does not belong to this user or schema version.' }
    return $state
}

Export-ModuleMember -Function Get-WesOwnerSid,Get-WesInstallationIdentity,Test-WesPrivateDirectory,Test-WesPrivateFile,Protect-WesPrivateFile,Read-WesPrivateJson,Write-WesPrivateJson,Initialize-WesPrivateDirectory,Read-WesInstallationState

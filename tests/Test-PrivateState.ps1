$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PrivateState.psm1') -Force
$path=Join-Path ([IO.Path]::GetTempPath()) ('wes-private-'+[guid]::NewGuid().ToString())
try {
    $root=Initialize-WesPrivateDirectory -Path $path
    if(-not (Test-WesPrivateDirectory $root)) { throw 'Private directory ACL validation failed.' }
    $owner=Get-WesOwnerSid
    $identity=Get-WesInstallationIdentity
    $same=Get-WesInstallationIdentity -OwnerSid $owner
    $other=Get-WesInstallationIdentity -OwnerSid 'S-1-5-21-100-200-300-999'
    if($identity.Id -ne $same.Id -or $identity.Roles.Claude.Sublayer -ne $same.Roles.Claude.Sublayer -or $identity.Id -eq $other.Id) { throw 'Installation identity is not stable and per-user.' }
    $statePath=Join-Path $root 'installation.private.json'
    $unicode=([string][char]0x0442)+[char]0x0435+[char]0x0441+[char]0x0442
    Write-WesPrivateJson -Path $statePath -Value @{SchemaVersion=1;OwnerSid=$owner;Example=$unicode;Generation=1}
    if((Read-WesInstallationState $root).Example -cne $unicode) { throw 'Private JSON Unicode decoding failed.' }
    Write-WesPrivateJson -Path $statePath -Value @{SchemaVersion=1;OwnerSid=$owner;Example=$unicode;Generation=2}
    if((Read-WesInstallationState $root).Generation -ne 2) { throw 'Atomic state replacement failed.' }
    if(-not (Test-WesPrivateFile $statePath)) { throw 'New state file did not inherit private ACLs.' }
    if(@(Get-ChildItem -LiteralPath $root -Filter '*.tmp' -Force).Count) { throw 'Temporary state file was left behind.' }
    $originalAcl=[IO.File]::GetAccessControl($statePath,[Security.AccessControl.AccessControlSections]::Access)
    $fileAcl=[IO.File]::GetAccessControl($statePath,[Security.AccessControl.AccessControlSections]::Access)
    $broadRead=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Read','Allow')
    $fileAcl.AddAccessRule($broadRead);[IO.File]::SetAccessControl($statePath,$fileAcl)
    if(Test-WesPrivateFile $statePath) { throw 'Broad permissions on the state file were accepted.' }
    $rejected=$false;try { Write-WesPrivateJson -Path $statePath -Value @{SchemaVersion=1;OwnerSid=$owner} } catch { $rejected=$true }
    if(-not $rejected) { throw 'Atomic replacement preserved broad access to private data.' }
    $rejected=$false;try { $null=Read-WesInstallationState $root } catch { $rejected=$true }
    if(-not $rejected) { throw 'Reading state with broad file ACLs was allowed.' }
    $restoredAcl=[Security.AccessControl.FileSecurity]::new()
    $restoredAcl.SetSecurityDescriptorSddlForm($originalAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access),[Security.AccessControl.AccessControlSections]::Access)
    [IO.File]::SetAccessControl($statePath,$restoredAcl)
    [IO.File]::WriteAllText($statePath,'{"private": fixture-sensitive-value}',[Text.UTF8Encoding]::new($false))
    $rejected=$false
    try { $null=Read-WesInstallationState $root } catch { $rejected=$true;if($_.Exception.Message.Contains('fixture-sensitive-value')) { throw 'Private JSON content leaked in a parsing error.' } }
    if(-not $rejected) { throw 'Malformed private JSON was accepted.' }
    Write-WesPrivateJson -Path $statePath -Value @{SchemaVersion=1;OwnerSid='S-1-5-18'}
    $rejected=$false;try { $null=Read-WesInstallationState $root } catch { $rejected=$true }
    if(-not $rejected) { throw 'Another user state was accepted.' }
    $acl=[IO.Directory]::GetAccessControl($root,[Security.AccessControl.AccessControlSections]::Access)
    $extra=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($extra);[IO.Directory]::SetAccessControl($root,$acl)
    if(Test-WesPrivateDirectory $root) { throw 'A directory readable by other local users was accepted.' }
    Write-Output 'PASS: private ACLs, per-user identity, Unicode JSON, atomic replacement, foreign owner rejection, broad file access rejection and redacted JSON errors.'
} finally {
    foreach($file in @('installation.private.json','.wes-owner.json')) { Remove-Item -LiteralPath (Join-Path $path $file) -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
}

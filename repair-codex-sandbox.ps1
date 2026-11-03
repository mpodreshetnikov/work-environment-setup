#Requires -Version 5.1
[CmdletBinding()]
param([string]$CodexHome=(Join-Path $env:USERPROFILE '.codex'))
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell 5.1.' }
Import-Module (Join-Path $PSScriptRoot 'src\PrivateState.psm1') -Force
$homePath=[IO.Path]::GetFullPath($CodexHome)
$target=Join-Path $homePath '.sandbox-bin'
$current=$target
while($current) {
    $item=Get-Item -LiteralPath $current -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to repair a sandbox path containing a reparse point.' }
    $current=Split-Path -Path $current -Parent
}
$errorPath=Join-Path $homePath '.sandbox\setup_error.json'
if(-not (Test-Path -LiteralPath $errorPath) -or (Get-Content -LiteralPath $errorPath -Raw | ConvertFrom-Json).code -ne 'helper_sandbox_lock_failed') { throw 'This repair only handles a recorded helper_sandbox_lock_failed error. Run sandbox setup and inspect its error first.' }
$owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
$acl=Get-Acl -LiteralPath $target
if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $owner.Value) { throw 'The sandbox directory belongs to another account. No permissions were changed.' }
$backupRoot=Initialize-WesPrivateDirectory (Join-Path $env:LOCALAPPDATA 'WorkEnvironmentSetup\Diagnostics')
$backup=Join-Path $backupRoot ('sandbox-acl-'+[guid]::NewGuid().ToString('N')+'.private.json')
Write-WesPrivateJson $backup @{Directory=$target;OwnerSid=$owner.Value;Sddl=$acl.Sddl;CreatedUtc=[DateTime]::UtcNow.ToString('o')}
# Directory-only grants: keep existing child ACLs and sandbox-user restrictions.
# icacls changes the DACL without requiring SeSecurityPrivilege for the SACL.
$grants=@(('*'+$owner.Value+':(F)'),'*S-1-5-18:(F)','*S-1-5-32-544:(F)')
& (Join-Path $env:SystemRoot 'System32\icacls.exe') $target /grant $grants | Out-Null
if($LASTEXITCODE) { throw 'Directory ACL repair failed. Keep the saved ACL backup.' }
[pscustomobject]@{Status='DirectoryPermissionsRepaired';Directory=$target;Backup=$backup;NextStep='Retry Windows sandbox setup in the app, then run a sandboxed command.'}

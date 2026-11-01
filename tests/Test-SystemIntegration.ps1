#Requires -Version 5.1
#Requires -RunAsAdministrator
param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
foreach($module in @('PrivateState','SystemIntegration')) { Import-Module (Join-Path $PSScriptRoot ('..\src\'+$module+'.psm1')) -Force }
$rootPath=Initialize-WesPrivateDirectory $Root
$key='HKCU:\Software\WorkEnvironmentSetupTests\'+[guid]::NewGuid().ToString('N')
$receipt=$null;$failure=$null
try {
    $directories=@{}
    foreach($name in @('Desktop','Programs','Documents','bin')) { $directories[$name]=Join-Path $rootPath $name;$null=[IO.Directory]::CreateDirectory($directories[$name]) }
    $directories['Run']=$key+'\Run';$null=New-Item -Path $directories.Run -Force
    $exe=Join-Path $rootPath 'v2rayN.exe';Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $exe
    $runValue='"'+$exe+'" -fixture'
    Set-ItemProperty -LiteralPath $directories.Run -Name FixtureVpn -Value $runValue
    Set-ItemProperty -LiteralPath $directories.Run -Name Unrelated -Value 'unchanged'
    $profileOne=Join-Path $directories.Documents 'PowerShell\profile.ps1'
    $profileTwo=Join-Path $directories.Documents 'WindowsPowerShell\profile.ps1'
    foreach($path in @($profileOne,$profileTwo)) { $null=[IO.Directory]::CreateDirectory((Split-Path $path));[IO.File]::WriteAllText($path,'# original profile',[Text.Encoding]::Unicode) }
    $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($profileTwo))
    $state=[pscustomobject]@{Vpn=@{V2rayRoot=$rootPath};Applications=@(
        [pscustomobject]@{Kind='PackagedDesktop';Scope='ClaudeDesktop';MainExecutable=$exe},
        [pscustomobject]@{Kind='NativeCli';Scope='CodexCli'})}
    $receipt=Install-WesSystemIntegration -Root $rootPath -State $state -Locations $directories -SkipUserPath
    $task=Get-ScheduledTask -TaskName $receipt.TaskName
    if($task.Principal.RunLevel -ne 'Highest' -or $task.Actions.Execute -ne $exe) { throw 'Elevated logon task is incorrect.' }
    if(Get-ItemProperty -LiteralPath $directories.Run -Name FixtureVpn -ErrorAction SilentlyContinue) { throw 'Matching legacy autorun was not removed.' }
    if((Get-ItemProperty -LiteralPath $directories.Run -Name Unrelated).Unrelated -ne 'unchanged') { throw 'Unrelated autorun changed.' }
    foreach($entry in @($receipt.Shortcuts)) { if(-not (Test-Path -LiteralPath $entry.Path)) { throw 'Fixture shortcut is missing.' } }
    foreach($path in @($profileOne,$profileTwo)) { if([IO.File]::ReadAllText($path) -notmatch '# BEGIN WORK ENVIRONMENT AI VPN') { throw 'Managed profile block is missing.' } }
    [IO.File]::AppendAllText($profileOne,"`r`n# later user edit",[Text.UTF8Encoding]::new($false))
    $changedLink=Join-Path $directories.Desktop 'Claude VPN.lnk'
    $shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($changedLink);$link.TargetPath=$exe;$link.Arguments='user-edited';$link.Save()
    Remove-WesSystemIntegration $rootPath
    if(Get-ScheduledTask -TaskName $receipt.TaskName -ErrorAction SilentlyContinue) { throw 'Fixture task remains.' }
    if((Get-ItemProperty -LiteralPath $directories.Run -Name FixtureVpn).FixtureVpn -ne $runValue) { throw 'Legacy autorun was not restored.' }
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($profileTwo)) -ne $before) { throw 'Unedited profile bytes were not restored.' }
    $content=[IO.File]::ReadAllText($profileOne)
    if($content -match '# BEGIN WORK ENVIRONMENT AI VPN' -or $content -notmatch '# later user edit') { throw 'Profile cleanup lost the subsequent user edit.' }
    if(-not (Test-Path -LiteralPath $changedLink)) { throw 'A user-edited shortcut was removed.' }
    if(Test-Path -LiteralPath (Join-Path $directories.Programs 'Claude VPN.lnk')) { throw 'Owned shortcut remains after cleanup.' }
    Remove-WesSystemIntegration $rootPath
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($profileTwo)) -ne $before) { throw 'Repeated rollback changed an already restored profile.' }
    # A fresh installation must also handle accounts with no PowerShell profile.
    Remove-Item -LiteralPath $changedLink,$profileTwo,(Join-Path $rootPath 'integration.private.json')
    $receipt=Install-WesSystemIntegration -Root $rootPath -State $state -Locations $directories -SkipUserPath
    if(-not (Test-Path -LiteralPath $profileTwo)) { throw 'Missing profile was not created.' }
    Remove-WesSystemIntegration $rootPath
    if(Test-Path -LiteralPath $profileTwo) { throw 'Newly created profile remains after rollback.' }
} catch { $failure=$_.Exception.Message }
finally {
    try { if($receipt) { Remove-WesSystemIntegration $rootPath } elseif(Test-Path -LiteralPath (Join-Path $rootPath 'integration.private.json')) { Remove-WesSystemIntegration $rootPath } } catch { $failure='Integration rollback failed: '+$_.Exception.Message }
    if($key.StartsWith('HKCU:\Software\WorkEnvironmentSetupTests\',[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    Write-WesPrivateJson (Join-Path $rootPath 'integration-test-result.private.json') @{Status=if($failure){'Failed'}else{'Passed'};Error=$failure;UserPathChanged=$false;RealUserProfilesChanged=$false}
}
if($failure) { throw $failure }
Write-Output 'PASS: elevated logon task, isolated shortcuts and profiles, matching autorun backup/restore, preserved user changes and complete integration rollback.'

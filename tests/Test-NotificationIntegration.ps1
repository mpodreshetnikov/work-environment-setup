#Requires -Version 5.1
param([switch]$MachineRegistration,[switch]$WarmServer,[string]$FixtureRoot)
$ErrorActionPreference='Stop'
foreach($name in @('PrivateState','NotificationIntegration')) {Import-Module (Join-Path $PSScriptRoot ('..\src\'+$name+'.psm1')) -Force}
$base=if($FixtureRoot){$FixtureRoot}else{Join-Path ([IO.Path]::GetTempPath()) ('wes-toast-'+[guid]::NewGuid().ToString('N'))}
$root=Initialize-WesPrivateDirectory $base
$notificationRoot=Join-Path $root 'notifications'
$receipt=$null;$result=$null
try {
    $shortcut=Join-Path $root 'Fixture.lnk';$shell=New-Object -ComObject WScript.Shell
    $link=$shell.CreateShortcut($shortcut);$link.TargetPath=Join-Path $env:SystemRoot 'System32\notepad.exe';$link.Save()
    $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($shortcut))
    $launcher=Join-Path $root 'Launcher.ps1'
    [IO.File]::WriteAllText($launcher,'param([string]$Scope,[string]$NotificationArguments,[switch]$Quiet) @{Scope=$Scope;Arguments=$NotificationArguments}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot "observed.json")',[Text.Encoding]::ASCII)
    $appId='WorkEnvironmentSetup.ToastFixture.'+[guid]::NewGuid().ToString('N')
    $result=Install-WesNotificationIntegration -Root $notificationRoot -Kind Portable -LaunchScript $launcher -ShortcutPaths @($shortcut) -AppIds @($appId) -MachineRegistration:$MachineRegistration
    $receipt=Read-WesPrivateJson (Join-Path $notificationRoot 'notification-integration.private.json')
    $null=Assert-WesNotificationIntegration $notificationRoot
    foreach($entry in @($receipt.Registry)) {if((Get-Item -LiteralPath $entry.Path).GetValue($entry.Name) -ne $entry.Managed) {throw ('Notification registry value differs: '+$entry.Name)}}
    $merged=[Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('CLSID\'+$result.Clsid+'\LocalServer32')
    if(-not $merged) {throw 'The notification COM class is missing from the merged registry.'}
    $merged.Dispose()
    $folder=(New-Object -ComObject Shell.Application).NameSpace($root)
    if([string]$folder.ParseName('Fixture.lnk').ExtendedProperty('System.AppUserModel.ToastActivatorCLSID') -ne $result.Clsid) {throw 'Shortcut activator was not updated.'}
    $activation=@{AppId=$appId;Arguments='type=action&action=1&tag=123456789'}|ConvertTo-Json -Compress
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($activation))
    if($WarmServer) {
        $server=Start-Process -FilePath $result.Bridge -ArgumentList '-Embedding' -PassThru
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while(-not (Test-Path -LiteralPath (Join-Path $notificationRoot 'server-ready.private.json')) -and [DateTime]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 100}
    }
    $client=Join-Path $notificationRoot 'ToastProbe.exe';Copy-Item -LiteralPath $result.Bridge -Destination $client
    $process=Start-Process -FilePath $client -ArgumentList @('--probe-com',$encoded) -PassThru
    if(-not $process.WaitForExit(20000) -or $process.ExitCode -ne 0) {throw 'Real COM activation failed.'}
    $deadline=[DateTime]::UtcNow.AddSeconds(15);$observed=Join-Path $root 'observed.json'
    while(-not (Test-Path -LiteralPath $observed) -and [DateTime]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 100}
    if(-not (Test-Path -LiteralPath $observed)) {throw 'COM activation did not reach the protected launcher.'}
    $value=Get-Content -LiteralPath $observed -Raw|ConvertFrom-Json
    if($value.Scope -ne 'CodexDesktop' -or $value.Arguments -ne 'type=action&action=1&tag=123456789') {throw 'Notification payload was changed.'}
    foreach($bad in @(@{AppId='wrong';Arguments='type=action&action=1&tag=1'},@{AppId=$appId;Arguments='type=action&action=1&tag=1 --proxy-server=other'})) {
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($bad|ConvertTo-Json -Compress)))
        $process=Start-Process -FilePath $result.Bridge -ArgumentList @('--dispatch-base64',$encoded) -PassThru
        if(-not $process.WaitForExit(10000) -or $process.ExitCode -eq 0) {throw 'An unknown app or injected launch argument was accepted.'}
    }
    $route=@($receipt.Registry | Where-Object Name -eq 'CustomActivator')[0]
    Set-ItemProperty -LiteralPath $route.Path -Name $route.Name -Value 'modified-fixture'
    $rejected=$false;try {$null=Assert-WesNotificationIntegration $notificationRoot}catch{$rejected=$true}
    if(-not $rejected) {throw 'Changed notification routing was accepted.'}
    Set-ItemProperty -LiteralPath $route.Path -Name $route.Name -Value $route.Managed
    Remove-WesNotificationIntegration $notificationRoot
    Remove-WesNotificationIntegration $notificationRoot
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($shortcut)) -ne $before) {throw 'Original shortcut bytes were not restored.'}
    foreach($entry in @($receipt.Registry)) {if(Test-Path -LiteralPath $entry.Path) {if($entry.Name -in (Get-Item -LiteralPath $entry.Path).GetValueNames()) {throw 'Owned notification registration remains.'}}}
    Write-Output 'PASS: real COM activation, exact payload, invalid input denial, shortcut rollback and repeated notification cleanup.'
} finally {
    if($result) {Remove-WesNotificationIntegration $notificationRoot}
    if($result) {
        foreach($item in @(Get-CimInstance Win32_Process | Where-Object ExecutablePath -eq $result.Bridge)) {
            $owner=Invoke-CimMethod -InputObject $item -MethodName GetOwnerSid
            if($owner.Sid -eq (Get-WesOwnerSid)) {$p=Get-Process -Id $item.ProcessId;try{if($p.Path -eq $result.Bridge){$p.Kill();$null=$p.WaitForExit(5000)}}finally{$p.Dispose()}}
        }
    }
    # The COM server and loaded assembly may retain the executable until their
    # bounded lifetime ends. Keep this private fixture for explicit cleanup.
    Write-Output ('Notification fixture: '+$root)
}

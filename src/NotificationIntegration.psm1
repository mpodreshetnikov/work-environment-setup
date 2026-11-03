Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'PrivateState.psm1')

function Initialize-WesToastType {
    param([string]$Assembly)
    if(-not ('WorkEnvironmentSetup.Notifications.Shortcut' -as [type])) {$null=[Reflection.Assembly]::LoadFrom($Assembly)}
}

function Install-WesNotificationIntegration {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root,[ValidateSet('Legacy','Portable')][string]$Kind='Portable',
        [string]$LaunchScript,[string]$GuardScript,[string]$ProxyUrl,
        [string[]]$ShortcutPaths=@((Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\ChatGPT.lnk')),
        [string[]]$AppIds=@('com.openai.codex','OpenAI.Codex_2p2nqsd0c76g0!App'),[switch]$MachineRegistration)
    $full=Initialize-WesPrivateDirectory $Root
    $journal=Join-Path $full 'notification-integration.private.json'
    if(Test-Path -LiteralPath $journal) {
        $previous=Read-WesPrivateJson $journal
        if($previous.Status -ne 'Removed') {throw 'Notification integration already has a journal. Remove it before reinstalling.'}
        Move-Item -LiteralPath $journal -Destination ($journal+'.removed-'+[guid]::NewGuid().ToString('N'))
    }
    if($Kind -eq 'Legacy' -and (-not (Test-Path -LiteralPath $GuardScript) -or $ProxyUrl -notmatch '^http://127\.0\.0\.1:[0-9]{1,5}$')) {throw 'Invalid legacy notification guard.'}
    if($Kind -eq 'Portable' -and -not (Test-Path -LiteralPath $LaunchScript)) {throw 'Protected desktop launcher is missing.'}
    foreach($path in $ShortcutPaths) {if(-not (Test-Path -LiteralPath $path)) {throw 'Open Codex once, then fully quit it: its notification shortcut must exist before installation.'}}
    if('com.openai.codex' -in $AppIds) {
        $shell=New-Object -ComObject Shell.Application
        $links=New-Object -ComObject WScript.Shell
        $package=Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
        if(-not $package) {throw 'Codex package is unavailable.'}
        $expected=Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        foreach($path in $ShortcutPaths) {
            $folder=$shell.NameSpace((Split-Path $path));$item=$folder.ParseName((Split-Path $path -Leaf))
            if([string]$item.ExtendedProperty('System.AppUserModel.ID') -ne 'com.openai.codex' -or $links.CreateShortcut($path).TargetPath -ne $expected) {throw 'The notification shortcut belongs to another application. No routing was changed.'}
        }
    }
    $exe=Join-Path $full 'ToastBridge.exe'
    if(Test-Path -LiteralPath $exe) {Remove-Item -LiteralPath $exe -ErrorAction Stop}
    $compiler=[CodeDom.Compiler.CompilerParameters]::new()
    $compiler.GenerateExecutable=$true;$compiler.OutputAssembly=$exe;$compiler.CompilerOptions='/platform:x64 /target:winexe'
    foreach($reference in @('System.dll','System.Web.Extensions.dll','System.Windows.Forms.dll')) {$null=$compiler.ReferencedAssemblies.Add($reference)}
    Add-Type -Path (Join-Path $PSScriptRoot 'native\ToastBridge.cs') -CompilerParameters $compiler
    Protect-WesPrivateFile $exe
    Initialize-WesToastType $exe
    $source=Join-Path $PSScriptRoot 'runtime\NotificationActivation.ps1'
    if(-not (Test-Path -LiteralPath $source)) {$source=Join-Path $PSScriptRoot 'NotificationActivation.ps1'}
    $activation=Join-Path $full 'NotificationActivation.ps1';Copy-Item -LiteralPath $source -Destination $activation
    foreach($name in @('PrivateState.psm1','NotificationIntegration.psm1')) {Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $full $name)}
    $clsid=[guid]::NewGuid().ToString('B').ToUpperInvariant()
    Write-WesPrivateJson (Join-Path $full 'notification-config.private.json') @{Clsid=$clsid;AppIds=@($AppIds);ActivationScript=$activation;Kind=$Kind;LaunchScript=$LaunchScript;GuardScript=$GuardScript;ProxyUrl=$ProxyUrl}
    $receipt=[ordered]@{OwnerSid=(Get-WesOwnerSid);Status='Installing';Clsid=$clsid;Registry=@();Shortcuts=@();Files=@()}
    foreach($file in @($exe,$activation,(Join-Path $full 'notification-config.private.json'))) {$receipt.Files+=@(@{Path=$file;Hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash})}
    Write-WesPrivateJson $journal $receipt
    try {
        $classes=if($MachineRegistration){'HKLM:\Software\Classes'}else{'HKCU:\Software\Classes'}
        $changes=@(@{Path=($classes+'\CLSID\'+$clsid);Name='';Value='Codex VPN Notification Activator'},@{Path=($classes+'\CLSID\'+$clsid+'\LocalServer32');Name='';Value=('"'+$exe+'" -Embedding')},@{Path=($classes+'\CLSID\'+$clsid+'\LocalServer32');Name='ServerExecutable';Value=$exe})
        foreach($id in $AppIds) {
            if($id -notmatch '^[A-Za-z0-9_.!-]+$') {throw 'Invalid notification application identity.'}
            $changes+=@{Path=('HKCU:\Software\Classes\AppUserModelId\'+$id);Name='CustomActivator';Value=$clsid}
        }
        foreach($change in $changes) {
            $existed=$false;$before=$null;$kindBefore=$null;$keyExisted=Test-Path -LiteralPath $change.Path
            if($keyExisted) {$key=Get-Item -LiteralPath $change.Path;if($change.Name -in $key.GetValueNames()) {$existed=$true;$before=$key.GetValue($change.Name);$kindBefore=$key.GetValueKind($change.Name).ToString()}}
            $receipt.Registry+=@(@{Path=$change.Path;Name=$change.Name;Existed=$existed;Before=$before;Kind=$kindBefore;KeyExisted=$keyExisted;Managed=$change.Value})
            Write-WesPrivateJson $journal $receipt
            if(-not (Test-Path -LiteralPath $change.Path)) {$null=New-Item -Path $change.Path -Force}
            if($change.Name) {$null=New-ItemProperty -LiteralPath $change.Path -Name $change.Name -Value $change.Value -PropertyType String -Force}
            else {Set-Item -LiteralPath $change.Path -Value $change.Value}
        }
        foreach($path in $ShortcutPaths) {
            $entry=@{Path=$path;Before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($path));AfterHash=$null}
            $receipt.Shortcuts+=@($entry);Write-WesPrivateJson $journal $receipt
            [WorkEnvironmentSetup.Notifications.Shortcut]::SetActivator($path,$clsid)
            $entry.AfterHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Write-WesPrivateJson $journal $receipt
        }
        if('com.openai.codex' -in $AppIds) {
            $null=[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
            foreach($id in @($AppIds)) {[Windows.UI.Notifications.ToastNotificationManager]::History.Clear($id)}
        }
        $receipt.Status='Installed';Write-WesPrivateJson $journal $receipt
        return [pscustomobject]@{Root=$full;Bridge=$exe;Clsid=$clsid}
    } catch {Remove-WesNotificationIntegration $full;throw}
}

function Assert-WesNotificationIntegration {
    param([Parameter(Mandatory=$true)][string]$Root,[switch]$ActivationContext)
    $receipt=Read-WesPrivateJson (Join-Path $Root 'notification-integration.private.json')
    if($receipt.Status -ne 'Installed' -or $receipt.OwnerSid -ne (Get-WesOwnerSid)) {throw 'Notification protection is incomplete. Run repair.'}
    foreach($file in @($receipt.Files)) {if(-not (Test-WesPrivateFile $file.Path) -or (Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash -ne $file.Hash) {throw 'A protected notification handler file changed. Run repair.'}}
    foreach($entry in @($receipt.Registry)) {
        # Windows has already selected this activator during a COM callback.
        # The callback's per-user registry view can differ from the installer.
        # Check its machine registration, shortcut and private files here; the
        # standalone installation verifier also checks every per-user route.
        if($ActivationContext -and $entry.Path.StartsWith('HKCU:')) {continue}
        # COM-launched processes can have a different HKCU mapping. Verify the
        # installation owner's loaded hive explicitly, never the ambient alias.
        if($entry.Path.StartsWith('HKCU:')) {$key=[Microsoft.Win32.Registry]::Users.OpenSubKey($receipt.OwnerSid+'\'+$entry.Path.Substring(6))}
        elseif($entry.Path.StartsWith('HKLM:')) {$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($entry.Path.Substring(6))}
        else {throw 'Unknown notification registry scope.'}
        $exists=($null -ne $key);$actual=$null
        if($key) {try{$actual=$key.GetValue($entry.Name)}finally{$key.Dispose()}}
        if(-not $exists -or $actual -ne $entry.Managed) {
            Write-WesPrivateJson (Join-Path $Root 'routing-error.private.json') @{Path=$entry.Path;Name=$entry.Name;Actual=$actual;Expected=$entry.Managed;Exists=$exists;Is64Bit=[Environment]::Is64BitProcess;OwnerSid=(Get-WesOwnerSid)}
            throw 'Notification routing changed. Run repair.'
        }
    }
    foreach($entry in @($receipt.Shortcuts)) {if(-not (Test-Path -LiteralPath $entry.Path) -or (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -ne $entry.AfterHash) {throw 'The notification shortcut changed. Run repair.'}}
    return $receipt
}

function Remove-WesNotificationIntegration {
    param([Parameter(Mandatory=$true)][string]$Root)
    $journal=Join-Path $Root 'notification-integration.private.json'
    if(-not (Test-Path -LiteralPath $journal)) {return}
    $receipt=Read-WesPrivateJson $journal
    if($receipt.OwnerSid -ne (Get-WesOwnerSid)) {throw 'Notification journal belongs to another account.'}
    if($receipt.Status -eq 'Removed') {return}
    foreach($entry in @($receipt.Shortcuts)) {
        if($entry.AfterHash -and (Test-Path -LiteralPath $entry.Path) -and (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -eq $entry.AfterHash) {[IO.File]::WriteAllBytes($entry.Path,[Convert]::FromBase64String($entry.Before))}
    }
    $entries=@($receipt.Registry);[array]::Reverse($entries)
    foreach($entry in $entries) {
        if(-not (Test-Path -LiteralPath $entry.Path)) {continue}
        $key=Get-Item -LiteralPath $entry.Path
        if($key.GetValue($entry.Name) -ne $entry.Managed) {continue}
        if($entry.Existed) {
            if($entry.Name) {$null=New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Before -PropertyType $entry.Kind -Force}
            else {Set-Item -LiteralPath $entry.Path -Value $entry.Before}
        } else {
            $hive=if($entry.Path.StartsWith('HKLM:')) {[Microsoft.Win32.Registry]::LocalMachine}else{[Microsoft.Win32.Registry]::CurrentUser}
            $key=$hive.OpenSubKey($entry.Path.Substring(6),$true)
            try {$key.DeleteValue($entry.Name,$false)} finally {$key.Dispose()}
        }
        $key=Get-Item -LiteralPath $entry.Path
        if(-not $entry.KeyExisted -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {Remove-Item -LiteralPath $entry.Path}
    }
    $receipt.Status='Removed';Write-WesPrivateJson $journal $receipt
}

Export-ModuleMember -Function Install-WesNotificationIntegration,Remove-WesNotificationIntegration,Assert-WesNotificationIntegration

Set-StrictMode -Version 2
foreach($module in @('PrivateState','Discovery','NetworkProtection','SystemIntegration')) { Import-Module (Join-Path $PSScriptRoot ($module+'.psm1')) }

function Assert-WesApplicationsClosed {
    param([Parameter(Mandatory=$true)][object[]]$Applications)
    $paths=@($Applications.Executables | Sort-Object -Unique)
    $running=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -in $paths })
    if($running.Count) { throw ('Fully quit the selected AI applications before installation or maintenance. Running processes: '+(($running | ForEach-Object { $_.Name+' ('+$_.ProcessId+')' }) -join ', ')) }
}

function Remove-WesOwnedSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root)
    $state=Read-WesInstallationState $Root
    $state.Status='Removing';Write-WesPrivateJson (Join-Path $Root 'installation.private.json') $state
    Remove-WesSystemIntegration $Root
    foreach($role in @('Claude','Codex')) {
        $path=Join-Path $Root ($role.ToLowerInvariant()+'-protection.private.json')
        if(Test-Path -LiteralPath $path) {
            $receipt=Read-WesPrivateJson $path
            $identity=Get-WesInstallationIdentity
            if($receipt.OwnerSid -ne $identity.OwnerSid -or $receipt.Tag -ne $identity.Roles[$role].Tag) { throw 'Protection receipt belongs to another user.' }
            if($receipt.Status -notin @('Removed','RolledBack')) { Remove-WesRoleProtection $receipt }
            $receipt.Status='Removed';Write-WesPrivateJson $path $receipt
        }
    }
    $state.Status='Removed';Write-WesPrivateJson (Join-Path $Root 'installation.private.json') $state
}

function Stop-WesOwnedProxy {
    param([Parameter(Mandatory=$true)][string]$Root)
    $exe=Join-Path $Root 'core\xray.exe';$config=Join-Path $Root 'proxy.private.json'
    foreach($item in @(Get-CimInstance Win32_Process -Filter "Name='xray.exe'" | Where-Object { $_.ExecutablePath -eq $exe })) {
        $owner=Invoke-CimMethod -InputObject $item -MethodName GetOwnerSid
        if($owner.ReturnValue -ne 0 -or $owner.Sid -ne (Get-WesOwnerSid) -or -not $item.CommandLine.Contains($config)) { throw 'Refusing to stop an unexpected proxy process.' }
        $process=Get-Process -Id $item.ProcessId -ErrorAction Stop
        try { if($process.Path -ne $exe) { throw 'Proxy process changed during removal.' };$process.Kill();$null=$process.WaitForExit(5000) } finally { $process.Dispose() }
    }
}

Export-ModuleMember -Function Assert-WesApplicationsClosed,Remove-WesOwnedSettings,Stop-WesOwnedProxy

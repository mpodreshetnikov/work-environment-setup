#Requires -Version 5.1
#Requires -RunAsAdministrator
param([Parameter(Mandatory=$true)][string]$Root,[switch]$Handshake,[switch]$Integration,[switch]$DirectHttpsCheck)
$ErrorActionPreference='Stop'
foreach($module in @('PrivateState','NetworkProtection')) { Import-Module (Join-Path $PSScriptRoot ('..\src\'+$module+'.psm1')) -Force }
$rootPath=Initialize-WesPrivateDirectory $Root
$report=Join-Path $rootPath 'test-result.private.json'
$receipt=$null;$fixture=$null;$failure=$null
function Invoke-FixtureCurl {
    param([string]$Executable,[int]$Port,[switch]$DirectHttps)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Executable
    $start.Arguments='--disable --noproxy * --connect-timeout 2 --max-time 3 --silent --output NUL http://127.0.0.1:'+$Port+'/'
    if($DirectHttps) { $start.Arguments='--disable --noproxy * --ipv4 --connect-timeout 4 --max-time 8 --silent --output NUL https://www.cloudflare.com/cdn-cgi/trace' }
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($start)
    try { if(-not $process.WaitForExit(12000)) { $process.Kill();throw 'Fixture curl timed out.' };return $process.ExitCode } finally { $process.Dispose() }
}
try {
    if($Integration) {
        & (Join-Path $PSScriptRoot 'Test-SystemIntegration.ps1') -Root (Join-Path $rootPath 'integration-fixture')
        & (Join-Path $PSScriptRoot 'Test-NotificationIntegration.ps1') -MachineRegistration -FixtureRoot (Join-Path $rootPath 'notification-fixture')
    }
    Add-Type -Path (Join-Path $PSScriptRoot 'HttpFixture.cs')
    $fixture=[WorkEnvironmentSetup.Tests.HttpFixture]::new()
    $curl=Join-Path $rootPath 'fixture-curl.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\curl.exe') -Destination $curl
    if((Invoke-FixtureCurl $curl $fixture.Port) -ne 0) { throw 'Fixture was not reachable before protection.' }
    if($DirectHttpsCheck -and (Invoke-FixtureCurl $curl 0 -DirectHttps) -ne 0) { throw 'Direct HTTPS was not reachable before the fixture firewall rule.' }
    $applications=@([pscustomobject]@{Scope='ClaudeCode';Executables=@($curl);TagPatterns=@($curl)})
    $receipt=Install-WesRoleProtection -Root $rootPath -Role Claude -Applications $applications -DeniedProxyPorts @($fixture.Port)
    $null=Assert-WesNetworkProtection -Root $rootPath -Scope ClaudeCode
    if((Invoke-FixtureCurl $curl $fixture.Port) -ne 7) { throw 'Persistent alternate-proxy block did not reject the isolated connection.' }
    if($DirectHttpsCheck) {
        if((Invoke-FixtureCurl $curl 0 -DirectHttps) -ne 7) { throw 'Non-loopback IPv4 HTTPS was not rejected by the fixture firewall rule.' }
        if((Invoke-FixtureCurl (Join-Path $env:SystemRoot 'System32\curl.exe') 0 -DirectHttps) -ne 0) { throw 'The fixture firewall rule restricted an unrelated system curl.' }
    }
    # A normal system tool remains unrestricted, although the fixture copy is protected.
    if((Invoke-FixtureCurl (Join-Path $env:SystemRoot 'System32\curl.exe') $fixture.Port) -ne 0) { throw 'An unrelated executable inherited the fixture restriction.' }
    $owner=Get-WesOwnerSid
    $tagTest=[WorkEnvironmentSetup.WfpProtection]::Test($curl,$receipt.Tag,$owner)
    if($tagTest['before'] -ne 0 -or $tagTest['blocked'] -ne 7 -or $tagTest['afterCleanup'] -ne 0) { throw 'Per-user AppID-tagged filter did not pass the isolated test.' }
    $foreign=[WorkEnvironmentSetup.WfpProtection]::Test($curl,$null,'S-1-5-21-111111111-222222222-333333333-4444')
    if($foreign['before'] -ne 0 -or $foreign['blocked'] -ne 0 -or $foreign['afterCleanup'] -ne 0) { throw 'A filter for another user affected this account.' }
    Write-WesPrivateJson $report @{Phase='Installed';Root=$rootPath;Checks=@('Persistent WFP block','Unrelated curl allowed','Per-user AppID tag','Foreign SID unaffected')}
    if($Handshake) {
        $signal=Join-Path $rootPath 'continue.private.json';$deadline=[DateTime]::UtcNow.AddSeconds(45)
        while(-not (Test-Path -LiteralPath $signal) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
        if(-not (Test-Path -LiteralPath $signal)) { throw 'Unelevated verification handshake timed out.' }
    }
} catch { $failure=$_.Exception.Message }
finally {
    try {
        if($receipt) {
            Remove-WesRoleProtection $receipt
            # A power loss can leave a deployed receipt after the actual objects
            # have been removed. Recovery must tolerate the same receipt again.
            Remove-WesRoleProtection $receipt
        }
        if($fixture -and (Test-Path -LiteralPath (Join-Path $rootPath 'fixture-curl.exe'))) {
            if((Invoke-FixtureCurl (Join-Path $rootPath 'fixture-curl.exe') $fixture.Port) -ne 0) { throw 'Fixture connection did not recover after rollback.' }
            if($DirectHttpsCheck -and (Invoke-FixtureCurl (Join-Path $rootPath 'fixture-curl.exe') 0 -DirectHttps) -ne 0) { throw 'Direct HTTPS did not recover after the fixture firewall rollback.' }
        }
    } catch { $failure='Rollback verification failed: '+$_.Exception.Message }
    if($fixture) { $fixture.Dispose() }
    Write-WesPrivateJson $report @{Phase=if($failure){'Failed'}else{'Passed'};Error=$failure;SettingsRemoved=($null -ne $receipt)}
}
if($failure) { throw $failure }
Write-Output 'PASS: persistent filters, per-user tags, unrelated executable, rollback and connection restoration.'

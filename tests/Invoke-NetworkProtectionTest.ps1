#Requires -Version 5.1
param([switch]$Integration,[switch]$DirectHttpsCheck)
$ErrorActionPreference='Stop'
foreach($module in @('PrivateState','NetworkProtection')) { Import-Module (Join-Path $PSScriptRoot ('..\src\'+$module+'.psm1')) -Force }
$isAdministrator=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if($isAdministrator) { throw 'Run this test from an unelevated Windows PowerShell; it requests UAC for its isolated child.' }
$path=Join-Path ([IO.Path]::GetTempPath()) ('wes-network-'+[guid]::NewGuid().ToString('N'))
$root=Initialize-WesPrivateDirectory $path
$process=$null;$passed=$false
try {
    $script=Join-Path $PSScriptRoot 'Test-NetworkProtection.ps1'
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$script+'" -Root "'+$root+'" -Handshake'
    if($Integration) { $arguments+=' -Integration' }
    if($DirectHttpsCheck) { $arguments+=' -DirectHttpsCheck' }
    $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
    $report=Join-Path $root 'test-result.private.json';$deadline=[DateTime]::UtcNow.AddSeconds(90)
    while(-not (Test-Path -LiteralPath $report) -and [DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) { Start-Sleep -Milliseconds 250 }
    if(-not (Test-Path -LiteralPath $report)) { throw 'Elevated fixture did not report readiness.' }
    $result=Read-WesPrivateJson $report
    if($result.Phase -ne 'Installed') { throw ('Elevated fixture failed: '+$result.Error) }
    try {
        $null=Assert-WesNetworkProtection -Root $root -Scope ClaudeCode
        Write-Output 'PASS: actual WFP filters and firewall rules are readable and verifiable without administrator rights.'
    } finally { Write-WesPrivateJson (Join-Path $root 'continue.private.json') @{Continue=$true} }
    if(-not $process.WaitForExit(15000)) { throw 'Elevated fixture rollback did not finish.' }
    $result=Read-WesPrivateJson $report
    if($result.Phase -ne 'Passed') { throw ('Elevated fixture failed: '+$result.Error) }
    $receipt=Read-WesPrivateJson (Join-Path $root 'claude-protection.private.json')
    if(Get-NetFirewallRule -Group $receipt.Group -ErrorAction SilentlyContinue) { throw 'Fixture firewall rules remain after cleanup.' }
    Initialize-WesWfpType
    if([WorkEnvironmentSetup.WfpProtection]::VerifyBlocks([guid]$receipt.Sublayer,[string[]]$receipt.FilterKeys)) { throw 'Fixture WFP filters remain after cleanup.' }
    $policy=Join-Path $env:SystemRoot ('System32\CodeIntegrity\CiPolicies\Active\'+$receipt.PolicyId+'.cip')
    if(Test-Path -LiteralPath $policy) { throw 'Fixture AppID tagging policy remains after cleanup.' }
    $passed=$true
    Write-Output 'PASS: persistent WFP denial, AppID tag, user scope, unrestricted external curl, rollback and restored connection.'
} finally {
    if($process) { $process.Dispose() }
    if($passed) {
        $full=[IO.Path]::GetFullPath($root);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if($full.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -like 'wes-network-*') { Remove-Item -LiteralPath $full -Recurse -Force }
    } else { Write-Warning ('Test state retained for recovery: '+$root) }
}

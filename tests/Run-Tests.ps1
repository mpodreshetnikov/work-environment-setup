#Requires -Version 5.1
param([switch]$Live,[string]$V2rayRoot,[string]$TunInterfaceAlias,[switch]$Network)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell 5.1.' }
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$offline=@('Test-SourceSafety.ps1','Test-CanonicalPath.ps1','Test-ExecutableArchitecture.ps1','Test-PrivateState.ps1','Test-StartupControls.ps1','Test-CliBridge.ps1')
foreach($test in $offline) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if($LASTEXITCODE -ne 0) { throw ('Test failed: '+$test) }
}
if($Live) {
    Import-Module (Join-Path $PSScriptRoot '..\src\V2rayProfile.psm1')
    $resolved=Resolve-WesV2rayRoot $V2rayRoot
    if(-not $TunInterfaceAlias) { throw 'Pass -TunInterfaceAlias for live VPN tests.' }
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-V2rayImport.ps1') -SqliteDllPath (Join-Path $resolved 'e_sqlite3.dll')
    if($LASTEXITCODE -ne 0) { throw 'Profile import test failed.' }
    foreach($test in @('Test-ProxyPreparation.ps1','Test-RuntimeProxy.ps1')) {
        if($test -eq 'Test-RuntimeProxy.ps1') { & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test) -V2rayRoot $resolved -TunInterfaceAlias $TunInterfaceAlias }
        else { & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test) -V2rayRoot $resolved }
        if($LASTEXITCODE -ne 0) { throw ('Live test failed: '+$test) }
    }
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-LaunchPreparation.ps1')
    if($LASTEXITCODE -ne 0) { throw 'Launch preparation test failed.' }
}
if($Network) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Invoke-NetworkProtectionTest.ps1')
    if($LASTEXITCODE -ne 0) { throw 'Network protection test failed.' }
}
Write-Output 'PASS: requested test suites completed.'

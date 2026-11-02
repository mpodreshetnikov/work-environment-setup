$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\StartupControls.psm1') -Force
$id=[guid]::NewGuid().ToString('N')
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('wes-startup-'+$id)
$registry='HKCU:\Software\WorkEnvironmentSetupTests\'+$id
$family='WesStartupFixture_test';$taskPath=$registry+'\'+$family+'\App'
try {
    $null=[IO.Directory]::CreateDirectory($temporary)
    [IO.File]::WriteAllText((Join-Path $temporary 'AppxManifest.xml'),'<Package><StartupTask TaskId="App" Enabled="true" /></Package>')
    $application=[pscustomobject]@{Scope='CodexDesktop';Kind='PackagedDesktop';PackageFamilyName=$family;InstallRoot=$temporary}
    $null=New-Item -Path $taskPath -Force
    foreach($initial in @(0,1,2,3)) {
        $null=New-ItemProperty -LiteralPath $taskPath -Name State -PropertyType DWord -Value $initial -Force
        $records=@(Get-WesStartupTaskRecords -Applications @($application) -RegistryRoot $registry)
        Disable-WesStartupTasks $records
        $expected=if($initial -eq 3){3}else{1}
        if((Get-ItemProperty -LiteralPath $taskPath).State -ne $expected) { throw 'Startup task was not disabled while preserving disabled administrator policy.' }
        Restore-WesStartupTasks $records
        Restore-WesStartupTasks $records
        if((Get-ItemProperty -LiteralPath $taskPath).State -ne $initial) { throw 'Startup task rollback did not restore the original state.' }
    }
    Remove-ItemProperty -LiteralPath $taskPath -Name State
    $records=@(Get-WesStartupTaskRecords -Applications @($application) -RegistryRoot $registry)
    Disable-WesStartupTasks $records;Restore-WesStartupTasks $records
    if('State' -in (Get-Item -LiteralPath $taskPath).GetValueNames()) { throw 'An originally absent startup state was not removed.' }
    $null=New-ItemProperty -LiteralPath $taskPath -Name State -PropertyType DWord -Value 2 -Force
    $records=@(Get-WesStartupTaskRecords -Applications @($application) -RegistryRoot $registry)
    Disable-WesStartupTasks $records
    Set-ItemProperty -LiteralPath $taskPath -Name State -Value 0
    Restore-WesStartupTasks $records
    if((Get-ItemProperty -LiteralPath $taskPath).State -ne 0) { throw 'Rollback overwrote a later user change.' }
    Set-ItemProperty -LiteralPath $taskPath -Name State -Value 4
    $rejected=$false;try {$null=Get-WesStartupTaskRecords -Applications @($application) -RegistryRoot $registry} catch {$rejected=$true}
    if(-not $rejected) { throw 'Administrator-enforced startup was silently overridden.' }
    Set-ItemProperty -LiteralPath $taskPath -Name State -Value 2
    $records=@(Get-WesStartupTaskRecords -Applications @($application) -RegistryRoot $registry)
    Set-ItemProperty -LiteralPath $taskPath -Name State -Value 4
    $rejected=$false;try {Disable-WesStartupTasks $records} catch {$rejected=$true}
    if(-not $rejected -or (Get-ItemProperty -LiteralPath $taskPath).State -ne 4) { throw 'A policy change between planning and application was overwritten.' }
    Write-Output 'PASS: packaged startup disable, original/missing state restoration, repeat rollback, preserved user change and administrator policy rejection.'
} finally {
    if($registry -eq ('HKCU:\Software\WorkEnvironmentSetupTests\'+$id)) { Remove-Item -LiteralPath $registry -Recurse -Force -ErrorAction SilentlyContinue }
    $full=[IO.Path]::GetFullPath($temporary);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -eq ('wes-startup-'+$id)) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
}

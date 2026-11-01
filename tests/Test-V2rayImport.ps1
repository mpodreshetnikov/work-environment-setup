param([Parameter(Mandatory=$true)][string]$SqliteDllPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\V2rayProfile.psm1') -Force
if(-not ('WorkEnvironmentSetup.SqliteProfileReader' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot '..\src\native\SqliteProfileReader.cs') }
[WorkEnvironmentSetup.SqliteProfileReader]::Load($SqliteDllPath)
Add-Type -Path (Join-Path $PSScriptRoot 'SqliteFixture.cs')
$suffix=([string][char]0x0442)+[char]0x0435+[char]0x0441+[char]0x0442
$dir=Join-Path ([IO.Path]::GetTempPath()) ('wes-'+[guid]::NewGuid().ToString()+'-'+$suffix)
New-Item -ItemType Directory -Path $dir | Out-Null
$db=Join-Path $dir 'fixture.db'
try {
    [WesSqliteFixture]::Create($db)
    $before=(Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash
    $profile=[WorkEnvironmentSetup.SqliteProfileReader]::ReadProfile($db,"profile'quoted")
    if(-not $profile -or $profile['Address'] -ne '203.0.113.10') { throw 'Quoted identifier or Unicode path read failed.' }
    if($null -ne [WorkEnvironmentSetup.SqliteProfileReader]::ReadProfile($db,"' OR 1=1 --")) { throw 'Identifier binding did not isolate the selected row.' }
    $outbound=ConvertTo-WesVlessOutbound -Profile $profile
    if($outbound.protocol -ne 'vless' -or $outbound.settings.vnext[0].users[0].id -ne $profile['Id'] -or $outbound.streamSettings.realitySettings.fingerprint -ne 'firefox') { throw 'VLESS conversion changed required profile fields.' }
    $gui=Join-Path $dir 'guiConfigs'; New-Item -ItemType Directory -Path $gui | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dir 'v2rayN.exe'),[byte[]]@())
    Copy-Item -LiteralPath $db -Destination (Join-Path $gui 'guiNDB.db')
    @{IndexId="profile'quoted";TunModeItem=@{EnableTun=$true}} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $gui 'guiNConfig.json') -Encoding UTF8
    $snapshot=Get-WesVpnSnapshot -V2rayRoot $dir -SqliteLibraryPath $SqliteDllPath
    if($snapshot.Source -ne 'persistent-database') { throw 'Missing runtime configuration was not handled.' }
    $corePath=Join-Path $dir 'core.json'
    @{outbounds=@($outbound)} | ConvertTo-Json -Depth 50 | Set-Content $corePath -Encoding UTF8
    $exported=Get-WesVpnSnapshot -V2rayRoot $dir -SqliteLibraryPath $SqliteDllPath -CoreConfigPath $corePath
    if($exported.Source -ne 'core-json') { throw 'Verified exported configuration was not imported.' }
    $broken=Get-Content $corePath -Raw | ConvertFrom-Json
    $broken.outbounds[0].settings.vnext=@($broken.outbounds[0].settings.vnext[0],$broken.outbounds[0].settings.vnext[0])
    $broken | ConvertTo-Json -Depth 50 | Set-Content $corePath -Encoding UTF8
    $rejected=$false; try { $null=Get-WesVpnSnapshot -V2rayRoot $dir -SqliteLibraryPath $SqliteDllPath -CoreConfigPath $corePath } catch { $rejected=$true }
    if(-not $rejected) { throw 'An additional outbound server was silently accepted.' }
    $broken=@{outbounds=@($outbound)} | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $broken.outbounds[0].streamSettings.security='none'
    $broken | ConvertTo-Json -Depth 50 | Set-Content $corePath -Encoding UTF8
    $rejected=$false; try { $null=Get-WesVpnSnapshot -V2rayRoot $dir -SqliteLibraryPath $SqliteDllPath -CoreConfigPath $corePath } catch { $rejected=$true }
    if(-not $rejected) { throw 'A transport security downgrade was silently accepted.' }
    [IO.File]::WriteAllText($corePath,'{"outbounds": fixture-sensitive-value}',[Text.UTF8Encoding]::new($false))
    $rejected=$false
    try { $null=Get-WesVpnSnapshot -V2rayRoot $dir -SqliteLibraryPath $SqliteDllPath -CoreConfigPath $corePath } catch { $rejected=$true;if($_.Exception.Message.Contains('fixture-sensitive-value')) { throw 'Exported VPN contents leaked through a parsing error.' } }
    if(-not $rejected) { throw 'Malformed exported JSON was accepted.' }
    $profile['Network']='ws'
    $rejected=$false
    try { $null=ConvertTo-WesVlessOutbound -Profile $profile } catch { $rejected=$true }
    if(-not $rejected) { throw 'Unsupported transport was silently changed.' }
    if((Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash -ne $before) { throw 'The read-only adapter changed the source database.' }
    Write-Output 'PASS: Unicode path, bound ID, read-only DB, missing runtime JSON, verified export, extra server rejection, security downgrade rejection, unsupported transport rejection.'
} finally {
    foreach($file in @('guiNDB.db','guiNConfig.json')) { Remove-Item -LiteralPath (Join-Path (Join-Path $dir 'guiConfigs') $file) -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $dir 'guiConfigs') -ErrorAction SilentlyContinue
    foreach($file in @('core.json','v2rayN.exe')) { Remove-Item -LiteralPath (Join-Path $dir $file) -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $db -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -ErrorAction SilentlyContinue
}

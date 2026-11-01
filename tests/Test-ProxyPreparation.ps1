param([string]$V2rayRoot)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PrivateState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\V2rayProfile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\ProxyPreparation.psm1') -Force
$path=Join-Path ([IO.Path]::GetTempPath()) ('wes-proxy-'+[guid]::NewGuid().ToString())
try {
    $root=Initialize-WesPrivateDirectory -Path $path
    $snapshot=Get-WesVpnSnapshot -V2rayRoot $V2rayRoot
    $proxy=Initialize-WesPinnedProxy -Root $root -Snapshot $snapshot -Port 20080
    $config=Read-WesPrivateJson -Path $proxy.ConfigPath
    if(@($config.outbounds).Count -ne 1 -or $config.outbounds[0].protocol -in @('freedom','blackhole') -or $config.inbounds[0].listen -ne '127.0.0.1') { throw 'The prepared proxy has an unexpected routing boundary.' }
    if(-not (Test-WesPrivateFile $proxy.Executable) -or -not (Test-WesPrivateFile $proxy.ConfigPath)) { throw 'Prepared proxy files have unsafe ACLs.' }
    if((Get-FileHash -LiteralPath $proxy.Executable -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $snapshot.XrayPath -Algorithm SHA256).Hash) { throw 'The proxy binary changed during preparation.' }
    $rejected=$false;try { $null=Initialize-WesPinnedProxy -Root $root -Snapshot $snapshot -Port 20081 } catch { $rejected=$true }
    if(-not $rejected) { throw 'An existing pinned profile was silently replaced.' }
    Write-Output 'PASS: private proxy files, original binary hash, one outbound, no direct fallback, Xray validation and explicit-repin guard. No listener was started.'
} finally {
    foreach($file in @('proxy.private.json','proxy-manifest.private.json','.wes-owner.json','core\xray.exe','core\.wes-owner.json')) { Remove-Item -LiteralPath (Join-Path $path $file) -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $path 'core') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
}

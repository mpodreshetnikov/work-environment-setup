param([Parameter(Mandatory=$true)][string]$TunInterfaceAlias,[string]$V2rayRoot)
$ErrorActionPreference='Stop'
foreach($module in @('PrivateState','V2rayProfile','ProxyPreparation','Runtime')) { Import-Module (Join-Path $PSScriptRoot ('..\src\'+$module+'.psm1')) -Force }
$path=Join-Path ([IO.Path]::GetTempPath()) ('wes-runtime-'+[guid]::NewGuid().ToString())
$proxy=$null
try {
    $root=Initialize-WesPrivateDirectory -Path $path
    $snapshot=Get-WesVpnSnapshot -V2rayRoot $V2rayRoot
    $used=@(Get-NetTCPConnection -State Listen | Select-Object -ExpandProperty LocalPort)
    $port=@(20100..20150 | Where-Object {$_ -notin $used})[0]
    if(-not $port) { throw 'No free test port.' }
    $proxy=Initialize-WesPinnedProxy -Root $root -Snapshot $snapshot -Port $port
    $state=@{SchemaVersion=1;OwnerSid=(Get-WesOwnerSid);Vpn=@{ProfileId=$snapshot.ProfileId;GuiConfigPath=$snapshot.GuiConfigPath;TunInterfaceAlias=$TunInterfaceAlias}}
    Write-WesPrivateJson -Path (Join-Path $root 'installation.private.json') -Value $state
    $ready=Get-WesRuntimeReadiness $root
    $again=Start-WesPinnedProxy $root
    if($ready.ProcessId -ne $again.ProcessId) { throw 'A second proxy process was started instead of reusing the verified listener.' }
    $state.Vpn.ProfileId='invalid-profile-fixture'
    Write-WesPrivateJson -Path (Join-Path $root 'installation.private.json') -Value $state
    $rejected=$false;try { $null=Get-WesRuntimeReadiness $root } catch { $rejected=$true }
    if(-not $rejected) { throw 'A different selected profile was allowed.' }
    $rejected=$false;try { Assert-WesVpnReady -State $state } catch { $rejected=$true }
    if(-not $rejected) { throw 'Persistent GUI profile mismatch was allowed.' }
    $state.Vpn.ProfileId=$snapshot.ProfileId;$state.Vpn.TunInterfaceAlias='missing-wes-interface-fixture'
    Write-WesPrivateJson -Path (Join-Path $root 'installation.private.json') -Value $state
    $rejected=$false;try { $null=Get-WesRuntimeReadiness $root } catch { $rejected=$true }
    if(-not $rejected) { throw 'A missing TUN interface was allowed.' }
    foreach($invalidUrl in @('http://example.com:20080','http://user:password@127.0.0.1:20080','http://127.0.0.1:20080/ --noproxy *')) {
        $rejected=$false;try { $null=Test-WesProxyConnection $invalidUrl } catch { $rejected=$true }
        if(-not $rejected) { throw 'An invalid or injectable proxy URL was allowed.' }
    }
    if(-not (Test-WesPathPattern -Path 'C:\Users\Name[1]\bin\v1\codex.exe' -Patterns @('C:\Users\Name[1]\bin\*\codex*.exe'))) { throw 'Literal brackets in a path were interpreted as a wildcard character class.' }
    Write-Output 'PASS: verified HTTPS through a private proxy, listener reuse/ownership, profile mismatch rejection, missing TUN rejection and literal path matching.'
} finally {
    if($proxy) {
        foreach($item in @(Get-CimInstance Win32_Process -Filter "Name='xray.exe'" | Where-Object ExecutablePath -eq $proxy.Executable)) {
            $process=Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
            if($process) {
                try { if($process.Path -eq $proxy.Executable) { $process.Kill();$null=$process.WaitForExit(5000) } }
                finally { $process.Dispose() }
            }
        }
    }
    foreach($file in @('proxy.private.json','proxy-manifest.private.json','installation.private.json','.wes-owner.json','core\xray.exe','core\.wes-owner.json')) { Remove-Item -LiteralPath (Join-Path $path $file) -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $path 'core') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
}

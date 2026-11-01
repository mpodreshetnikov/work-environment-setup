Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'PrivateState.psm1')
Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1')

function Test-WesPathPattern {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string[]]$Patterns)
    foreach($pattern in $Patterns) {
        $expression='^'+[regex]::Escape($pattern).Replace('\*','.*').Replace('\?','.')+'$'
        if([regex]::IsMatch($Path,$expression,([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))) { return $true }
    }
    return $false
}

function Get-WesVerifiedProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root)
    $state=Read-WesInstallationState $Root
    $manifest=Read-WesPrivateJson (Join-Path $Root 'proxy-manifest.private.json')
    if($manifest.SchemaVersion -ne 1 -or $manifest.OwnerSid -ne (Get-WesOwnerSid)) { throw 'Proxy manifest owner or schema is invalid.' }
    if($manifest.SourceProfileId -ne $state.Vpn.ProfileId -or $manifest.GuiConfigPath -ne $state.Vpn.GuiConfigPath) { throw 'Proxy and installation profile identities differ.' }
    $port=0
    if(-not [int]::TryParse([string]$manifest.Port,[ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'Pinned proxy port is invalid.' }
    $expectedConfig=Join-Path $Root 'proxy.private.json'
    $expectedExe=Join-Path $Root 'core\xray.exe'
    if([IO.Path]::GetFullPath($manifest.ConfigPath) -ne [IO.Path]::GetFullPath($expectedConfig) -or [IO.Path]::GetFullPath($manifest.Executable) -ne [IO.Path]::GetFullPath($expectedExe)) { throw 'Proxy files are outside the expected installation layout.' }
    foreach($file in @($expectedConfig,$expectedExe)) { if(-not (Test-WesPrivateFile $file)) { throw 'Proxy file permissions are unsafe or a file is missing.' } }
    if(-not (Test-WesPrivateDirectory (Split-Path $expectedExe))) { throw 'Proxy binary directory permissions are unsafe.' }
    if((Get-FileHash -LiteralPath $expectedConfig -Algorithm SHA256).Hash -ne $manifest.ConfigHash -or (Get-FileHash -LiteralPath $expectedExe -Algorithm SHA256).Hash -ne $manifest.ExecutableHash) { throw 'Pinned proxy files changed. Run repair before launching applications.' }
    return [pscustomobject]@{State=$state;Manifest=$manifest;ProxyUrl=('http://127.0.0.1:'+$port)}
}

function Assert-WesVpnReady {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$State)
    if(-not (Get-Process -Name v2rayN -ErrorAction SilentlyContinue)) { throw 'v2rayN is not running.' }
    try { $saved=Get-Content -LiteralPath $State.Vpn.GuiConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Saved v2rayN settings are unavailable or invalid.' }
    if([string]$saved.IndexId -ne [string]$State.Vpn.ProfileId) { throw 'Another v2rayN profile is selected. Restore the pinned profile or repin explicitly.' }
    if(-not $saved.TunModeItem.EnableTun) { throw 'TUN mode is disabled in v2rayN.' }
    $adapter=@(Get-NetAdapter -ErrorAction Stop | Where-Object Name -eq $State.Vpn.TunInterfaceAlias)
    if($adapter.Count -ne 1 -or $adapter[0].Status -ne 'Up') { throw 'The configured TUN interface is not active.' }
}

function Get-WesOwnedProxyProcess {
    param([Parameter(Mandatory=$true)]$Manifest)
    $listeners=@(Get-NetTCPConnection -State Listen -LocalPort ([int]$Manifest.Port) -ErrorAction SilentlyContinue)
    if(-not $listeners.Count) { return $null }
    $ids=@($listeners.OwningProcess | Sort-Object -Unique)
    if($ids.Count -ne 1 -or @($listeners | Where-Object LocalAddress -ne '127.0.0.1').Count) { throw 'Pinned proxy port has an unexpected listener.' }
    $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ids[0]) -ErrorAction Stop
    if(-not $process -or -not $process.ExecutablePath -or (Resolve-WesCanonicalPath $process.ExecutablePath) -ne (Resolve-WesCanonicalPath $Manifest.Executable)) { throw 'Pinned proxy port belongs to another executable.' }
    if(-not $process.CommandLine -or $process.CommandLine.IndexOf([string]$Manifest.ConfigPath,[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'Proxy process uses an unexpected configuration.' }
    $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
    if($owner.ReturnValue -ne 0 -or $owner.Sid -ne (Get-WesOwnerSid)) { throw 'Proxy process belongs to another user.' }
    return $process
}

function Start-WesPinnedProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root)
    $identity=Get-WesInstallationIdentity
    $mutex=[Threading.Mutex]::new($false,('Local\'+$identity.NamePrefix+'-proxy'))
    $locked=$false
    try {
        try { $locked=$mutex.WaitOne(20000) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if(-not $locked) { throw 'Another proxy startup is still in progress.' }
        $context=Get-WesVerifiedProxy $Root
        Assert-WesVpnReady $context.State
        $running=Get-WesOwnedProxyProcess $context.Manifest
        if($running) { return [pscustomobject]@{ProcessId=$running.ProcessId;ProxyUrl=$context.ProxyUrl} }
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$context.Manifest.Executable
        $start.Arguments='run -config "'+$context.Manifest.ConfigPath+'"';$start.WorkingDirectory=Split-Path $context.Manifest.Executable
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($start)
        try {
            for($attempt=0;$attempt -lt 20;$attempt++) {
                if($process.HasExited) { throw 'Pinned proxy exited during startup.' }
                $running=Get-WesOwnedProxyProcess $context.Manifest
                if($running -and $running.ProcessId -eq $process.Id) { return [pscustomobject]@{ProcessId=$process.Id;ProxyUrl=$context.ProxyUrl} }
                Start-Sleep -Milliseconds 200
            }
            try { $process.Kill() } catch { }
            throw 'Pinned proxy startup timed out.'
        } finally { $process.Dispose() }
    } finally { if($locked) { $mutex.ReleaseMutex() };$mutex.Dispose() }
}

function Test-WesProxyConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ProxyUrl)
    $uri=$null
    if(-not [Uri]::TryCreate($ProxyUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.Port -lt 1 -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) { throw 'Only the local pinned HTTP proxy can be tested.' }
    $canonicalProxy='http://127.0.0.1:'+$uri.Port
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=Join-Path $env:SystemRoot 'System32\curl.exe'
    $start.Arguments='--disable --noproxy no-proxy-bypass.invalid --proxy '+$canonicalProxy+' --connect-timeout 4 --max-time 8 --fail --silent --show-error https://www.cloudflare.com/cdn-cgi/trace'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(12000)) { $process.Kill();throw 'Pinned VPN connection check timed out.' }
        $response=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or $response -notmatch '(?m)^ip=([^\r\n]+)') { throw 'The pinned VPN could not complete the HTTPS check.' }
        $address=$null
        if(-not [Net.IPAddress]::TryParse($matches[1],[ref]$address)) { throw 'Pinned VPN check returned an invalid response.' }
        return $true
    } finally { $process.Dispose() }
}

function Get-WesRuntimeReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root)
    $context=Get-WesVerifiedProxy $Root
    Assert-WesVpnReady $context.State
    $proxy=Start-WesPinnedProxy $Root
    $null=Test-WesProxyConnection $proxy.ProxyUrl
    # Recheck selection after the network operation rather than trusting a stale check.
    $fresh=Get-WesVerifiedProxy $Root
    Assert-WesVpnReady $fresh.State
    if($fresh.ProxyUrl -ne $proxy.ProxyUrl) { throw 'Pinned proxy settings changed during the launch check.' }
    return [pscustomobject]@{State=$fresh.State;ProxyUrl=$proxy.ProxyUrl;ProcessId=$proxy.ProcessId}
}

Export-ModuleMember -Function Test-WesPathPattern,Get-WesVerifiedProxy,Assert-WesVpnReady,Start-WesPinnedProxy,Get-WesOwnedProxyProcess,Test-WesProxyConnection,Get-WesRuntimeReadiness

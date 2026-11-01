Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'PrivateState.psm1')

function Invoke-WesXrayValidation {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Executable,[Parameter(Mandatory=$true)][string]$ConfigPath)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Executable;$start.Arguments='run -test -config "'+$ConfigPath+'"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        if(-not $process.Start()) { throw 'Could not start Xray configuration validation.' }
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(15000)) { $process.Kill();throw 'Xray configuration validation timed out.' }
        $null=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        # Never print native diagnostics here: invalid fields may contain credentials.
        if($process.ExitCode -ne 0) { throw 'Xray rejected the imported configuration. Raw output was suppressed to protect private fields.' }
    } finally { $process.Dispose() }
}

function Initialize-WesPinnedProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)]$Snapshot,[ValidateRange(1,65535)][int]$Port=20080)
    if(-not (Test-WesPrivateDirectory $Root)) { throw 'Proxy preparation requires an initialized private directory.' }
    $config=Join-Path $Root 'proxy.private.json';$manifest=Join-Path $Root 'proxy-manifest.private.json'
    if((Test-Path -LiteralPath $config) -or (Test-Path -LiteralPath $manifest)) { throw 'A proxy is already prepared. Repinning must be explicit.' }
    if($Snapshot.Outbound.protocol -notin @('vless','vmess') -or @($Snapshot.Outbound.settings.vnext).Count -ne 1 -or @($Snapshot.Outbound.settings.vnext[0].users).Count -ne 1) { throw 'Pinned proxy requires exactly one supported server and identity.' }
    if(-not (Test-Path -LiteralPath $Snapshot.XrayPath -PathType Leaf)) { throw 'The configured v2rayN Xray executable is missing.' }
    $core=Initialize-WesPrivateDirectory -Path (Join-Path $Root 'core')
    $exe=Join-Path $core 'xray.exe'
    if(Test-Path -LiteralPath $exe) { throw 'An unfinished proxy preparation exists. Inspect or remove it before retrying.' }
    try {
        Copy-Item -LiteralPath $Snapshot.XrayPath -Destination $exe -ErrorAction Stop
        Protect-WesPrivateFile $exe
        $sourceHash=(Get-FileHash -LiteralPath $Snapshot.XrayPath -Algorithm SHA256).Hash
        if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $sourceHash) { throw 'Copied Xray executable hash mismatch.' }
        $document=[ordered]@{
            log=@{loglevel='error'}
            inbounds=@(@{tag='wes-ai-proxy';listen='127.0.0.1';port=$Port;protocol='http';settings=@{allowTransparent=$false}})
            outbounds=@($Snapshot.Outbound)
            routing=@{domainStrategy='AsIs';rules=@(@{type='field';inboundTag=@('wes-ai-proxy');outboundTag='proxy'})}
        }
        Write-WesPrivateJson -Path $config -Value $document
        Invoke-WesXrayValidation -Executable $exe -ConfigPath $config
        $result=[ordered]@{
            SchemaVersion=1;OwnerSid=(Get-WesOwnerSid);Port=$Port
            Executable=$exe;ExecutableHash=$sourceHash;ConfigPath=$config
            ConfigHash=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
            SourceProfileId=$Snapshot.ProfileId;GuiConfigPath=$Snapshot.GuiConfigPath
        }
        Write-WesPrivateJson -Path $manifest -Value $result
        return [pscustomobject]$result
    } catch {
        foreach($file in @($config,$manifest,$exe)) { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
        throw
    }
}

Export-ModuleMember -Function Invoke-WesXrayValidation,Initialize-WesPinnedProxy

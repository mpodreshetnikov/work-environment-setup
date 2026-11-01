#Requires -Version 5.1
[CmdletBinding()]
param([ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Commit,[switch]$Repair,[switch]$DisableGpu,
    [string]$V2rayRoot,[string]$CoreConfigPath,[string]$TunInterfaceAlias,
    [ValidateSet('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli')][string[]]$Apps=@('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli'),
    [ValidateRange(1024,65535)][int]$ProxyPort=20080,[uint16[]]$AdditionalDeniedProxyPorts=@())
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT') { throw 'This installer supports Windows only.' }
$ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('wes-bootstrap-'+[guid]::NewGuid().ToString('N'))
$source=$null
try {
    $null=[IO.Directory]::CreateDirectory($temporary)
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @($ownerSid,'S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    if($PSVersionTable.PSEdition -eq 'Core') { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($temporary),$acl) }
    else { [IO.Directory]::SetAccessControl($temporary,$acl) }
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    if(-not $Commit) {
        $metadata=Invoke-RestMethod 'https://api.github.com/repos/mpodreshetnikov/work-environment-setup/commits/main' -Headers @{Accept='application/vnd.github+json';'User-Agent'='work-environment-setup'}
        $Commit=[string]$metadata.sha
        if($Commit -notmatch '^[a-fA-F0-9]{40}$') { throw 'GitHub returned an invalid commit ID.' }
    }
    $archive=Join-Path $temporary 'source.zip'
    Invoke-WebRequest ('https://codeload.github.com/mpodreshetnikov/work-environment-setup/zip/'+$Commit) -UseBasicParsing -OutFile $archive
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($archive)
    $prefix='work-environment-setup-'+$Commit+'/'
    try {
        foreach($entry in $zip.Entries) {
            if(-not $entry.FullName.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $entry.FullName -match '(^|[/\\])\.\.([/\\]|$)|:|^[/\\]') { throw 'The downloaded archive contains an unexpected path.' }
        }
    } finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $archive -DestinationPath $temporary
    $source=Join-Path $temporary ('work-environment-setup-'+$Commit)
    $script=Join-Path $source 'install.ps1'
    if(-not (Test-Path -LiteralPath $script)) { throw 'The downloaded archive has no installer.' }
    $systemDirectory=if([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {'Sysnative'} else {'System32'}
    $powershell=Join-Path $env:SystemRoot ($systemDirectory+'\WindowsPowerShell\v1.0\powershell.exe')
    $runner=Join-Path $temporary 'runner.ps1';$resultPath=Join-Path $temporary 'install-result.private.json'
    $requestPath=Join-Path $temporary 'install-request.private.json'
    $options=@{ExpectedOwnerSid=$ownerSid;Repair=[bool]$Repair;DisableGpu=[bool]$DisableGpu;Apps=@($Apps);ProxyPort=$ProxyPort;AdditionalDeniedProxyPorts=@($AdditionalDeniedProxyPorts)}
    foreach($pair in @{V2rayRoot=$V2rayRoot;CoreConfigPath=$CoreConfigPath;TunInterfaceAlias=$TunInterfaceAlias}.GetEnumerator()) { if($pair.Value) { $options[$pair.Key]=$pair.Value } }
    [IO.File]::WriteAllText($requestPath,(ConvertTo-Json -InputObject $options -Depth 6),[Text.UTF8Encoding]::new($false))
    $runnerCode=@'
param([string]$SourceRoot,[string]$RequestPath)
$ErrorActionPreference='Stop'
$result=@{Success=$false;Error='Installation failed.'}
try {
    $request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($request.ExpectedOwnerSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'UAC switched to another Windows user. Nothing was installed.' }
    $options=@{};foreach($property in $request.PSObject.Properties) { $options[$property.Name]=$property.Value }
    & (Join-Path $SourceRoot 'install.ps1') @options
    $result=@{Success=$true;Error=$null}
} catch { $result.Error=$_.Exception.Message }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'install-result.private.json'),(ConvertTo-Json -InputObject $result),[Text.UTF8Encoding]::new($false))
if(-not $result.Success) { exit 1 }
'@
    [IO.File]::WriteAllText($runner,$runnerCode,[Text.UTF8Encoding]::new($true))
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$runner+'" -SourceRoot "'+$source+'" -RequestPath "'+$requestPath+'"'
    Write-Output ('Installing commit '+$Commit+'. Confirm Windows UAC for the same user account.')
    $process=Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    if(-not (Test-Path -LiteralPath $resultPath)) { throw 'Installer did not return a result. Inspect private installation state before retrying.' }
    try { $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw 'Installer returned an invalid result.' }
    if($process.ExitCode -ne 0 -or -not $result.Success) { throw ('Installation failed: '+$result.Error) }
    Write-Output 'Installation completed. Open a new terminal; use Claude VPN / Codex VPN shortcuts.'
} finally {
    $full=[IO.Path]::GetFullPath($temporary);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -like 'wes-bootstrap-*') { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
}

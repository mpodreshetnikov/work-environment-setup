$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PrivateState.psm1') -Force
$path=Join-Path ([IO.Path]::GetTempPath()) ('wes-bridge-'+[guid]::NewGuid().ToString())
$savedProxy=[Environment]::GetEnvironmentVariable('HTTPS_PROXY','Process')
$savedNodeProxy=[Environment]::GetEnvironmentVariable('NODE_USE_ENV_PROXY','Process')
try {
    $root=Initialize-WesPrivateDirectory -Path $path
    $bin=Join-Path $root 'bin';$runtime=Join-Path $root 'runtime'
    New-Item -ItemType Directory -Path $bin,$runtime | Out-Null
    $bridge=Join-Path $bin 'CliBridge.exe';$echo=Join-Path $bin 'echo.exe'
    Add-Type -Path (Join-Path $PSScriptRoot '..\src\native\CliBridge.cs') -OutputAssembly $bridge -OutputType ConsoleApplication -ReferencedAssemblies @('System.dll','System.Web.Extensions.dll')
    $null=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($bridge))
    Add-Type -Path (Join-Path $PSScriptRoot 'ArgumentEcho.cs') -OutputAssembly $echo -OutputType ConsoleApplication -ReferencedAssemblies @('System.dll','System.Web.Extensions.dll')
    $check=@'
param([string]$Scope)
$p=[ordered]@{Success=$true;Scope=$Scope;ProxyUrl='http://127.0.0.1:20080';Command=@{Executable=(Join-Path $PSScriptRoot '..\bin\echo.exe');PrefixArguments=@('--fixture-prefix')}}
if(@(Get-ChildItem (Join-Path $PSScriptRoot '..') -Filter '.cli-args-*.private.json' -Force).Count) { $p.Success=$false;$p.Error='Private arguments were not removed before the launch check.' }
$bytes=[Text.Encoding]::UTF8.GetBytes(($p | ConvertTo-Json -Depth 4 -Compress))
$stream=[Console]::OpenStandardOutput();$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
'@
    $checkPath=Join-Path $runtime 'Check.ps1';[IO.File]::WriteAllText($checkPath,$check,[Text.UTF8Encoding]::new($true))
    $unicode=([string][char]0x0442)+[char]0x0435+[char]0x0441+[char]0x0442
    $fixture=@('-m','model','-s','read-only','','a b','a"b',"a'b",'C:\trailing slash\','; & | %PATH%',$unicode)
    foreach($mode in @('argv','private-file','empty-arguments','empty-value')) {
        $values=$fixture
        if($mode -eq 'private-file') { $values=$fixture+@([string]::new([char]0x0442,18000)) }
        elseif($mode -eq 'empty-arguments') { $values=@() }
        elseif($mode -eq 'empty-value') { $values=@('') }
        $expected=@('--fixture-prefix')+$values
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$bridge;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        if($mode -eq 'argv') { $start.Arguments=[WorkEnvironmentSetup.CliBridge]::JoinArguments([string[]](@('CodexCli')+$values)) }
        else {
            $argumentId=[guid]::NewGuid().ToString('N')
            $argumentPath=Join-Path $root ('.cli-args-'+$argumentId+'.private.json')
            Write-WesPrivateJson -Path $argumentPath -Value @{SchemaVersion=1;OwnerSid=(Get-WesOwnerSid);Arguments=$values}
            $start.Arguments='CodexCli --wes-private-arguments '+$argumentId
        }
        $process=[Diagnostics.Process]::Start($start)
        try {
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(20000)) { $process.Kill();throw 'CLI bridge test timed out.' }
            $encoded=$stdout.GetAwaiter().GetResult().Trim();$errorText=$stderr.GetAwaiter().GetResult()
            if($process.ExitCode -ne 17) { throw ('Native exit code was not preserved: '+$process.ExitCode+' '+$errorText) }
            $decoded=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
            $actual=$decoded | ConvertFrom-Json
            if(@($actual.Arguments).Count -ne $expected.Count) { throw ('CLI argument count changed in '+$mode+': expected '+$expected.Count+', got '+@($actual.Arguments).Count) }
            for($i=0;$i -lt $expected.Count;$i++) { if($actual.Arguments[$i] -cne $expected[$i]) { throw ('CLI argument changed at index '+$i) } }
            if($actual.Proxy -ne 'http://127.0.0.1:20080') { throw 'Child process proxy environment was not scoped correctly.' }
            if($actual.NodeUseEnvProxy -ne '1') { throw 'Codex Node.js proxy handling was not enabled in the child process.' }
        } finally { $process.Dispose() }
    }
    $start.Arguments=[WorkEnvironmentSetup.CliBridge]::JoinArguments(@('CodexCli','--fixture-stdin'))
    $start.RedirectStandardInput=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $text='stdin '+$unicode+"`nsecond line"
        $bytes=[Text.Encoding]::UTF8.GetBytes($text);$process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$process.StandardInput.Close()
        if(-not $process.WaitForExit(20000)) { $process.Kill();throw 'CLI stdin forwarding timed out.' }
        $actual=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($stdout.GetAwaiter().GetResult().Trim())) | ConvertFrom-Json
        $null=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 17 -or $actual.Input -cne $text) { throw 'CLI stdin bytes were not preserved.' }
    } finally { $process.Dispose() }
    $start.RedirectStandardInput=$false
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\src\runtime\Shell.ps1') -Destination (Join-Path $runtime 'Shell.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\src\PrivateState.psm1') -Destination (Join-Path $runtime 'PrivateState.psm1')
    Write-WesPrivateJson (Join-Path $root 'installation.private.json') @{SchemaVersion=1;OwnerSid=(Get-WesOwnerSid);Applications=@(@{Scope='CodexCli'})}
    . (Join-Path $runtime 'Shell.ps1')
    $shellEncoded=codex @fixture
    $actual=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($shellEncoded.Trim())) | ConvertFrom-Json
    $expected=@('--fixture-prefix')+$fixture
    if($LASTEXITCODE -ne 17 -or @($actual.Arguments).Count -ne $expected.Count) { throw 'PowerShell wrapper lost native arguments or exit code.' }
    for($i=0;$i -lt $expected.Count;$i++) { if($actual.Arguments[$i] -cne $expected[$i]) { throw 'PowerShell wrapper changed a native argument.' } }
    $shellEncoded=('pipeline '+$unicode) | codex --fixture-stdin
    $actual=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($shellEncoded.Trim())) | ConvertFrom-Json
    if($actual.Input -cne ('pipeline '+$unicode+[Environment]::NewLine) -or $LASTEXITCODE -ne 17) { throw 'PowerShell wrapper lost Unicode pipeline input.' }
    if(Get-Command claude -CommandType Function -ErrorAction SilentlyContinue) { throw 'Wrapper was installed for an unselected application.' }
    foreach($invalidArguments in @(@{Value=[string]::new([char]'x',40000);Error='too long'},@{Value=('a'+[char]0+'b');Error='NUL'})) {
        $argumentId=[guid]::NewGuid().ToString('N')
        Write-WesPrivateJson -Path (Join-Path $root ('.cli-args-'+$argumentId+'.private.json')) -Value @{SchemaVersion=1;OwnerSid=(Get-WesOwnerSid);Arguments=@($invalidArguments.Value)}
        $start.Arguments='CodexCli --wes-private-arguments '+$argumentId
        $process=[Diagnostics.Process]::Start($start)
        try {
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(20000)) { $process.Kill();throw 'Invalid argument rejection timed out.' }
            $output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
            if($process.ExitCode -ne 1 -or $output.Trim() -or -not $errorText.Contains($invalidArguments.Error)) { throw 'Unsupported native arguments were not rejected before target launch.' }
        } finally { $process.Dispose() }
    }
    $blocked=$check.Replace('Success=$true','Success=$false;Error="VPN unavailable fixture"')
    [IO.File]::WriteAllText($checkPath,$blocked,[Text.UTF8Encoding]::new($true))
    $start.Arguments='CodexCli'
    $process=[Diagnostics.Process]::Start($start)
    try {
        $output=$process.StandardOutput.ReadToEnd();$null=$process.StandardError.ReadToEnd();$process.WaitForExit()
        if($process.ExitCode -ne 1 -or $output.Trim()) { throw 'The native target ran after a failed VPN launch check.' }
    } finally { $process.Dispose() }
    $invalid=@'
$bytes=[Text.Encoding]::UTF8.GetBytes('not-json-fixture-sensitive-value')
$stream=[Console]::OpenStandardOutput();$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
'@
    [IO.File]::WriteAllText($checkPath,$invalid,[Text.UTF8Encoding]::new($true))
    $process=[Diagnostics.Process]::Start($start)
    try {
        $output=$process.StandardOutput.ReadToEnd();$errors=$process.StandardError.ReadToEnd();$process.WaitForExit()
        if($process.ExitCode -ne 1 -or $output.Trim() -or $errors.Contains('fixture-sensitive-value')) { throw 'Malformed launch metadata was exposed or allowed execution.' }
    } finally { $process.Dispose() }
    if([Environment]::GetEnvironmentVariable('HTTPS_PROXY','Process') -cne $savedProxy) { throw 'The parent proxy environment changed.' }
    if([Environment]::GetEnvironmentVariable('NODE_USE_ENV_PROXY','Process') -cne $savedNodeProxy) { throw 'The parent Node.js proxy environment changed.' }
    Write-Output 'PASS: native argv, private arguments, PowerShell wrappers/pipeline, empty/quoted/long Unicode values, stdin/stdout, exit code, child proxy environment, failed-check rejection and redacted metadata errors.'
} finally {
    if(Test-Path -LiteralPath $path) { Get-ChildItem -LiteralPath $path -Filter '.cli-args-*.private.json' -Force | ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue } }
    foreach($file in @('bin\CliBridge.exe','bin\echo.exe','runtime\Check.ps1','runtime\Shell.ps1','runtime\PrivateState.psm1','installation.private.json','.wes-owner.json')) { Remove-Item -LiteralPath (Join-Path $path $file) -ErrorAction SilentlyContinue }
    foreach($dir in @('bin','runtime')) { Remove-Item -LiteralPath (Join-Path $path $dir) -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
}

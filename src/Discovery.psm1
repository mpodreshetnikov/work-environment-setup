Set-StrictMode -Version 2

function Resolve-WesCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not ('WorkEnvironmentSetup.CanonicalPath' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'native\CanonicalPath.cs') }
    return [WorkEnvironmentSetup.CanonicalPath]::Resolve($Path)
}

function Get-WesExecutableArchitecture {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream=[IO.File]::OpenRead((Resolve-WesCanonicalPath $Path))
    $reader=[IO.BinaryReader]::new($stream)
    try {
        if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw 'Executable has no valid DOS header.' }
        $stream.Position=0x3C;$offset=$reader.ReadInt32()
        if($offset -lt 64 -or $offset -gt $stream.Length-6) { throw 'Executable PE header offset is invalid.' }
        $stream.Position=$offset
        if($reader.ReadUInt32() -ne 0x4550) { throw 'Executable PE signature is invalid.' }
        switch($reader.ReadUInt16()) {
            0x8664 { return 'x64' }
            0xAA64 { return 'arm64' }
            0x014C { return 'x86' }
            default { throw 'Executable architecture is unsupported.' }
        }
    } finally { $reader.Dispose() }
}

function Get-WesDesktopApplication {
    param([Parameter(Mandatory=$true)][ValidateSet('ClaudeDesktop','CodexDesktop')][string]$Scope)
    if($Scope -eq 'ClaudeDesktop') { $packageName='Claude';$mainFile='Claude.exe';$aliasName='claude-desktop.exe' }
    else { $packageName='OpenAI.Codex';$mainFile='ChatGPT.exe';$aliasName='chatgpt-desktop.exe' }
    $packages=@(Get-AppxPackage -Name $packageName -ErrorAction Stop)
    if($packages.Count -ne 1) { throw "Application package is missing or ambiguous for this account: $Scope" }
    $package=$packages[0]
    [xml]$manifest=Get-Content -LiteralPath (Join-Path $package.InstallLocation 'AppxManifest.xml') -Encoding UTF8
    $mains=@($manifest.SelectNodes("//*[local-name()='Applications']/*[local-name()='Application']") | Where-Object {
        $_.HasAttribute('Executable') -and [IO.Path]::GetFileName($_.GetAttribute('Executable').Replace('/','\')) -ieq $mainFile
    })
    if($mains.Count -ne 1) { throw "The main application entry is ambiguous: $Scope" }
    $aliases=@($mains[0].SelectNodes(".//*[local-name()='ExecutionAlias']") | ForEach-Object { $_.GetAttribute('Alias') })
    if($aliasName -notin $aliases) { throw "The registered desktop launch alias is missing: $Scope" }
    $alias=Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps') $package.PackageFamilyName) $aliasName
    if(-not (Test-Path -LiteralPath $alias)) { throw "The desktop launch alias needs installation repair: $Scope" }
    $files=@(Get-ChildItem -LiteralPath $package.InstallLocation -File -Filter '*.exe' -Recurse -ErrorAction Stop | Select-Object -ExpandProperty FullName)
    $pattern=Join-Path (Split-Path $package.InstallLocation) ($package.Name+'_*_'+$package.PublisherId+'\*')
    $patterns=@($pattern)
    if($Scope -eq 'CodexDesktop') {
        $privateRoot=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
        foreach($directory in @('bin','runtimes')) {
            $directoryPath=Join-Path $privateRoot $directory
            if(Test-Path -LiteralPath $directoryPath) {
                $files+=@(Get-ChildItem -LiteralPath $directoryPath -File -Filter '*.exe' -Recurse | Where-Object { $_.Name -like 'codex*.exe' -or $_.Name -in @('node.exe','node_repl.exe') } | Select-Object -ExpandProperty FullName)
            }
            foreach($name in @('codex*.exe','node.exe','node_repl.exe')) { $patterns+=Join-Path $directoryPath $name; $patterns+=Join-Path $directoryPath ('*\'+$name) }
        }
        $cache=Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime'
        # Do not tag the cache wholesale: it also contains external command tools.
        foreach($relative in @('dependencies\node\bin\node.exe','dependencies\python\Lib\site-packages\artifact_tool_v2\bin\artifact_tool_rpc_daemon.exe')) {
            $path=Join-Path $cache $relative
            $patterns+=$path
            if(Test-Path -LiteralPath $path) { $files+=$path }
        }
    }
    return [pscustomobject]@{
        Scope=$Scope;Kind='PackagedDesktop';PackageName=$package.Name;PackageFamilyName=$package.PackageFamilyName
        InstallRoot=$package.InstallLocation;LaunchAlias=$alias;ApplicationId=$mains[0].GetAttribute('Id')
        MainExecutable=(Join-Path $package.InstallLocation ($mains[0].GetAttribute('Executable').Replace('/','\')))
        Executables=@($files | Sort-Object -Unique);TagPatterns=@($patterns | Sort-Object -Unique)
    }
}

function Get-WesClaudeCode {
    $command=Get-Command 'claude.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $command) { throw 'Native Claude Code is not installed. The npm JavaScript implementation cannot be isolated from unrelated Node.js applications by executable path.' }
    $path=Resolve-WesCanonicalPath -Path $command.Source
    $pattern=$path
    $winget=Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if($path.StartsWith($winget+'\',[StringComparison]::OrdinalIgnoreCase) -and $path -like '*\Anthropic.ClaudeCode_*\*') {
        $pattern=Join-Path $winget 'Anthropic.ClaudeCode_*\*'
    } else {
        $versions=Join-Path $env:USERPROFILE '.local\share\claude\versions'
        if($path.StartsWith($versions+'\',[StringComparison]::OrdinalIgnoreCase)) { $pattern=Join-Path $versions '*' }
    }
    if([Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductName -notlike '*Claude Code*') { throw 'The claude.exe command is not the native Claude Code distribution.' }
    return [pscustomobject]@{Scope='ClaudeCode';Kind='NativeCli';CommandName='claude';LaunchExecutable=$path;NativeExecutable=$path;Executables=@($path);TagPatterns=@($pattern)}
}

function Get-WesCodexCli {
    $shim=Get-Command 'codex.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if($shim) {
        $logicalRoot=Split-Path $shim.Source
        $package=Join-Path $logicalRoot 'node_modules\@openai\codex'
        $entry=Join-Path $package 'bin\codex.js'
        if(Test-Path -LiteralPath $entry) {
            $node=Join-Path $logicalRoot 'node.exe'
            if(-not (Test-Path -LiteralPath $node)) {
                $nodeCommand=Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if(-not $nodeCommand) { throw 'Node.js required by the installed Codex CLI was not found.' }
                $node=$nodeCommand.Source
            }
            $architecture=Get-WesExecutableArchitecture $node
            if($architecture -eq 'arm64') { $packageSuffix='arm64';$triple='aarch64-pc-windows-msvc' }
            elseif($architecture -eq 'x64') { $packageSuffix='x64';$triple='x86_64-pc-windows-msvc' }
            else { throw 'Codex CLI discovery requires x64 or ARM64 Windows.' }
            $relative='vendor\'+$triple+'\bin\codex.exe'
            $candidates=@(
                (Join-Path $package ('node_modules\@openai\codex-win32-'+$packageSuffix+'\'+$relative)),
                (Join-Path $logicalRoot ('node_modules\@openai\codex-win32-'+$packageSuffix+'\'+$relative)),
                (Join-Path $package $relative)
            )
            $native=@($candidates | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Resolve-WesCanonicalPath $_ } | Sort-Object -Unique)
            if($native.Count -ne 1) { throw 'The native Codex CLI executable is missing or ambiguous. Repair the official npm installation.' }
            $canonicalPackage=Resolve-WesCanonicalPath $package
            $patterns=@((Join-Path $canonicalPackage '*'))
            $engineRoots=@($canonicalPackage)
            $nvmHomePath=[Environment]::GetEnvironmentVariable('NVM_HOME','Process')
            if($nvmHomePath -and (Test-Path -LiteralPath $nvmHomePath)) {
                $nvm=Resolve-WesCanonicalPath $nvmHomePath
                if($canonicalPackage.StartsWith($nvm+'\',[StringComparison]::OrdinalIgnoreCase)) { $patterns+=Join-Path $nvm '*\node_modules\@openai\codex\*' }
            }
            # A hoisted platform package also needs its own narrowly scoped pattern.
            if(-not $native[0].StartsWith($canonicalPackage+'\',[StringComparison]::OrdinalIgnoreCase)) {
                $platformRoot=Split-Path (Split-Path (Split-Path (Split-Path $native[0])))
                $patterns+=Join-Path $platformRoot '*'
                $engineRoots+=$platformRoot
            }
            $engineFiles=@($native)
            foreach($engineRoot in $engineRoots) { $engineFiles+=@(Get-ChildItem -LiteralPath $engineRoot -Filter 'codex*.exe' -File -Recurse | Select-Object -ExpandProperty FullName) }
            if((Get-WesExecutableArchitecture $native[0]) -ne $architecture) { throw 'The native Codex package does not match the installed Node.js architecture.' }
            return [pscustomobject]@{Scope='CodexCli';Kind='NativeViaNode';CommandName='codex';ShimPath=$shim.Source;LaunchExecutable=(Resolve-WesCanonicalPath $node);EntryScript=(Resolve-WesCanonicalPath $entry);NativeExecutable=$native[0];Executables=@($engineFiles | Sort-Object -Unique);TagPatterns=@($patterns | Sort-Object -Unique)}
        }
    }
    $command=Get-Command 'codex.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $command) { throw 'Codex CLI was not found.' }
    $path=Resolve-WesCanonicalPath $command.Source
    $patterns=@($path)
    $desktopRoot=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
    if($path.StartsWith($desktopRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { $patterns=@((Join-Path $desktopRoot '*')) }
    return [pscustomobject]@{Scope='CodexCli';Kind='NativeCli';CommandName='codex';LaunchExecutable=$path;NativeExecutable=$path;Executables=@($path);TagPatterns=$patterns}
}

function Get-WesApplicationInventory {
    [CmdletBinding()]
    param([ValidateSet('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli')][string[]]$Scopes=@('ClaudeDesktop','ClaudeCode','CodexDesktop','CodexCli'))
    $result=@()
    foreach($scope in @($Scopes | Select-Object -Unique)) {
        switch($scope) {
            'ClaudeDesktop' { $result+=Get-WesDesktopApplication $scope }
            'CodexDesktop' { $result+=Get-WesDesktopApplication $scope }
            'ClaudeCode' { $result+=Get-WesClaudeCode }
            'CodexCli' { $result+=Get-WesCodexCli }
        }
    }
    return $result
}

Export-ModuleMember -Function Resolve-WesCanonicalPath,Get-WesExecutableArchitecture,Get-WesApplicationInventory

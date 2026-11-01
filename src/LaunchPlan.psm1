Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'PrivateState.psm1')
Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1')
Import-Module (Join-Path $PSScriptRoot 'Runtime.psm1')

function Get-WesNativeLaunchCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Saved,[Parameter(Mandatory=$true)]$Current)
    if($Saved.Scope -ne $Current.Scope -or $Saved.Kind -ne $Current.Kind) { throw 'Application distribution changed. Run repair before launching.' }
    foreach($path in @($Current.Executables)) {
        if(-not (Test-WesPathPattern (Resolve-WesCanonicalPath $path) @($Saved.TagPatterns))) { throw 'An application executable is outside the installed protection scope. Run repair.' }
    }
    if($Current.Kind -eq 'PackagedDesktop') {
        if($Saved.PackageFamilyName -ne $Current.PackageFamilyName) { throw 'Application package publisher changed. Run repair.' }
        return [pscustomobject]@{Executable=$Current.LaunchAlias;PrefixArguments=@()}
    }
    if(-not (Test-WesPathPattern (Resolve-WesCanonicalPath $Current.NativeExecutable) @($Saved.TagPatterns))) { throw 'The native CLI backend is outside the installed protection scope.' }
    if($Current.Kind -eq 'NativeCli') { return [pscustomobject]@{Executable=$Current.NativeExecutable;PrefixArguments=@()} }
    if($Current.Kind -ne 'NativeViaNode') { throw 'Unsupported application distribution.' }
    $bootstrap=$Saved.Bootstrap
    if($Current.LaunchExecutable -ne $bootstrap.Source -or -not (Test-WesPrivateFile $bootstrap.Executable) -or
       (Get-FileHash -LiteralPath $bootstrap.Executable -Algorithm SHA256).Hash -ne $bootstrap.Hash -or
       (Get-FileHash -LiteralPath $Current.LaunchExecutable -Algorithm SHA256).Hash -ne $bootstrap.Hash -or
       (Get-WesExecutableArchitecture $Current.NativeExecutable) -ne $bootstrap.Architecture) { throw 'Node.js or Codex architecture changed. Run repair before launching.' }
    if(-not (Test-WesPathPattern $Current.EntryScript @($Saved.TagPatterns))) { throw 'Codex bootstrap script is outside the installed protection scope.' }
    return [pscustomobject]@{Executable=$bootstrap.Executable;PrefixArguments=@($Current.EntryScript)}
}

Export-ModuleMember -Function Get-WesNativeLaunchCommand

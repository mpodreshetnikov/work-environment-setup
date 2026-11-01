Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'PrivateState.psm1')
Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1')

function Initialize-WesLaunchRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][object[]]$Applications,[switch]$Repair)
    if(-not (Test-WesPrivateDirectory $Root)) { throw 'Launch preparation requires a private installation directory.' }
    $bin=Initialize-WesPrivateDirectory (Join-Path $Root 'bin')
    $runtime=Initialize-WesPrivateDirectory (Join-Path $Root 'runtime')
    $native=Initialize-WesPrivateDirectory (Join-Path $runtime 'native')
    foreach($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.psm1')) {
        $destination=Join-Path $runtime $file.Name
        if($file.FullName -ne $destination) { Copy-Item -LiteralPath $file.FullName -Destination $destination }
    }
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'native') -File -Filter '*.cs')) {
        $destination=Join-Path $native $file.Name
        if($file.FullName -ne $destination) { Copy-Item -LiteralPath $file.FullName -Destination $destination }
    }
    foreach($name in @('Check.ps1','Desktop.ps1','Shell.ps1')) {
        $source=Join-Path $PSScriptRoot ('runtime\'+$name)
        if(-not (Test-Path -LiteralPath $source)) { $source=Join-Path $PSScriptRoot $name }
        $destination=Join-Path $runtime $name
        if($source -ne $destination) { Copy-Item -LiteralPath $source -Destination $destination }
    }
    $bridge=Join-Path $bin 'CliBridge.exe'
    if(Test-Path -LiteralPath $bridge) {
        if(-not $Repair) { throw 'CLI bridge already exists. Use explicit repair rather than overwriting a running installation.' }
        Remove-Item -LiteralPath $bridge -ErrorAction Stop
    }
    Add-Type -Path (Join-Path $PSScriptRoot 'native\CliBridge.cs') -OutputAssembly $bridge -OutputType ConsoleApplication -ReferencedAssemblies @('System.dll','System.Web.Extensions.dll')
    Protect-WesPrivateFile $bridge
    $result=@()
    foreach($application in $Applications) {
        $copy=$application | ConvertTo-Json -Depth 15 | ConvertFrom-Json
        if($application.Kind -eq 'NativeViaNode') {
            $node=Join-Path $bin 'CodexBootstrapNode.exe'
            Copy-Item -LiteralPath $application.LaunchExecutable -Destination $node -ErrorAction Stop
            Protect-WesPrivateFile $node
            $hash=(Get-FileHash -LiteralPath $application.LaunchExecutable -Algorithm SHA256).Hash
            if((Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash -ne $hash) { throw 'Private Node.js bootstrap copy hash mismatch.' }
            $copy | Add-Member -NotePropertyName Bootstrap -NotePropertyValue ([pscustomobject]@{Executable=$node;Source=$application.LaunchExecutable;Hash=$hash;Architecture=(Get-WesExecutableArchitecture $node)})
            $copy.Executables=@($copy.Executables)+@($node)
            $copy.TagPatterns=@($copy.TagPatterns)+@($node)
        }
        $result+=$copy
    }
    return $result
}

Export-ModuleMember -Function Initialize-WesLaunchRuntime

$ErrorActionPreference='Stop'
foreach($module in @('PrivateState','Discovery','LaunchPreparation','LaunchPlan')) { Import-Module (Join-Path $PSScriptRoot ('..\src\'+$module+'.psm1')) -Force }
$path=Join-Path ([IO.Path]::GetTempPath()) ('wes-launch-'+[guid]::NewGuid().ToString())
try {
    $root=Initialize-WesPrivateDirectory $path
    $current=@(Get-WesApplicationInventory)
    $prepared=@(Initialize-WesLaunchRuntime -Root $root -Applications $current)
    foreach($saved in $prepared) {
        $now=@($current | Where-Object Scope -eq $saved.Scope)[0]
        $command=Get-WesNativeLaunchCommand -Saved $saved -Current $now
        if(-not (Test-Path -LiteralPath $command.Executable)) { throw 'Prepared executable is missing.' }
        if($saved.Kind -eq 'NativeViaNode') {
            if($command.Executable -eq $now.LaunchExecutable -or $command.PrefixArguments[0] -ne $now.EntryScript) { throw 'Codex is not using a private Node.js bootstrap.' }
            $output=& $command.Executable --version
            if($LASTEXITCODE -ne 0 -or $output -notmatch '^v[0-9]') { throw 'Private Node.js copy could not execute.' }
            $changed=$now | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $changed.NativeExecutable=Join-Path $root 'unprotected-native.exe'
            Copy-Item -LiteralPath $now.NativeExecutable -Destination $changed.NativeExecutable
            $rejected=$false;try { $null=Get-WesNativeLaunchCommand -Saved $saved -Current $changed } catch { $rejected=$true }
            if(-not $rejected) { throw 'Unprotected backend update was accepted.' }
            Remove-Item -LiteralPath $changed.NativeExecutable
            $bytes=[IO.File]::ReadAllBytes($command.Executable);$bytes[$bytes.Length-1]=$bytes[$bytes.Length-1] -bxor 1
            [IO.File]::WriteAllBytes($command.Executable,$bytes)
            $rejected=$false;try { $null=Get-WesNativeLaunchCommand -Saved $saved -Current $now } catch { $rejected=$true }
            if(-not $rejected) { throw 'A modified private Node.js copy was accepted.' }
        }
    }
    Write-Output 'PASS: all four distributions prepared, package scope validated, private Node.js runs, unprotected backend and modified bootstrap rejected.'
} finally {
    # Verify the absolute target before deleting this test-owned temporary tree.
    $full=[IO.Path]::GetFullPath($path);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($full.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -like 'wes-launch-*') { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
}

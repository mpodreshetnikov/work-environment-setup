$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failures=@()
foreach($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -and $_.FullName -notlike '*\.git\*' })) {
    $tokens=$null;$parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    foreach($errorItem in @($parseErrors)) { $failures+=($file.Name+': '+$errorItem.Message) }
}
if($failures.Count) { throw ($failures -join [Environment]::NewLine) }
if(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notlike '*\.git\*' -and ($_.Name -like '*.private.json' -or $_.Extension -in @('.exe','.dll','.cip','.db','.sqlite','.pem','.key','.pfx')) }) { throw 'Private state, credentials or compiled binaries are present in the source checkout.' }
Write-Output 'PASS: PowerShell 5.1 syntax and source-only checkout.'

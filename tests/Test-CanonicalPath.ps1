$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Discovery.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('wes-path-'+[guid]::NewGuid().ToString())
$actual=Join-Path $root 'actual';$junction=Join-Path $root 'junction'
New-Item -ItemType Directory -Path $actual -Force | Out-Null
$file=Join-Path $actual 'fixture.exe';[IO.File]::WriteAllBytes($file,[byte[]]@(0))
try {
    New-Item -ItemType Junction -Path $junction -Target $actual | Out-Null
    $direct=Resolve-WesCanonicalPath $file
    $indirect=Resolve-WesCanonicalPath (Join-Path $junction 'fixture.exe')
    if($direct -ne $indirect -or $direct -ne $file) { throw 'Junction canonicalization failed.' }
    if((Resolve-WesCanonicalPath $junction) -ne $actual) { throw 'Directory canonicalization failed.' }
    Write-Output 'PASS: file and directory paths resolve through a junction without executing the target.'
} finally {
    if(Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $actual -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -ErrorAction SilentlyContinue
}

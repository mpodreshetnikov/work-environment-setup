$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Discovery.psm1') -Force
$path=Join-Path ([IO.Path]::GetTempPath()) ('wes-pe-'+[guid]::NewGuid().ToString()+'.exe')
try {
    foreach($case in @(@{machine=0x8664;expected='x64'},@{machine=0xAA64;expected='arm64'},@{machine=0x014C;expected='x86'})) {
        $stream=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($stream)
        try {
            $writer.Write([uint16]0x5A4D);$stream.Position=0x3C;$writer.Write([int]0x80)
            $stream.Position=0x80;$writer.Write([uint32]0x4550);$writer.Write([uint16]$case.machine)
            [IO.File]::WriteAllBytes($path,$stream.ToArray())
        } finally { $writer.Dispose() }
        if((Get-WesExecutableArchitecture $path) -ne $case.expected) { throw 'PE architecture did not match the executable header.' }
    }
    [IO.File]::WriteAllBytes($path,[byte[]]@(0))
    $rejected=$false;try { $null=Get-WesExecutableArchitecture $path } catch { $rejected=$true }
    if(-not $rejected) { throw 'A malformed executable was accepted.' }
    Write-Output 'PASS: x64, ARM64, x86 and malformed PE detection without executing the file.'
} finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }

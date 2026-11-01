function global:Invoke-WesGuardedCli {
    param([ValidateSet('ClaudeCode','CodexCli')][string]$Scope,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments=@())
    $root=Split-Path $PSScriptRoot
    if(-not $Scope) { throw 'A CLI application scope is required.' }
    Import-Module (Join-Path $PSScriptRoot 'PrivateState.psm1')
    $id=[guid]::NewGuid().ToString('N');$argumentFile=Join-Path $root ('.cli-args-'+$id+'.private.json')
    $previousEncoding=$OutputEncoding
    try {
        Write-WesPrivateJson -Path $argumentFile -Value @{SchemaVersion=1;OwnerSid=(Get-WesOwnerSid);Arguments=@($Arguments)}
        $bridge=Join-Path $root 'bin\CliBridge.exe'
        $OutputEncoding=[Text.UTF8Encoding]::new($false)
        if($MyInvocation.ExpectingInput) { $input | & $bridge $Scope --wes-private-arguments $id }
        else { & $bridge $Scope --wes-private-arguments $id }
    } finally { $OutputEncoding=$previousEncoding;Remove-Item -LiteralPath $argumentFile -ErrorAction SilentlyContinue }
}

# Unbound arguments preserve native switches such as -m and -s.
$wesShellRoot=Split-Path $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'PrivateState.psm1')
$wesShellScopes=@((Read-WesInstallationState $wesShellRoot).Applications.Scope)
if('CodexCli' -in $wesShellScopes) { function global:codex {
    if($MyInvocation.ExpectingInput) { $input | Invoke-WesGuardedCli -Scope CodexCli -Arguments $args }
    else { Invoke-WesGuardedCli -Scope CodexCli -Arguments $args }
} }
if('ClaudeCode' -in $wesShellScopes) { function global:claude {
    if($MyInvocation.ExpectingInput) { $input | Invoke-WesGuardedCli -Scope ClaudeCode -Arguments $args }
    else { Invoke-WesGuardedCli -Scope ClaudeCode -Arguments $args }
} }
Remove-Variable wesShellRoot,wesShellScopes

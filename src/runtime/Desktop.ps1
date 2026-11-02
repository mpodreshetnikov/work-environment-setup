param([Parameter(Mandatory=$true)][ValidateSet('ClaudeDesktop','CodexDesktop')][string]$Scope)
$ErrorActionPreference='Stop'
try {
    # Check.ps1 writes UTF-8 bytes for the native CLI bridge. Run it as a child here.
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Check.ps1')+'" -Scope '+$Scope
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.StandardOutputEncoding=[Text.Encoding]::UTF8
    $process=[Diagnostics.Process]::Start($start)
    try {
        $output=$process.StandardOutput.ReadToEndAsync();$errorOutput=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(45000)) { $process.Kill();throw 'VPN launch check timed out.' }
        $text=$output.GetAwaiter().GetResult();$null=$errorOutput.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0) { throw 'VPN launch check failed. Run verification.' }
        try { $plan=$text | ConvertFrom-Json -ErrorAction Stop } catch { throw 'VPN launch check returned invalid metadata.' }
    } finally { $process.Dispose() }
    if(-not $plan.Success) { throw $plan.Error }
    Import-Module (Join-Path $PSScriptRoot 'Discovery.psm1')
    $application=@(Get-WesApplicationInventory -Scopes @($Scope))[0]
    $main=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $application.MainExecutable -and $_.CommandLine -notmatch '--type=' })
    foreach($item in $main) {
        if(-not $item.CommandLine -or $item.CommandLine -notlike ('*--proxy-server='+$plan.ProxyUrl+'*')) { throw 'Fully quit the running application, then launch its VPN shortcut.' }
    }
    $launch=[Diagnostics.ProcessStartInfo]::new();$launch.FileName=$plan.Command.Executable
    $launch.UseShellExecute=$false;$launch.Arguments='--proxy-server='+$plan.ProxyUrl
    if($plan.DisableGpu) { $launch.Arguments+=' --disable-gpu' }
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) { $launch.EnvironmentVariables[$name]=$plan.ProxyUrl }
    $launch.EnvironmentVariables['NO_PROXY']='localhost,127.0.0.1,::1'
    if($Scope -eq 'CodexDesktop') { $launch.EnvironmentVariables['NODE_USE_ENV_PROXY']='1' }
    $child=[Diagnostics.Process]::Start($launch);if($child) { $child.Dispose() }
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    $null=[Windows.Forms.MessageBox]::Show($_.Exception.Message,'AI VPN launch check',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}

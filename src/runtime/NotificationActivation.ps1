param([Parameter(Mandatory=$true)][string]$ActivationBase64)
$ErrorActionPreference='Stop'
# COM activation does not inherit an interactive PowerShell environment. Use
# Windows PowerShell's own modules, including Utility/Get-FileHash, for checks.
$env:PSModulePath=@((Join-Path $PSHOME 'Modules'),(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')) -join ';'
$report=Join-Path $PSScriptRoot 'last-activation.private.json'
try {
    Import-Module (Join-Path $PSScriptRoot 'NotificationIntegration.psm1') -Force
    $null=Assert-WesNotificationIntegration $PSScriptRoot -ActivationContext
    $config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'notification-config.private.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $payload=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ActivationBase64)) | ConvertFrom-Json
    if($payload.AppId -notin @($config.AppIds) -or [string]$payload.Arguments -notmatch '\Atype=(?:action&action=[0-9]{1,3}|click)&tag=[0-9]{1,40}\z') { throw 'Unsupported notification activation. Open the VPN shortcut instead.' }
    if($config.Kind -eq 'Portable') {
        $launch=[Diagnostics.ProcessStartInfo]::new()
        $launch.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $launch.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$config.LaunchScript+'" -Scope CodexDesktop -Quiet -NotificationArguments "'+$payload.Arguments+'"'
        $launch.UseShellExecute=$false;$launch.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($launch)
        try {if(-not $process.WaitForExit(60000)) {$process.Kill();throw 'Protected notification launch timed out.'};if($process.ExitCode -ne 0) {throw 'Protected notification launch failed. Run verification.'}} finally {$process.Dispose()}
    } elseif($config.Kind -eq 'Legacy') {
        $check=[Diagnostics.ProcessStartInfo]::new()
        $check.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $check.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$config.GuardScript+'" -Mode Check'
        $check.UseShellExecute=$false;$check.CreateNoWindow=$true;$check.RedirectStandardOutput=$true;$check.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($check)
        try {
            $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(45000)) {$process.Kill();throw 'VPN notification check timed out.'}
            $checkOutput=$out.GetAwaiter().GetResult();$checkError=$err.GetAwaiter().GetResult()
            if($process.ExitCode -ne 0) {
                @{ExitCode=$process.ExitCode;Output=$checkOutput;Error=$checkError} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'health-error.private.json') -Encoding UTF8
                throw 'VPN notification check failed. Restore the pinned VPN first.'
            }
        } finally {$process.Dispose()}
        $package=Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
        if(-not $package) {throw 'Codex package is unavailable.'}
        $mainPath=Join-Path $package.InstallLocation 'app\ChatGPT.exe'
        foreach($p in @(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -eq $mainPath -and $_.CommandLine -notmatch '--type='})) {
            if($p.CommandLine -notlike ('*--proxy-server='+$config.ProxyUrl+'*')) {throw 'Fully quit the unprotected Codex window, then open Codex VPN.'}
        }
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\'+$package.PackageFamilyName+'\chatgpt-desktop.exe')
        $start.UseShellExecute=$false
        $start.Arguments='--disable-gpu --proxy-server='+$config.ProxyUrl+' '+$payload.Arguments
        foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {$start.EnvironmentVariables[$name]=$config.ProxyUrl}
        $start.EnvironmentVariables['NO_PROXY']='localhost,127.0.0.1,::1'
        $start.EnvironmentVariables['NODE_USE_ENV_PROXY']='1'
        $child=[Diagnostics.Process]::Start($start);if($child){$child.Dispose()}
    } else {throw 'Unknown notification launcher configuration.'}
    @{Status='Started';Source='NotificationBridge';Utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $report -Encoding UTF8
} catch {
    @{Status='Failed';Error=$_.Exception.Message;Utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $report -Encoding UTF8
    Add-Type -AssemblyName System.Windows.Forms
    $null=[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Codex VPN notification',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}

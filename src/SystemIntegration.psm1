Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'PrivateState.psm1')

function Write-WesIntegrationReceipt {
    param([string]$Root,$Receipt)
    Write-WesPrivateJson (Join-Path $Root 'integration.private.json') $Receipt
}

function Install-WesSystemIntegration {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)]$State,[hashtable]$Locations=@{},[switch]$SkipUserPath)
    $identity=Get-WesInstallationIdentity
    $path=Join-Path $Root 'integration.private.json'
    if(Test-Path -LiteralPath $path) { throw 'System integration already has a journal. Remove or repair it explicitly.' }
    foreach($entry in @{Desktop=[Environment]::GetFolderPath('Desktop');Programs=(Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs');Documents=[Environment]::GetFolderPath('MyDocuments');Run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'}.GetEnumerator()) {
        if(-not $Locations.ContainsKey($entry.Key)) { $Locations[$entry.Key]=$entry.Value }
    }
    $receipt=[ordered]@{SchemaVersion=1;OwnerSid=$identity.OwnerSid;Status='Installing';TaskName=$identity.V2rayTaskName;TaskCreated=$false;RunRegistryPath=$Locations.Run;RunValues=@();Shortcuts=@();Profiles=@();UserPathBefore=$null;UserPathAfter=$null}
    Write-WesIntegrationReceipt $Root $receipt
    try {
        $exe=Join-Path $State.Vpn.V2rayRoot 'v2rayN.exe'
        if(Get-ScheduledTask -TaskName $identity.V2rayTaskName -ErrorAction SilentlyContinue) { throw 'An existing task uses this installation task name.' }
        $action=New-ScheduledTaskAction -Execute $exe -WorkingDirectory $State.Vpn.V2rayRoot
        $trigger=New-ScheduledTaskTrigger -AtLogOn -User $identity.OwnerSid
        $principal=New-ScheduledTaskPrincipal -UserId $identity.OwnerSid -LogonType Interactive -RunLevel Highest
        $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
        $receipt.TaskCreated=$true;Write-WesIntegrationReceipt $Root $receipt
        Register-ScheduledTask -TaskName $identity.V2rayTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Start v2rayN elevated at logon. AI applications start only on demand.' | Out-Null
        $run=$Locations.Run
        if(Test-Path $run) {
            $values=Get-ItemProperty $run
            foreach($property in $values.PSObject.Properties | Where-Object MemberType -eq NoteProperty) {
                if($property.Name -like 'PS*' -or $property.Value -isnot [string]) { continue }
                $command=[string]$property.Value
                if($command -match ('^\s*"?'+[regex]::Escape($exe)+'"?(?:\s|$)')) {
                    $receipt.RunValues+=@(@{Name=$property.Name;Value=$command});Write-WesIntegrationReceipt $Root $receipt
                    Remove-ItemProperty -LiteralPath $run -Name $property.Name
                }
            }
        }
        $shell=New-Object -ComObject WScript.Shell
        $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        foreach($application in @($State.Applications | Where-Object Kind -eq 'PackagedDesktop')) {
            $label=if($application.Scope -eq 'ClaudeDesktop') {'Claude VPN'} else {'Codex VPN'}
            foreach($directory in @($Locations.Desktop,$Locations.Programs)) {
                $linkPath=Join-Path $directory ($label+'.lnk')
                if(Test-Path -LiteralPath $linkPath) { throw 'A VPN shortcut already exists. Move or remove it before installation.' }
                $receipt.Shortcuts+=@(@{Path=$linkPath;Target=$powershell});Write-WesIntegrationReceipt $Root $receipt
                $link=$shell.CreateShortcut($linkPath);$link.TargetPath=$powershell
                $link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $Root 'runtime\Desktop.ps1')+'" -Scope '+$application.Scope
                $link.IconLocation=$application.MainExecutable+',0';$link.Description='Verify pinned VPN before launch';$link.WindowStyle=7;$link.Save()
            }
        }
        if(@($State.Applications | Where-Object { $_.Scope -in @('ClaudeCode','CodexCli') }).Count) {
            $documents=$Locations.Documents
            $source=Join-Path $Root 'runtime\Shell.ps1'
            $block="`r`n# BEGIN WORK ENVIRONMENT AI VPN`r`n. '"+$source.Replace("'","''")+"'`r`n# END WORK ENVIRONMENT AI VPN`r`n"
            foreach($relative in @('PowerShell\profile.ps1','WindowsPowerShell\profile.ps1')) {
                $profilePath=Join-Path $documents $relative;$existed=Test-Path -LiteralPath $profilePath
                $bytes=[byte[]]@();if($existed) { $bytes=[IO.File]::ReadAllBytes($profilePath) }
                $content=if($existed) { [IO.File]::ReadAllText($profilePath) } else { '' }
                if($content -match '# BEGIN WORK ENVIRONMENT AI VPN') { throw 'An existing managed PowerShell profile block needs repair.' }
                $record=@{Path=$profilePath;Existed=$existed;Before=[Convert]::ToBase64String($bytes);AfterHash=$null}
                $receipt.Profiles+=@($record);Write-WesIntegrationReceipt $Root $receipt
                $null=[IO.Directory]::CreateDirectory((Split-Path $profilePath))
                [IO.File]::WriteAllText($profilePath,($content+$block),[Text.UTF8Encoding]::new($true))
                $record.AfterHash=(Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash;Write-WesIntegrationReceipt $Root $receipt
            }
            $bin=Join-Path $Root 'bin';$bridge=Join-Path $bin 'CliBridge.exe'
            foreach($scope in @('ClaudeCode','CodexCli')) {
                if($scope -notin @($State.Applications.Scope)) { continue }
                $commandName=if($scope -eq 'ClaudeCode') {'claude-vpn.cmd'} else {'codex-vpn.cmd'}
                [IO.File]::WriteAllText((Join-Path $bin $commandName),('@echo off' + "`r`n" + '"%~dp0CliBridge.exe" '+$scope+' %*'+"`r`n"),[Text.Encoding]::ASCII)
            }
            if(-not $SkipUserPath) {
            $receipt.UserPathBefore=[Environment]::GetEnvironmentVariable('Path','User')
            $entries=@(([string]$receipt.UserPathBefore).Split(';') | Where-Object {$_})
            $receipt.UserPathAfter=(@($entries)+@($bin) | Select-Object -Unique) -join ';'
            Write-WesIntegrationReceipt $Root $receipt
            [Environment]::SetEnvironmentVariable('Path',$receipt.UserPathAfter,'User')
            }
        }
        $receipt.Status='Installed';Write-WesIntegrationReceipt $Root $receipt
        return [pscustomobject]$receipt
    } catch {
        # The journal is intentionally retained so rollback can finish after interruption.
        $receipt.Status='RollbackRequired';Write-WesIntegrationReceipt $Root $receipt
        throw
    }
}

function Remove-WesSystemIntegration {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Root)
    $path=Join-Path $Root 'integration.private.json'
    if(-not (Test-Path -LiteralPath $path)) { return }
    $receipt=Read-WesPrivateJson $path;$identity=Get-WesInstallationIdentity
    if($receipt.OwnerSid -ne $identity.OwnerSid -or $receipt.TaskName -ne $identity.V2rayTaskName) { throw 'System integration journal belongs to another user.' }
    if($receipt.Status -eq 'Removed') { return }
    if($receipt.TaskCreated -and (Get-ScheduledTask -TaskName $receipt.TaskName -ErrorAction SilentlyContinue)) { Unregister-ScheduledTask -TaskName $receipt.TaskName -Confirm:$false }
    $run=$receipt.RunRegistryPath
    foreach($entry in @($receipt.RunValues)) {
        if(-not (Get-ItemProperty -LiteralPath $run -Name $entry.Name -ErrorAction SilentlyContinue)) { Set-ItemProperty -LiteralPath $run -Name $entry.Name -Value $entry.Value }
    }
    $shell=New-Object -ComObject WScript.Shell
    foreach($entry in @($receipt.Shortcuts)) {
        if(Test-Path -LiteralPath $entry.Path) {
            $link=$shell.CreateShortcut($entry.Path)
            if($link.TargetPath -eq $entry.Target -and $link.Arguments.Contains((Join-Path $Root 'runtime\Desktop.ps1'))) { Remove-Item -LiteralPath $entry.Path }
        }
    }
    foreach($entry in @($receipt.Profiles)) {
        if(-not (Test-Path -LiteralPath $entry.Path)) { continue }
        if($entry.AfterHash -and (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -eq $entry.AfterHash) {
            if($entry.Existed) { [IO.File]::WriteAllBytes($entry.Path,[Convert]::FromBase64String($entry.Before)) }
            else { Remove-Item -LiteralPath $entry.Path }
        } else {
            $content=[IO.File]::ReadAllText($entry.Path)
            if($content -notmatch '# BEGIN WORK ENVIRONMENT AI VPN') { continue }
            $expression='(?ms)\r?\n?# BEGIN WORK ENVIRONMENT AI VPN\r?\n.*?# END WORK ENVIRONMENT AI VPN\r?\n?'
            [IO.File]::WriteAllText($entry.Path,[regex]::Replace($content,$expression,''),[Text.UTF8Encoding]::new($true))
        }
    }
    if($receipt.UserPathAfter) {
        $current=[Environment]::GetEnvironmentVariable('Path','User')
        if($current -eq $receipt.UserPathAfter) { [Environment]::SetEnvironmentVariable('Path',$receipt.UserPathBefore,'User') }
        else { $bin=Join-Path $Root 'bin';[Environment]::SetEnvironmentVariable('Path',(@($current.Split(';') | Where-Object { $_ -ne $bin }) -join ';'),'User') }
    }
    $receipt.Status='Removed';Write-WesIntegrationReceipt $Root $receipt
}

Export-ModuleMember -Function Install-WesSystemIntegration,Remove-WesSystemIntegration

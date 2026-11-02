Set-StrictMode -Version 2

function Get-WesStartupTaskRecords {
    param([object[]]$Applications,[string]$RegistryRoot='HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData')
    $records=@()
    foreach($application in @($Applications | Where-Object Kind -eq 'PackagedDesktop')) {
        if(-not $application.PSObject.Properties['PackageFamilyName']) { continue }
        [xml]$manifest=Get-Content -LiteralPath (Join-Path $application.InstallRoot 'AppxManifest.xml') -Encoding UTF8
        foreach($task in @($manifest.SelectNodes("//*[local-name()='StartupTask']"))) {
            $id=$task.GetAttribute('TaskId')
            if($id -notmatch '^[A-Za-z0-9_.-]+$' -or $application.PackageFamilyName -notmatch '^[A-Za-z0-9_.-]+_[A-Za-z0-9]+$') { throw 'Invalid packaged application startup identity.' }
            $path=Join-Path (Join-Path $RegistryRoot $application.PackageFamilyName) $id
            $present=$false;$before=$null
            if(Test-Path -LiteralPath $path) {
                $key=Get-Item -LiteralPath $path
                if('State' -in $key.GetValueNames()) {
                    if($key.GetValueKind('State') -ne [Microsoft.Win32.RegistryValueKind]::DWord) { throw 'Unexpected startup task registry value type.' }
                    $present=$true;$before=[int]$key.GetValue('State')
                    if($before -lt 0 -or $before -gt 4) { throw 'Unknown packaged startup task state.' }
                }
            }
            if($present -and $before -eq 4) { throw 'Administrator policy enforces application startup. Change the policy before installation.' }
            $records+=@([pscustomobject]@{Scope=$application.Scope;Path=$path;StateExisted=$present;Before=$before;ManagedState=1;Changed=(-not $present -or $before -notin @(1,3))})
        }
    }
    return $records
}

function Disable-WesStartupTasks {
    param([object[]]$Records)
    foreach($record in @($Records)) {
        if(-not $record.Changed) { continue }
        if(-not (Test-Path -LiteralPath $record.Path)) { $null=New-Item -Path $record.Path -Force }
        $current=Get-ItemProperty -LiteralPath $record.Path
        if($current.PSObject.Properties['State']) {
            if($current.State -eq 4) { throw 'Administrator policy now enforces application startup.' }
            if($current.State -eq 3) { continue }
        }
        # DisabledByUser prevents an app from silently enabling its task again.
        $null=New-ItemProperty -LiteralPath $record.Path -Name State -PropertyType DWord -Value $record.ManagedState -Force
        if((Get-ItemProperty -LiteralPath $record.Path -Name State).State -ne $record.ManagedState) { throw 'Packaged application startup was not disabled.' }
    }
}

function Restore-WesStartupTasks {
    param([object[]]$Records)
    foreach($record in @($Records)) {
        if(-not $record.Changed -or -not (Test-Path -LiteralPath $record.Path)) { continue }
        $current=Get-ItemProperty -LiteralPath $record.Path
        if(-not $current.PSObject.Properties['State'] -or $current.State -ne $record.ManagedState) { continue }
        if($record.StateExisted) { $null=New-ItemProperty -LiteralPath $record.Path -Name State -PropertyType DWord -Value ([int]$record.Before) -Force }
        else { Remove-ItemProperty -LiteralPath $record.Path -Name State }
    }
}

Export-ModuleMember -Function Get-WesStartupTaskRecords,Disable-WesStartupTasks,Restore-WesStartupTasks

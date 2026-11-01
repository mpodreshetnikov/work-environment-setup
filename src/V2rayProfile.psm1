Set-StrictMode -Version 2

function Resolve-WesV2rayRoot {
    [CmdletBinding()]
    param([string]$Path)
    $candidates = @()
    if ($Path) {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { $resolved = Split-Path $resolved }
        $candidates = @($resolved)
    } else {
        $candidates += @(Get-Process -Name v2rayN -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Path) { Split-Path $_.Path } })
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $candidates += @(Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object { foreach ($action in $_.Actions) { if ($action.PSObject.Properties['Execute'] -and $action.Execute -match '(?i)(?:^|[\\/])v2rayN\.exe"?$') { Split-Path ($action.Execute.Trim('"')) } } })
        }
        $run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
        if ($run) {
            foreach ($entry in $run.PSObject.Properties) {
                if ($entry.Value -is [string] -and $entry.Value -match '(?i)^\s*"?(.+?v2rayN\.exe)"?(?:\s|$)') {
                    $candidates += Split-Path $matches[1]
                }
            }
        }
    }
    $valid = @($candidates | Where-Object { $_ } | Sort-Object -Unique | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_ 'v2rayN.exe')) -and
        (Test-Path -LiteralPath (Join-Path $_ 'guiConfigs\guiNConfig.json')) -and
        (Test-Path -LiteralPath (Join-Path $_ 'guiConfigs\guiNDB.db'))
    })
    if ($valid.Count -ne 1) { throw 'Could not uniquely locate v2rayN. Specify its directory explicitly.' }
    return $valid[0]
}

function Get-WesProfileValue {
    param([System.Collections.Generic.Dictionary[string,string]]$Profile, [string]$Name, [string]$Default = '')
    if ($Profile.ContainsKey($Name) -and $null -ne $Profile[$Name]) { return $Profile[$Name] }
    return $Default
}

function ConvertTo-WesVlessOutbound {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][System.Collections.Generic.Dictionary[string,string]]$Profile)
    $type = Get-WesProfileValue $Profile 'ConfigType'
    $network = Get-WesProfileValue $Profile 'Network' 'tcp'
    $security = Get-WesProfileValue $Profile 'StreamSecurity'
    if ($type -ne '5' -or $network -notin @('tcp','raw') -or $security -ne 'reality') {
        throw 'Automatic database import currently supports VLESS over TCP/REALITY only. Supply an exported Xray core configuration for another profile type.'
    }
    foreach ($name in @('Address','Port','Id','PublicKey','Sni')) {
        if (-not (Get-WesProfileValue $Profile $name)) { throw "The selected profile is missing required field: $name" }
    }
    foreach ($name in @('Extra','EchConfigList','RequestHost','Path','Mldsa65Verify','Alpn')) {
        if (Get-WesProfileValue $Profile $name) { throw "Profile field $name requires an exported core configuration; automatic import would be incomplete." }
    }
    if ((Get-WesProfileValue $Profile 'HeaderType' 'none') -notin @('','none')) { throw 'A non-default TCP header requires an exported core configuration.' }
    $port = 0
    if (-not [int]::TryParse((Get-WesProfileValue $Profile 'Port'), [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'The selected server port is invalid.' }
    $encryption = Get-WesProfileValue $Profile 'Security' 'none'
    if ($encryption -ne 'none') { throw 'VLESS encryption extensions require an exported core configuration.' }
    $fingerprint = Get-WesProfileValue $Profile 'Fingerprint' 'chrome'
    if (-not $fingerprint) { $fingerprint = 'chrome' }
    $reality = [ordered]@{
        serverName = Get-WesProfileValue $Profile 'Sni'
        fingerprint = $fingerprint
        publicKey = Get-WesProfileValue $Profile 'PublicKey'
        shortId = Get-WesProfileValue $Profile 'ShortId'
    }
    $spider = Get-WesProfileValue $Profile 'SpiderX'
    if ($spider) { $reality.spiderX = $spider }
    return [pscustomobject][ordered]@{
        tag = 'proxy'
        protocol = 'vless'
        settings = @{vnext=@(@{address=(Get-WesProfileValue $Profile 'Address');port=$port;users=@(@{id=(Get-WesProfileValue $Profile 'Id');encryption='none';flow=(Get-WesProfileValue $Profile 'Flow')})})}
        streamSettings = @{network=$network;security='reality';realitySettings=$reality}
    }
}

function Get-WesVpnSnapshot {
    [CmdletBinding()]
    param([string]$V2rayRoot, [string]$CoreConfigPath, [string]$SqliteLibraryPath)
    $root = Resolve-WesV2rayRoot -Path $V2rayRoot
    $saved = Get-Content -LiteralPath (Join-Path $root 'guiConfigs\guiNConfig.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    $id = [string]$saved.IndexId
    if (-not $id) { throw 'No active profile is saved in v2rayN.' }
    if (-not ('WorkEnvironmentSetup.SqliteProfileReader' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'native\SqliteProfileReader.cs') }
    if (-not $SqliteLibraryPath) { $SqliteLibraryPath = Join-Path $root 'e_sqlite3.dll' }
    [WorkEnvironmentSetup.SqliteProfileReader]::Load($SqliteLibraryPath)
    $profile = [WorkEnvironmentSetup.SqliteProfileReader]::ReadProfile((Join-Path $root 'guiConfigs\guiNDB.db'), $id)
    if ($null -eq $profile) { throw 'The selected profile was not found in the persistent database.' }
    $generated = $CoreConfigPath
    if (-not $generated) { $generated = Join-Path $root 'binConfigs\config.json' }
    if (Test-Path -LiteralPath $generated) {
        $core = Get-Content -LiteralPath $generated -Raw -Encoding UTF8 | ConvertFrom-Json
        $outbounds = @($core.outbounds | Where-Object tag -eq 'proxy')
        if ($outbounds.Count -ne 1) { throw 'The core configuration must contain exactly one proxy outbound.' }
        $outbound = $outbounds[0]
        $type = Get-WesProfileValue $profile 'ConfigType'
        if (($type -eq '5' -and $outbound.protocol -ne 'vless') -or ($type -eq '1' -and $outbound.protocol -ne 'vmess') -or $type -notin @('1','5')) { throw 'Core protocol does not match a supported selected profile.' }
        # Validate the exported/runtime snapshot against the persistent selection.
        $endpoint = $null
        if ($outbound.settings.PSObject.Properties['vnext']) {
            if (@($outbound.settings.vnext).Count -ne 1) { throw 'Multiple proxy endpoints are not allowed.' }
            $endpoint = @($outbound.settings.vnext)[0]
        }
        if (-not $endpoint -or $endpoint.address -ne (Get-WesProfileValue $profile 'Address') -or [int]$endpoint.port -ne [int](Get-WesProfileValue $profile 'Port')) {
            throw 'Core configuration does not match the selected server.'
        }
        if ($outbound.protocol -in @('vless','vmess')) {
            if (@($endpoint.users).Count -ne 1) { throw 'Multiple proxy identities are not allowed.' }
            if (@($endpoint.users)[0].id -ne (Get-WesProfileValue $profile 'Id')) { throw 'Core credentials do not match the selected profile.' }
        } else { throw 'Core profile verification is currently implemented for VLESS and VMess only.' }
        $selectedSecurity = Get-WesProfileValue $profile 'StreamSecurity' 'none'
        if (-not $selectedSecurity) { $selectedSecurity = 'none' }
        $coreSecurity = 'none'
        if ($outbound.PSObject.Properties['streamSettings'] -and $outbound.streamSettings -and $outbound.streamSettings.PSObject.Properties['security'] -and $outbound.streamSettings.security) { $coreSecurity = [string]$outbound.streamSettings.security }
        if ($coreSecurity -ne $selectedSecurity) { throw 'Core transport security differs from the saved profile.' }
        if ($selectedSecurity -eq 'reality') {
            if (-not $outbound.streamSettings.PSObject.Properties['realitySettings']) { throw 'REALITY settings missing.' }
            $reality = $outbound.streamSettings.realitySettings
            $publicKey = ''
            if ($reality.PSObject.Properties['publicKey']) { $publicKey = [string]$reality.publicKey }
            elseif ($reality.PSObject.Properties['password']) { $publicKey = [string]$reality.password }
            if ($publicKey -ne (Get-WesProfileValue $profile 'PublicKey') -or $reality.serverName -ne (Get-WesProfileValue $profile 'Sni') -or [string]$reality.shortId -ne (Get-WesProfileValue $profile 'ShortId')) { throw 'REALITY identity differs from the saved profile.' }
        }
        if ($outbound.protocol -eq 'vless' -and (@($endpoint.users)[0].encryption -ne (Get-WesProfileValue $profile 'Security' 'none') -or [string]@($endpoint.users)[0].flow -ne (Get-WesProfileValue $profile 'Flow'))) { throw 'VLESS security settings differ from the saved profile.' }
        if (($outbound.PSObject.Properties['proxySettings'] -and $outbound.proxySettings) -or
            ($outbound.PSObject.Properties['streamSettings'] -and $outbound.streamSettings -and $outbound.streamSettings.PSObject.Properties['sockopt'] -and $outbound.streamSettings.sockopt -and $outbound.streamSettings.sockopt.PSObject.Properties['dialerProxy'] -and $outbound.streamSettings.sockopt.dialerProxy)) {
            throw 'A chained outbound needs additional configuration and is not imported automatically.'
        }
        $outbound = $outbound | ConvertTo-Json -Depth 70 | ConvertFrom-Json
        $outbound.tag = 'proxy'
        $source = 'core-json'
    } else {
        if ($CoreConfigPath) { throw 'The specified core configuration file does not exist.' }
        $outbound = ConvertTo-WesVlessOutbound -Profile $profile
        $source = 'persistent-database'
    }
    # This object contains private VPN credentials. Never print or commit it.
    return [pscustomobject]@{
        V2rayRoot=$root; ProfileId=$id; Source=$source; Outbound=$outbound
        XrayPath=(Join-Path $root 'bin\xray\xray.exe')
        GuiConfigPath=(Join-Path $root 'guiConfigs\guiNConfig.json')
        TunEnabled=[bool]$saved.TunModeItem.EnableTun
    }
}

Export-ModuleMember -Function Resolve-WesV2rayRoot,ConvertTo-WesVlessOutbound,Get-WesVpnSnapshot

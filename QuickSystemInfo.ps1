#requires -Version 5.1
<#
Quick System Info
Gathers a quick point-in-time diagnostic snapshot of this machine and produces
a single shareable HTML report. Intended as a starting point for troubleshooting,
not an exhaustive audit.
#>

# Shown in the report footer so you can tell which copy someone ran. Bump on every change.
$script:ToolVersion = '1.1.0'

# ---------------------------------------------------------------------------
# Relaunch in STA if needed (WinForms requires a Single Threaded Apartment)
# ---------------------------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($PSCommandPath) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',"`"$PSCommandPath`"")
        exit
    } else {
        Write-Warning 'Please re-run with: powershell -STA -File QuickSystemInfo.ps1'
        exit
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:LastReportPath = $null
$script:LogBox = $null
$script:StatusLabel = $null
$script:ProgressBar = $null

# ===========================================================================
# region: Small helpers
# ===========================================================================

function Write-Log {
    param([string]$Message)
    if ($script:LogBox) {
        $script:LogBox.AppendText("$Message`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.Text.Length
        $script:LogBox.ScrollToCaret()
    }
    if ($script:StatusLabel) { $script:StatusLabel.Text = $Message }
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-Progress {
    if ($script:ProgressBar -and $script:ProgressBar.Value -lt $script:ProgressBar.Maximum) {
        $script:ProgressBar.Value += 1
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-Section {
    param([string]$Name, [scriptblock]$Action)
    Write-Log "Collecting: $Name ..."
    try {
        $data = & $Action
        Write-Log "  Done: $Name"
        [PSCustomObject]@{ Success = $true; Data = $data; Error = $null }
    } catch {
        Write-Log "  Skipped ($Name): $($_.Exception.Message)"
        [PSCustomObject]@{ Success = $false; Data = $null; Error = $_.Exception.Message }
    } finally {
        Update-Progress
    }
}

function HtmlEncode($text) {
    if ($null -eq $text) { return '' }
    ([string]$text).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Format-DT($dt) {
    if (-not $dt) { return '' }
    try { ([datetime]$dt).ToString('yyyy-MM-dd HH:mm') } catch { [string]$dt }
}

function Badge($text, $class) {
    "<span class='badge $class'>$(HtmlEncode $text)</span>"
}

function Format-Count([int]$Count, [string]$Noun) {
    if ($Count -eq 1) { "1 $Noun" } else { "$Count ${Noun}s" }
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    else { '{0:N0} KB' -f [math]::Ceiling($Bytes / 1KB) }
}

function Test-PlaceholderValue($Value) {
    if ($null -eq $Value) { return $true }
    $v = ([string]$Value).Trim()
    if (-not $v) { return $true }
    # Strings firmware vendors leave in place when a real value was never programmed (common on custom builds)
    $v -match '^(default string|to be filled by o\.?e\.?m\.?|o\.?e\.?m\.?|system serial number|base ?board serial number|chassis serial number|system product name|system manufacturer|system version|not applicable|not specified|n/?a|none|serial|rev ?x\.0x|x\.x+|0+|1234567890?|x+|\.+)$'
}

function Format-HardwareId($Value) {
    if (Test-PlaceholderValue $Value) {
        $raw = ([string]$Value).Trim()
        $reported = if ($raw) { " (reports &quot;$(HtmlEncode $raw)&quot;)" } else { '' }
        return "<span class='muted'>Not set by manufacturer$reported</span>"
    }
    HtmlEncode $Value
}

function New-HtmlTable {
    param([array]$Rows, [string[]]$Columns, [string]$EmptyMessage = 'No data available.')
    if (-not $Rows -or $Rows.Count -eq 0) {
        return "<p class='muted'>$(HtmlEncode $EmptyMessage)</p>"
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $Columns) { [void]$sb.Append("<th>$(HtmlEncode $c)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in $Rows) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columns) {
            [void]$sb.Append("<td>$(HtmlEncode $row.$c)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    "<div class='table-wrap'>$($sb.ToString())</div>"
}

function ConvertTo-SubnetMask {
    param([int]$PrefixLength)
    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) { return '' }
    $maskBits = [uint32]([math]::Pow(2,32) - [math]::Pow(2, 32 - $PrefixLength))
    $bytes = [BitConverter]::GetBytes($maskBits)
    [Array]::Reverse($bytes)
    ($bytes -join '.')
}

# ===========================================================================
# region: Data gathering functions
# ===========================================================================

function Get-SystemOverview {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $board = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $mem = Get-CimInstance Win32_PhysicalMemory
    $gpu = Get-CimInstance Win32_VideoController

    [PSCustomObject]@{
        Manufacturer      = $cs.Manufacturer
        Model             = $cs.Model
        SerialNumber      = $bios.SerialNumber
        BIOSVersion       = $bios.SMBIOSBIOSVersion
        BIOSDate          = $bios.ReleaseDate
        # Win32_BIOS.SerialNumber is usually the whole PC's serial; the board's own is in Win32_BaseBoard
        BoardManufacturer = $board.Manufacturer
        BoardProduct      = $board.Product
        BoardVersion      = $board.Version
        BoardSerial       = $board.SerialNumber
        CPU               = $cpu.Name
        Cores             = $cpu.NumberOfCores
        LogicalProcessors = $cpu.NumberOfLogicalProcessors
        TotalRAMGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        RAMModules = @($mem | ForEach-Object {
            [PSCustomObject]@{
                Location     = $_.DeviceLocator
                CapacityGB   = [math]::Round($_.Capacity / 1GB, 1)
                SpeedMHz     = $_.Speed
                Manufacturer = $_.Manufacturer
                PartNumber   = ([string]$_.PartNumber).Trim()
            }
        })
        GPUs = @($gpu | ForEach-Object {
            [PSCustomObject]@{
                Name          = $_.Name
                DriverVersion = $_.DriverVersion
                DriverDate    = $_.DriverDate
                VRAMGB        = if ($_.AdapterRAM) { [math]::Round($_.AdapterRAM / 1GB, 2) } else { $null }
            }
        })
    }
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    try {
        $pfro = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($pfro) { return $true }
    } catch { }
    return $false
}

function Get-OSInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $uptime = (Get-Date) - $os.LastBootUpTime
    $licenseMap = @{0='Unlicensed';1='Licensed';2='OOB Grace';3='OOT Grace';4='Non-Genuine Grace';5='Notification';6='Extended Grace'}
    # 55c92734-... is the Windows application ID; without it, an Office licence listed first can be picked up instead
    $license = Get-CimInstance -Query "SELECT LicenseStatus FROM SoftwareLicensingProduct WHERE PartialProductKey IS NOT NULL AND ApplicationID = '55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction SilentlyContinue | Select-Object -First 1

    [PSCustomObject]@{
        Caption          = $os.Caption
        Version          = $os.Version
        Build            = $os.BuildNumber
        Arch             = $os.OSArchitecture
        InstallDate      = $os.InstallDate
        LastBoot         = $os.LastBootUpTime
        Uptime           = '{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes
        ActivationStatus = if ($license) { $licenseMap[[int]$license.LicenseStatus] } else { 'Unknown' }
        PendingReboot    = Test-PendingReboot
    }
}

function Get-WindowsUpdatesInfo {
    $hotfixes = @(Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 20 HotFixID, Description, InstalledOn)
    $failed = @()
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count    = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            $history = $searcher.QueryHistory(0, [Math]::Min(50, $count))
            $failed = @($history | Where-Object { $_.ResultCode -ne 2 } | Select-Object -First 15 Title, Date, @{n='Result';e={
                switch ($_.ResultCode) { 3 {'SucceededWithErrors'} 4 {'Failed'} 5 {'Aborted'} default {'Unknown'} }
            }})
        }
    } catch { }
    [PSCustomObject]@{ RecentHotfixes = $hotfixes; FailedUpdates = $failed }
}

function Get-HardwareDriverInfo {
    $problems = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -ne 'OK' } |
        Select-Object FriendlyName, Class, Status, InstanceId)

    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceClass -in @('NET','DISPLAY','MEDIA','HDC','SCSIADAPTER','USB','MONITOR','BLUETOOTH') } |
        Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate |
        Sort-Object DeviceClass, DeviceName)

    [PSCustomObject]@{ ProblemDevices = $problems; KeyDrivers = $drivers }
}

function Get-HardwareEventLogErrors {
    param([int]$Days = 14, [int]$MaxEvents = 300)
    $start = (Get-Date).AddDays(-$Days)
    $events = @(Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2,3; StartTime=$start} -MaxEvents $MaxEvents -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, LevelDisplayName, ProviderName, Id, @{n='Message';e={ (($_.Message -split "`n") | Select-Object -First 1) }})
    $events
}

function Get-CrashHistory {
    $unexpected = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41} -MaxEvents 15 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, @{n='Detail';e={'Unexpected shutdown / power loss (not a clean shutdown)'}})
    $bugchecks = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; Id=1001} -MaxEvents 15 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, @{n='Detail';e={ (($_.Message -split "`n") | Select-Object -First 1) }})
    # Windows can be configured to write dumps somewhere other than the defaults, so check both
    $crashControl = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
    $defaultMiniDir  = Join-Path $env:SystemRoot 'Minidump'
    $defaultFullDump = Join-Path $env:SystemRoot 'MEMORY.DMP'
    $miniDir  = if ($crashControl.MinidumpDir) { [Environment]::ExpandEnvironmentVariables([string]$crashControl.MinidumpDir).TrimEnd('\') } else { $defaultMiniDir }
    $fullDump = if ($crashControl.DumpFile) { [Environment]::ExpandEnvironmentVariables([string]$crashControl.DumpFile) } else { $defaultFullDump }

    $dumpType = 'Unknown'
    if ($null -ne $crashControl.CrashDumpEnabled) {
        $dumpType = switch ([int]$crashControl.CrashDumpEnabled) {
            0 { 'None (dumps disabled)' }
            1 { if ($crashControl.FilterPages -eq 1) { 'Active memory dump' } else { 'Complete memory dump' } }
            2 { 'Kernel memory dump' }
            3 { 'Small memory dump (minidump only)' }
            7 { 'Automatic memory dump' }
            default { "Unknown ($($crashControl.CrashDumpEnabled))" }
        }
    }

    $notes = @()
    $minidumps = @()
    foreach ($dir in @($defaultMiniDir, $miniDir) | Sort-Object -Unique) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        try {
            $minidumps += @(Get-ChildItem -LiteralPath $dir -Filter *.dmp -File -ErrorAction Stop |
                Sort-Object LastWriteTime -Descending | ForEach-Object { ConvertTo-DumpFileRow $_ })
        } catch {
            $notes += if ($_.CategoryInfo.Category -eq 'PermissionDenied' -or $_.Exception -is [UnauthorizedAccessException]) {
                "Could not list $dir - run as Administrator to see minidump files."
            } else { "Could not list ${dir}: $($_.Exception.Message)" }
        }
    }

    $fullDumps = @()
    foreach ($file in @($defaultFullDump, $fullDump) | Sort-Object -Unique) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $fullDumps += ConvertTo-DumpFileRow (Get-Item -LiteralPath $file -Force -ErrorAction Stop)
        } catch {
            $notes += "Found $file but could not read its details: $($_.Exception.Message)"
        }
    }

    [PSCustomObject]@{
        UnexpectedShutdowns = $unexpected
        BugChecks           = $bugchecks
        DumpType            = $dumpType
        MinidumpFolder      = $miniDir
        FullDumpFile        = $fullDump
        Minidumps           = $minidumps
        FullDumps           = $fullDumps
        Notes               = $notes
    }
}

function ConvertTo-DumpFileRow([System.IO.FileInfo]$File) {
    [PSCustomObject]@{
        Path     = $File.FullName
        Created  = Format-DT $File.CreationTime
        Modified = Format-DT $File.LastWriteTime
        Size     = Format-Size $File.Length
    }
}

function Get-NetworkInfo {
    $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Address })
    $adapters = @($configs | ForEach-Object {
        $c = $_
        $ipInfo  = Get-NetIPAddress -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $adapter = Get-NetAdapter -InterfaceIndex $c.InterfaceIndex -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Adapter      = $c.InterfaceAlias
            Status       = $adapter.Status
            LinkSpeed    = $adapter.LinkSpeed
            MacAddress   = $adapter.MacAddress
            IPAddress    = ($c.IPv4Address.IPAddress -join ', ')
            SubnetMask   = if ($ipInfo) { ConvertTo-SubnetMask $ipInfo.PrefixLength } else { '' }
            Gateway      = ($c.IPv4DefaultGateway.NextHop -join ', ')
            DNSServers   = ($c.DNSServer.ServerAddresses -join ', ')
        }
    })
    [PSCustomObject]@{ Adapters = $adapters; Wireless = Get-WirelessInfo }
}

function Resolve-PtrName {
    param([string]$IpAddress, [int]$TimeoutMs = 800)
    try {
        $iar = [System.Net.Dns]::BeginGetHostEntry($IpAddress, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return [System.Net.Dns]::EndGetHostEntry($iar).HostName
        }
    } catch { }
    return $null
}

function Invoke-TraceRoute {
    param([string]$Target, [int]$MaxHops = 20, [int]$TimeoutMs = 600, [int]$ProbesPerHop = 3, [int]$DnsTimeoutMs = 700)
    $ping = New-Object System.Net.NetworkInformation.Ping
    $buffer = New-Object byte[] 32
    $destIp = $Target
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($Target) | Select-Object -First 1
        if ($resolved) { $destIp = $resolved.IPAddressToString }
    } catch { }
    $hops = @()
    for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
        $opts = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
        $rtts = @()
        $hopAddr = $null
        $reachedTarget = $false
        for ($probe = 0; $probe -lt $ProbesPerHop; $probe++) {
            try {
                $reply = $ping.Send($destIp, $TimeoutMs, $buffer, $opts)
                if ($reply.Status -in @('Success', 'TtlExpired')) {
                    $rtts += $reply.RoundtripTime
                    # PingReply.Address is unreliable (often echoes the destination) unless the probe actually got a reply
                    if (-not $hopAddr -and $reply.Address) { $hopAddr = $reply.Address.ToString() }
                    if ($reply.Status -eq 'Success') { $reachedTarget = $true }
                } else {
                    $rtts += $null
                }
            } catch {
                $rtts += $null
            }
        }
        $hostname = if ($hopAddr) { Resolve-PtrName -IpAddress $hopAddr -TimeoutMs $DnsTimeoutMs } else { $null }
        $hops += [PSCustomObject]@{ Hop = $ttl; Rtt1 = $rtts[0]; Rtt2 = $rtts[1]; Rtt3 = $rtts[2]; Address = $hopAddr; Hostname = $hostname }
        if ($reachedTarget) { break }
    }
    $hops
}

function Invoke-ConnectivityTest {
    param([string[]]$Targets, [int]$CountPerTarget = 8, [scriptblock]$OnProgress)
    $ping = New-Object System.Net.NetworkInformation.Ping
    $results = @()
    foreach ($target in $Targets) {
        if ($OnProgress) { & $OnProgress "Testing $target ..." }
        $dnsInfo = $null
        if ($target -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                $addr = [System.Net.Dns]::GetHostAddresses($target) | Select-Object -First 1
                $sw.Stop()
                $dnsInfo = [PSCustomObject]@{ Resolved = $true; IP = $addr.IPAddressToString; TimeMs = $sw.ElapsedMilliseconds }
            } catch {
                $sw.Stop()
                $dnsInfo = [PSCustomObject]@{ Resolved = $false; IP = $null; TimeMs = $sw.ElapsedMilliseconds }
            }
            if ($OnProgress) {
                if ($dnsInfo.Resolved) { & $OnProgress "  DNS: $target -> $($dnsInfo.IP) ($($dnsInfo.TimeMs) ms)" }
                else { & $OnProgress "  DNS: $target failed to resolve" }
            }
        }
        $times = @(); $sent = 0; $received = 0
        for ($i = 0; $i -lt $CountPerTarget; $i++) {
            $sent++
            try {
                $reply = $ping.Send($target, 1000)
                if ($reply.Status -eq 'Success') {
                    $received++
                    $times += $reply.RoundtripTime
                    if ($OnProgress) { & $OnProgress "  reply #$($i+1) from $target : $($reply.RoundtripTime) ms" }
                } else {
                    if ($OnProgress) { & $OnProgress "  reply #$($i+1) from $target : $($reply.Status)" }
                }
            } catch {
                if ($OnProgress) { & $OnProgress "  reply #$($i+1) from $target : error - $($_.Exception.Message)" }
            }
            Start-Sleep -Milliseconds 150
        }
        $lossPct = if ($sent -gt 0) { [math]::Round((($sent - $received) / $sent) * 100, 1) } else { 100 }
        $jitter = $null
        if ($times.Count -ge 2) {
            $diffs = for ($k = 1; $k -lt $times.Count; $k++) { [math]::Abs($times[$k] - $times[$k - 1]) }
            $jitter = [math]::Round(($diffs | Measure-Object -Average).Average, 1)
        }
        $results += [PSCustomObject]@{
            Target            = $target
            DNS               = $dnsInfo
            Sent              = $sent
            Received          = $received
            PacketLossPercent = $lossPct
            MinMs             = if ($times) { ($times | Measure-Object -Minimum).Minimum } else { $null }
            AvgMs             = if ($times) { [math]::Round(($times | Measure-Object -Average).Average, 1) } else { $null }
            MaxMs             = if ($times) { ($times | Measure-Object -Maximum).Maximum } else { $null }
            JitterMs          = $jitter
        }
    }
    $results
}

function Get-DiskHealthInfo {
    $volumes = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{
            Drive       = $_.DeviceID
            SizeGB      = [math]::Round($_.Size / 1GB, 1)
            FreeGB      = [math]::Round($_.FreeSpace / 1GB, 1)
            FreePercent = if ($_.Size) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
        }
    })
    $physicalDisks = @()
    try {
        $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object DeviceId, FriendlyName, MediaType, @{n='SizeGB';e={[math]::Round($_.Size / 1GB, 1)}}, HealthStatus, OperationalStatus)
    } catch { }
    [PSCustomObject]@{ Volumes = $volumes; PhysicalDisks = $physicalDisks }
}

function Get-SecurityStatusInfo {
    $defender = $null
    try { $defender = Get-MpComputerStatus -ErrorAction Stop | Select-Object AntivirusEnabled, RealTimeProtectionEnabled, AntispywareEnabled, AntivirusSignatureLastUpdated } catch { }
    $firewall = @()
    try { $firewall = @(Get-NetFirewallProfile -ErrorAction Stop | Select-Object Name, Enabled) } catch { }
    $bitlocker = @()
    try { $bitlocker = @(Get-BitLockerVolume -ErrorAction Stop | Select-Object MountPoint, VolumeStatus, ProtectionStatus) } catch { }
    [PSCustomObject]@{ Defender = $defender; Firewall = $firewall; BitLocker = $bitlocker }
}

function Get-StartupAndProcessInfo {
    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object Name, Command, Location, User)
    $topCPU = @(Get-Process -ErrorAction SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 5 Name, Id, @{n='CPUs';e={[math]::Round($_.CPU,1)}}, @{n='MemMB';e={[math]::Round($_.WorkingSet64/1MB,1)}})
    $topMem = @(Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 Name, Id, @{n='MemMB';e={[math]::Round($_.WorkingSet64/1MB,1)}}, @{n='CPUs';e={[math]::Round($_.CPU,1)}})
    [PSCustomObject]@{ Startup = $startup; TopCPU = $topCPU; TopMemory = $topMem }
}

function Get-InstalledSoftwareInfo {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and $_.DisplayName -notmatch '^KB\d{6,}$' }
    }
    @($apps | Select-Object `
        @{n='Name'; e={$_.DisplayName}},
        @{n='Version'; e={$_.DisplayVersion}},
        Publisher,
        @{n='InstallDate'; e={
            if ($_.InstallDate -match '^\d{8}$') { [datetime]::ParseExact($_.InstallDate,'yyyyMMdd',$null).ToString('yyyy-MM-dd') } else { $_.InstallDate }
        }} |
        Sort-Object Name, Version -Unique)
}

function Get-WirelessPowerSetting {
    try {
        $activeScheme = powercfg /GETACTIVESCHEME
        if ($activeScheme -notmatch 'GUID:\s*([0-9a-fA-F-]{36})') { return 'Unknown' }
        $schemeGuid = $matches[1]
        # 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 is the fixed, locale-independent subgroup GUID for "Wireless Adapter Settings"
        $query = powercfg /Q $schemeGuid 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 2>$null
        $text = $query -join "`n"
        if ($text -match 'Current AC Power Setting Index:\s*0x0*([0-9a-fA-F]+)') {
            switch ([Convert]::ToInt32($matches[1], 16)) {
                0 { return 'Maximum Performance' }
                1 { return 'Low Power Saving' }
                2 { return 'Medium Power Saving' }
                3 { return 'Maximum Power Saving' }
                default { return "Unknown (index $($matches[1]))" }
            }
        }
        return 'Unknown'
    } catch { return 'Unknown' }
}

function Get-WirelessInfo {
    $output = netsh wlan show interfaces 2>$null
    if (-not $output -or ($output -join ' ') -match 'no wireless interface') { return $null }
    $info = @{}
    foreach ($line in $output) {
        if ($line -match '^\s*([A-Za-z0-9 ./()-]+?)\s*:\s*(.*)$') {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()
            if ($key -and -not $info.ContainsKey($key)) { $info[$key] = $val }
        }
    }
    if (-not $info.ContainsKey('SSID') -and -not $info.ContainsKey('State')) { return $null }
    [PSCustomObject]@{
        SSID          = $info['SSID']
        State         = $info['State']
        BSSID         = $info['AP BSSID']
        Band          = $info['Band']
        Channel       = $info['Channel']
        RadioType     = $info['Radio type']
        Authentication= $info['Authentication']
        SignalPercent = $info['Signal']
        RssiDbm       = $info['Rssi']
        ReceiveMbps   = $info['Receive rate (Mbps)']
        TransmitMbps  = $info['Transmit rate (Mbps)']
        PowerSaveMode = Get-WirelessPowerSetting
    }
}

# ===========================================================================
# region: HTML report rendering
# ===========================================================================

function Get-ReportCss {
    @'
:root {
  --bg:#f5f6f8; --card-bg:#ffffff; --text:#1c1f24; --muted:#6b7280; --border:#e2e5ea; --accent:#2563eb;
  --ok-bg:#e6f4ea; --ok-text:#1a7f37; --warn-bg:#fff4e0; --warn-text:#9a6700; --bad-bg:#fde8e8; --bad-text:#c0261e;
}
@media (prefers-color-scheme: dark) {
  :root { --bg:#14161a; --card-bg:#1d2026; --text:#e6e8eb; --muted:#9aa1ac; --border:#2b2f36; --accent:#60a5fa;
    --ok-bg:#123321; --ok-text:#4ade80; --warn-bg:#3a2c0a; --warn-text:#fbbf24; --bad-bg:#3a1414; --bad-text:#f87171; }
}
* { box-sizing:border-box; }
body { margin:0; font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif; background:var(--bg); color:var(--text); }
.container { max-width:1100px; margin:0 auto; padding:24px 16px 60px; }
header.report-header { background:var(--card-bg); border:1px solid var(--border); border-radius:10px; padding:20px 24px; margin-bottom:16px; }
header.report-header h1 { margin:0 0 6px; font-size:1.5rem; }
header.report-header p { margin:2px 0; color:var(--muted); font-size:.9rem; }
nav.toc { background:var(--card-bg); border:1px solid var(--border); border-radius:10px; padding:14px 20px; margin-bottom:20px; }
nav.toc ul { list-style:none; margin:0; padding:0; display:flex; flex-wrap:wrap; gap:8px 16px; }
nav.toc a { color:var(--accent); text-decoration:none; font-size:.9rem; }
nav.toc a:hover { text-decoration:underline; }
.toc-actions { display:flex; gap:8px; margin-bottom:10px; }
.toc-actions button { font:inherit; font-size:.85rem; padding:5px 12px; border:1px solid var(--border); border-radius:6px; background:var(--bg); color:var(--text); cursor:pointer; }
.toc-actions button:hover { border-color:var(--accent); color:var(--accent); }
.card { background:var(--card-bg); border:1px solid var(--border); border-radius:10px; padding:20px 24px; margin-bottom:18px; }
.card h2 { margin-top:0; font-size:1.15rem; border-bottom:1px solid var(--border); padding-bottom:10px; }
details.section { padding:14px 24px; }
details.section > summary { display:flex; align-items:center; flex-wrap:wrap; gap:8px 12px; cursor:pointer; list-style:none; }
details.section > summary::-webkit-details-marker { display:none; }
details.section > summary::before { content:'\25B8'; color:var(--muted); font-size:.9rem; transition:transform .15s; }
details.section[open] > summary::before { transform:rotate(90deg); }
details.section > summary h2 { margin:0; padding:0; border:0; flex:1 1 auto; }
details.section[open] > summary { border-bottom:1px solid var(--border); padding-bottom:10px; margin-bottom:6px; }
.section-badges { display:flex; flex-wrap:wrap; gap:6px; }
.card h3 { font-size:.8rem; color:var(--muted); text-transform:uppercase; letter-spacing:.03em; margin:18px 0 8px; }
.grid2 { display:grid; grid-template-columns:repeat(auto-fill,minmax(240px,1fr)); gap:10px 24px; margin-bottom:8px; }
.grid2 > div { display:flex; flex-direction:column; padding:6px 0; border-bottom:1px dashed var(--border); }
.label { font-size:.75rem; color:var(--muted); text-transform:uppercase; letter-spacing:.03em; }
.value { font-size:.95rem; margin-top:2px; word-break:break-word; }
.table-wrap { overflow-x:auto; margin-bottom:10px; }
.table-wrap table { margin-bottom:0; }
table { width:100%; border-collapse:collapse; font-size:.85rem; margin-bottom:10px; }
.filter-box { width:100%; padding:8px 12px; margin-bottom:10px; border:1px solid var(--border); border-radius:8px; background:var(--card-bg); color:var(--text); font-size:.9rem; }
th, td { text-align:left; padding:7px 10px; border-bottom:1px solid var(--border); vertical-align:top; }
th { color:var(--muted); font-weight:600; font-size:.72rem; text-transform:uppercase; }
tbody tr:hover { background:rgba(127,127,127,0.06); }
.badge { display:inline-block; padding:2px 9px; border-radius:999px; font-size:.75rem; font-weight:600; white-space:nowrap; }
.badge.ok { background:var(--ok-bg); color:var(--ok-text); }
.badge.warn { background:var(--warn-bg); color:var(--warn-text); }
.badge.bad { background:var(--bad-bg); color:var(--bad-text); }
.badge.info { background:var(--bg); color:var(--muted); border:1px solid var(--border); }
.muted { color:var(--muted); font-size:.9rem; }
.ok-text { color:var(--ok-text); }
.footnote { color:var(--muted); font-size:.75rem; margin-top:6px; }
p.warn { background:var(--warn-bg); color:var(--warn-text); padding:8px 12px; border-radius:8px; font-size:.85rem; }
footer { text-align:center; color:var(--muted); font-size:.8rem; margin-top:30px; }
@media print {
  nav.toc { display:none; }
  .card { break-inside:avoid; border:1px solid #ccc; }
}
'@
}

function Get-SectionBadges {
    # Header badges, visible while a section is collapsed, so problems stand out without opening it
    param([string]$Key, [System.Collections.Specialized.OrderedDictionary]$Report)
    $result = $Report[$Key]
    $badges = New-Object System.Collections.ArrayList
    if (-not $result -or -not $result.Success) {
        [void]$badges.Add((Badge 'Incomplete' 'warn'))
        return ($badges -join ' ')
    }
    $d = $result.Data
    $hasChecks = $true
    switch ($Key) {
        'OSInfo' {
            if ($d.PendingReboot) { [void]$badges.Add((Badge 'Reboot pending' 'bad')) }
            if ($d.ActivationStatus -eq 'Unknown') { [void]$badges.Add((Badge 'Activation unknown' 'warn')) }
            elseif ($d.ActivationStatus -ne 'Licensed') { [void]$badges.Add((Badge 'Not activated' 'warn')) }
            $upd = $Report['Updates']
            if ($upd -and $upd.Success -and $upd.Data.FailedUpdates.Count -gt 0) {
                [void]$badges.Add((Badge (Format-Count $upd.Data.FailedUpdates.Count 'failed update') 'warn'))
            }
        }
        'Hardware' {
            if ($d.ProblemDevices.Count -gt 0) { [void]$badges.Add((Badge (Format-Count $d.ProblemDevices.Count 'problem device') 'bad')) }
        }
        'EventLogs' {
            $errors   = @($d | Where-Object { $_.LevelDisplayName -in @('Critical','Error') }).Count
            $warnings = @($d | Where-Object { $_.LevelDisplayName -eq 'Warning' }).Count
            if ($errors -gt 0)   { [void]$badges.Add((Badge (Format-Count $errors 'error') 'bad')) }
            if ($warnings -gt 0) { [void]$badges.Add((Badge (Format-Count $warnings 'warning') 'warn')) }
        }
        'Crash' {
            if ($d.BugChecks.Count -gt 0) { [void]$badges.Add((Badge (Format-Count $d.BugChecks.Count 'bluescreen') 'bad')) }
            if ($d.UnexpectedShutdowns.Count -gt 0) { [void]$badges.Add((Badge (Format-Count $d.UnexpectedShutdowns.Count 'unexpected shutdown') 'warn')) }
            $dumps = $d.Minidumps.Count + $d.FullDumps.Count
            if ($dumps -gt 0) { [void]$badges.Add((Badge (Format-Count $dumps 'dump file') 'bad')) }
            if ($d.Notes.Count -gt 0) { [void]$badges.Add((Badge 'Dump folder unreadable' 'warn')) }
        }
        'Network' {
            if ($d.Adapters.Count -eq 0) { [void]$badges.Add((Badge 'No active adapter' 'bad')) }
            if ($d.Wireless -and $d.Wireless.SignalPercent -match '(\d+)' -and [int]$matches[1] -lt 50) {
                [void]$badges.Add((Badge 'Weak Wi-Fi signal' 'warn'))
            }
        }
        'Connectivity' {
            if (@($d | Where-Object { $_.DNS -and -not $_.DNS.Resolved }).Count -gt 0) { [void]$badges.Add((Badge 'DNS failure' 'bad')) }
            $worstLoss = ($d | Measure-Object -Property PacketLossPercent -Maximum).Maximum
            if ($worstLoss -gt 10) { [void]$badges.Add((Badge 'Packet loss' 'bad')) }
            elseif ($worstLoss -gt 0) { [void]$badges.Add((Badge 'Packet loss' 'warn')) }
            if (@($d | Where-Object { $_.JitterMs -gt 30 }).Count -gt 0) { [void]$badges.Add((Badge 'High jitter' 'warn')) }
        }
        'Disks' {
            $lowest = ($d.Volumes | Measure-Object -Property FreePercent -Minimum).Minimum
            if ($null -ne $lowest -and $lowest -lt 10) { [void]$badges.Add((Badge 'Low disk' 'bad')) }
            elseif ($null -ne $lowest -and $lowest -lt 20) { [void]$badges.Add((Badge 'Low disk' 'warn')) }
            if (@($d.PhysicalDisks | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count -gt 0) { [void]$badges.Add((Badge 'Disk unhealthy' 'bad')) }
        }
        'Security' {
            if ($d.Defender -and -not $d.Defender.RealTimeProtectionEnabled) { [void]$badges.Add((Badge 'Real-time protection off' 'bad')) }
            $fwOff = @($d.Firewall | Where-Object { -not $_.Enabled }).Count
            if ($fwOff -gt 0) { [void]$badges.Add((Badge 'Firewall off' 'bad')) }
        }
        'InstalledSoftware' {
            [void]$badges.Add((Badge (Format-Count @($d).Count 'app') 'info'))
            $hasChecks = $false
        }
        default { $hasChecks = $false }
    }
    if ($hasChecks -and $badges.Count -eq 0) { [void]$badges.Add((Badge 'OK' 'ok')) }
    $badges -join ' '
}

function Render-SectionWrapper {
    param([string]$Id, [string]$Title, [string]$BodyHtml, $SectionResult, [string]$BadgesHtml)
    $status = ''
    if ($SectionResult -and -not $SectionResult.Success) {
        $adminHint = if (-not $script:IsAdmin) { ' This may require running as Administrator.' } else { '' }
        $status = "<p class='warn'>&#9888; This section could not be fully collected: $(HtmlEncode $SectionResult.Error)$adminHint</p>"
    }
    @"
<details id="$Id" class="card section">
<summary><h2>$Title</h2><span class="section-badges">$BadgesHtml</span></summary>
<div class="section-body">
$status
$BodyHtml
</div>
</details>
"@
}

function Render-SystemOverview($result) {
    if (-not $result.Success) { return '' }
    $d = $result.Data
    $ramTable = New-HtmlTable -Rows $d.RAMModules -Columns @('Location','CapacityGB','SpeedMHz','Manufacturer','PartNumber') -EmptyMessage 'No memory module details available.'
    $gpuTable = New-HtmlTable -Rows $d.GPUs -Columns @('Name','DriverVersion','DriverDate','VRAMGB') -EmptyMessage 'No display adapter details available.'
    @"
<div class='grid2'>
  <div><span class='label'>Manufacturer</span><span class='value'>$(HtmlEncode $d.Manufacturer)</span></div>
  <div><span class='label'>Model</span><span class='value'>$(HtmlEncode $d.Model)</span></div>
  <div><span class='label'>System Serial Number</span><span class='value'>$(Format-HardwareId $d.SerialNumber)</span></div>
  <div><span class='label'>BIOS Version</span><span class='value'>$(HtmlEncode $d.BIOSVersion) ($(Format-DT $d.BIOSDate))</span></div>
  <div><span class='label'>Motherboard Manufacturer</span><span class='value'>$(Format-HardwareId $d.BoardManufacturer)</span></div>
  <div><span class='label'>Motherboard Model</span><span class='value'>$(Format-HardwareId $d.BoardProduct)</span></div>
  <div><span class='label'>Motherboard Version</span><span class='value'>$(Format-HardwareId $d.BoardVersion)</span></div>
  <div><span class='label'>Motherboard Serial Number</span><span class='value'>$(Format-HardwareId $d.BoardSerial)</span></div>
  <div><span class='label'>Processor</span><span class='value'>$(HtmlEncode $d.CPU)</span></div>
  <div><span class='label'>Cores / Threads</span><span class='value'>$($d.Cores) / $($d.LogicalProcessors)</span></div>
  <div><span class='label'>Total RAM</span><span class='value'>$($d.TotalRAMGB) GB</span></div>
</div>
<h3>Memory Modules</h3>
$ramTable
<h3>Display Adapters</h3>
$gpuTable
<p class='footnote'>Reported VRAM can be inaccurate for adapters with more than 4GB, a known Windows/WMI limitation.</p>
"@
}

function Render-OSInfo($osResult, $updResult) {
    $html = ''
    if ($osResult.Success) {
        $d = $osResult.Data
        $rebootBadge = if ($d.PendingReboot) { Badge 'Reboot Pending' 'bad' } else { Badge 'No Reboot Pending' 'ok' }
        $actClass = if ($d.ActivationStatus -eq 'Licensed') { 'ok' } else { 'warn' }
        $actBadge = Badge $d.ActivationStatus $actClass
        $html += @"
<div class='grid2'>
  <div><span class='label'>OS</span><span class='value'>$(HtmlEncode $d.Caption) ($($d.Arch))</span></div>
  <div><span class='label'>Version / Build</span><span class='value'>$($d.Version) / $($d.Build)</span></div>
  <div><span class='label'>Installed</span><span class='value'>$(Format-DT $d.InstallDate)</span></div>
  <div><span class='label'>Last Boot</span><span class='value'>$(Format-DT $d.LastBoot)</span></div>
  <div><span class='label'>Uptime</span><span class='value'>$($d.Uptime)</span></div>
  <div><span class='label'>Activation</span><span class='value'>$actBadge</span></div>
  <div><span class='label'>Pending Reboot</span><span class='value'>$rebootBadge</span></div>
</div>
"@
    }
    if ($updResult -and $updResult.Success) {
        $u = $updResult.Data
        $html += "<h3>Recently Installed Updates</h3>"
        $html += New-HtmlTable -Rows $u.RecentHotfixes -Columns @('HotFixID','Description','InstalledOn') -EmptyMessage 'No hotfix history available via Get-HotFix.'
        $html += "<h3>Recent Failed / Incomplete Updates</h3>"
        if ($u.FailedUpdates -and $u.FailedUpdates.Count -gt 0) {
            $html += New-HtmlTable -Rows $u.FailedUpdates -Columns @('Title','Date','Result')
        } else {
            $html += "<p class='ok-text'>&#10003; No failed updates found in recent history.</p>"
        }
    }
    $html
}

function Render-Hardware($result) {
    if (-not $result.Success) { return '' }
    $d = $result.Data
    $problemHtml = if ($d.ProblemDevices -and $d.ProblemDevices.Count -gt 0) {
        New-HtmlTable -Rows $d.ProblemDevices -Columns @('FriendlyName','Class','Status','InstanceId')
    } else {
        "<p class='ok-text'>&#10003; No problem devices detected.</p>"
    }
    $driverHtml = New-HtmlTable -Rows $d.KeyDrivers -Columns @('DeviceName','DeviceClass','Manufacturer','DriverVersion','DriverDate') -EmptyMessage 'No driver details available.'
    @"
<h3>Devices With Problems</h3>
$problemHtml
<h3>Key Driver Versions (Network / Display / Media / Storage / USB / Bluetooth)</h3>
$driverHtml
"@
}

function Render-EventLogs($result) {
    if (-not $result.Success) { return '' }
    $events = $result.Data
    if (-not $events -or $events.Count -eq 0) {
        return "<p class='ok-text'>&#10003; No hardware-related error/warning events found in the last 14 days.</p>"
    }
    $rows = foreach ($e in $events) {
        $cls = switch ($e.LevelDisplayName) { 'Critical' {'bad'} 'Error' {'bad'} 'Warning' {'warn'} default {'muted'} }
        "<tr><td>$(Format-DT $e.TimeCreated)</td><td><span class='badge $cls'>$(HtmlEncode $e.LevelDisplayName)</span></td><td>$(HtmlEncode $e.ProviderName)</td><td>$($e.Id)</td><td>$(HtmlEncode $e.Message)</td></tr>"
    }
    "<table><thead><tr><th>Time</th><th>Level</th><th>Source</th><th>Event ID</th><th>Message</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
}

function Render-Crash($result) {
    if (-not $result.Success) { return '' }
    $d = $result.Data
    $html = ''
    $html += "<h3>Unexpected Shutdowns (Kernel-Power Event 41)</h3>"
    $html += New-HtmlTable -Rows $d.UnexpectedShutdowns -Columns @('TimeCreated','Detail') -EmptyMessage 'None found in recent System log history.'
    $html += "<h3>Bug Check / Stop Error Summaries</h3>"
    $html += New-HtmlTable -Rows $d.BugChecks -Columns @('TimeCreated','Detail') -EmptyMessage 'None found in recent System log history.'
    $html += "<h3>Crash Dump Settings</h3>"
    $html += @"
<div class='grid2'>
  <div><span class='label'>Dump Type</span><span class='value'>$(HtmlEncode $d.DumpType)</span></div>
  <div><span class='label'>Minidump Folder</span><span class='value'>$(HtmlEncode $d.MinidumpFolder)</span></div>
  <div><span class='label'>Full Dump File</span><span class='value'>$(HtmlEncode $d.FullDumpFile)</span></div>
</div>
"@
    foreach ($note in $d.Notes) { $html += "<p class='warn'>&#9888; $(HtmlEncode $note)</p>" }
    $html += "<h3>Minidump Files (Bluescreens)</h3>"
    $html += New-HtmlTable -Rows $d.Minidumps -Columns @('Path','Created','Modified','Size') -EmptyMessage 'No minidump files found.'
    $html += "<h3>Full Memory Dump</h3>"
    $html += New-HtmlTable -Rows $d.FullDumps -Columns @('Path','Created','Modified','Size') -EmptyMessage 'No full memory dump file found.'
    if ($d.FullDumps.Count -gt 0) { $html += "<p class='warn'>&#9888; A full memory dump is present, indicating at least one prior crash.</p>" }
    $html
}

function Render-Network($result) {
    if (-not $result.Success) { return '' }
    $d = $result.Data
    $html = New-HtmlTable -Rows $d.Adapters -Columns @('Adapter','Status','IPAddress','SubnetMask','Gateway','DNSServers','LinkSpeed','MacAddress') -EmptyMessage 'No active network adapters found.'
    $html += "<h3>Wireless Adapter</h3>"
    if ($d.Wireless) {
        $w = $d.Wireless
        $html += @"
<div class='grid2'>
  <div><span class='label'>Network Name (SSID)</span><span class='value'>$(HtmlEncode $w.SSID)</span></div>
  <div><span class='label'>State</span><span class='value'>$(HtmlEncode $w.State)</span></div>
  <div><span class='label'>Signal</span><span class='value'>$(HtmlEncode $w.SignalPercent) ($(HtmlEncode $w.RssiDbm) dBm)</span></div>
  <div><span class='label'>Band / Channel</span><span class='value'>$(HtmlEncode $w.Band) / $(HtmlEncode $w.Channel)</span></div>
  <div><span class='label'>Radio Type</span><span class='value'>$(HtmlEncode $w.RadioType)</span></div>
  <div><span class='label'>Authentication</span><span class='value'>$(HtmlEncode $w.Authentication)</span></div>
  <div><span class='label'>Receive / Transmit Rate</span><span class='value'>$(HtmlEncode $w.ReceiveMbps) / $(HtmlEncode $w.TransmitMbps) Mbps</span></div>
  <div><span class='label'>Power Saving Mode</span><span class='value'>$(HtmlEncode $w.PowerSaveMode)</span></div>
</div>
"@
    } else {
        $html += "<p class='muted'>No active wireless (Wi-Fi) interface detected.</p>"
    }
    $html
}

function Render-Connectivity($result) {
    if (-not $result.Success) { return '' }
    $rows = foreach ($r in $result.Data) {
        $lossClass = if ($r.PacketLossPercent -eq 0) { 'ok' } elseif ($r.PacketLossPercent -le 10) { 'warn' } else { 'bad' }
        $jitterClass = if ($null -eq $r.JitterMs) { 'muted' } elseif ($r.JitterMs -le 10) { 'ok' } elseif ($r.JitterMs -le 30) { 'warn' } else { 'bad' }
        $dnsText = if ($r.DNS) {
            if ($r.DNS.Resolved) { "$($r.DNS.IP) ($($r.DNS.TimeMs) ms)" } else { 'Failed to resolve' }
        } else { 'n/a (IP address)' }
        "<tr><td>$(HtmlEncode $r.Target)</td><td>$(HtmlEncode $dnsText)</td><td>$($r.Sent)</td><td>$($r.Received)</td><td><span class='badge $lossClass'>$($r.PacketLossPercent)%</span></td><td>$($r.MinMs)</td><td>$($r.AvgMs)</td><td>$($r.MaxMs)</td><td><span class='badge $jitterClass'>$($r.JitterMs)</span></td></tr>"
    }
    "<div class='table-wrap'><table><thead><tr><th>Target</th><th>DNS Resolution</th><th>Sent</th><th>Received</th><th>Packet Loss</th><th>Min ms</th><th>Avg ms</th><th>Max ms</th><th>Jitter ms</th></tr></thead><tbody>$($rows -join '')</tbody></table></div>"
}

function Render-Traceroute($result) {
    if (-not $result.Success) { return '' }
    $html = ''
    foreach ($t in $result.Data) {
        $rows = foreach ($h in $t.Hops) {
            $rtt1 = if ($null -ne $h.Rtt1) { "$($h.Rtt1) ms" } else { '*' }
            $rtt2 = if ($null -ne $h.Rtt2) { "$($h.Rtt2) ms" } else { '*' }
            $rtt3 = if ($null -ne $h.Rtt3) { "$($h.Rtt3) ms" } else { '*' }
            $addr = if ($h.Address) {
                if ($h.Hostname -and $h.Hostname -ne $h.Address) { "$(HtmlEncode $h.Hostname) [$(HtmlEncode $h.Address)]" } else { HtmlEncode $h.Address }
            } else { "<span class='muted'>Request timed out.</span>" }
            "<tr><td>$($h.Hop)</td><td>$rtt1</td><td>$rtt2</td><td>$rtt3</td><td>$addr</td></tr>"
        }
        $html += "<h3>Path to $(HtmlEncode $t.Target)</h3><div class='table-wrap'><table><thead><tr><th>Hop</th><th>RTT 1</th><th>RTT 2</th><th>RTT 3</th><th>Address</th></tr></thead><tbody>$($rows -join '')</tbody></table></div>"
    }
    $html += "<p class='footnote'>Three timed probes per hop, matching the classic tracert layout; reverse-DNS hostnames are resolved where available. A '*' just means that one probe did not get a reply (common and not necessarily a problem) - what matters is where replies stop entirely or latency jumps.</p>"
    $html
}

function Render-InstalledSoftware($result) {
    if (-not $result.Success) { return '' }
    $apps = $result.Data
    if (-not $apps -or $apps.Count -eq 0) { return "<p class='muted'>No installed software found in the registry uninstall keys.</p>" }
    $rows = foreach ($a in $apps) {
        "<tr><td>$(HtmlEncode $a.Name)</td><td>$(HtmlEncode $a.Version)</td><td>$(HtmlEncode $a.Publisher)</td><td>$(HtmlEncode $a.InstallDate)</td></tr>"
    }
    @"
<input type='text' id='softwareFilter' class='filter-box' placeholder='Filter by name or publisher... ($($apps.Count) installed)' onkeyup="filterTable('softwareFilter','softwareTable')">
<div class='table-wrap'><table id='softwareTable'><thead><tr><th>Name</th><th>Version</th><th>Publisher</th><th>Install Date</th></tr></thead><tbody>
$($rows -join '')
</tbody></table></div>
"@
}

function Render-Disks($result) {
    if (-not $result.Success) { return '' }
    $d = $result.Data
    $volRows = foreach ($v in $d.Volumes) {
        $cls = if ($v.FreePercent -lt 10) { 'bad' } elseif ($v.FreePercent -lt 20) { 'warn' } else { 'ok' }
        "<tr><td>$(HtmlEncode $v.Drive)</td><td>$($v.SizeGB)</td><td>$($v.FreeGB)</td><td><span class='badge $cls'>$($v.FreePercent)% free</span></td></tr>"
    }
    $volHtml = "<table><thead><tr><th>Drive</th><th>Size GB</th><th>Free GB</th><th>Free %</th></tr></thead><tbody>$($volRows -join '')</tbody></table>"

    $physHtml = 'No physical disk data available (may require Administrator rights or the Storage module).'
    if ($d.PhysicalDisks -and $d.PhysicalDisks.Count -gt 0) {
        $physRows = foreach ($p in $d.PhysicalDisks) {
            $cls = switch ($p.HealthStatus) { 'Healthy' {'ok'} 'Warning' {'warn'} default {'bad'} }
            "<tr><td>$($p.DeviceId)</td><td>$(HtmlEncode $p.FriendlyName)</td><td>$(HtmlEncode $p.MediaType)</td><td>$($p.SizeGB)</td><td><span class='badge $cls'>$(HtmlEncode $p.HealthStatus)</span></td><td>$(HtmlEncode $p.OperationalStatus)</td></tr>"
        }
        $physHtml = "<table><thead><tr><th>#</th><th>Name</th><th>Media</th><th>Size GB</th><th>Health</th><th>Operational Status</th></tr></thead><tbody>$($physRows -join '')</tbody></table>"
    }
    @"
<h3>Volumes</h3>
$volHtml
<h3>Physical Disks</h3>
$physHtml
"@
}

function Render-Security($result) {
    if (-not $result.Success) { return '' }
    $d = $result.Data
    $html = ''
    $html += "<h3>Windows Defender</h3>"
    if ($d.Defender) {
        $rt = if ($d.Defender.RealTimeProtectionEnabled) { Badge 'Enabled' 'ok' } else { Badge 'Disabled' 'bad' }
        $av = if ($d.Defender.AntivirusEnabled) { Badge 'Enabled' 'ok' } else { Badge 'Disabled' 'bad' }
        $html += "<div class='grid2'><div><span class='label'>Antivirus</span><span class='value'>$av</span></div><div><span class='label'>Real-Time Protection</span><span class='value'>$rt</span></div><div><span class='label'>Signatures Updated</span><span class='value'>$(Format-DT $d.Defender.AntivirusSignatureLastUpdated)</span></div></div>"
    } else {
        $html += "<p class='muted'>Not available (Defender may be replaced by a third-party product, or this check requires elevated rights).</p>"
    }
    $html += "<h3>Firewall Profiles</h3>"
    if ($d.Firewall -and $d.Firewall.Count -gt 0) {
        $rows = foreach ($f in $d.Firewall) {
            $cls = if ($f.Enabled) { 'ok' } else { 'bad' }
            $state = if ($f.Enabled) { 'On' } else { 'Off' }
            "<tr><td>$(HtmlEncode $f.Name)</td><td><span class='badge $cls'>$state</span></td></tr>"
        }
        $html += "<table><thead><tr><th>Profile</th><th>State</th></tr></thead><tbody>$($rows -join '')</tbody></table>"
    } else {
        $html += "<p class='muted'>Firewall profile status not available.</p>"
    }
    $html += "<h3>BitLocker</h3>"
    if ($d.BitLocker -and $d.BitLocker.Count -gt 0) {
        $html += New-HtmlTable -Rows $d.BitLocker -Columns @('MountPoint','VolumeStatus','ProtectionStatus')
    } else {
        $html += "<p class='muted'>Not available (BitLocker may not be present on this edition, or requires Administrator rights).</p>"
    }
    $html
}

function Render-StartupProcesses($result) {
    if (-not $result.Success) { return '' }
    $d = $result.Data
    @"
<h3>Startup Programs</h3>
$(New-HtmlTable -Rows $d.Startup -Columns @('Name','Command','Location','User') -EmptyMessage 'No startup entries found via WMI.')
<h3>Top 5 Processes by CPU Time</h3>
$(New-HtmlTable -Rows $d.TopCPU -Columns @('Name','Id','CPUs','MemMB'))
<h3>Top 5 Processes by Memory</h3>
$(New-HtmlTable -Rows $d.TopMemory -Columns @('Name','Id','MemMB','CPUs'))
<p class='footnote'>Process snapshot reflects a single point in time, not sustained usage.</p>
"@
}

function Build-HtmlReport {
    param([System.Collections.Specialized.OrderedDictionary]$Report)

    $meta = $Report['Meta']
    $toc  = New-Object System.Text.StringBuilder
    $body = New-Object System.Text.StringBuilder

    $sections = @(
        @{ Key='SystemOverview';   Title='System Overview';                              Render={ Render-SystemOverview $Report['SystemOverview'] } }
        @{ Key='OSInfo';           Title='Operating System, Updates &amp; Pending Reboot';Render={ Render-OSInfo $Report['OSInfo'] $Report['Updates'] } }
        @{ Key='Hardware';         Title='Hardware &amp; Driver Versions';                Render={ Render-Hardware $Report['Hardware'] } }
        @{ Key='EventLogs';        Title='Hardware-Related Event Log Errors';             Render={ Render-EventLogs $Report['EventLogs'] } }
        @{ Key='Crash';            Title='Crash &amp; Unexpected Shutdown History';       Render={ Render-Crash $Report['Crash'] } }
        @{ Key='Network';          Title='Network Configuration';                         Render={ Render-Network $Report['Network'] } }
        @{ Key='Connectivity';     Title='Connectivity Test (Ping + DNS)';                Render={ Render-Connectivity $Report['Connectivity'] } }
        @{ Key='Traceroute';       Title='Network Path (Traceroute)';                     Render={ Render-Traceroute $Report['Traceroute'] } }
        @{ Key='Disks';            Title='Disk Health &amp; Free Space';                  Render={ Render-Disks $Report['Disks'] } }
        @{ Key='Security';         Title='Security Status';                               Render={ Render-Security $Report['Security'] } }
        @{ Key='StartupProcesses'; Title='Startup Programs &amp; Top Processes';          Render={ Render-StartupProcesses $Report['StartupProcesses'] } }
        @{ Key='InstalledSoftware';Title='Installed Software';                            Render={ Render-InstalledSoftware $Report['InstalledSoftware'] } }
    )

    foreach ($s in $sections) {
        if ($Report.Contains($s.Key)) {
            [void]$toc.Append("<li><a href='#$($s.Key)'>$($s.Title)</a></li>")
            $sectionResult = $Report[$s.Key]
            $inner = & $s.Render
            $badges = Get-SectionBadges -Key $s.Key -Report $Report
            [void]$body.Append((Render-SectionWrapper -Id $s.Key -Title $s.Title -BodyHtml $inner -SectionResult $sectionResult -BadgesHtml $badges))
        }
    }

    $adminBanner = ''
    if (-not $meta.IsAdmin) {
        $adminBanner = "<p class='warn'>&#9888; This report was generated without Administrator rights. Some details (physical disk health, BitLocker, crash dump files) may be limited or missing.</p>"
    }

    $css = Get-ReportCss

    @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Quick System Info - $(HtmlEncode $meta.ComputerName)</title>
<style>
$css
</style>
</head>
<body>
<div class="container">
<header class="report-header">
  <h1>Quick System Info</h1>
  <p>Computer: <strong>$(HtmlEncode $meta.ComputerName)</strong> &nbsp;|&nbsp; Generated: $(Format-DT $meta.GeneratedOn) by $(HtmlEncode $meta.GeneratedBy) &nbsp;|&nbsp; Elevated: $(if ($meta.IsAdmin) {'Yes'} else {'No'})</p>
</header>
$adminBanner
<nav class="toc">
<div class="toc-actions"><button type="button" onclick="setAllSections(true)">Expand all</button><button type="button" onclick="setAllSections(false)">Collapse all</button></div>
<ul>
$($toc.ToString())
</ul></nav>
$($body.ToString())
<footer>Generated by Quick System Info v$($script:ToolVersion) &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</footer>
</div>
<script>
function filterTable(inputId, tableId) {
  var filter = document.getElementById(inputId).value.toLowerCase();
  var rows = document.getElementById(tableId).getElementsByTagName('tbody')[0].getElementsByTagName('tr');
  for (var i = 0; i < rows.length; i++) {
    var text = rows[i].textContent.toLowerCase();
    rows[i].style.display = text.indexOf(filter) > -1 ? '' : 'none';
  }
}
function allSections() { return document.querySelectorAll('details.section'); }
function setAllSections(open) {
  var s = allSections();
  for (var i = 0; i < s.length; i++) { s[i].open = open; }
}
// Contents links (and opening the report with #SectionName) open the section they point to
function openSection(id) {
  var el = id ? document.getElementById(id) : null;
  if (el && el.tagName === 'DETAILS') { el.open = true; }
  return el;
}
document.addEventListener('click', function (e) {
  var a = e.target.closest ? e.target.closest('a[href^="#"]') : null;
  if (a) { openSection(a.getAttribute('href').slice(1)); }
});
window.addEventListener('hashchange', function () { openSection(decodeURIComponent(location.hash.slice(1))); });
var initial = openSection(decodeURIComponent(location.hash.slice(1)));
if (initial) { initial.scrollIntoView(); }
// Print everything, then put the sections back the way they were
var printState = null;
window.addEventListener('beforeprint', function () {
  var s = allSections();
  printState = [];
  for (var i = 0; i < s.length; i++) { printState.push(s[i].open); s[i].open = true; }
});
window.addEventListener('afterprint', function () {
  if (!printState) { return; }
  var s = allSections();
  for (var i = 0; i < s.length; i++) { s[i].open = printState[i]; }
  printState = null;
});
</script>
</body>
</html>
"@
}

# ===========================================================================
# region: GUI
# ===========================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = "Quick System Info v$($script:ToolVersion)"
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.MinimumSize = New-Object System.Drawing.Size(600, 560)

# Size and center the window against the working area of the monitor under the cursor,
# so it can't get created larger than the screen or straddling multiple monitors.
$targetScreen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
$workArea = $targetScreen.WorkingArea
$margin = 60
$clientWidth = [Math]::Min(640, $workArea.Width - $margin)
$clientHeight = [Math]::Min(800, $workArea.Height - $margin)
$form.ClientSize = New-Object System.Drawing.Size($clientWidth, $clientHeight)
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(
    ($workArea.X + [Math]::Max(0, [int](($workArea.Width - $form.Width) / 2))),
    ($workArea.Y + [Math]::Max(0, [int](($workArea.Height - $form.Height) / 2)))
)

$y = 10

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Quick System Info'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(16, $y)
$lblTitle.Size = New-Object System.Drawing.Size(600, 30)
$lblTitle.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblTitle)
$y += 26

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = 'Gathers a quick diagnostic snapshot of this machine and produces a shareable HTML report.'
$lblSubtitle.ForeColor = [System.Drawing.Color]::DimGray
$lblSubtitle.Location = New-Object System.Drawing.Point(16, $y)
$lblSubtitle.Size = New-Object System.Drawing.Size(608, 20)
$lblSubtitle.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblSubtitle)
$y += 30

$pnlAdmin = New-Object System.Windows.Forms.Panel
$pnlAdmin.Location = New-Object System.Drawing.Point(16, $y)
$pnlAdmin.Size = New-Object System.Drawing.Size(608, 54)
$pnlAdmin.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 214)
$pnlAdmin.Visible = -not $script:IsAdmin
$pnlAdmin.Anchor = 'Top,Left,Right'
$form.Controls.Add($pnlAdmin)

$lblAdminWarn = New-Object System.Windows.Forms.Label
$lblAdminWarn.Text = "Not running as Administrator. Some checks (disk health, BitLocker, crash dumps) will be limited."
$lblAdminWarn.Location = New-Object System.Drawing.Point(10, 8)
$lblAdminWarn.Size = New-Object System.Drawing.Size(340, 38)
$lblAdminWarn.Anchor = 'Top,Left'
$pnlAdmin.Controls.Add($lblAdminWarn)

$btnElevate = New-Object System.Windows.Forms.Button
$btnElevate.Text = 'Restart as Admin'
$btnElevate.Location = New-Object System.Drawing.Point(360, 13)
$btnElevate.Size = New-Object System.Drawing.Size(120, 28)
$btnElevate.Anchor = 'Top,Right'
$pnlAdmin.Controls.Add($btnElevate)

$btnDismiss = New-Object System.Windows.Forms.Button
$btnDismiss.Text = 'Dismiss'
$btnDismiss.Location = New-Object System.Drawing.Point(488, 13)
$btnDismiss.Size = New-Object System.Drawing.Size(100, 28)
$btnDismiss.Anchor = 'Top,Right'
$pnlAdmin.Controls.Add($btnDismiss)

$y += 64

$grpSections = New-Object System.Windows.Forms.GroupBox
$grpSections.Text = 'Sections to Include'
$grpSections.Location = New-Object System.Drawing.Point(16, $y)
$grpSections.Size = New-Object System.Drawing.Size(608, 250)
$grpSections.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpSections)

$btnSelectAll = New-Object System.Windows.Forms.Button
$btnSelectAll.Text = 'Select All'
$btnSelectAll.Location = New-Object System.Drawing.Point(420, 18)
$btnSelectAll.Size = New-Object System.Drawing.Size(80, 24)
$btnSelectAll.Anchor = 'Top,Right'
$grpSections.Controls.Add($btnSelectAll)

$btnSelectNone = New-Object System.Windows.Forms.Button
$btnSelectNone.Text = 'Select None'
$btnSelectNone.Location = New-Object System.Drawing.Point(506, 18)
$btnSelectNone.Size = New-Object System.Drawing.Size(90, 24)
$btnSelectNone.Anchor = 'Top,Right'
$grpSections.Controls.Add($btnSelectNone)

$clbSections = New-Object System.Windows.Forms.CheckedListBox
$clbSections.Location = New-Object System.Drawing.Point(12, 46)
$clbSections.Size = New-Object System.Drawing.Size(584, 195)
$clbSections.Anchor = 'Top,Left,Right'
$clbSections.CheckOnClick = $true
$sectionLabels = @(
    'System Overview (Make / Model / Specs)',
    'Operating System, Updates & Pending Reboot',
    'Hardware & Driver Versions',
    'Hardware-Related Event Log Errors',
    'Crash / Unexpected Shutdown History',
    'Network Configuration (incl. Wi-Fi details)',
    'Connectivity Test (Ping + Jitter + DNS + Traceroute)',
    'Disk Health & Free Space',
    'Security Status (Defender / Firewall / BitLocker)',
    'Startup Programs & Top Processes',
    'Installed Software'
)
foreach ($label in $sectionLabels) { [void]$clbSections.Items.Add($label, $true) }
$grpSections.Controls.Add($clbSections)

$y += 260

$lblPing = New-Object System.Windows.Forms.Label
$lblPing.Text = 'Additional ping targets (comma-separated, optional - e.g. a WAN IP):'
$lblPing.Location = New-Object System.Drawing.Point(16, $y)
$lblPing.Size = New-Object System.Drawing.Size(608, 18)
$lblPing.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblPing)
$y += 20

$txtPing = New-Object System.Windows.Forms.TextBox
$txtPing.Location = New-Object System.Drawing.Point(16, $y)
$txtPing.Size = New-Object System.Drawing.Size(608, 24)
$txtPing.Anchor = 'Top,Left,Right'
$form.Controls.Add($txtPing)
$y += 34

$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text = 'Save report to:'
$lblOutput.Location = New-Object System.Drawing.Point(16, $y)
$lblOutput.Size = New-Object System.Drawing.Size(608, 18)
$lblOutput.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblOutput)
$y += 20

$txtOutputPath = New-Object System.Windows.Forms.TextBox
$txtOutputPath.Location = New-Object System.Drawing.Point(16, $y)
$txtOutputPath.Size = New-Object System.Drawing.Size(508, 24)
$txtOutputPath.Anchor = 'Top,Left,Right'
$defaultName = "QuickSystemInfo_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
$txtOutputPath.Text = Join-Path ([Environment]::GetFolderPath('Desktop')) $defaultName
$form.Controls.Add($txtOutputPath)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(532, $y)
$btnBrowse.Size = New-Object System.Drawing.Size(92, 24)
$btnBrowse.Anchor = 'Top,Right'
$form.Controls.Add($btnBrowse)
$y += 34

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Run Snapshot'
$btnRun.Location = New-Object System.Drawing.Point(16, $y)
$btnRun.Size = New-Object System.Drawing.Size(608, 36)
$btnRun.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnRun.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.Anchor = 'Top,Left,Right'
$form.Controls.Add($btnRun)
$y += 46

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(16, $y)
$progressBar.Size = New-Object System.Drawing.Size(608, 18)
$progressBar.Anchor = 'Top,Left,Right'
$form.Controls.Add($progressBar)
$script:ProgressBar = $progressBar
$y += 26

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Status: Idle'
$lblStatus.Location = New-Object System.Drawing.Point(16, $y)
$lblStatus.Size = New-Object System.Drawing.Size(608, 18)
$lblStatus.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblStatus)
$script:StatusLabel = $lblStatus
$y += 22

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(16, $y)
$logBox.Size = New-Object System.Drawing.Size(608, 150)
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($logBox)
$script:LogBox = $logBox
$y += 158

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Open Report'
$btnOpen.Location = New-Object System.Drawing.Point(16, $y)
$btnOpen.Size = New-Object System.Drawing.Size(296, 30)
$btnOpen.Enabled = $false
$btnOpen.Anchor = 'Bottom,Left'
$form.Controls.Add($btnOpen)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = 'Open Containing Folder'
$btnOpenFolder.Location = New-Object System.Drawing.Point(328, $y)
$btnOpenFolder.Size = New-Object System.Drawing.Size(296, 30)
$btnOpenFolder.Enabled = $false
$btnOpenFolder.Anchor = 'Bottom,Right'
$form.Controls.Add($btnOpenFolder)

# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------

$btnElevate.Add_Click({
    if (-not $PSCommandPath) {
        [System.Windows.Forms.MessageBox]::Show('Save this script as a .ps1 file first, then re-run it to use auto-restart. Otherwise, open PowerShell as Administrator manually and run the script.', 'Cannot Restart', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',"`"$PSCommandPath`"") -Verb RunAs
        $form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not restart elevated: $($_.Exception.Message)", 'Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnDismiss.Add_Click({ $pnlAdmin.Visible = $false })

$btnSelectAll.Add_Click({ for ($i = 0; $i -lt $clbSections.Items.Count; $i++) { $clbSections.SetItemChecked($i, $true) } })
$btnSelectNone.Add_Click({ for ($i = 0; $i -lt $clbSections.Items.Count; $i++) { $clbSections.SetItemChecked($i, $false) } })

$btnBrowse.Add_Click({
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'HTML Report (*.html)|*.html'
    $sfd.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    $sfd.FileName = [System.IO.Path]::GetFileName($txtOutputPath.Text)
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtOutputPath.Text = $sfd.FileName
    }
})

$btnOpen.Add_Click({ if ($script:LastReportPath) { Start-Process $script:LastReportPath } })
$btnOpenFolder.Add_Click({ if ($script:LastReportPath) { Start-Process 'explorer.exe' "/select,`"$($script:LastReportPath)`"" } })

$btnRun.Add_Click({
    $checked = @($clbSections.CheckedItems | ForEach-Object { $_.ToString() })
    if ($checked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Select at least one section to include.', 'Nothing Selected', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($txtOutputPath.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Choose a valid output file path.', 'Missing Path', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $btnRun.Enabled = $false
    $btnBrowse.Enabled = $false
    $btnSelectAll.Enabled = $false
    $btnSelectNone.Enabled = $false
    $clbSections.Enabled = $false
    $txtPing.Enabled = $false
    $btnOpen.Enabled = $false
    $btnOpenFolder.Enabled = $false
    $logBox.Clear()
    $progressBar.Value = 0
    $progressBar.Maximum = $checked.Count + 1
    $progressBar.Style = 'Blocks'

    try {
        $report = [ordered]@{}
        $report['Meta'] = [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            GeneratedBy  = $env:USERNAME
            GeneratedOn  = Get-Date
            IsAdmin      = $script:IsAdmin
        }

        if ($checked -contains 'System Overview (Make / Model / Specs)') {
            $report['SystemOverview'] = Invoke-Section 'System Overview' { Get-SystemOverview }
        }
        if ($checked -contains 'Operating System, Updates & Pending Reboot') {
            $report['OSInfo']  = Invoke-Section 'Operating System Info' { Get-OSInfo }
            $report['Updates'] = Invoke-Section 'Windows Update History' { Get-WindowsUpdatesInfo }
        }
        if ($checked -contains 'Hardware & Driver Versions') {
            $report['Hardware'] = Invoke-Section 'Hardware & Drivers' { Get-HardwareDriverInfo }
        }
        if ($checked -contains 'Hardware-Related Event Log Errors') {
            $report['EventLogs'] = Invoke-Section 'Event Log Errors' { Get-HardwareEventLogErrors }
        }
        if ($checked -contains 'Crash / Unexpected Shutdown History') {
            $report['Crash'] = Invoke-Section 'Crash History' { Get-CrashHistory }
        }
        if ($checked -contains 'Network Configuration (incl. Wi-Fi details)') {
            $report['Network'] = Invoke-Section 'Network Configuration' { Get-NetworkInfo }
        }
        if ($checked -contains 'Connectivity Test (Ping + Jitter + DNS + Traceroute)') {
            $defaultTargets = @('google.com', '8.8.8.8', '1.1.1.1')
            $extraTargets = @($txtPing.Text -split '[,;\r\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $allTargets = @($defaultTargets + $extraTargets)
            $report['Connectivity'] = Invoke-Section 'Connectivity Test' {
                Invoke-ConnectivityTest -Targets $allTargets -CountPerTarget 8 -OnProgress { param($m) Write-Log $m }
            }
            $traceTargets = @(@($defaultTargets[0]) + $extraTargets | Select-Object -Unique)
            $report['Traceroute'] = Invoke-Section 'Network Path (Traceroute)' {
                foreach ($t in $traceTargets) {
                    Write-Log "  Tracing route to $t ..."
                    [PSCustomObject]@{ Target = $t; Hops = Invoke-TraceRoute -Target $t -MaxHops 20 -TimeoutMs 600 -ProbesPerHop 3 -DnsTimeoutMs 700 }
                }
            }
        }
        if ($checked -contains 'Disk Health & Free Space') {
            $report['Disks'] = Invoke-Section 'Disk Health' { Get-DiskHealthInfo }
        }
        if ($checked -contains 'Security Status (Defender / Firewall / BitLocker)') {
            $report['Security'] = Invoke-Section 'Security Status' { Get-SecurityStatusInfo }
        }
        if ($checked -contains 'Startup Programs & Top Processes') {
            $report['StartupProcesses'] = Invoke-Section 'Startup & Processes' { Get-StartupAndProcessInfo }
        }
        if ($checked -contains 'Installed Software') {
            $report['InstalledSoftware'] = Invoke-Section 'Installed Software' { Get-InstalledSoftwareInfo }
        }

        Write-Log 'Building HTML report...'
        $html = Build-HtmlReport -Report $report
        $outPath = $txtOutputPath.Text
        $html | Out-File -FilePath $outPath -Encoding UTF8 -Force
        Update-Progress

        $script:LastReportPath = $outPath
        Write-Log "Report saved to: $outPath"
        $btnOpen.Enabled = $true
        $btnOpenFolder.Enabled = $true
        Start-Process $outPath
    } catch {
        [System.Windows.Forms.MessageBox]::Show("An error occurred: $($_.Exception.Message)", 'Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $btnRun.Enabled = $true
        $btnBrowse.Enabled = $true
        $btnSelectAll.Enabled = $true
        $btnSelectNone.Enabled = $true
        $clbSections.Enabled = $true
        $txtPing.Enabled = $true
    }
})

[void]$form.ShowDialog()

function Get-InstalledSoftwareLocal {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $apps = @()
    foreach ($k in $keys) {
        if (!(Test-Path $k)) { continue }; dir $k -EA 0 | % { $p = gp $_.PsPath -EA 0; if ($p.DisplayName) { $apps += [PSCustomObject]@{Name = $p.DisplayName; Version = $p.DisplayVersion } } }
    }
    return $apps | Sort-Object Name -Unique
}
function Get-Disks {
    $disks = @()
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | % {
        $sizeGB = if ($_.Size) { [math]::Round($_.Size / 1GB, 2) } else { $null }
        $freeGB = if ($_.FreeSpace) { [math]::Round($_.FreeSpace / 1GB, 2) } else { $null }
        $disks += [PSCustomObject]@{
            Device      = $_.DeviceID
            SizeGB      = $sizeGB
            FreeGB      = $freeGB
            FreePercent = if ($sizeGB -and $freeGB) { [math]::Round(($freeGB / $sizeGB) * 100, 1) } else { $null }
        }
    }
    return $disks
}

function Get-LastLoggedOnUser {
    $val = gp 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -Name LastLoggedOnUser -EA 0
    if ($val -and $val.LastLoggedOnUser) { return $val.LastLoggedOnUser }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -EA 0
    if ($cs -and $cs.UserName) { return $cs.UserName }
    return $null
}

function Get-IPAddresses {
    $addrs = @()
    $nics = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" -EA 0
    if ($nics) {
        foreach ($nic in $nics) {
            foreach ($ip in ($nic.IPAddress)) {
                if ($ip -and ($ip -match '^\d{1,3}(?:\.\d{1,3}){3}$')) { $addrs += $ip }
            }
        }
    }
    return $addrs | Select-Object -Unique
}

function Test-PendingReboot {
    # Checks several known registry locations for pending reboot indicators
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' # PendingFileRenameOperations
    )
    foreach ($k in $keys) {
        if (Test-Path $k) {
            if ($k -like '*Session Manager') {
                $val = gp $k -Name PendingFileRenameOperations -EA 0
                if ($val -and $val.PendingFileRenameOperations) { return $true }
            }
            else { return $true }
        }
    }
    return $false
}

# Safe converter that returns an ISO 8601 string or $null
function Convert-ToIsoDateString([string]$v) {
    if (!$v) { return $null }
    try { return ([datetime]::Parse($v)).ToString('o') } catch { return $null }
}

function Get-AVInfo {
    $info = [PSCustomObject]@{Product = $null; UpToDate = $null; DefinitionVersion = $null; LastScanTime = $null; LastDefinitionUpdate = $null }
    # Try Security Center provider first to get product name and any available metadata
    $av = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -EA 0 | select -First 1
    if ($av) {
        $info.Product = $av.displayName
        foreach ($p in $av.PSObject.Properties) {
            $n = $p.Name.ToLower()
            $v = $p.Value
            if (!$info.DefinitionVersion -and $v -and ($n -match 'signature|version|productversion')) {
                if ($v -is [string] -or $v -is [int] -or $v -is [long]) { $info.DefinitionVersion = $v }
            }
            if ($v -and $n -match 'timestamp') {
                $iso = Convert-ToIsoDateString $v
                if ($iso) { if (!$info.LastScanTime) { $info.LastScanTime = $iso } if (!$info.LastDefinitionUpdate) { $info.LastDefinitionUpdate = $iso } }
                continue
            }
            if (!$info.LastScanTime -and $v -and ($n -match 'lastscan|lastfull')) { $iso = Convert-ToIsoDateString $v; if ($iso) { $info.LastScanTime = $iso } }
            if (!$info.LastDefinitionUpdate -and $v -and ($n -match 'signaturelastupdated|signatureupdated|lastupdated')) { $iso = Convert-ToIsoDateString $v; if ($iso) { $info.LastDefinitionUpdate = $iso } }
        }
    }

    # Prefer Get-MpComputerStatus for Defender-specific signature/version/timestamp fields
    $mp = Get-MpComputerStatus -EA 0
    if ($mp) {
        if (!$info.Product) { $info.Product = 'Windows Defender' }
        $sigUpdated = $mp.AntivirusSignatureLastUpdated; if (!$sigUpdated) { $sigUpdated = $mp.AntispywareSignatureLastUpdated }; if (!$sigUpdated) { $sigUpdated = $mp.NISSignatureLastUpdated }; if (!$sigUpdated) { $sigUpdated = $mp.SignatureLastUpdated }
        if ($sigUpdated) { $iso = Convert-ToIsoDateString $sigUpdated; if ($iso) { $info.LastDefinitionUpdate = $iso; $d = [datetime]::Parse($iso); $info.UpToDate = ((Get-Date) - $d).TotalDays -lt 8 } }
        $sigVer = $mp.AntivirusSignatureVersion; if (!$sigVer) { $sigVer = $mp.AntispywareSignatureVersion }; if (!$sigVer) { $sigVer = $mp.NISSignatureVersion }; if (!$sigVer) { $sigVer = $mp.AMSignatureVersion }; if (!$sigVer) { $sigVer = $mp.SignatureVersion }
        if ($sigVer) { $info.DefinitionVersion = [string]$sigVer }
        $fs = $mp.LastFullScanTime; if (!$fs) { $fs = $mp.FullScanEndTime }; if (!$fs) { $fs = $mp.FullScanStartTime }
        $qs = $mp.LastQuickScanTime; if (!$qs) { $qs = $mp.QuickScanEndTime }; if (!$qs) { $qs = $mp.QuickScanStartTime }
        $iso = $null
        if ($fs) { $iso = Convert-ToIsoDateString $fs }
        if (!$iso -and $qs) { $iso = Convert-ToIsoDateString $qs }
        if ($iso) { $info.LastScanTime = $iso }
        elseif ($fs) { $info.LastScanTime = $fs }
        elseif ($qs) { $info.LastScanTime = $qs }
    }

    return $info
}

try {
    $bios = Get-CimInstance -ClassName Win32_BIOS -EA 2
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -EA 2
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -EA 2
    $procs = Get-CimInstance -ClassName Win32_Processor -EA 2
    $av = Get-AVInfo

    $info = [PSCustomObject]@{
        ComputerName      = $env:COMPUTERNAME
        Timestamp         = (Get-Date).ToString('o')
        SerialNumber      = $bios.SerialNumber
        CPU               = [PSCustomObject]@{
            PhysicalCount          = ($procs | Measure-Object).Count
            TotalCores             = ($procs | Measure-Object -Property NumberOfCores -Sum).Sum
            TotalLogicalProcessors = ($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            Model                  = ($procs | select -First 1 -ExpandProperty Name)
        }
        MemoryGB          = $(if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 2) } else { $null })
        Disks             = Get-Disks
        IPAddresses       = Get-IPAddresses
        HWModel           = $cs.Model
        OSCaption         = $os.Caption
        OSVersion         = $os.Version
        BuildNumber       = $os.BuildNumber
        UBR               = (gp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA 0).UBR
        LastBootUpTime    = ($os.LastBootUpTime).ToString('o')
        PendingReboot     = Test-PendingReboot
        AV                = $(if ($av) { [PSCustomObject]@{ Product = $av.Product; UpToDate = $av.UpToDate; DefinitionVersion = $av.DefinitionVersion; LastScanTime = $av.LastScanTime; LastDefinitionUpdate = $av.LastDefinitionUpdate } } else { [PSCustomObject]@{ Product = $null; UpToDate = $null; DefinitionVersion = $null; LastScanTime = $null; LastDefinitionUpdate = $null } })
        LastScanTime      = $(if ($av -and $av.LastScanTime) { $av.LastScanTime } else { $null })
        InstalledSoftware = Get-InstalledSoftwareLocal
        LastLoggedOnUser  = Get-LastLoggedOnUser
    }

    $outFile = Join-Path $PSScriptRoot "$($env:COMPUTERNAME).json"
    $info | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $outFile -Encoding UTF8 -Force
}
catch {
    Write-EventLog -LogName Application -Source 'InventoryScript' -EntryType Error -EventId 1000 -Message ("Inventory failed: $($_.Exception.Message)") -EA 0
    Write-Warning ("Inventory failed: $($_.Exception.Message)")
}

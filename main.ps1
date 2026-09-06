#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Karibu Wi-Fi Password Audit Benchmark.

.DESCRIPTION
    Generates random password candidates and benchmarks a local
    password-verification pipeline.

    The generated candidate is compared against a locally configured
    test password.

    IMPORTANT:
    This script intentionally performs NO Wi-Fi authentication.

    It does not use:
      - netsh wlan connect
      - nmcli device wifi connect
      - any wireless authentication API
      - any mechanism that submits generated passwords to a network

    The purpose is to study:
      - password search spaces
      - random candidate generation
      - duplicate detection
      - local verification performance
      - candidates-per-second
      - elapsed time
      - logging
      - reporting

.NOTES
    Version      : 2.2.0
    Runtime      : PowerShell 7+
    Platforms    : Windows / Linux / macOS
    Dependencies : PowerShell 7+ / .NET runtime
    Author       : Karibu Security Research

    SAFETY:
    Network authentication is intentionally disabled.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# 0. GLOBAL CONFIGURATION
# ============================================================

$CONFIG = @{
    # Number of characters generated for every candidate.
    PasswordLength = 18

    # Characters available to the candidate generator.
    CharacterSet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

    # Maximum number of UNIQUE candidates to test.
    MaxCandidates = 100000

    # Print benchmark statistics after this many candidates.
    StatisticsInterval = 1000

    # Local verification value.
    #
    # This value is ONLY compared locally.
    # It is NEVER sent to a Wi-Fi network.
    #
    # It intentionally has the same length as PasswordLength so that
    # the benchmark can actually compare generated candidates to it.
    TestPassword = 'TEST123456789ABCDE'

    # Directory where logs and reports are stored.
    LogDirectory = if (
        -not [string]::IsNullOrWhiteSpace($PSScriptRoot)
    ) {
        $PSScriptRoot
    }
    else {
        (Get-Location).Path
    }
}

# ============================================================
# 1. ENVIRONMENT INITIALIZATION
# ============================================================

function Initialize-AuditEnvironment {
    <#
    .SYNOPSIS
        Initializes the local benchmark environment.

    .DESCRIPTION
        Creates the configured output directory when necessary and
        generates unique filenames for the current execution.

    .OUTPUTS
        PSCustomObject containing log and result file paths.
    #>

    if (
        -not (
            Test-Path -LiteralPath $CONFIG.LogDirectory -PathType Container
        )
    ) {
        New-Item `
            -ItemType Directory `
            -Path $CONFIG.LogDirectory `
            -Force |
            Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'

    return [PSCustomObject]@{
        LogFile = Join-Path `
            -Path $CONFIG.LogDirectory `
            -ChildPath "wifi_audit_$timestamp.log"

        ResultFile = Join-Path `
            -Path $CONFIG.LogDirectory `
            -ChildPath "wifi_audit_$timestamp.result.txt"
    }
}

# ============================================================
# 2. LOGGING
# ============================================================

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to the benchmark log.

    .PARAMETER Message
        Message to write.

    .PARAMETER Level
        Log severity.

    .PARAMETER LogFile
        Destination log file.
    #>

    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet(
            'INFO',
            'DEBUG',
            'WARNING',
            'ERROR',
            'SUCCESS'
        )]
        [string]$Level = 'INFO',

        [Parameter(Mandatory)]
        [string]$LogFile
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'

    $entry = "[$timestamp] [$Level] $Message"

    Add-Content `
        -LiteralPath $LogFile `
        -Value $entry `
        -Encoding UTF8
}

# ============================================================
# 3. CONFIGURATION VALIDATION
# ============================================================

function Test-Configuration {
    <#
    .SYNOPSIS
        Validates the global benchmark configuration.

    .OUTPUTS
        Boolean.

    .NOTES
        Throws an exception when the configuration is invalid.
    #>

    if ($CONFIG.PasswordLength -lt 1) {
        throw 'PasswordLength must be greater than zero.'
    }

    if ($CONFIG.PasswordLength -gt 10000) {
        throw 'PasswordLength cannot exceed 10000.'
    }

    if ($CONFIG.MaxCandidates -lt 1) {
        throw 'MaxCandidates must be greater than zero.'
    }

    if ($CONFIG.StatisticsInterval -lt 1) {
        throw 'StatisticsInterval must be greater than zero.'
    }

    if ([string]::IsNullOrWhiteSpace($CONFIG.CharacterSet)) {
        throw 'CharacterSet cannot be empty.'
    }

    if ($CONFIG.CharacterSet.Length -gt 65535) {
        throw 'CharacterSet is too large.'
    }

    if ([string]::IsNullOrEmpty($CONFIG.TestPassword)) {
        throw 'TestPassword cannot be empty.'
    }

    # The generator always creates candidates with PasswordLength.
    # Therefore the local target must have exactly the same length.
    if ($CONFIG.TestPassword.Length -ne $CONFIG.PasswordLength) {
        throw (
            "TestPassword length ($($CONFIG.TestPassword.Length)) " +
            "must equal PasswordLength ($($CONFIG.PasswordLength))."
        )
    }

    # Validate every character in TestPassword.
    foreach ($character in $CONFIG.TestPassword.ToCharArray()) {
        if (
            -not $CONFIG.CharacterSet.Contains([string]$character)
        ) {
            throw (
                "TestPassword contains '$character', " +
                'which is not present in CharacterSet.'
            )
        }
    }

    # Detect duplicate characters in CharacterSet.
    # Duplicate symbols would make the configured character distribution
    # different from the apparent character count.
    $uniqueCharacters = (
        $CONFIG.CharacterSet.ToCharArray() |
        Select-Object -Unique
    )

    if ($uniqueCharacters.Count -ne $CONFIG.CharacterSet.Length) {
        throw 'CharacterSet contains duplicate characters.'
    }

    # Validate LogDirectory.
    if ([string]::IsNullOrWhiteSpace($CONFIG.LogDirectory)) {
        throw 'LogDirectory cannot be empty.'
    }

    return $true
}

# ============================================================
# 4. SEARCH-SPACE ANALYSIS
# ============================================================

function Get-SearchSpaceInfo {
    <#
    .SYNOPSIS
        Calculates search-space information.

    .DESCRIPTION
        For N possible characters and a password length L:

            Search Space = N^L

        Extremely large values are represented using logarithmic
        notation instead of attempting to store them in a normal
        integer type.

    .OUTPUTS
        PSCustomObject.
    #>

    $characterCount = $CONFIG.CharacterSet.Length
    $length = $CONFIG.PasswordLength

    $log10Space =
        $length * [Math]::Log10($characterCount)

    $digitCount =
        [int][Math]::Floor($log10Space) + 1

    return [PSCustomObject]@{
        CharacterCount = $characterCount
        PasswordLength = $length
        Log10Space     = $log10Space
        DigitCount     = $digitCount
    }
}

# ============================================================
# 5. CRYPTOGRAPHIC RANDOM INTEGER
# ============================================================

function Get-CryptoRandomIndex {
    <#
    .SYNOPSIS
        Generates a cryptographically secure random index.

    .DESCRIPTION
        Returns an integer in the range:

            0 .. Maximum - 1

        Uses the instance-based RandomNumberGenerator API for
        broad PowerShell/.NET compatibility.

        Rejection sampling is used instead of direct modulo
        reduction so that the resulting index distribution does
        not contain modulo bias.

    .PARAMETER Maximum
        Exclusive upper bound.

    .PARAMETER Rng
        Existing RandomNumberGenerator instance.

    .OUTPUTS
        System.Int32.
    #>

    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Maximum,

        [Parameter(Mandatory)]
        [System.Security.Cryptography.RandomNumberGenerator]$Rng
    )

    # A UInt32 provides exactly 2^32 possible values.
    $rangeSize = [uint64]4294967296

    $remainder = $rangeSize % [uint64]$Maximum

    $limit = $rangeSize - $remainder

    $bytes = New-Object byte[] 4

    do {
        $Rng.GetBytes($bytes)

        $randomValue = [uint64](
            [BitConverter]::ToUInt32($bytes, 0)
        )

    } while ($randomValue -ge $limit)

    return [int](
        $randomValue % [uint64]$Maximum
    )
}

# ============================================================
# 6. RANDOM PASSWORD GENERATOR
# ============================================================

function Generate-RandomPassword {
    <#
    .SYNOPSIS
        Generates a random password candidate.

    .PARAMETER Length
        Number of characters to generate.

    .PARAMETER CharacterSet
        Allowed characters.

    .PARAMETER Rng
        Existing RandomNumberGenerator instance.

    .OUTPUTS
        System.String.
    #>

    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 10000)]
        [int]$Length,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CharacterSet,

        [Parameter(Mandatory)]
        [System.Security.Cryptography.RandomNumberGenerator]$Rng
    )

    $builder = [System.Text.StringBuilder]::new($Length)

    for ($i = 0; $i -lt $Length; $i++) {

        $index = Get-CryptoRandomIndex `
            -Maximum $CharacterSet.Length `
            -Rng $Rng

        [void]$builder.Append(
            $CharacterSet[$index]
        )
    }

    return $builder.ToString()
}

# ============================================================
# 7. LOCAL PASSWORD VERIFICATION
# ============================================================

function Test-LocalPassword {
    <#
    .SYNOPSIS
        Compares a candidate against the configured local test value.

    .DESCRIPTION
        Performs a local constant-time comparison.

        NO network connection is attempted.

    .PARAMETER Candidate
        Candidate generated by the benchmark.

    .OUTPUTS
        System.Boolean.
    #>

    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Candidate
    )

    $candidateBytes =
        [System.Text.Encoding]::UTF8.GetBytes(
            $Candidate
        )

    $targetBytes =
        [System.Text.Encoding]::UTF8.GetBytes(
            $CONFIG.TestPassword
        )

    # FixedTimeEquals requires equal-length byte arrays.
    if ($candidateBytes.Length -ne $targetBytes.Length) {
        return $false
    }

    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        $candidateBytes,
        $targetBytes
    )
}

# ============================================================
# 8. BENCHMARK STATISTICS
# ============================================================

function Get-BenchmarkStatistics {
    <#
    .SYNOPSIS
        Calculates benchmark statistics.

    .PARAMETER Attempts
        Number of unique candidates tested.

    .PARAMETER StartTime
        Benchmark start time.

    .OUTPUTS
        PSCustomObject.
    #>

    param(
        [Parameter(Mandatory)]
        [long]$Attempts,

        [Parameter(Mandatory)]
        [datetime]$StartTime
    )

    $elapsed = (Get-Date) - $StartTime

    $seconds = [Math]::Max(
        $elapsed.TotalSeconds,
        0.000001
    )

    $speed = $Attempts / $seconds

    $remaining = [Math]::Max(
        [long]$CONFIG.MaxCandidates - $Attempts,
        0
    )

    $estimatedSeconds =
        if ($speed -gt 0) {
            $remaining / $speed
        }
        else {
            0
        }

    return [PSCustomObject]@{
        Attempts          = $Attempts
        Elapsed           = $elapsed
        AttemptsPerSecond = $speed
        Remaining         = $remaining
        EstimatedSeconds  = $estimatedSeconds
    }
}

# ============================================================
# 9. DISPLAY HELPERS
# ============================================================

function Show-Banner {
    <#
    .SYNOPSIS
        Displays the application banner.
    #>

    Clear-Host

    Write-Host ''
    Write-Host `
        '============================================================' `
        -ForegroundColor Cyan

    Write-Host `
        '       KARIBU WI-FI PASSWORD AUDIT BENCHMARK' `
        -ForegroundColor Cyan

    Write-Host `
        '============================================================' `
        -ForegroundColor Cyan

    Write-Host ''
    Write-Host `
        'Local security research / password-search benchmark' `
        -ForegroundColor Gray

    Write-Host ''
}

function Show-Configuration {
    <#
    .SYNOPSIS
        Displays the active benchmark configuration.
    #>

    $space = Get-SearchSpaceInfo

    Write-Host `
        'Configuration' `
        -ForegroundColor Cyan

    Write-Host '-------------'

    Write-Host `
        "Password length : $($CONFIG.PasswordLength)"

    Write-Host `
        "Character set   : $($CONFIG.CharacterSet)"

    Write-Host `
        "Candidates max  : $($CONFIG.MaxCandidates)"

    Write-Host `
        "Character count : $($space.CharacterCount)"

    Write-Host ''

    Write-Host `
        "Search-space magnitude: approximately 10^$([Math]::Round($space.Log10Space, 2)) candidates" `
        -ForegroundColor Yellow

    Write-Host ''

    Write-Host `
        "Local test length: $($CONFIG.TestPassword.Length) characters" `
        -ForegroundColor Gray

    Write-Host ''
}

# ============================================================
# 10. RESULT REPORT
# ============================================================

function Save-BenchmarkResult {
    <#
    .SYNOPSIS
        Saves the final benchmark report.

    .PARAMETER FilePath
        Destination path.

    .PARAMETER Attempts
        Number of tested candidates.

    .PARAMETER Found
        Whether the local test value was found.

    .PARAMETER Statistics
        Final benchmark statistics.
    #>

    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [long]$Attempts,

        [Parameter(Mandatory)]
        [bool]$Found,

        [Parameter(Mandatory)]
        [PSCustomObject]$Statistics
    )

    $space = Get-SearchSpaceInfo

    $report = @"
# Karibu Wi-Fi Audit Benchmark

Execution Date:
$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Password Length:
$($CONFIG.PasswordLength)

Character Set:
$($CONFIG.CharacterSet)

Character Count:
$($space.CharacterCount)

Search Space:
approximately 10^$([Math]::Round($space.Log10Space, 4))

Maximum Candidates:
$($CONFIG.MaxCandidates)

Candidates Tested:
$Attempts

Candidates Per Second:
$([Math]::Round($Statistics.AttemptsPerSecond, 4))

Elapsed:
$($Statistics.Elapsed.ToString('hh\:mm\:ss\.fff'))

Local Match:
$Found

Network Authentication:
DISABLED

Network Credentials:
NOT USED

Verification Mode:
LOCAL ONLY

Purpose:
Local password-search benchmarking only.
"@

    $report |
        Out-File `
            -LiteralPath $FilePath `
            -Encoding UTF8
}

# ============================================================
# 11. MAIN BENCHMARK
# ============================================================

function Start-WiFiAuditBenchmark {
    <#
    .SYNOPSIS
        Runs the complete local password-search benchmark.

    .DESCRIPTION
        Initializes the environment, validates configuration,
        generates unique candidates, verifies them locally,
        displays statistics, and writes a final report.

        Network authentication is never performed.
    #>

    Show-Banner

    $paths = Initialize-AuditEnvironment

    Write-Log `
        -Message 'Benchmark initialization started.' `
        -Level INFO `
        -LogFile $paths.LogFile

    $rng = $null

    try {

        Test-Configuration | Out-Null

        Show-Configuration

        Write-Host `
            'SAFETY MODE' `
            -ForegroundColor Green

        Write-Host '-----------'

        Write-Host `
            'Network authentication is DISABLED.' `
            -ForegroundColor Green

        Write-Host `
            'Candidates are verified locally only.' `
            -ForegroundColor Green

        Write-Host `
            'No wireless credentials are submitted anywhere.' `
            -ForegroundColor Green

        Write-Host ''

        $confirmation = Read-Host `
            'Start local benchmark? (Y/N)'

        if ($confirmation -notmatch '^[Yy]$') {

            Write-Log `
                -Message 'Benchmark cancelled by user.' `
                -Level WARNING `
                -LogFile $paths.LogFile

            Write-Host ''
            Write-Host `
                'Benchmark cancelled.' `
                -ForegroundColor Yellow

            return
        }

        # HashSet prevents duplicate candidates from being counted twice.
        $testedSet =
            [System.Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal
            )

        # Create the cryptographic RNG once for the complete benchmark.
        # Creating a new RNG for every character would add unnecessary
        # overhead and distort the performance measurement.
        $rng =
            [System.Security.Cryptography.RandomNumberGenerator]::Create()

        $startTime = Get-Date

        $attempts = [long]0

        $found = $false

        $matchedCandidate = $null

        Write-Host ''
        Write-Host `
            'Starting benchmark...' `
            -ForegroundColor Cyan

        Write-Host ''

        Write-Host `
            'Press Ctrl+C to stop.' `
            -ForegroundColor Yellow

        Write-Host ''

        while ($attempts -lt $CONFIG.MaxCandidates) {

            $candidate = Generate-RandomPassword `
                -Length $CONFIG.PasswordLength `
                -CharacterSet $CONFIG.CharacterSet `
                -Rng $rng

            # If this candidate already exists, generate another one
            # without increasing the attempt counter.
            if (-not $testedSet.Add($candidate)) {
                continue
            }

            $attempts++

            $success = Test-LocalPassword `
                -Candidate $candidate

            if ($success) {

                $found = $true

                $matchedCandidate = $candidate

                $statistics =
                    Get-BenchmarkStatistics `
                        -Attempts $attempts `
                        -StartTime $startTime

                Write-Host ''
                Write-Host `
                    '============================================================' `
                    -ForegroundColor Green

                Write-Host `
                    'LOCAL TEST VALUE FOUND' `
                    -ForegroundColor Green

                Write-Host `
                    '============================================================' `
                    -ForegroundColor Green

                Write-Host `
                    "Candidate : $candidate"

                Write-Host `
                    "Attempts  : $attempts"

                Write-Host `
                    "Speed     : $([Math]::Round($statistics.AttemptsPerSecond, 2)) candidates/s"

                Write-Host `
                    "Elapsed   : $($statistics.Elapsed.ToString('hh\:mm\:ss\.fff'))"

                Write-Log `
                    -Message "Local test value matched after $attempts unique candidates." `
                    -Level SUCCESS `
                    -LogFile $paths.LogFile

                break
            }

            if (
                $attempts % $CONFIG.StatisticsInterval -eq 0
            ) {

                $statistics =
                    Get-BenchmarkStatistics `
                        -Attempts $attempts `
                        -StartTime $startTime

                Write-Host `
                    "[#$attempts] $([Math]::Round($statistics.AttemptsPerSecond, 2)) candidates/s" `
                    -ForegroundColor Gray
            }
        }

        $finalStatistics =
            Get-BenchmarkStatistics `
                -Attempts $attempts `
                -StartTime $startTime

        Write-Host ''

        if (-not $found) {

            Write-Host `
                '============================================================' `
                -ForegroundColor Yellow

            Write-Host `
                'BENCHMARK FINISHED WITHOUT MATCH' `
                -ForegroundColor Yellow

            Write-Host `
                '============================================================' `
                -ForegroundColor Yellow

            Write-Host `
                "Candidates tested : $attempts"

            Write-Host `
                "Speed             : $([Math]::Round($finalStatistics.AttemptsPerSecond, 2)) candidates/s"

            Write-Host `
                "Elapsed           : $($finalStatistics.Elapsed.ToString('hh\:mm\:ss\.fff'))"

            Write-Log `
                -Message "Benchmark completed without local match. Attempts=$attempts." `
                -Level INFO `
                -LogFile $paths.LogFile
        }

        Save-BenchmarkResult `
            -FilePath $paths.ResultFile `
            -Attempts $attempts `
            -Found $found `
            -Statistics $finalStatistics

        Write-Log `
            -Message "Benchmark completed. Attempts=$attempts; Found=$found; Speed=$([Math]::Round($finalStatistics.AttemptsPerSecond, 4)) candidates/s." `
            -Level SUCCESS `
            -LogFile $paths.LogFile

        Write-Host ''
        Write-Host `
            "Result saved to: $($paths.ResultFile)" `
            -ForegroundColor Green

        Write-Host `
            "Log saved to   : $($paths.LogFile)" `
            -ForegroundColor Green

    }
    catch {

        try {
            Write-Log `
                -Message $_.Exception.ToString() `
                -Level ERROR `
                -LogFile $paths.LogFile
        }
        catch {
            # Do not hide the original exception if logging itself fails.
        }

        Write-Host ''
        Write-Host `
            "ERROR: $($_.Exception.Message)" `
            -ForegroundColor Red

        throw
    }
    finally {

        if ($null -ne $rng) {
            $rng.Dispose()
        }
    }
}

# ============================================================
# 12. ENTRY POINT
# ============================================================

try {

    Start-WiFiAuditBenchmark

}
catch {

    Write-Host ''
    Write-Host `
        'Application terminated because of an error.' `
        -ForegroundColor Red

    Write-Host `
        $_.Exception.Message `
        -ForegroundColor Red
}

Write-Host ''
Write-Host `
    'Press Enter to exit...' `
    -ForegroundColor Cyan

Read-Host | Out-Null
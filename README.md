# 🔐   Wi-Fi Password Audit Benchmark

Cross-platform PowerShell 7+ project for studying password-search algorithms, random candidate generation, search-space size, verification throughput, logging, and benchmark performance.

> **Important:** This project intentionally does **not** perform authentication attempts against real Wi-Fi networks. Password candidates are verified exclusively against a local test value.

---

## 🎯 Project Objective

The original concept was a Wi-Fi brute-force tester.

For responsible security research, this implementation separates the interesting engineering components from real-world authentication:

```text
Candidate Generation
        ↓
Duplicate Detection
        ↓
Local Verification
        ↓
Statistics
        ↓
Logging
        ↓
Benchmark Report
```

This allows experimentation with:

* random password generation;
* candidate-space calculations;
* cryptographic random number generation;
* duplicate detection;
* candidates/second;
* elapsed time;
* search-space magnitude;
* logging;
* benchmark reproducibility;
* PowerShell cross-platform development.

---

## 🖥️ Requirements

* PowerShell 7+
* Windows, Linux, or macOS
* No Wi-Fi adapter is required.
* No administrator privileges are required.
* No `netsh` or `nmcli` dependency exists.

Check your PowerShell version:

```powershell
$PSVersionTable.PSVersion
```

---

## 🚀 Running the Project

Save the script as:

```text
wifi-audit-benchmark.ps1
```

Then run:

```powershell
pwsh ./wifi-audit-benchmark.ps1
```

On Windows PowerShell 7:

```powershell
./wifi-audit-benchmark.ps1
```

---

## ⚙️ Configuration

The main configuration is located near the beginning of the script:

```powershell
$CONFIG = @{
    PasswordLength      = 18
    MaxCandidates       = 100000
    CharacterSet        = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    TestPassword        = 'TEST123'
    StatisticsInterval  = 1000
}
```

### PasswordLength

Controls the generated candidate length.

Example:

```text
PasswordLength = 8
```

means every generated candidate contains eight characters.

### CharacterSet

Defines the characters available to the generator.

Example:

```text
ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
```

contains:

* 26 uppercase letters;
* 10 digits;
* 36 possible characters.

### MaxCandidates

Defines the maximum number of unique candidates generated during one benchmark.

### TestPassword

This is the local value used by the verifier.

It is **not sent anywhere**.

It is never submitted to a router or access point.

---

## 🧮 Search-Space Calculation

For a character set containing `N` possible characters and passwords of length `L`:

```text
Search Space = N^L
```

For example:

```text
36^18
```

produces an extremely large candidate space.

The script calculates the magnitude using logarithmic arithmetic to avoid integer overflow.

---

## 🔑 Random Candidate Generation

The generator uses:

```text
System.Security.Cryptography.RandomNumberGenerator
```

rather than the ordinary `Get-Random` function.

This provides stronger randomness and makes the benchmark more representative of a security-oriented candidate generator.

---

## 🛡️ Local Verification

The verifier is deliberately local:

```text
Generated Candidate
        ↓
Test-LocalPassword
        ↓
Local TestPassword
```

There is no:

```text
netsh wlan connect
nmcli device wifi connect
```

and no network authentication mechanism.

This boundary is intentional.

---

## 📊 Benchmark Statistics

The program measures:

* total candidates;
* elapsed time;
* candidates per second;
* remaining candidates;
* estimated remaining time;
* whether the local value was found.

Example:

```text
[#$attempts] 1250.47 candidates/s
```

---

## 📝 Logging

Each execution creates timestamped files such as:

```text
wifi_audit_20260906_153000.log
wifi_audit_20260906_153000.result.txt
```

The log records:

* initialization;
* configuration errors;
* benchmark completion;
* benchmark failures;
* final statistics.

---

## 🔬 What You Can Learn From This Project

This project is useful for studying several security concepts.

### 1. Entropy

A larger character set and longer password increase the search space.

### 2. Random Search

Random candidate generation does not guarantee that candidates are tested in an optimal order.

### 3. Birthday-Style Collisions

Random generation can produce duplicate candidates.

The script therefore maintains a `HashSet` to prevent duplicate counting.

### 4. Throughput

The benchmark lets you measure how many candidate/verifier operations your machine can perform per second.

### 5. Search-Space Impossibility

A benchmark can demonstrate why a sufficiently large password space can become computationally impractical.

---

## ⚠️ Why the Project Does Not Authenticate Against Wi-Fi

Automatically generating credentials and submitting them to a real authentication service changes the program from a local benchmark into an authentication attack tool.

The benchmark therefore keeps the verification layer local.

This makes the project suitable for:

* programming education;
* algorithm benchmarking;
* password-strength research;
* security demonstrations;
* controlled experiments.

---

## 🏗️ Architecture

```text
┌───────────────────────────────┐
│        Configuration          │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│     Search Space Analysis     │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│   Cryptographic Generator     │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│      Duplicate Detection      │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│       Local Verification      │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│       Statistics Engine       │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│       Logs + Result File      │
└───────────────────────────────┘
```

---

## 🧪 Recommended Experiments

You can compare different configurations.

### Experiment A — Short Password

```text
Length: 6
Character set: ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
```

### Experiment B — Longer Password

```text
Length: 10
Character set: ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
```

### Experiment C — Larger Character Set

Add lowercase characters:

```text
ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789
```

Compare:

```text
36^L
```

against:

```text
62^L
```

and observe how quickly the search space grows.

---

## 📈 Important Interpretation

A benchmark showing:

```text
10,000 candidates/second
```

does **not** mean a real Wi-Fi password can be searched at that rate.

Real authentication systems have protocol-specific behavior, rate limiting, lockouts, handshake requirements, hardware constraints, and other security mechanisms.

The benchmark measures the performance of the **local generation + verification pipeline**, not the performance of breaking a real Wi-Fi network.

---

## 🔒 Security Recommendations for Your Own Wi-Fi

For an actual network-security assessment, focus on:

* WPA3 where supported;
* WPA2-AES when WPA3 is unavailable;
* disabling WPS when it is not required;
* using a long, unique passphrase;
* updating router firmware;
* changing default administrator credentials;
* separating guest devices from trusted devices;
* reviewing connected devices;
* avoiding reused passwords.

---

## 📁 Suggested Repository Structure

```text
 -wifi-audit/
│
├── wifi-audit-benchmark.ps1
├── README.md
├── LICENSE
│
├── docs/
│   ├── architecture.md
│   └── security-model.md
│
├── tests/
│   └── benchmark.tests.ps1
│
└── reports/
    └── .gitkeep
```

---

## 🧭 Future Improvements

Potential safe extensions include:

* deterministic seeded benchmarks;
* CSV/JSON export;
* HTML reports;
* password entropy estimation;
* configurable character sets;
* benchmark comparison between machines;
* parallel local verification;
* Pester automated tests;
* graphical dashboard;
* configurable algorithms;
* statistical analysis of duplicate candidates.

---

## 📜 License

Use this project responsibly and only for legitimate security research, education, and systems you are authorized to assess.

---

## #️⃣ Hashtags

#PowerShell #PowerShell7 #CyberSecurity #CyberSecurityEducation #EthicalHacking #SecurityResearch #WiFiSecurity #NetworkSecurity #PasswordSecurity #PasswordStrength #BruteForceResearch #SecurityBenchmark #Cryptography #RandomNumberGeneration #Programming #Automation #DevSecOps #BlueTeam #DefensiveSecurity # Platform

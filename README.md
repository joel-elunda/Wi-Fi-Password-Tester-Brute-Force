# 📡 WiFi Security Testing Tool — Untraceable Edition

> A cross-platform PowerShell tool for auditing WiFi network security, featuring MAC address randomization, multi-phase password testing, and anti-forensic cleanup.

![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Status](https://img.shields.io/badge/status-active-success)

---

## ⚠️ Disclaimer

**This tool is intended strictly for authorized security testing and educational purposes.**

- Only use it against networks **you own** or for which you have **explicit written permission**.
- Unauthorized access to computer networks is **illegal** in most jurisdictions (CFAA, GDPR, Computer Misuse Act, etc.).
- The author assumes **no liability** for misuse or damage caused by this tool.

By using this software, you agree to these terms.

---

## 📖 Table of Contents

- [Overview](#-overview)
- [Features](#-features)
- [Requirements](#-requirements)
- [Installation](#-installation)
- [Usage](#-usage)
- [How It Works](#-how-it-works)
- [Password Generation Strategy](#-password-generation-strategy)
- [Modes](#-modes)
- [Restoration & Safety](#-restoration--safety)
- [Troubleshooting](#-troubleshooting)
- [Project Structure](#-project-structure)
- [Contributing](#-contributing)
- [License](#-license)

---

## 🔍 Overview

**WiFi Security Testing Tool — Untraceable Edition** is a PowerShell script that audits the strength of WiFi networks by testing generated password candidates against a target access point.

It is designed for **red-team engagements, penetration testing labs, and security researchers** who need a portable, cross-platform tool with anonymity features.

Key differentiators:

- **Cross-platform** — Works on Windows (native), Linux, and macOS.
- **MAC randomization** — Rotates the network adapter's hardware address to avoid tracking.
- **Multi-phase password strategy** — SSID-derived → common wordlist → pattern-based.
- **Self-restoring** — Always restores the original MAC and reactivates the adapter on exit.
- **Anti-forensic** — Clears event logs and DNS cache.

---

## ✨ Features

| Feature | Description |
|---|---|
| 🌐 **Cross-platform** | Windows 10/11, most Linux distros, macOS |
| 🎭 **MAC randomization** | Random MAC per test / per ghost-cycle |
| 🧠 **Smart password generation** | SSID-based, common passwords, 18-char patterns |
| 🕵️ **Ghost mode** | Rotates MAC every 10 attempts |
| 🛡️ **Auto-restore** | Restores original MAC + re-enables adapter on exit |
| 🔄 **Interactive controls** | Press `Q` to quit, `R` to rotate MAC mid-scan |
| 🧹 **Trace cleanup** | Clears Windows event logs, DNS cache, bash history |
| 📊 **Live progress** | Progress bar + phase indicator + signal strength colors |
| 🧪 **Robust adapter detection** | 3 fallback methods (Get-NetAdapter → netsh → wmic) |

---

## 🖥️ Requirements

### Common
- **PowerShell 5.1+** (Windows) or **PowerShell 7+** (cross-platform)
- **Administrator / root privileges**

### Windows
- Windows 10 or 11
- WiFi adapter with compatible drivers
- Built-in tools: `netsh`, `Get-NetAdapter`, `wevtutil`

### Linux
- `iw`, `iwconfig`, `nmcli` (NetworkManager)
- `sudo` privileges
- Root access for MAC manipulation

### macOS
- `spoof-mac` or similar (optional — MAC spoofing is a no-op by default)
- Root privileges

---

## 📦 Installation

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/wifi-security-tester.git
cd wifi-security-tester
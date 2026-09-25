# 🔐 WiFi Security Testing Tool v5.0

<p align="center">
  <img src="https://img.shields.io/badge/Version-5.0-blue.svg" alt="Version">
  <img src="https://img.shields.io/badge/PowerShell-5.1+-purple.svg" alt="PowerShell">
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20Linux-green.svg" alt="Platform">
  <img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License">
</p>

<p align="center">
  <b>Advanced WiFi Security Testing Tool with MAC Anonymization and ISP Pattern Analysis</b><br>
  <i>Optimized for Orange and Vodacom Fiber Box Password Patterns</i>
</p>

---

## 📋 Table of Contents

- [Description](#-description)
- [Features](#-features)
- [Prerequisites](#-prerequisites)
- [Installation](#-installation)
- [Usage](#-usage)
- [Pattern Analysis](#-pattern-analysis)
- [Security Features](#-security-features)
- [Troubleshooting](#-troubleshooting)
- [Legal Disclaimer](#-legal-disclaimer)

---

## 📝 Description

**WiFi Security Testing Tool** is a professional PowerShell-based penetration testing framework designed for security auditors and network administrators. The tool features advanced anonymization (MAC spoofing), hostile environment detection, and intelligent password pattern generation specifically optimized for Orange and Vodacom fiber box default passwords.

### Key Capabilities
- 🔒 **Anonymization**: Automatic MAC address spoofing before and after testing
- 🛡️ **Protection**: VM detection, security software detection, and environment analysis
- 🎯 **Pattern Intelligence**: Advanced pattern generation based on ISP-specific password structures
- 🔧 **Cross-Platform**: Works on Windows (netsh) and Linux (NetworkManager/iw)
- 📊 **Reporting**: Detailed logging and performance statistics

---

## ✨ Features

### Core Features
| Feature | Description |
|---------|-------------|
| **18-Character Hex Generation** | Generates random 18-character hexadecimal passwords |
| **ISP Pattern Mode** | Intelligent patterns based on Orange/Vodacom box analysis |
| **MAC Spoofing** | Automatic MAC address randomization for anonymity |
| **Security Detection** | Detects VMs, security software, and analysis tools |
| **Cross-Platform** | Windows and Linux support |
| **Resume Capability** | Saves tested passwords to avoid repetition |

### Pattern Analysis Mode
Based on analysis of real Orange Fiber passwords (e.g., `2TFG3AQ72NZH5CCAGX`), the tool generates:
- Base36 encoded patterns
- MAC-address derived passwords
- Manufacturing date-based sequences
- Double-character pattern variations

---

## 📋 Prerequisites

### System Requirements
- **OS**: Windows 10/11 or Linux (Ubuntu/Debian/Kali)
- **PowerShell**: Version 5.1 or higher
- **Privileges**: Administrator (Windows) or root (Linux)
- **Network**: Compatible wireless adapter with monitor mode support

### Windows Prerequisites
```powershell
# Check PowerShell version
$PSVersionTable.PSVersion

# Ensure execution policy allows scripts
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
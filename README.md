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

# WiFi Security Testing Tool - Untraceable Edition

Outil de test de sécurité WiFi multi-plateforme (Windows, Linux, macOS) avec anonymisation MAC, génération de mots de passe ciblée et modes furtifs.

> **⚠️ AVERTISSEMENT LÉGAL**  
> Cet outil est destiné **exclusivement** à des tests de sécurité sur des réseaux **dont vous êtes le propriétaire** ou pour lesquels vous disposez d'une **autorisation écrite explicite**.  
> L'utilisation sur des réseaux tiers sans autorisation est **illégale** et peut entraîner des poursuites pénales.  
> Les auteurs déclinent toute responsabilité en cas d'utilisation abusive.

---

## 🚀 Fonctionnalités

- **Multi-plateforme** : Windows 10/11, Ubuntu, Debian, RedHat, CentOS, Fedora, Kali, macOS.
- **Détection automatique de l'OS** et des adaptateurs WiFi.
- **Anonymisation MAC** : changement d'adresse MAC aléatoire (spoofing) avec restauration en fin d'exécution.
- **Modes d'exécution** :
  - `standard` : scan et test classique.
  - `stealth` : rotation MAC périodique.
  - `aggressive` : priorité haute, moins de délais.
  - `ghost` (par défaut) : rotation MAC fréquente + nettoyage des traces.
- **Génération de mots de passe en 3 phases** :
  1. Basés sur le SSID (nom du réseau, variations, années).
  2. Mots de passe communs mondiaux (dictionnaire intégré).
  3. Motifs hexadécimaux de 18 caractères (Orange/Vodacom + aléatoire).
- **Interface interactive** : sélection d'adaptateur et de réseau avec validation des entrées.
- **Nettoyage des traces** (logs Windows, historique bash).
- **Barre de progression** en temps réel.

---

## 📋 Prérequis

### Windows
- PowerShell 5.1 ou supérieur (Windows 10/11).
- Droits **Administrateur** obligatoires.
- Adaptateur WiFi fonctionnel.

### Linux
- PowerShell Core (`pwsh`) installé.
- Droits **root** (`sudo`).
- Outils réseau : `iw`, `iwlist`, `nmcli`, `macchanger` (optionnel).
- Installation :
  ```bash
  sudo apt install iw wireless-tools network-manager macchanger
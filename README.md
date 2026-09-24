# Mode standard, région Afrique Centrale
.\main.ps1

# Mode furtif avec sécurité renforcée
.\main.ps1 -Mode stealth -Region central-africa

# Sans changement de MAC
.\main.ps1 -DisableMacSpoof

# Toutes les régions, 10000 mots de passe hex
.\main.ps1 -Region all -HexPasswordCount 10000
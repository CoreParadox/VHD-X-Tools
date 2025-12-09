# VHD(X)-Tools

A collection of PowerShell tools for creating and booting Windows VHD/VHDX virtual hard disks.

# ⚠️⚠️⚠️ Warning ⚠️⚠️⚠️
## This comes with no support or warranty, if you mess up your BCD Store it can be difficult to get it working again without reinstalling. Use at your own risk!

At the very least I recommend [backing up your BCD store](https://www.tenforums.com/tutorials/163900-backup-restore-boot-configuration-data-bcd-store-windows.html) and saving it to a different drive than windows so you can boot to recovery and restore it if you need to

## Overview

This project provides two main tools:

1. **CreateVHDX** - Creates a bootable Windows VHDX from a Windows ISO, with automated setup via unattend.xml and winget package installation
2. **BootVHDX** - Boots into an existing VHDX natively (without Hyper-V) using a one-time boot sequence

> ❓ Initially made this so I could install League of Legends without putting Riot Vanguard on my main windows install, and without messing with dual-boot and other weirdness, but it can easily be used for plently of other things.

> 💡 For maximum isolation, encrypt all your other logical drives, storing the VHDX on it's own logical drive.

## CreateVHDX

Creates a new VHDX file, installs Windows from an ISO, configures automated setup, and optionally creates a Hyper-V VM.

### Requirements

- Windows with Hyper-V PowerShell module (the script will enable it automatically if missing)
- Full Hyper-V platform only required if using `-VmName` to create a VM
- Administrator privileges
- Windows 11 ISO file

### Usage

```powershell
# Create VHDX only (no VM) - works without full Hyper-V
.\CreateVHDX\CreateVHDX.ps1 -VhdPath "F:\VHDX\MyVM.vhdx" -VhdSizeGB 80 -IsoPath "C:\ISOs\Win11.iso" -SystemLabel "MyWin"

# Create VHDX and Hyper-V VM - requires full Hyper-V
.\CreateVHDX\CreateVHDX.ps1 -VhdPath "F:\VHDX\MyVM.vhdx" -VhdSizeGB 80 -IsoPath "C:\ISOs\Win11.iso" -VmName "MyVM" -SystemLabel "MyWin"
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-VhdPath` | `F:\VHDX\League.vhdx` | Path where the VHDX will be created |
| `-VhdSizeGB` | `80` | Size of the VHDX in GB (dynamic expansion) |
| `-IsoPath` | *(required)* | Path to Windows ISO file |
| `-VmName` | *(optional)* | Name for the Hyper-V VM (omit to skip VM creation) |
| `-SystemLabel` | `LeagueWin` | Volume label for the Windows partition |

### Rundown

1. Enables Hyper-V PowerShell module if not already available
2. Creates a dynamic VHDX at the specified path
3. Mounts and partitions the VHDX (MBR, NTFS, active partition)
4. Applies Windows image from ISO using DISM
5. Injects unattend.xml for automated OOBE setup
6. Copies winget installation scripts to `C:\FirstTimeSetup\`
7. Installs BIOS boot files inside the VHDX
8. (Optional If) `-VmName` is provided, creates a Generation 1 Hyper-V VM configured with:
   - 4 vCPUs
   - Dynamic memory (2GB-8GB)
   - Default Switch networking

### Supporting Files

`unattend.xml`

Automates Windows OOBE by:
- Skipping EULA, registration, and wireless setup screens
- Creating a local admin account (`LeagueUser`)
- Enabling auto-logon
- ~~Running winget package installation on first login~~

> ⚠️Automatic winget-install currently doesn't run on first login but you can run it yourself from `C:\FirstTimeSetup\winget-install.ps1`

#### `winget-packages.txt`
List of winget package IDs to install with winget-install.ps1 (one per line, `#` for comments):
```
Microsoft.WindowsTerminal
VideoLAN.VLC
Discord.Discord
# Add your packages here
```

`winget-install.ps1`    
Script that reads `winget-packages.txt` and installs each package silently.

# BootVHDX

Boots into a VHDX natively on bare metal using Windows Boot Manager's one-time boot sequence feature.

### Requirements

- Windows with native VHD boot support (Win 10/11 should both work)
- Administrator privileges
- A bootable VHDX file

### Usage

```powershell
# Set up boot sequence (reboot manually later)
.\BootVHDX\boot-vhdx.ps1 -VhdPath "F:\VHDX\MyVM.vhdx"

# Set up and reboot immediately
.\BootVHDX\boot-vhdx.ps1 -VhdPath "F:\VHDX\MyVM.vhdx" -RebootNow
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-VhdPath` | *(required)* | Path to the VHDX file to boot |
| `-Description` | `Temp VHD Boot` | Description for the BCD entry |
| `-RebootNow` | `$false` | Reboot immediately after configuration |

### What It Does

1. Validates the VHDX is on a local filesystem (not network)
2. Checks for existing BCD entry for this VHDX and reuses it if found
3. Creates a new BCD entry by copying the current OS entry (if needed)
4. Configures the entry to point to the VHDX
5. Sets one-time boot sequence - next reboot boots into VHDX, subsequent reboots return to normal

Your default boot configuration remains unchanged. The VHDX boot entry is hidden from the boot menu and only used once per invocation of this script.

## Typical Workflow

1. **Create the VHDX only (for native boot):**
   ```powershell
   .\CreateVHDX\CreateVHDX.ps1 -IsoPath "D:\Win11.iso" -VhdPath "F:\VHDX\Gaming.vhdx"
   ```

2. **Or create VHDX with a Hyper-V VM:**
   ```powershell
   .\CreateVHDX\CreateVHDX.ps1 -IsoPath "D:\Win11.iso" -VhdPath "F:\VHDX\Gaming.vhdx" -VmName "Gaming-VM"
   ```

3. **Boot in Hyper-V for initial setup (if VM was created):**
   ```powershell
   Start-VM "Gaming-VM"
   ```

4. **Boot natively for better performance:**
   ```powershell
   .\BootVHDX\boot-vhdx.ps1 -VhdPath "F:\VHDX\Gaming.vhdx" -RebootNow
   ```
5. **Create a Shortcut for easy access**
   
   5.1 Right-click > New > Shortcut
   
   5.2 Enter the following
   ```ps
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"G:\Util\Scripts\boot-vhdx.ps1\" -VhdPath \"F:\VHDX\League.vhdx\" -RebootNow'"
    ```
    ### ⚠️ Make sure to replace the file paths with yours!

    ### ⚠️ Quoting and escape sequences are important!


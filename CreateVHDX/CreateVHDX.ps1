param(
    [string]$VhdPath = "F:\VHDX\League.vhdx",
    [int]   $VhdSizeGB = 80,
    [string]$IsoPath = "PATH TO WIN11_x64 ISO",
    [string]$SystemLabel = "LeagueWin",
    [string]$VmName
)

function Resolve-HyperVModule {
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        Write-Host "Enabling Hyper-V PowerShell..." -ForegroundColor Yellow
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -All -NoRestart
        Write-Host "Hyper-V PowerShell enabled. Restart Windows, then rerun this script." -ForegroundColor Yellow
        exit 1
    }

    Import-Module Hyper-V -ErrorAction Stop
    Write-Host "Hyper-V PowerShell module loaded." -ForegroundColor Green
}

function New-VHDAtPath {
    param(
        [string]$Path,
        [int]   $SizeGB
    )

    $dir = Split-Path $Path
    New-Item -ItemType Directory -Path $dir -ErrorAction SilentlyContinue | Out-Null

    if (-not (Test-Path $Path)) {
        New-VHD -Path $Path -SizeBytes ($SizeGB * 1GB) -Dynamic | Out-Null
        Write-Host "Created VHDX at $Path"
    }
    else {
        Write-Host "VHDX already exists at $Path"
    }

    $disk = Mount-VHD -Path $Path -PassThru

    $existingPartitions = $disk | Get-Partition -ErrorAction SilentlyContinue
    if (-not $existingPartitions) {
        # Fresh disk
        $disk | Initialize-Disk -PartitionStyle MBR -PassThru | Out-Null

        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter

        Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -IsActive $true

        $vol = Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $SystemLabel -Confirm:$false
    }
    else {
        $vol = Get-Volume -DiskNumber $disk.Number | Where-Object { $_.FileSystemLabel -eq $SystemLabel } |
        Select-Object -First 1

        if (-not $vol) {
            throw "Disk already has partitions but no '$SystemLabel' volume was found. Aborting to avoid trashing existing data."
        }
    }

    $winDrive = "$($vol.DriveLetter):"
    Write-Host "VHD mounted as $winDrive"

    return [PSCustomObject]@{
        Disk     = $disk
        Volume   = $vol
        WinDrive = $winDrive
    }
}

function Deploy-WindowsImage {
    param(
        [string]$WinDrive,
        [string]$IsoPath
    )

    $iso = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $isoVol = ($iso | Get-Volume)
    $isoDrive = "$($isoVol.DriveLetter):"

    $wimPath = Join-Path $isoDrive "sources\install.wim"
    if (-not (Test-Path $wimPath)) {
        $wimPath = Join-Path $isoDrive "sources\install.esd"
    }
    if (-not (Test-Path $wimPath)) {
        throw "Could not find install.wim or install.esd in $isoDrive\sources"
    }

    Write-Host "Applying Windows image from $wimPath to $WinDrive ..." -ForegroundColor Cyan
    & dism /Apply-Image /ImageFile:$wimPath /Index:1 /ApplyDir:$WinDrive

    Dismount-DiskImage -ImagePath $IsoPath

    Write-Host "Image applied." -ForegroundColor Green
}

function Install-Unattend {
    param(
        [string]$WinDrive,
        [string]$UnattendPath
    )

    if (-not (Test-Path $UnattendPath)) {
        Write-Host "No unattend.xml found at $UnattendPath. Skipping unattend injection." -ForegroundColor Yellow
        return
    }

    $pantherDir = Join-Path $WinDrive "Windows\Panther"
    $sysprepDir = Join-Path $WinDrive "Windows\System32\Sysprep"

    New-Item -ItemType Directory -Path $pantherDir -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Path $sysprepDir -ErrorAction SilentlyContinue | Out-Null

    Copy-Item $UnattendPath (Join-Path $pantherDir "unattend.xml") -Force
    Copy-Item $UnattendPath (Join-Path $sysprepDir "unattend.xml") -Force

    Write-Host "Injected unattend.xml into offline image (Panther + Sysprep)." -ForegroundColor Green
}

function Install-BootFilesInsideVhd {
    param(
        [string]$WinDrive
    )

    Write-Host "Creating boot files inside VHD..." -ForegroundColor Cyan
    # BIOS-style boot for Gen1 VM; does *not* touch host BCD
    & bcdboot "$WinDrive\Windows" /s $WinDrive /f BIOS
    Write-Host "Boot files created." -ForegroundColor Green
}

function Dismount-NewVhd {
    param(
        [string]$VhdPath
    )

    Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
    Write-Host "VHD dismounted: $VhdPath"
}

function New-VMFromVhd {
    param(
        [string]$VmName,
        [string]$VhdPath
    )

    Write-Host "Creating Hyper-V VM '$VmName'..." -ForegroundColor Cyan

    # Create Gen1 VM for BIOS-style boot from MBR VHD
    $vm = New-VM -Name $VmName -MemoryStartupBytes 4GB -Generation 1 -VHDPath $VhdPath -SwitchName "Default Switch"

    Set-VMProcessor -VMName $VmName -Count 4
    Set-VMMemory    -VMName $VmName -DynamicMemoryEnabled $true -MinimumBytes 2GB -MaximumBytes 8GB

    Write-Host "VM '$VmName' created. Start-VM '$VmName' to boot into Windows." -ForegroundColor Green
    return $vm
}

function Install-WingetPackagesScript {
    param(
        [string]$WinDrive,
        [string]$PackagesFile,
        [string]$WingetScriptTemplate
    )

    $setupDir = Join-Path $WinDrive "FirstTimeSetup"
    New-Item -ItemType Directory -Path $setupDir -ErrorAction SilentlyContinue | Out-Null

    if (Test-Path $PackagesFile) {
        $targetPackages = Join-Path $setupDir "winget-packages.txt"
        Copy-Item $PackagesFile $targetPackages -Force
        Write-Host "Copied winget-packages.txt into $targetPackages" -ForegroundColor Green
    }
    else {
        Write-Host "No winget-packages.txt found at $PackagesFile. Skipping package list." -ForegroundColor Yellow
    }

    if (Test-Path $WingetScriptTemplate) {
        $targetScript = Join-Path $setupDir "winget-install.ps1"
        Copy-Item $WingetScriptTemplate $targetScript -Force
        Write-Host "Copied winget-install.ps1 into $targetScript" -ForegroundColor Green
    }
    else {
        Write-Host "No winget-install.ps1 template found at $WingetScriptTemplate. Skipping winget script." -ForegroundColor Yellow
    }
}


# ---------------- MAIN FLOW ----------------

Resolve-HyperVModule

$vhInfo = New-VHDAtPath -Path $VhdPath -SizeGB $VhdSizeGB
$winDrive = $vhInfo.WinDrive

Deploy-WindowsImage -WinDrive $winDrive -IsoPath $IsoPath

$unattendPath = Join-Path $PSScriptRoot "unattend.xml"
Install-Unattend -WinDrive $winDrive -UnattendPath $unattendPath

$packagesPath = Join-Path $PSScriptRoot "winget-packages.txt"
Install-WingetPackagesScript -WinDrive $winDrive -PackagesFile $packagesPath -WingetScriptTemplate (Join-Path $PSScriptRoot "winget-install.ps1")

Install-BootFilesInsideVhd -WinDrive $winDrive

Dismount-NewVhd -VhdPath $VhdPath
Write-Host "VHDX prepared at $VhdPath" -ForegroundColor Green


if ($VmName) {
    New-VMFromVhd -VmName $VmName -VhdPath $VhdPath
    Write-Host "Done. Use: Start-VM '$VmName' to boot into Windows with unattend + winget script applied." -ForegroundColor Green
}

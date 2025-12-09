<#
.SYNOPSIS
Boot a VHD/VHDX natively once, without permanently changing the boot menu.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, Position = 0)][Alias("Path")][ValidateScript({ Test-Path $_ })][string]$VhdPath,
    [Parameter(Mandatory = $false)][string]$Description = "Temp VHD Boot",
    [Parameter(Mandatory = $false)][switch]$RebootNow
)

function Test-Elevated{
<#
.SYNOPSIS
Makes sure we are running from an elevated terminal
#>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run from an elevated PowerShell session (Run as administrator)."
    }
}

function Test-VhdPath{
<#
.SYNOPSIS
Makes sure the VHD isn't on a network drive or some other mount
#>
    param([string]$VhdPath)

    $resolved = (Resolve-Path $VhdPath).ProviderPath
    $item     = Get-Item $resolved
    $drive    = $item.PSDrive

    if (-not $drive) { throw "Could not determine drive for '$resolved'." }
    if ($drive.Provider.Name -ne 'FileSystem') { throw "VHD must live on a local filesystem drive (NTFS/BitLocker volume), not a network or other mount." }

    return [pscustomobject]@{
        VhdPath = $resolved
        Drive   = $drive
    }
}

function Build-VhdPath{
<#
.SYNOPSIS
Build the VHD path in the format bcdedit expects: vhd=[C:]\path\to\file.vhdx
#>
    param(
        [string]$VhdPath,
        [System.Management.Automation.PSDriveInfo]$Drive
    )

    $driveRoot    = $Drive.Name + ":"      # e.g. "C:"
    $relativePath = $VhdPath.Substring($driveRoot.Length).TrimStart('\')
    $bcdVhdPath   = "vhd=[$driveRoot]\$relativePath".Replace('/', '\')

    Write-Host "Using VHD path: $VhdPath"
    Write-Host "BCD device string: $bcdVhdPath"
    return $bcdVhdPath
}

function Test-ExistingVhd{
<#
.SYNOPSIS
Check for a BCD Entry that uses the same VHD path
#>
    param(
        [string]$bcdVhdPath
    )

    Write-Host "Searching for existing boot entry using this VHD path..." -ForegroundColor Cyan
    $allBcd        = & bcdedit /enum all 2>$null
    $entryGuid     = $null
    $currentId     = $null
    $currentDevice = $null
    $currentOsDevice = $null

    foreach ($line in $allBcd) {
        if ($line -match '^identifier\s+(\{[0-9a-fA-F\-]+\})') {
            if ($currentId -and ($currentDevice -eq $bcdVhdPath -or $currentOsDevice -eq $bcdVhdPath) -and -not $entryGuid) {
                $entryGuid = $currentId
            }
            $currentId       = $Matches[1]
            $currentDevice   = $null
            $currentOsDevice = $null
        }
        elseif ($line -match '^\s*device\s+(.+)$') {
            $currentDevice = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*osdevice\s+(.+)$') {
            $currentOsDevice = $Matches[1].Trim()
        }
    }

    if (-not $entryGuid -and $currentId -and ($currentDevice -eq $bcdVhdPath -or $currentOsDevice -eq $bcdVhdPath)) {
        $entryGuid = $currentId
    }

    if ($entryGuid) {
        Write-Host "Reusing existing entry: $entryGuid" -ForegroundColor Green
        return $entryGuid
    }
    
    Write-Host "No existing entry found for this VHD."
    return $null
}

function Copy-CurrentBcdEntry{
<#
.SYNOPSIS
Copies the current OS BCD entry
#>
    Write-Host "Copying {current} to new entry with description '$Description'..." -ForegroundColor Cyan
    $copyOutput = & bcdedit /copy '{current}' /d "$Description"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy {current}:`n$copyOutput"
    }

    $newGuid = ($copyOutput | Select-String '{.*}' | ForEach-Object { $_.Matches.Value })
    if (-not $newGuid) { throw "Could not parse GUID from bcdedit /copy output:`n$copyOutput" }

    Write-Host "New entry GUID: $newGuid" -ForegroundColor Green
    return $newGuid
}

function Update-BcdEntry{
<#
.SYNOPSIS
configures the provided BCD entry
#>
    param(
        [string]$newGuid,
        [string]$bcdVhdPath
    )

    Write-Host "Configuring BCD entry to use VHD..." -ForegroundColor Cyan

    bcdedit /set $newGuid device   $bcdVhdPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set device on $newGuid" }

    bcdedit /set $newGuid osdevice $bcdVhdPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set osdevice on $newGuid" }

    # keep it out of visible menu
    bcdedit /displayorder $newGuid /remove 2>$null | Out-Null

    Write-Host "Entry configured." -ForegroundColor Green
    Write-Host ""
}

function Enable-BootSequence{
<#
.SYNOPSIS
Enables the one-time boot sequence to boot to the provided VHD
#>
    param(
        [string]$newGuid
    )

    Write-Host "Setting one-time bootsequence to $newGuid ..." -ForegroundColor Cyan
    bcdedit /bootsequence $newGuid | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set bootsequence. `bcdedit /bootsequence` is not supported on every firmware/boot config."
    }
}

# ---------------- MAIN FLOW ----------------

Test-Elevated

$vhdInfo = Test-VhdPath -VhdPath $VhdPath
$VhdPath = $vhdInfo.VhdPath
$drive   = $vhdInfo.Drive

$bcdVhdPath = Build-VhdPath -VhdPath $VhdPath -Drive $drive

$newGuid = Test-ExistingVhd -bcdVhdPath $bcdVhdPath
if (-not $newGuid) {
    $newGuid = Copy-CurrentBcdEntry
}

Update-BcdEntry -newGuid $newGuid -bcdVhdPath $bcdVhdPath
Enable-BootSequence -newGuid $newGuid

Write-Host "Success." -ForegroundColor Green
Write-Host "Next reboot will boot ONCE into:" -ForegroundColor Green
Write-Host "  $VhdPath" -ForegroundColor Green
Write-Host "Your default boot entry and normal boot menu remain unchanged for future boots." -ForegroundColor Yellow

if ($RebootNow) {
    Write-Host "Rebooting now..." -ForegroundColor Cyan
    shutdown.exe /r /t 0
}
else {
    Write-Host "Run this when you're ready to boot into the VHD:" -ForegroundColor Yellow
    Write-Host "  shutdown /r /t 0"
}

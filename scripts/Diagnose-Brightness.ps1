#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only diagnostics for "internal display brightness cannot be adjusted"
    on Windows laptops.

.DESCRIPTION
    Collects every data point needed to tell apart the common causes:
    broken brightness interface, disabled NVIDIA container service,
    missing monitor driver, adaptive brightness lock, external display.

    Changes nothing. Safe to run without Administrator.

.EXAMPLE
    .\Diagnose-Brightness.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

function Section($title) {
    Write-Host ''
    Write-Host ('--- ' + $title + ' ' + ('-' * [Math]::Max(0, 58 - $title.Length))) -ForegroundColor Cyan
}

function Line($label, $value, $ok) {
    $color = 'Gray'
    if ($ok -eq $true)  { $color = 'Green' }
    if ($ok -eq $false) { $color = 'Red' }
    Write-Host ('  {0,-28} {1}' -f $label, $value) -ForegroundColor $color
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor White
Write-Host ' Brightness Diagnostics (read-only)' -ForegroundColor White
Write-Host '================================================================' -ForegroundColor White

# ------------------------------------------------------------------- OS ----
Section 'System'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
Line 'OS' ($os.Caption + '  Build ' + $os.BuildNumber)
Line 'Model' ($cs.Manufacturer + ' / ' + $cs.Model)
$typeText = switch ($cs.PCSystemType) { 1 { 'Desktop' } 2 { 'Laptop' } default { "Type $($cs.PCSystemType)" } }
Line 'Chassis' $typeText

# ------------------------------------------------------------- displays ----
Section 'Display adapters'
foreach ($v in (Get-CimInstance Win32_VideoController)) {
    Line $v.Name ($v.DriverVersion + '  ' + $v.Status)
}

# ------------------------------------------------------------ brightness ---
Section 'Brightness interface (root\wmi)'
try {
    $b = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction Stop
    $len = @($b.Level).Length
    Line 'Level array length' $len ($len -eq 101)
    Line 'Levels (count)' $b.Levels
    Line 'CurrentBrightness' $b.CurrentBrightness
    Line 'Instance' $b.InstanceName
    Write-Host ''
    if ($len -eq 101) {
        Write-Host '  OK: the brightness interface is healthy (0..100 levels).' -ForegroundColor Green
        Write-Host '      The problem is NOT in the WMI/ACPI layer.' -ForegroundColor Green
    } else {
        Write-Host '  WARNING: the brightness interface looks broken.' -ForegroundColor Red
        Write-Host '           Check monitor driver / graphics driver instead.' -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  Note: "Levels" is the NUMBER of levels (101), not the array.' -ForegroundColor DarkGray
    Write-Host '        The array is "Level". Checking Levels.Count gives 1 and' -ForegroundColor DarkGray
    Write-Host '        leads to a wrong diagnosis. See README.md.' -ForegroundColor DarkGray
} catch {
    Write-Host '  Could not read WmiMonitorBrightness.' -ForegroundColor Red
}

# -------------------------------------------------------------- services ---
Section 'NVIDIA services'
$nvContainer = Get-Service -Name 'NvContainerLocalSystem'
if ($nvContainer) {
    $ok = ($nvContainer.Status -eq 'Running')
    Line 'NvContainerLocalSystem' ($nvContainer.Status.ToString() + ' / ' + $nvContainer.StartType) $ok
    if ($nvContainer.StartType -eq 'Disabled') {
        Write-Host ''
        Write-Host '  >>> THIS IS THE KNOWN CAUSE. Run scripts\Fix-Brightness.ps1 <<<' -ForegroundColor Yellow
        Write-Host ''
    }
} else {
    Line 'NvContainerLocalSystem' 'not installed' 
}

$nvDisplay = Get-Service -Name 'NVDisplay.ContainerLocalSystem'
if ($nvDisplay) {
    Line 'NVDisplay.ContainerLocalSystem' ($nvDisplay.Status.ToString() + ' / ' + $nvDisplay.StartType) ($nvDisplay.Status -eq 'Running')
} else {
    Line 'NVDisplay.ContainerLocalSystem' 'not installed'
}

# --------------------------------------------------------- other checks ----
Section 'Other checks'

$mon = Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mon) {
    Line 'Monitor device' $mon.FriendlyName
    Line 'Monitor status' $mon.Status ($mon.Status -eq 'OK')
} else {
    Line 'Monitor device' 'none found'
}

try {
    $cp = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop
    $tech = '0x{0:X}' -f $cp.VideoOutputTechnology
    $internal = ($cp.VideoOutputTechnology -eq 0x80000000)
    Line 'Video output technology' $tech $internal
    if (-not $internal) {
        Write-Host '  Note: this does not look like an internal panel.' -ForegroundColor Yellow
        Write-Host '        External monitors need DDC/CI, not the brightness slider.' -ForegroundColor Yellow
    }
} catch {
    Line 'Video output technology' 'unavailable'
}

$adapt = (& powercfg /query SCHEME_CURRENT SUB_VIDEO 2>$null) -join "`n"
if ($adapt -match 'ADAPTBRIGHT') {
    $idx = [regex]::Matches($adapt, '0x([0-9a-fA-F]{8})') | ForEach-Object { $_.Groups[1].Value }
    Line 'Adaptive brightness' ('present (values: ' + ($idx -join ', ') + ')')
} else {
    Line 'Adaptive brightness' 'not present'
}

Section 'Third-party display drivers / virtual displays'
$virtual = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
           Where-Object { $_.InstanceId -like 'ROOT\*' }
if ($virtual) {
    foreach ($v in $virtual) { Line $v.FriendlyName $v.Status }
    Write-Host ''
    Write-Host '  Virtual display adapters can interfere with display topology.' -ForegroundColor DarkGray
} else {
    Line 'Virtual displays' 'none'
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor White
Write-Host ' Done. If NvContainerLocalSystem is Disabled, run Fix-Brightness.ps1' -ForegroundColor White
Write-Host '================================================================' -ForegroundColor White
Write-Host ''
Read-Host 'Press Enter to exit'

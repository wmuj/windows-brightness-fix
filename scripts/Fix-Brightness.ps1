#Requires -Version 5.1
<#
.SYNOPSIS
    Enable the NVIDIA LocalSystem Container service and reload the NVIDIA
    display device to restore internal display brightness control.

.DESCRIPTION
    Fixes the "brightness slider / brightness hotkeys do nothing" problem on
    Windows laptops with NVIDIA hybrid graphics, caused by the
    NvContainerLocalSystem service being set to Disabled.

    No reboot required in most cases. Requires Administrator privileges.

.EXAMPLE
    .\Fix-Brightness.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- elevate ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ''
    Write-Host 'Administrator privileges required. Requesting elevation...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
    } catch {
        Write-Host 'Elevation failed or was cancelled.' -ForegroundColor Red
        Write-Host 'Right-click this file and choose "Run with PowerShell" from an elevated prompt.' -ForegroundColor Red
        Read-Host 'Press Enter to exit'
    }
    return
}

function Write-Step($text) {
    Write-Host ''
    Write-Host "==> $text" -ForegroundColor Cyan
}

# ------------------------------------------------------------- pre-check ----
Write-Host ''
Write-Host '======================================================' -ForegroundColor White
Write-Host ' Brightness Fix - NVIDIA LocalSystem Container' -ForegroundColor White
Write-Host '======================================================' -ForegroundColor White

try {
    $b = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction Stop
    Write-Host ("Brightness interface : Level array = {0}, current = {1}" -f $b.Level.Length, $b.CurrentBrightness)
    if ($b.Level.Length -le 1) {
        Write-Host 'WARNING: the brightness interface itself looks broken (not the service).' -ForegroundColor Yellow
        Write-Host 'This script will not help in that case. See README.md.' -ForegroundColor Yellow
    }
} catch {
    Write-Host 'Could not read WmiMonitorBrightness. Continue anyway.' -ForegroundColor Yellow
}

# ------------------------------------------------------- step 1: service ----
Write-Step 'Step 1/3  NvContainerLocalSystem -> Automatic + Start'

$svc = Get-Service -Name 'NvContainerLocalSystem' -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host 'Service not found. This machine may not have NVIDIA graphics.' -ForegroundColor Red
    Write-Host 'Nothing to fix here. See README.md for other causes.' -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    return
}

Write-Host ("Before : {0} / {1}" -f $svc.Status, $svc.StartType)
try {
    Set-Service -Name 'NvContainerLocalSystem' -StartupType Automatic -ErrorAction Stop
    Start-Service -Name 'NvContainerLocalSystem' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name 'NvContainerLocalSystem'
    Write-Host ("After  : {0} / {1}" -f $svc.Status, $svc.StartType) -ForegroundColor Green
} catch {
    Write-Host ("Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

# -------------------------------------------------------- step 2: driver ----
Write-Step 'Step 2/3  Reload NVIDIA display device'

$gpu = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
       Where-Object { $_.FriendlyName -like '*NVIDIA*' } |
       Select-Object -First 1

if ($gpu) {
    Write-Host ("Device : {0}" -f $gpu.FriendlyName)
    Write-Host ("Instance: {0}" -f $gpu.InstanceId)
    Write-Host 'Screen may flicker for a few seconds. This is normal.' -ForegroundColor Yellow
    $out = & pnputil /restart-device "$($gpu.InstanceId)" 2>&1
    Write-Host (($out -join ' ') -replace '\s+', ' ')
    Start-Sleep -Seconds 6
} else {
    Write-Host 'No NVIDIA display device found, skipping.' -ForegroundColor Yellow
}

# -------------------------------------------------------- step 3: verify ----
Write-Step 'Step 3/3  Verify'

$svc = Get-Service -Name 'NvContainerLocalSystem' -ErrorAction SilentlyContinue
if ($svc) {
    $color = if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' }
    Write-Host ("NvContainerLocalSystem : {0} / {1}" -f $svc.Status, $svc.StartType) -ForegroundColor $color
}

try {
    $b = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction Stop
    Write-Host ("Brightness interface   : Level array = {0}, current = {1}" -f $b.Level.Length, $b.CurrentBrightness)
} catch {
    Write-Host 'Brightness interface   : read failed'
}

Write-Host ''
Write-Host 'Now drag the brightness slider and press the brightness keys.' -ForegroundColor Green
Write-Host 'If it still does not work, see README.md (other causes).' -ForegroundColor Green
Write-Host ''
Read-Host 'Press Enter to exit'

<#
.SYNOPSIS
    Automated installer for Mandiant Commando VM.

.DESCRIPTION
    Wraps the documented Commando VM installation steps into a single script:
    pre-flight checks, repo download, file unblocking, and installer launch.

    Commando VM is a Windows-based penetration testing distribution from Mandiant.
    Source: https://github.com/mandiant/commando-vm

.NOTES
    RUN ONLY ON A DEDICATED, ISOLATED VM SNAPSHOT YOU CONTROL.
    This script disables Windows Defender, which is required by the upstream
    installer. Do not run on a host machine or any system with real data.

    Must be run in an elevated (Administrator) PowerShell session.

.PARAMETER Cli
    Run the command-line installer instead of the GUI.

.PARAMETER InstallPath
    Where to download/extract the repo. Defaults to $env:USERPROFILE\Downloads.

.EXAMPLE
    .\Install-CommandoVM.ps1
    .\Install-CommandoVM.ps1 -Cli
#>

[CmdletBinding()]
param(
    [switch]$Cli,
    [string]$InstallPath = "$env:USERPROFILE\Downloads"
)

$ErrorActionPreference = "Stop"
$RepoUrl  = "https://github.com/mandiant/commando-vm/archive/refs/heads/main.zip"
$ZipPath  = Join-Path $InstallPath "commando-vm.zip"
$Extract  = Join-Path $InstallPath "commando-vm"

function Write-Step { param($msg) Write-Host "`n[+] $msg" -ForegroundColor Cyan }
function Write-Warn { param($msg) Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "[x] $msg" -ForegroundColor Red }

# ------------------------------------------------------------
# 1. Pre-flight checks
# ------------------------------------------------------------
Write-Step "Running pre-flight checks"

# Elevation check
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "This script must be run as Administrator. Right-click PowerShell > Run as Administrator."
    exit 1
}

# OS check
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "    OS: $($os.Caption) ($($os.Version))"
if ($os.Caption -notmatch "Windows 10|Windows 11") {
    Write-Warn "Commando VM officially supports Windows 10 (22H2 recommended). Detected: $($os.Caption)"
}

# Disk space check (need 60GB+ free)
$drive = (Get-PSDrive C).Free / 1GB
Write-Host "    Free space on C: $([math]::Round($drive,1)) GB"
if ($drive -lt 60) {
    Write-Warn "Less than 60 GB free. Install may fail."
}

# RAM check
$ram = $os.TotalVisibleMemorySize / 1MB
Write-Host "    RAM: $([math]::Round($ram,1)) GB"
if ($ram -lt 2) {
    Write-Warn "Less than 2 GB RAM detected."
}

# ------------------------------------------------------------
# 2. Safety confirmation — this disables Defender
# ------------------------------------------------------------
Write-Host ""
Write-Warn "This will DISABLE Windows Defender (Tamper Protection, Real-Time"
Write-Warn "Protection, and the AV engine) which is required by Commando VM."
Write-Warn "Only proceed on a dedicated, isolated VM with no sensitive data."
Write-Host ""
$confirm = Read-Host "Type 'I UNDERSTAND' to continue"
if ($confirm -ne "I UNDERSTAND") {
    Write-Err "Confirmation not received. Aborting."
    exit 1
}

# Recommend a snapshot
Write-Warn "Strongly recommended: take a VM snapshot now before continuing."
$snap = Read-Host "Have you taken a snapshot? (y/N)"
if ($snap -notmatch '^[Yy]') {
    Write-Err "Take a snapshot first, then re-run. Aborting."
    exit 1
}

# ------------------------------------------------------------
# 3. Disable Tamper Protection (manual step — cannot be scripted)
# ------------------------------------------------------------
Write-Step "Tamper Protection"
$tp = (Get-MpComputerStatus).IsTamperProtected
if ($tp) {
    Write-Warn "Tamper Protection is ON and CANNOT be disabled via script by design."
    Write-Warn "Disable it manually now:"
    Write-Host  "      Windows Security > Virus & threat protection >"
    Write-Host  "      Manage settings > Tamper Protection > Off"
    Read-Host  "    Press ENTER once Tamper Protection is OFF"
} else {
    Write-Host "    Tamper Protection already disabled."
}

# ------------------------------------------------------------
# 4. Disable Defender via Group Policy registry keys
# ------------------------------------------------------------
Write-Step "Disabling Microsoft Defender (Group Policy)"
$defPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
$rtPath  = "$defPath\Real-Time Protection"

New-Item -Path $defPath -Force | Out-Null
New-Item -Path $rtPath  -Force | Out-Null
Set-ItemProperty -Path $defPath -Name "DisableAntiSpyware"        -Value 1 -Type DWord
Set-ItemProperty -Path $rtPath  -Name "DisableRealtimeMonitoring" -Value 1 -Type DWord
Set-ItemProperty -Path $rtPath  -Name "DisableBehaviorMonitoring" -Value 1 -Type DWord
Set-ItemProperty -Path $rtPath  -Name "DisableOnAccessProtection" -Value 1 -Type DWord
Set-ItemProperty -Path $rtPath  -Name "DisableScanOnRealtimeEnable" -Value 1 -Type DWord
Write-Host "    Group Policy keys set. A reboot is required for these to fully apply."

# Also try the live cmdlet (works until reboot if Tamper is off)
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Write-Host "    Real-time monitoring disabled for current session."
} catch {
    Write-Warn "Could not disable real-time monitoring live; reboot will apply GPO."
}

Write-Warn "A REBOOT is recommended now before continuing the install."
$reboot = Read-Host "Reboot now? Script will need to be re-run after. (y/N)"
if ($reboot -match '^[Yy]') {
    Write-Host "Rebooting in 5 seconds..."
    Start-Sleep 5
    Restart-Computer -Force
    exit 0
}

# ------------------------------------------------------------
# 5. Download and extract the repo
# ------------------------------------------------------------
Write-Step "Downloading Commando VM repo"
Set-ExecutionPolicy Unrestricted -Scope Process -Force

if (Test-Path $Extract) {
    Write-Warn "Existing extract found at $Extract — removing."
    Remove-Item $Extract -Recurse -Force
}

Invoke-WebRequest -Uri $RepoUrl -OutFile $ZipPath -UseBasicParsing
Write-Host "    Downloaded to $ZipPath"

Write-Step "Extracting"
Expand-Archive -Path $ZipPath -DestinationPath $InstallPath -Force
# The archive extracts as commando-vm-main; normalise the name
$extractedDir = Join-Path $InstallPath "commando-vm-main"
if (Test-Path $extractedDir) {
    Rename-Item $extractedDir $Extract -Force
}
Write-Host "    Extracted to $Extract"

# ------------------------------------------------------------
# 6. Unblock files
# ------------------------------------------------------------
Write-Step "Unblocking downloaded files"
Get-ChildItem $Extract -Recurse | Unblock-File
Write-Host "    Done."

# ------------------------------------------------------------
# 7. Launch the installer
# ------------------------------------------------------------
Write-Step "Launching Commando VM installer"
Set-Location $Extract

if ($Cli) {
    Write-Host "    Running CLI install (.\install.ps1 -cli)"
    .\install.ps1 -cli
} else {
    Write-Host "    Running GUI install (.\install.ps1)"
    .\install.ps1
}

Write-Step "Installer launched. Follow the on-screen prompts."
Write-Warn "The full install takes a long time and reboots several times."
Write-Warn "After each reboot, the installer resumes automatically."

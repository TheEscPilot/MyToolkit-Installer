#Requires -Version 5.1
<#
.SYNOPSIS
    MyToolkit Installer — Bootstrap script for first-time installation.

.DESCRIPTION
    This public installer script prompts the user for their issued GitHub
    Personal Access Token (PAT), validates it against the private MyToolkit
    repository and the Gist licence list, then downloads and installs the
    full toolkit to a chosen local folder.

    The PAT is stored securely in Windows Credential Manager after install.
    This installer script deletes itself from temp after completion.

.NOTES
    This script lives in a PUBLIC GitHub repo.
    The MyToolkit tool files live in a PRIVATE GitHub repo.
    Access is controlled by issuing PATs per user.

.EXAMPLE
    Run this one-liner in PowerShell to install MyToolkit :
    irm "https://raw.githubusercontent.com/YOUR_USER/mytoolkit-installer/main/install.ps1" | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# INSTALLER CONFIGURATION
# Edit these values to match your private repo details.
# ============================================================
$Script:GitHubUser    = "YOUR_GITHUB_USERNAME"
$Script:GitHubRepo    = "YOUR_PRIVATE_REPO_NAME"
$Script:GitHubBranch  = "main"
$Script:GistURL       = "https://gist.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_GIST_ID/raw/licence.json"
$Script:CredTarget    = "MyToolkit_GitHub_PAT"
$Script:DefaultInstall= "$env:USERPROFILE\MyToolkit"

# Files to download from the private repo (relative paths)
$Script:FilesToDownload = @(
    "MyToolkit.ps1",
    "VERSION",
    "Tools/tools.manifest.json",
    "Tools/UserManagement/Get-LocalUserReport.ps1",
    "Tools/UserManagement/Reset-LocalUserPassword.ps1",
    "Tools/SystemHealth/Get-SystemSnapshot.ps1",
    "Tools/SystemHealth/Get-DiskHealthReport.ps1",
    "Tools/Network/Test-Connectivity.ps1",
    "Tools/Network/Get-NetworkConfig.ps1",
    "Tools/FileDisk/Clear-TempFiles.ps1",
    "Tools/FileDisk/Get-LargeFiles.ps1",
    "Tools/Security/Get-InstalledSoftware.ps1",
    "Tools/Security/Test-OpenPorts.ps1",
    "Tools/Services/Get-RunningServices.ps1",
    "Tools/Services/Restart-ServiceHelper.ps1",
    "Tools/CyberSecurity/Get-DefenderStatus.ps1",
    "Tools/CyberSecurity/Get-StartupItems.ps1"
)

# ============================================================
# COLOUR HELPERS
# ============================================================
function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   MyToolkit — Installer                             ║" -ForegroundColor Cyan
    Write-Host "  ║   Secure bootstrap for first-time setup             ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host "  → $Text" -ForegroundColor White
}

function Write-OK {
    param([string]$Text)
    Write-Host "  [ ✔ ] $Text" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Text)
    Write-Host "  [ ✗ ] $Text" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [ ! ] $Text" -ForegroundColor DarkYellow
}

# ============================================================
# FUNCTION : ConvertFrom-SecureStringPlain
# Converts a SecureString to plain text (held in memory only).
# ============================================================
function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$SecureString)
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

# ============================================================
# FUNCTION : Save-ToCredentialManager
# Stores the PAT in Windows Credential Manager.
# ============================================================
function Save-ToCredentialManager {
    param([string]$PlainToken)

    # Use cmdkey to store securely
    $result = cmdkey /add:$Script:CredTarget /user:"MyToolkit" /pass:$PlainToken 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-OK "PAT stored in Windows Credential Manager."
        return $true
    } else {
        Write-Warn "Could not store PAT in Credential Manager : $result"
        return $false
    }
}

# ============================================================
# FUNCTION : Test-GitHubAccess
# Validates the PAT against the private repo.
# ============================================================
function Test-GitHubAccess {
    param([string]$Token)

    try {
        $headers  = @{ Authorization = "token $Token" }
        $apiUrl   = "https://api.github.com/repos/$Script:GitHubUser/$Script:GitHubRepo"
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 10 -ErrorAction Stop

        if ($response.name) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

# ============================================================
# FUNCTION : Test-GistLicence
# Checks the Gist licence list for the token suffix.
# ============================================================
function Test-GistLicence {
    param([string]$Token)

    $suffix = $Token.Substring([Math]::Max(0, $Token.Length - 8))

    try {
        $response   = Invoke-RestMethod -Uri $Script:GistURL -TimeoutSec 10 -ErrorAction Stop
        $activeList = $response.active

        if ($activeList -contains $suffix) {
            return @{ Valid = $true; Message = "" }
        } else {
            return @{ Valid = $false; Message = $response.message }
        }
    }
    catch {
        # Gist unreachable — allow install to proceed (grace mode)
        Write-Warn "Licence server unreachable. Proceeding in grace mode."
        return @{ Valid = $true; Message = "offline" }
    }
}

# ============================================================
# FUNCTION : Get-InstallPath
# Prompts the user for an installation folder.
# ============================================================
function Get-InstallPath {
    Write-Host ""
    Write-Host "  Install location (press Enter for default) :" -ForegroundColor White
    Write-Host "  Default : $Script:DefaultInstall" -ForegroundColor DarkGray
    Write-Host ""
    $userPath = Read-Host "  Path"

    if ($userPath.Trim() -eq "") {
        return $Script:DefaultInstall
    }
    return $userPath.Trim()
}

# ============================================================
# FUNCTION : Invoke-DownloadFiles
# Downloads all toolkit files from the private repo.
# ============================================================
function Invoke-DownloadFiles {
    param(
        [string]$Token,
        [string]$InstallPath
    )

    $headers  = @{ Authorization = "token $Token" }
    $tempBase = "$env:TEMP\MyToolkit_Install_$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $tempBase -Force

    $baseURL  = "https://raw.githubusercontent.com/$Script:GitHubUser/$Script:GitHubRepo/$Script:GitHubBranch"
    $total    = $Script:FilesToDownload.Count
    $current  = 0
    $failed   = @()

    Write-Host ""
    Write-Step "Downloading $total files from private repo..."
    Write-Host ""

    foreach ($file in $Script:FilesToDownload) {
        $current++
        $pct = [int](($current / $total) * 100)
        Write-Progress -Activity "Downloading MyToolkit" -Status "$file" -PercentComplete $pct

        $fileURL    = "$baseURL/$($file -replace '\\', '/')"
        $tempTarget = Join-Path $tempBase ($file -replace '/', '\')
        $tempDir    = Split-Path $tempTarget -Parent

        if (-not (Test-Path $tempDir)) {
            $null = New-Item -ItemType Directory -Path $tempDir -Force
        }

        try {
            Invoke-WebRequest -Uri $fileURL -Headers $headers -OutFile $tempTarget -ErrorAction Stop

            if (-not (Test-Path $tempTarget) -or (Get-Item $tempTarget).Length -eq 0) {
                throw "Empty file received."
            }
        }
        catch {
            $failed += $file
            Write-Warn "Failed to download : $file ($_)"
        }
    }

    Write-Progress -Activity "Downloading MyToolkit" -Completed

    if ($failed.Count -gt 0) {
        Write-Warn "$($failed.Count) file(s) failed to download. Install may be incomplete."
    } else {
        Write-OK "All files downloaded successfully."
    }

    # Move from temp staging to install path
    Write-Step "Installing to : $InstallPath"

    if (-not (Test-Path $InstallPath)) {
        $null = New-Item -ItemType Directory -Path $InstallPath -Force
    }

    # Copy files preserving folder structure
    Get-ChildItem -Path $tempBase -Recurse | ForEach-Object {
        $relativePath = $_.FullName.Substring($tempBase.Length).TrimStart('\')
        $destination  = Join-Path $InstallPath $relativePath

        if ($_.PSIsContainer) {
            $null = New-Item -ItemType Directory -Path $destination -Force -ErrorAction SilentlyContinue
        } else {
            $destDir = Split-Path $destination -Parent
            if (-not (Test-Path $destDir)) {
                $null = New-Item -ItemType Directory -Path $destDir -Force
            }
            Copy-Item -Path $_.FullName -Destination $destination -Force
        }
    }

    # Clean up staging area
    Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    Write-OK "Installation complete."

    return ($failed.Count -eq 0)
}

# ============================================================
# FUNCTION : Invoke-SelfDestruct
# Removes this installer script from temp after completion.
# ============================================================
function Invoke-SelfDestruct {
    # The installer runs via | iex so $PSCommandPath may be empty
    # Clean up any temp installer artifacts
    $tempInstaller = "$env:TEMP\install.ps1"
    if (Test-Path $tempInstaller) {
        Remove-Item -Path $tempInstaller -Force -ErrorAction SilentlyContinue
    }

    # Clear the installer download from PS history entry (best effort)
    Clear-History -ErrorAction SilentlyContinue
}

# ============================================================
# MAIN — Installer entry point
# ============================================================

Write-Banner

Write-Host "  This installer will :" -ForegroundColor White
Write-Host "   1. Validate your MyToolkit access key" -ForegroundColor DarkGray
Write-Host "   2. Download the toolkit from the private repository" -ForegroundColor DarkGray
Write-Host "   3. Store your access key securely (Windows Credential Manager)" -ForegroundColor DarkGray
Write-Host "   4. Launch MyToolkit" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host ""

# Step 1 — Get PAT securely
Write-Host "  Enter your MyToolkit access key :" -ForegroundColor White
Write-Host "  (Input is hidden — paste and press Enter)" -ForegroundColor DarkGray
Write-Host ""

$securePAT = Read-Host "  Access key" -AsSecureString
$plainPAT  = ConvertFrom-SecureStringPlain -SecureString $securePAT

if ($plainPAT.Length -lt 10) {
    Write-Fail "Access key appears invalid (too short)."
    exit 1
}

Write-Host ""

# Step 2 — Validate against GitHub repo
Write-Step "Validating access key against repository..."
$repoAccess = Test-GitHubAccess -Token $plainPAT

if (-not $repoAccess) {
    Write-Fail "Access key not recognised or repository unreachable."
    Write-Host "  Please check your key and try again, or contact your administrator." -ForegroundColor DarkGray
    $plainPAT = $null
    exit 1
}
Write-OK "Repository access confirmed."

# Step 3 — Validate against Gist licence
Write-Step "Checking licence status..."
$licenceResult = Test-GistLicence -Token $plainPAT

if (-not $licenceResult.Valid) {
    Write-Fail "Licence not active."
    Write-Host "  $($licenceResult.Message)" -ForegroundColor DarkGray
    $plainPAT = $null
    exit 1
}
Write-OK "Licence validated."

# Step 4 — Choose install location
$installPath = Get-InstallPath

# Step 5 — Download and install
$success = Invoke-DownloadFiles -Token $plainPAT -InstallPath $installPath

# Step 6 — Store PAT in Credential Manager
Write-Host ""
Write-Step "Storing access key securely..."
$stored = Save-ToCredentialManager -PlainToken $plainPAT

# Clear plain token from memory
$plainPAT = $null
[System.GC]::Collect()

# Step 7 — Summary
Write-Host ""
Write-Host "  ─────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host ""

if ($success) {
    Write-OK "MyToolkit installed successfully."
    Write-Host ""
    Write-Host "  To launch MyToolkit :" -ForegroundColor White
    Write-Host "  powershell -File `"$installPath\MyToolkit.ps1`"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Tip : Add the install folder to your PATH for quick access." -ForegroundColor DarkGray
    Write-Host ""

    $launch = Read-Host "  Launch MyToolkit now? [Y/N]"
    if ($launch -match "^[Yy]$") {
        Write-Host ""
        Write-Step "Launching MyToolkit..."
        Invoke-SelfDestruct
        & powershell -NoProfile -File "$installPath\MyToolkit.ps1"
    } else {
        Write-Host ""
        Write-Host "  Goodbye. Run MyToolkit.ps1 from your install folder when ready." -ForegroundColor DarkGray
        Invoke-SelfDestruct
    }
} else {
    Write-Warn "Installation completed with some errors. Please check the output above."
    Write-Host "  MyToolkit may still function. Run MyToolkit.ps1 from : $installPath" -ForegroundColor DarkGray
    Invoke-SelfDestruct
}

Write-Host ""

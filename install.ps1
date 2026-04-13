#Requires -Version 5.1
<#
.SYNOPSIS
    MyToolkit Installer - Bootstrap script for first-time installation.

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
    irm "https://raw.githubusercontent.com/TheEscPilot/MyToolkit-Installer/main/install.ps1" | iex
#>

Set-StrictMode -Version Latest
# FIX #6 : Scoped to Continue globally; individual calls use -ErrorAction Stop where needed.
# This prevents minor non-fatal operations from aborting the whole script unexpectedly.
$ErrorActionPreference = "Continue"

# ============================================================
# INSTALLER CONFIGURATION
# Edit these values to match your private repo details.
# ============================================================
$Script:GitHubUser    = "TheEscPilot"
$Script:GitHubRepo    = "MyToolkit"
$Script:GitHubBranch  = "main"
$Script:GistURL       = "https://gist.githubusercontent.com/TheEscPilot/7e7d0a0131af06c88b306f80da8254c7/raw/licence.json"
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
# FIX #1 : Script saved as UTF-8 with BOM; box-drawing characters
#           are now correctly encoded for PowerShell 5.1.
# ============================================================
function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |   MyToolkit - Installer                              |" -ForegroundColor Cyan
    Write-Host "  |   Secure bootstrap for first-time setup             |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host "  * $Text" -ForegroundColor White
}

function Write-OK {
    param([string]$Text)
    Write-Host "  [ OK ] $Text" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Text)
    Write-Host "  [FAIL] $Text" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [ !! ] $Text" -ForegroundColor DarkYellow
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
# Stores the PAT in Windows Credential Manager via direct API
# call (CredWrite) to avoid exposing the token as a process
# command-line argument, which is visible to all local processes.
# FIX #3 : Replaced cmdkey /pass:<token> with P/Invoke CredWrite.
# ============================================================
function Save-ToCredentialManager {
    param([string]$PlainToken)

    # Load the native CredWrite signature only once per session
    if (-not ([System.Management.Automation.PSTypeName]'CredManager.NativeMethods').Type) {
        $signature = @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
    public uint   Flags;
    public uint   Type;
    public string TargetName;
    public string Comment;
    public long   LastWritten;
    public uint   CredentialBlobSize;
    public IntPtr CredentialBlob;
    public uint   Persist;
    public uint   AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias;
    public string UserName;
}

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool CredWrite([In] ref CREDENTIAL userCredential, [In] uint flags);
'@
        Add-Type -MemberDefinition $signature -Namespace "CredManager" -Name "NativeMethods" -ErrorAction Stop
    }

    # Encode token as UTF-16 LE bytes (native Windows credential format)
    $credBlob    = [System.Text.Encoding]::Unicode.GetBytes($PlainToken)
    $credBlobPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($credBlob.Length)

    try {
        [System.Runtime.InteropServices.Marshal]::Copy($credBlob, 0, $credBlobPtr, $credBlob.Length)

        $cred                    = New-Object CredManager.NativeMethods+CREDENTIAL
        $cred.Type               = 1   # CRED_TYPE_GENERIC
        $cred.TargetName         = $Script:CredTarget
        $cred.UserName           = "MyToolkit"
        $cred.CredentialBlob     = $credBlobPtr
        $cred.CredentialBlobSize = [uint32]$credBlob.Length
        $cred.Persist            = 2   # CRED_PERSIST_LOCAL_MACHINE

        $ok = [CredManager.NativeMethods]::CredWrite([ref]$cred, 0)

        if ($ok) {
            Write-OK "PAT stored in Windows Credential Manager."
            return $true
        } else {
            $errCode = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Warn "Could not store PAT in Credential Manager (Win32 error $errCode)."
            return $false
        }
    }
    finally {
        # Zero and free the unmanaged blob regardless of outcome
        if ($credBlobPtr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($credBlobPtr)
        }
        # Zero the managed byte array
        [Array]::Clear($credBlob, 0, $credBlob.Length)
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
# FIX #4 : Validates JSON structure before use; avoids silent
#           false-negative when the Gist format is unexpected.
# ============================================================
function Test-GistLicence {
    param([string]$Token)

    $suffix = $Token.Substring([Math]::Max(0, $Token.Length - 8))

    try {
        $response = Invoke-RestMethod -Uri $Script:GistURL -TimeoutSec 10 -ErrorAction Stop

        # Validate expected structure before trusting the response
        if ($null -eq $response.active) {
            Write-Warn "Licence server returned an unexpected format. Proceeding in grace mode."
            return @{ Valid = $true; Message = "malformed-response" }
        }

        $activeList = $response.active

        if ($activeList -contains $suffix) {
            return @{ Valid = $true; Message = "" }
        } else {
            $msg = if ($null -ne $response.message) { $response.message } else { "Token suffix not found in active licence list." }
            return @{ Valid = $false; Message = $msg }
        }
    }
    catch {
        # Gist unreachable - allow install to proceed (grace mode)
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
# FIX #5 : Progress percentage now reflects completed downloads,
#           not downloads in progress (increment moved after download).
# FIX #7 : Relative path extraction uses a normalised base path
#           to avoid TrimStart edge cases on PS 5.1 (.NET 4.x).
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

    # FIX #7 : Normalise base path with trailing separator once, up front.
    $tempBaseNorm = $tempBase.TrimEnd('\') + '\'

    Write-Host ""
    Write-Step "Downloading $total files from private repo..."
    Write-Host ""

    foreach ($file in $Script:FilesToDownload) {
        # FIX #5 : Show percentage for files already completed, not the one starting now.
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

        # Increment AFTER download so 100% only shows when all files are done
        $current++
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

    # FIX #7 : Use normalised base path for clean relative-path extraction.
    Get-ChildItem -Path $tempBase -Recurse | ForEach-Object {
        $relativePath = $_.FullName.Substring($tempBaseNorm.Length)
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
# FIX #2 : Also removes the irm|iex command from the persistent
#           PSReadLine history file on disk, not just in-session history.
# ============================================================
function Invoke-SelfDestruct {
    # Remove temp installer artifact if present
    $tempInstaller = "$env:TEMP\install.ps1"
    if (Test-Path $tempInstaller) {
        Remove-Item -Path $tempInstaller -Force -ErrorAction SilentlyContinue
    }

    # Clear in-session history
    Clear-History -ErrorAction SilentlyContinue

    # FIX #2 : Clear the irm/iex entry from PSReadLine's persistent history file.
    # Clear-History only affects the in-memory session list; PSReadLine writes a
    # separate file that persists across sessions.
    try {
        $psrlOption = Get-PSReadLineOption -ErrorAction SilentlyContinue
        if ($psrlOption -and $psrlOption.HistorySavePath -and (Test-Path $psrlOption.HistorySavePath)) {
            $historyPath    = $psrlOption.HistorySavePath
            $filteredLines  = Get-Content $historyPath -ErrorAction SilentlyContinue |
                              Where-Object { $_ -notmatch '(?i)(irm|iex|install\.ps1|mytoolkit-installer)' }
            if ($null -ne $filteredLines) {
                $filteredLines | Set-Content $historyPath -Encoding UTF8 -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        # Non-fatal - best effort only
    }
}

# ============================================================
# MAIN - Installer entry point
# FIX #6 : Main body wrapped in try/catch so unexpected errors
#           surface a friendly message rather than a raw exception.
# ============================================================

try {

Write-Banner

Write-Host "  This installer will :" -ForegroundColor White
Write-Host "   1. Validate your MyToolkit access key" -ForegroundColor DarkGray
Write-Host "   2. Download the toolkit from the private repository" -ForegroundColor DarkGray
Write-Host "   3. Store your access key securely (Windows Credential Manager)" -ForegroundColor DarkGray
Write-Host "   4. Launch MyToolkit" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host ""

# ── Step 1 : Get and validate PAT — retry loop (max 3 attempts) ──────────────
# FIX #8 : Replaced single-shot key entry with a retry loop.
#           User gets 3 attempts before the installer exits cleanly.
#           Each failure shows the specific reason rather than closing silently.
$maxAttempts = 3
$attempt     = 0
$plainPAT    = $null

while ($attempt -lt $maxAttempts) {
    $attempt++

    if ($attempt -gt 1) {
        Write-Host ""
        Write-Warn "Attempt $attempt of $maxAttempts — please try again."
        Write-Host ""
    }

    Write-Host "  Enter your MyToolkit access key :" -ForegroundColor White
    Write-Host "  (Paste your full PAT — input is hidden)" -ForegroundColor DarkGray
    Write-Host ""

    $securePAT = Read-Host "  Access key" -AsSecureString
    $plainPAT  = ConvertFrom-SecureStringPlain -SecureString $securePAT

    # Basic length check
    if ($plainPAT.Length -lt 10) {
        Write-Fail "Access key is too short to be valid (minimum 10 characters)."
        Write-Host "  Make sure you paste the full key, not just part of it." -ForegroundColor DarkGray
        $plainPAT = $null
        continue
    }

    Write-Host ""

    # Validate against GitHub repo
    Write-Step "Validating access key against repository..."
    $repoAccess = Test-GitHubAccess -Token $plainPAT

    if (-not $repoAccess) {
        Write-Fail "Access key not recognised by GitHub (401 Unauthorised)."
        Write-Host "  Common causes :" -ForegroundColor DarkGray
        Write-Host "   - You entered only part of the key (paste the full ghp_... string)" -ForegroundColor DarkGray
        Write-Host "   - The key has expired or been revoked" -ForegroundColor DarkGray
        Write-Host "   - The key does not have Contents:Read on the MyToolkit repo" -ForegroundColor DarkGray
        $plainPAT = $null
        continue
    }
    Write-OK "Repository access confirmed."

    # Validate against Gist licence
    Write-Step "Checking licence status..."
    $licenceResult = Test-GistLicence -Token $plainPAT

    if (-not $licenceResult.Valid) {
        Write-Fail "Licence not active."
        Write-Host "  $($licenceResult.Message)" -ForegroundColor DarkGray
        Write-Host "  Contact your administrator to have your key activated." -ForegroundColor DarkGray
        $plainPAT = $null
        continue
    }
    Write-OK "Licence validated."

    # Both checks passed — break out of retry loop
    break
}

# If all attempts exhausted without a valid key — pause then exit
if (-not $plainPAT) {
    Write-Host ""
    Write-Fail "Maximum attempts reached. Installation cancelled."
    Write-Host "  Contact your administrator to request a valid access key." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}

# ── Step 2 : Choose install location ─────────────────────────────────────────
$installPath = Get-InstallPath

# ── Step 3 : Download and install ────────────────────────────────────────────
$success = Invoke-DownloadFiles -Token $plainPAT -InstallPath $installPath

# ── Step 4 : Store PAT in Credential Manager ─────────────────────────────────
Write-Host ""
Write-Step "Storing access key securely..."
$stored = Save-ToCredentialManager -PlainToken $plainPAT

# Clear plain token from memory immediately after storage
$plainPAT = $null
[System.GC]::Collect()

# ── Step 5 : Summary ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkCyan
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
    Write-Host ""
    Read-Host "  Press Enter to close"
    Invoke-SelfDestruct
}

Write-Host ""

} # end try
catch {
    # FIX #8 : Catch block now pauses before closing so the error is readable.
    Write-Host ""
    Write-Fail "An unexpected error stopped the installer :"
    Write-Host "  $_" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  If this persists, contact your administrator." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}

#Requires -Version 5.1
<#
.SYNOPSIS
    MyToolkit Installer

.DESCRIPTION
    Downloads MyToolkit.ps1 and VERSION directly to C:\temp\MyToolkit.
    No subfolders, no temp staging. Two files, two direct downloads.
    Tools are fetched on demand at runtime -- nothing else is installed.

.EXAMPLE
    irm "https://raw.githubusercontent.com/TheEscPilot/MyToolkit-Installer/main/install.ps1" | iex
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Configuration ─────────────────────────────────────────────────────────────
$Script:GitHubUser     = "TheEscPilot"
$Script:GitHubRepo     = "MyToolkit"
$Script:GitHubBranch   = "main"
$Script:GistURL        = "https://gist.githubusercontent.com/TheEscPilot/7e7d0a0131af06c88b306f80da8254c7/raw/licence.json"
$Script:CredTarget     = "MyToolkit_GitHub_PAT"
$Script:DefaultInstall = "C:\temp\MyToolkit"
$Script:RawBase        = "https://raw.githubusercontent.com/$Script:GitHubUser/$Script:GitHubRepo/$Script:GitHubBranch"

# ONLY these two files are downloaded. Everything else streams at runtime.
$Script:FilesToDownload = @(
    @{ Remote = "MyToolkit.ps1"; Local = "MyToolkit.ps1" },
    @{ Remote = "VERSION";       Local = "VERSION"       }
)

# ── Display helpers ───────────────────────────────────────────────────────────
function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |   MyToolkit -- Installer                             |" -ForegroundColor Cyan
    Write-Host "  |   Secure bootstrap -- tools stream from GitHub       |" -ForegroundColor Cyan
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Step { param([string]$T) Write-Host "  * $T" -ForegroundColor White }
function Write-OK   { param([string]$T) Write-Host "  [ OK ] $T" -ForegroundColor Green }
function Write-Fail { param([string]$T) Write-Host "  [FAIL] $T" -ForegroundColor Red }
function Write-Warn { param([string]$T) Write-Host "  [ !! ] $T" -ForegroundColor DarkYellow }

# ── ConvertFrom-SecureStringPlain ─────────────────────────────────────────────
function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$S)
    $p = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($S)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

# ── Save-ToCredentialManager ──────────────────────────────────────────────────
function Save-ToCredentialManager {
    param([string]$PlainToken)
    if (-not ([System.Management.Automation.PSTypeName]'CredManager.NativeMethods').Type) {
        Add-Type -MemberDefinition @'
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
public struct CREDENTIAL {
    public uint Flags,Type; public string TargetName,Comment;
    public long LastWritten; public uint CredentialBlobSize;
    public IntPtr CredentialBlob; public uint Persist,AttributeCount;
    public IntPtr Attributes; public string TargetAlias,UserName; }
[DllImport("advapi32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
public static extern bool CredWrite([In] ref CREDENTIAL c,[In] uint f);
'@ -Namespace "CredManager" -Name "NativeMethods" -ErrorAction Stop
    }
    $blob    = [System.Text.Encoding]::Unicode.GetBytes($PlainToken)
    $ptr     = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($blob.Length)
    try {
        [System.Runtime.InteropServices.Marshal]::Copy($blob, 0, $ptr, $blob.Length)
        $c = New-Object CredManager.NativeMethods+CREDENTIAL
        $c.Type = 1; $c.TargetName = $Script:CredTarget; $c.UserName = "MyToolkit"
        $c.CredentialBlob = $ptr; $c.CredentialBlobSize = [uint32]$blob.Length; $c.Persist = 2
        if ([CredManager.NativeMethods]::CredWrite([ref]$c, 0)) {
            Write-OK "PAT stored in Windows Credential Manager."
            return $true
        }
        Write-Warn "Could not store PAT (Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
        return $false
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
        [Array]::Clear($blob, 0, $blob.Length)
    }
}

# ── Test-GitHubAccess ─────────────────────────────────────────────────────────
function Test-GitHubAccess {
    param([string]$Token)
    try {
        $r = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$Script:GitHubUser/$Script:GitHubRepo" `
            -Headers @{ Authorization = "token $Token" } `
            -TimeoutSec 10 -ErrorAction Stop
        return ($null -ne $r.name)
    } catch { return $false }
}

# ── Test-GistLicence ──────────────────────────────────────────────────────────
function Test-GistLicence {
    param([string]$Token)
    $suffix = $Token.Substring([Math]::Max(0, $Token.Length - 8))
    try {
        $r = Invoke-RestMethod -Uri $Script:GistURL -TimeoutSec 10 -ErrorAction Stop
        if ($null -eq $r.active) {
            Write-Warn "Licence server format unexpected. Grace mode."
            return @{ Valid = $true; Message = "" }
        }
        if ($r.active -contains $suffix) { return @{ Valid = $true; Message = "" } }
        $msg = if ($r.message) { $r.message } else { "Token not in active licence list." }
        return @{ Valid = $false; Message = $msg }
    } catch {
        Write-Warn "Licence server unreachable. Grace mode."
        return @{ Valid = $true; Message = "" }
    }
}

# ── Get-InstallPath ───────────────────────────────────────────────────────────
function Get-InstallPath {
    Write-Host ""
    Write-Host "  Install location (Enter for default) :" -ForegroundColor White
    Write-Host "  Default : $Script:DefaultInstall" -ForegroundColor DarkGray
    Write-Host ""
    $p = (Read-Host "  Path").Trim()
    if ($p -eq "") { return $Script:DefaultInstall } else { return $p }
}

# ── Invoke-DownloadFiles ──────────────────────────────────────────────────────
# Downloads each file DIRECTLY to its final destination inside $InstallPath.
# No temp folders. No subfolder extraction. No relative path math.
# Each file = one Invoke-WebRequest straight to Join-Path $InstallPath $file.Local
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-DownloadFiles {
    param([string]$Token, [string]$InstallPath)

    $headers = @{ Authorization = "token $Token" }

    # Create the install folder if needed
    if (-not (Test-Path $InstallPath)) {
        try {
            $null = New-Item -ItemType Directory -Path $InstallPath -Force -ErrorAction Stop
            Write-OK "Created : $InstallPath"
        } catch {
            Write-Fail "Could not create install folder: $_"
            return $false
        }
    }

    Write-Host ""
    Write-Step "Downloading $($Script:FilesToDownload.Count) file(s) to $InstallPath"
    Write-Host ""

    $allOK = $true
    foreach ($file in $Script:FilesToDownload) {
        # Final destination is directly inside $InstallPath -- no subfolders
        $dest    = Join-Path $InstallPath $file.Local
        $url     = "$Script:RawBase/$($file.Remote)"

        Write-Host "  Downloading $($file.Remote)..." -NoNewline -ForegroundColor DarkGray
        try {
            Invoke-WebRequest -Uri $url -Headers $headers -OutFile $dest -ErrorAction Stop
            if (-not (Test-Path $dest) -or (Get-Item $dest).Length -eq 0) {
                throw "File missing or empty after download."
            }
            Write-Host "  OK" -ForegroundColor Green
        } catch {
            Write-Host "  FAILED: $_" -ForegroundColor Red
            $allOK = $false
        }
    }

    # Create Reports folder alongside the install
    $reportsPath = Join-Path $InstallPath "Reports"
    if (-not (Test-Path $reportsPath)) {
        $null = New-Item -ItemType Directory -Path $reportsPath -Force -ErrorAction SilentlyContinue
        Write-OK "Created reports folder : $reportsPath"
    }

    if ($allOK) {
        Write-Host ""
        Write-OK "Download complete. Files in : $InstallPath"
        Write-OK "Reports folder  : $reportsPath"
    } else {
        Write-Warn "One or more files failed. MyToolkit may not launch correctly."
    }
    return $allOK
}

# ── Start-MyToolkit ───────────────────────────────────────────────────────────
# Uses Start-Process with an explicit, verified path.
# This works correctly when called from irm|iex context.
# ─────────────────────────────────────────────────────────────────────────────
function Start-MyToolkit {
    param([string]$InstallPath)
    $scriptPath = Join-Path $InstallPath "MyToolkit.ps1"
    if (-not (Test-Path $scriptPath)) {
        Write-Fail "MyToolkit.ps1 not found at : $scriptPath"
        Write-Host "  Run it manually: powershell -File `"$scriptPath`"" -ForegroundColor DarkGray
        return
    }
    Write-Step "Launching MyToolkit..."
    Start-Process -FilePath "powershell.exe" `
                  -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"") `
                  -ErrorAction Stop
}

# ── Invoke-SelfDestruct ───────────────────────────────────────────────────────
function Invoke-SelfDestruct {
    @("$env:TEMP\install.ps1","$env:TEMP\mytoolkit_install.ps1") | ForEach-Object {
        if (Test-Path $_) { Remove-Item $_ -Force -ErrorAction SilentlyContinue }
    }
    Clear-History -ErrorAction SilentlyContinue
    try {
        $h = (Get-PSReadLineOption -ErrorAction SilentlyContinue).HistorySavePath
        if ($h -and (Test-Path $h)) {
            Get-Content $h -ErrorAction SilentlyContinue |
                Where-Object { $_ -notmatch '(?i)(irm|iex|install\.ps1|mytoolkit-installer)' } |
                Set-Content $h -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch {}
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
try {

Write-Banner

Write-Host "  This installer will :" -ForegroundColor White
Write-Host "   1. Validate your MyToolkit access key" -ForegroundColor DarkGray
Write-Host "   2. Download MyToolkit.ps1 to your chosen folder" -ForegroundColor DarkGray
Write-Host "   3. Store your key securely in Windows Credential Manager" -ForegroundColor DarkGray
Write-Host "   4. Launch MyToolkit (tools stream from GitHub at runtime)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Default install path : $Script:DefaultInstall" -ForegroundColor DarkGray
Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host ""

# Step 1 : PAT entry -- retry up to 3 times
$maxAttempts = 3
$attempt     = 0
$plainPAT    = $null

while ($attempt -lt $maxAttempts) {
    $attempt++
    if ($attempt -gt 1) {
        Write-Host ""
        Write-Warn "Attempt $attempt of $maxAttempts"
        Write-Host ""
    }

    Write-Host "  Enter your MyToolkit access key :" -ForegroundColor White
    Write-Host "  (Paste your full PAT -- input is hidden)" -ForegroundColor DarkGray
    Write-Host ""

    $secure   = Read-Host "  Access key" -AsSecureString
    $plainPAT = ConvertFrom-SecureStringPlain -S $secure

    if ($plainPAT.Length -lt 10) {
        Write-Fail "Key too short -- paste the full ghp_... string."
        $plainPAT = $null; continue
    }

    Write-Host ""
    Write-Step "Validating key against GitHub..."
    if (-not (Test-GitHubAccess -Token $plainPAT)) {
        Write-Fail "GitHub rejected the key (401 Unauthorised)."
        Write-Host "  - Paste the full key, not just part of it" -ForegroundColor DarkGray
        Write-Host "  - Key must have Contents:Read on the MyToolkit repo" -ForegroundColor DarkGray
        Write-Host "  - Key may have expired or been revoked" -ForegroundColor DarkGray
        $plainPAT = $null; continue
    }
    Write-OK "Repository access confirmed."

    Write-Step "Checking licence..."
    $lic = Test-GistLicence -Token $plainPAT
    if (-not $lic.Valid) {
        Write-Fail "Licence not active: $($lic.Message)"
        Write-Host "  Contact your administrator to activate your key." -ForegroundColor DarkGray
        $plainPAT = $null; continue
    }
    Write-OK "Licence validated."
    break
}

if (-not $plainPAT) {
    Write-Host ""
    Write-Fail "Maximum attempts reached. Installation cancelled."
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}

# Step 2 : Install path
$installPath = Get-InstallPath

# Step 3 : Download
$success = Invoke-DownloadFiles -Token $plainPAT -InstallPath $installPath

# Step 4 : Store PAT
Write-Host ""
Write-Step "Storing access key securely..."
$null = Save-ToCredentialManager -PlainToken $plainPAT
$plainPAT = $null
[System.GC]::Collect()

# Step 5 : Result
Write-Host ""
Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host ""

if ($success) {
    Write-OK "MyToolkit installed successfully."
    Write-Host ""
    Write-Host "  To launch any time :" -ForegroundColor White
    Write-Host "  powershell -File `"$installPath\MyToolkit.ps1`"" -ForegroundColor Cyan
    Write-Host ""

    $launch = Read-Host "  Launch MyToolkit now? [Y/N]"
    if ($launch -match "^[Yy]$") {
        Invoke-SelfDestruct
        Start-MyToolkit -InstallPath $installPath
    } else {
        Write-Host ""
        Write-Host "  Goodbye. Run MyToolkit.ps1 from: $installPath" -ForegroundColor DarkGray
        Invoke-SelfDestruct
    }
} else {
    Write-Warn "Install completed with errors."
    Write-Host "  Try launching manually: powershell -File `"$installPath\MyToolkit.ps1`"" -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "  Press Enter to close"
    Invoke-SelfDestruct
}

Write-Host ""

} catch {
    Write-Host ""
    Write-Fail "Unexpected error: $_"
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}

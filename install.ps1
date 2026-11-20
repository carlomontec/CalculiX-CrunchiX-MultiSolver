# ==============================================================================
# CalculiX CrunchiX (CCX) Multi-Solver - Windows PowerShell Universal Installer
#
# 1-Liner Usage (from Windows PowerShell or PowerShell 7):
#   irm https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.ps1 | iex
#
# Environment Variables (for 1-liner customization):
#   $env:CCX_REF             = "main"   # Git branch, tag, or commit SHA
#   $env:CCX_SOLVER          = "auto"   # auto | mumps | pardiso | spooles
#   $env:CCX_INSTALL_DIR     = "$env:USERPROFILE\.local\bin"
#   $env:CCX_NON_INTERACTIVE = "1"      # Accept defaults without prompting
#
# Local Usage (from cloned repo):
#   .\install.ps1
#   .\install.ps1 -Solver mumps -NonInteractive
#   .\install.ps1 -Solver pardiso
#   .\install.ps1 -Ref v2.23-json-export
# ==============================================================================

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("auto", "mumps", "pardiso", "spooles")]
    [string]$Solver = $(if ($env:CCX_SOLVER) { $env:CCX_SOLVER } else { "auto" }),

    [Parameter(Mandatory=$false)]
    [string]$InstallDir = $(if ($env:CCX_INSTALL_DIR) { $env:CCX_INSTALL_DIR } else { "$env:USERPROFILE\.local\bin" }),

    [Parameter(Mandatory=$false)]
    [string]$Ref = $(if ($env:CCX_REF) { $env:CCX_REF } else { "main" }),

    [Parameter(Mandatory=$false)]
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
}

if (-not $NonInteractive -and $env:CCX_NON_INTERACTIVE) {
    if ($env:CCX_NON_INTERACTIVE -match '^(1|true|yes|y)$') {
        $NonInteractive = $true
    }
}

$scriptPath = $MyInvocation.MyCommand.Path
$script:IsScriptFile = -not [string]::IsNullOrWhiteSpace($scriptPath)
$scriptDir = if ($script:IsScriptFile) { Split-Path -Parent $scriptPath } else { $null }

# -----------------------------------------------------------------------------
# Console & Error Helpers
# -----------------------------------------------------------------------------
function Write-Header([string]$msg) {
    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host "   $msg" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
}

function Write-Step([string]$msg) {
    Write-Host "`n--> $msg" -ForegroundColor Yellow
}

function Write-Success([string]$msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}

function Write-Warn([string]$msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Magenta
}

function Write-Err([string]$msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
}

function Fail-Install([string]$msg) {
    Write-Err $msg
    if ($script:IsScriptFile -or $NonInteractive) {
        exit 1
    }
    throw $msg
}

function Prompt-Value([string]$promptMsg, [string]$defaultVal) {
    if ($NonInteractive) {
        return $defaultVal
    }
    $val = Read-Host "$promptMsg [$defaultVal]"
    if ([string]::IsNullOrWhiteSpace($val)) {
        return $defaultVal
    }
    return $val.Trim()
}

function Confirm-User([string]$question, [string]$defaultVal = "Y") {
    $hint = if ($defaultVal -match '^[Yy]') { "Y/n" } else { "y/N" }
    if ($NonInteractive) {
        return ($defaultVal -match '^[Yy]')
    }
    $val = Read-Host "$question ($hint)"
    if ([string]::IsNullOrWhiteSpace($val)) {
        $val = $defaultVal
    }
    return ($val.Trim() -match '^[Yy]')
}

function Resolve-NormalizedPath([string]$pathVal) {
    $p = $pathVal.Trim()
    if ($p -eq "~") {
        $p = $env:USERPROFILE
    } elseif ($p -match '^~[\\/]') {
        $p = Join-Path $env:USERPROFILE ($p.Substring(2))
    }
    $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
    if ($p.Length -gt 3) {
        $p = $p.TrimEnd('\', '/')
    }
    return $p
}

function ConvertTo-MsysPath([string]$winPath) {
    $p = $winPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return "/" + $Matches[1].ToLower() + "/" + $Matches[2]
    }
    return $p
}

function Find-MsysRoot {
    $candidates = @()
    if ($env:MSYS2_ROOT) { $candidates += $env:MSYS2_ROOT }
    $candidates += @(
        "C:\msys64",
        "$env:LOCALAPPDATA\Programs\msys64",
        "C:\tools\msys64",
        "D:\msys64"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate "usr\bin\bash.exe"))) {
            return $candidate.TrimEnd('\', '/')
        }
    }
    return $null
}

function Find-MklRoot {
    $candidates = @()
    if ($env:MKLROOT) { $candidates += $env:MKLROOT }
    $candidates += @(
        "C:\Program Files (x86)\Intel\oneAPI\mkl\latest",
        "C:\Program Files\Intel\oneAPI\mkl\latest"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate "include\mkl.h"))) {
            return $candidate.TrimEnd('\', '/')
        }
    }
    return $null
}

function Find-IntelCompilerBin {
    $candidates = @(
        "C:\Program Files (x86)\Intel\oneAPI\compiler\latest\bin",
        "C:\Program Files\Intel\oneAPI\compiler\latest\bin"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate "libiomp5md.dll")) {
            return $candidate
        }
    }
    return $null
}

function Test-PathEntryPresent([string[]]$pathEntries, [string]$targetDir) {
    $normTarget = $targetDir.Trim().TrimEnd('\', '/')
    foreach ($entry in $pathEntries) {
        if ($entry -and ($entry.Trim().TrimEnd('\', '/') -ieq $normTarget)) {
            return $true
        }
    }
    return $false
}

function Get-AllPathEntries {
    $userRaw = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    $machineRaw = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    $entries = @()
    if ($userRaw) { $entries += ($userRaw -split ';') }
    if ($machineRaw) { $entries += ($machineRaw -split ';') }
    return $entries
}

function Add-ToUserPath([string[]]$dirsToAdd) {
    $userRaw = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    $userEntries = @()
    if ($userRaw) {
        $userEntries = @($userRaw -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $added = @()
    foreach ($dir in $dirsToAdd) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        if (-not (Test-PathEntryPresent $userEntries $dir)) {
            $userEntries += $dir
            $added += $dir
        }
        $procEntries = @($env:Path -split ';')
        if (-not (Test-PathEntryPresent $procEntries $dir)) {
            $env:Path = "$dir;$env:Path"
        }
    }
    if ($added.Count -gt 0) {
        $newUserPath = $userEntries -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newUserPath, [EnvironmentVariableTarget]::User)
        foreach ($d in $added) {
            Write-Success "Added $d to User PATH."
        }
        Write-Host "  (Open a new terminal session for User PATH changes to take effect.)" -ForegroundColor Gray
    }
}

function Invoke-MsysBashScript {
    param (
        [Parameter(Mandatory=$true)][string]$ScriptContent,
        [Parameter(Mandatory=$false)][hashtable]$ExtraEnv = @{},
        [Parameter(Mandatory=$false)][switch]$AllowNonZero,
        [Parameter(Mandatory=$false)][switch]$CaptureOutput
    )

    if (-not $script:MsysRoot) {
        Fail-Install "MSYS2 root is not configured."
    }

    $bashExe = Join-Path $script:MsysRoot "usr\bin\bash.exe"
    $tmpScript = Join-Path $env:TEMP ("ccx_msys_" + [System.Guid]::NewGuid().ToString("N") + ".sh")
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpScript, ($ScriptContent -replace "`r`n", "`n") + "`n", $utf8NoBom)

    $savedEnv = @{}
    $envToSet = @{
        "MSYSTEM"        = "UCRT64"
        "CHERE_INVOKING" = "1"
    }
    foreach ($k in $ExtraEnv.Keys) {
        $envToSet[$k] = $ExtraEnv[$k]
    }
    foreach ($k in $envToSet.Keys) {
        $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable($k, $envToSet[$k], [EnvironmentVariableTarget]::Process)
    }

    $prevEap = $ErrorActionPreference
    $captured = $null
    $exitCode = 1
    try {
        $ErrorActionPreference = "Continue"
        $msysScriptArg = $tmpScript -replace '\\', '/'
        if ($CaptureOutput) {
            $captured = & $bashExe -l $msysScriptArg 2>&1
            $exitCode = $LASTEXITCODE
        } else {
            & $bashExe -l $msysScriptArg
            $exitCode = $LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $prevEap
        foreach ($k in $savedEnv.Keys) {
            [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], [EnvironmentVariableTarget]::Process)
        }
        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
    }

    if (-not $AllowNonZero -and $exitCode -ne 0) {
        if ($CaptureOutput -and $captured) {
            $captured | ForEach-Object { Write-Host $_ }
        }
        Fail-Install "MSYS2 command failed with exit code $exitCode."
    }

    if ($CaptureOutput) {
        return $captured
    }
}

# =============================================================================
# Banner & Platform Detection
# =============================================================================
Write-Header "CalculiX CrunchiX (CCX) Multi-Solver - Windows Installer"

if (-not [Environment]::Is64BitOperatingSystem) {
    Fail-Install "CalculiX Multi-Solver requires a 64-bit Windows operating system (x86_64)."
}
Write-Host "Detected Platform: Windows (x86_64 64-bit)" -ForegroundColor Green

$script:MsysRoot = Find-MsysRoot
$detectedMklRoot = Find-MklRoot

$localRepoMode = ($scriptDir -and (Test-Path (Join-Path $scriptDir "CMakeLists.txt")) -and (Test-Path (Join-Path $scriptDir "src")))
if ($localRepoMode) {
    Write-Host "Source Mode      : Local repository ($scriptDir)" -ForegroundColor Cyan
} else {
    Write-Host "Source Mode      : GitHub clone (Ref: $Ref)" -ForegroundColor Cyan
}

if ($script:MsysRoot) {
    Write-Host "MSYS2 Detected   : $script:MsysRoot" -ForegroundColor Green
} else {
    Write-Host "MSYS2 Detected   : Not found (will install automatically)" -ForegroundColor Yellow
}

if ($detectedMklRoot) {
    Write-Host "Intel oneMKL     : Found at $detectedMklRoot" -ForegroundColor Green
}

# =============================================================================
# Phase 1: Ask All Questions Up Front
# =============================================================================
if (-not $PSBoundParameters.ContainsKey("InstallDir") -and -not $env:CCX_INSTALL_DIR) {
    $InstallDir = Prompt-Value "`nInstall directory (executables go here)" $InstallDir
}
$InstallDir = Resolve-NormalizedPath $InstallDir

$doInstallMsys = $false
if (-not $script:MsysRoot) {
    Write-Warn "MSYS2 was not found on your system."
    Write-Host "MSYS2 provides the native open-source GCC/gfortran and UCRT64 toolchain required to compile CalculiX on Windows."
    if (-not (Confirm-User "Would you like to download and install MSYS2 automatically now?" "Y")) {
        Fail-Install "MSYS2 is required to build CalculiX on Windows. Please install MSYS2 from https://www.msys2.org and re-run."
    }
    $doInstallMsys = $true
}

$doUpdatePkgs = Confirm-User "Update MSYS2 and ensure required MinGW-w64 UCRT64 build tools and math packages are installed?" "Y"

Write-Step "Sparse Direct Solver Selection"
Write-Host "  * MUMPS 5.x (Open-Source, MSYS2 UCRT64 package, OpenBLAS)" -ForegroundColor Green
Write-Host "  * Intel oneMKL PARDISO (Optional, proprietary, requires Intel oneMKL)" -ForegroundColor Yellow

$wantMumps = $false
$wantMkl = $false
$wantSpooles = $false

switch ($Solver) {
    "mumps" {
        $wantMumps = $true
    }
    "pardiso" {
        $wantMumps = $true
        $wantMkl = $true
    }
    "spooles" {
        Write-Warn "MSYS2 UCRT64 does not ship a SPOOLES package; this requires SPOOLES_DIR to be set manually."
        $wantSpooles = $true
    }
    default {
        $wantMumps = Confirm-User "Enable MUMPS 5.x as open-source multi-threaded direct solver?" "Y"
        if ($detectedMklRoot) {
            $mklDefault = if ($NonInteractive) { "N" } else { "Y" }
            $wantMkl = Confirm-User "Found Intel oneMKL on your system. Enable Intel oneMKL PARDISO?" $mklDefault
        } else {
            Write-Host "  To install oneMKL: https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl-download.html" -ForegroundColor Cyan
            $wantMkl = Confirm-User "Enable Intel oneMKL PARDISO (requires oneMKL already installed)?" "N"
        }

        if (-not $wantMumps -and -not $wantMkl -and -not $wantSpooles) {
            Write-Host ""
            Write-Warn "No direct sparse solver selected!"
            Write-Host "CalculiX requires at least one direct sparse solver (MUMPS, PARDISO, or SPOOLES) for standard FEA models."
            if (Confirm-User "Would you like to enable MUMPS 5.x (strongly recommended)?" "Y") {
                $wantMumps = $true
            } else {
                Fail-Install "Installation aborted: At least one direct solver must be enabled."
            }
        }
    }
}

if ($wantMkl -and -not $detectedMklRoot) {
    Write-Warn "Intel oneMKL was not detected in MKLROOT or standard Intel oneAPI paths."
    if (-not $wantMumps -and -not $wantSpooles) {
        Fail-Install "PARDISO was requested without MUMPS, and Intel oneMKL was not found."
    }
    Write-Host "  Continuing without PARDISO (MUMPS 5.x will be used)." -ForegroundColor Yellow
    $wantMkl = $false
}

$allPathEntries = Get-AllPathEntries
$needPathInstallDir = -not (Test-PathEntryPresent $allPathEntries $InstallDir)
$mklBinPreview = if ($wantMkl -and $detectedMklRoot) { Join-Path $detectedMklRoot "bin" } else { $null }
$ompBinPreview = if ($wantMkl -and $detectedMklRoot) { Find-IntelCompilerBin } else { $null }
$needPathMkl = (($mklBinPreview -and (Test-Path $mklBinPreview) -and -not (Test-PathEntryPresent $allPathEntries $mklBinPreview)) -or
                ($ompBinPreview -and -not (Test-PathEntryPresent $allPathEntries $ompBinPreview)))

$addPath = $false
if ($needPathInstallDir -or $needPathMkl) {
    if ($needPathInstallDir) {
        $addPath = Confirm-User "Add $InstallDir to your Windows User PATH?" "Y"
    } else {
        $addPath = Confirm-User "Add Intel oneMKL runtime directories to your Windows User PATH (needed for PARDISO)?" "Y"
    }
}

# =============================================================================
# Phase 2: Unattended Installation
# =============================================================================

# -----------------------------------------------------------------------------
# 2a. Install MSYS2 if missing
# -----------------------------------------------------------------------------
if ($doInstallMsys) {
    Write-Step "Installing MSYS2..."
    $hasWinget = (Get-Command winget -ErrorAction SilentlyContinue) -ne $null
    if ($hasWinget) {
        Write-Host "Installing MSYS2 via winget..." -ForegroundColor Cyan
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & winget install MSYS2.MSYS2 --silent --accept-package-agreements --accept-source-agreements
        } finally {
            $ErrorActionPreference = $prevEap
        }
        $script:MsysRoot = Find-MsysRoot
    }

    if (-not $script:MsysRoot) {
        $msysInstallerUrl = "https://github.com/msys2/msys2-installer/releases/latest/download/msys2-x86_64-latest.exe"
        $installerTemp = Join-Path $env:TEMP ("msys2-installer-" + [System.Guid]::NewGuid().ToString("N") + ".exe")
        try {
            Write-Host "Downloading MSYS2 installer from official GitHub release..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $msysInstallerUrl -OutFile $installerTemp -UseBasicParsing
            Write-Host "Running MSYS2 silent installer (installing to C:\msys64)..." -ForegroundColor Cyan
            Start-Process -FilePath $installerTemp -ArgumentList "in", "--confirm-command", "--accept-messages", "--root", "C:\msys64" -Wait -NoNewWindow
        } finally {
            Remove-Item $installerTemp -Force -ErrorAction SilentlyContinue
        }
        $script:MsysRoot = Find-MsysRoot
    }

    if (-not $script:MsysRoot) {
        Fail-Install "Failed to install MSYS2 automatically. Please install MSYS2 from https://www.msys2.org and re-run."
    }
    Write-Success "MSYS2 installed at $script:MsysRoot"
}

# -----------------------------------------------------------------------------
# 2b. MSYS2 System Upgrade & UCRT64 Package Installation
# -----------------------------------------------------------------------------
if ($doUpdatePkgs) {
    Write-Step "Updating MSYS2 and installing MinGW-w64 (UCRT64) build tools & libraries..."

    # Two-pass upgrade: pass 1 updates core runtime/pacman/bash (may exit early to restart MSYS2);
    # pass 2 completes remaining upgrades and resolves package splits (e.g. gcc-libs -> libgcc).
    Write-Host "Synchronizing MSYS2 package database and core runtime..." -ForegroundColor Cyan
    Invoke-MsysBashScript -ScriptContent "pacman -Syu --noconfirm --ask=20" -AllowNonZero

    Write-Host "Completing pending MSYS2 package upgrades..." -ForegroundColor Cyan
    Invoke-MsysBashScript -ScriptContent "pacman -Su --noconfirm --ask=20"

    $requiredPackages = @(
        "git",
        "mingw-w64-ucrt-x86_64-gcc",
        "mingw-w64-ucrt-x86_64-gcc-fortran",
        "mingw-w64-ucrt-x86_64-cmake",
        "mingw-w64-ucrt-x86_64-ninja",
        "mingw-w64-ucrt-x86_64-pkgconf",
        "mingw-w64-ucrt-x86_64-openblas",
        "mingw-w64-ucrt-x86_64-arpack",
        "mingw-w64-ucrt-x86_64-metis",
        "mingw-w64-ucrt-x86_64-scotch"
    )
    if ($wantMumps) {
        $requiredPackages += "mingw-w64-ucrt-x86_64-mumps"
    }

    $pkgListStr = $requiredPackages -join " "
    Write-Host "Installing UCRT64 compiler, linear algebra, and solver packages..." -ForegroundColor Cyan
    Invoke-MsysBashScript -ScriptContent "pacman -S --noconfirm --needed --ask=20 $pkgListStr"
    Write-Success "UCRT64 build tools and libraries verified."
}

# -----------------------------------------------------------------------------
# 2c - 2g. Source Acquisition, Build, Installation, DLL Bundling & Verification
# -----------------------------------------------------------------------------
$tempRoot = Join-Path $env:TEMP ("CalculiX_build_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$buildDir = Join-Path $tempRoot "build"

$builtSolvers = ""
$defaultSolver = "NONE"

try {
    if ($localRepoMode) {
        $sourceDir = $scriptDir
        Write-Step "Using local repository: $sourceDir"
    } else {
        $sourceDir = Join-Path $tempRoot "src"
        Write-Step "Cloning CalculiX-CrunchiX-MultiSolver repository (Ref: $Ref)..."
        $cloneScript = @'
set -e
DEST_DIR="$(cygpath -u "$CCX_DEST_WIN")"
REPO_URL="https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver.git"
if [ "$CCX_REF" = "main" ]; then
    git clone --depth 1 "$REPO_URL" "$DEST_DIR"
elif ! git clone --depth 1 --branch "$CCX_REF" "$REPO_URL" "$DEST_DIR" 2>/dev/null; then
    rm -rf "$DEST_DIR"
    git clone "$REPO_URL" "$DEST_DIR"
    git -C "$DEST_DIR" checkout "$CCX_REF"
fi
'@
        Invoke-MsysBashScript -ScriptContent $cloneScript -ExtraEnv @{
            "CCX_DEST_WIN" = $sourceDir
            "CCX_REF"      = $Ref
        }
    }

    # Build CMake flags explicitly
    $onOff = { param([bool]$b) if ($b) { "ON" } else { "OFF" } }
    $cmakeFlags = @(
        "-DCCX_SOLVERS_STRICT=OFF",
        "-DCCX_USE_ACCELERATE=OFF",
        "-DCCX_USE_ARPACK=ON",
        "-DCCX_USE_MUMPS=$(& $onOff $wantMumps)",
        "-DCCX_USE_PARDISO=$(& $onOff $wantMkl)",
        "-DCCX_USE_SPOOLES=$(& $onOff $wantSpooles)"
    )
    if (-not $wantMkl) {
        $cmakeFlags += "-DCCX_BLAS=OPENBLAS"
    }
    $cmakeFlagsStr = $cmakeFlags -join " "

    Write-Step "Configuring CalculiX with CMake + Ninja..."
    $configureScript = @'
set -e
SRC_DIR="$(cygpath -u "$CCX_SRC_WIN")"
BLD_DIR="$(cygpath -u "$CCX_BUILD_WIN")"
if [ -n "${CCX_MKL_WIN:-}" ]; then
    export MKLROOT="$(cygpath -m "$CCX_MKL_WIN")"
else
    unset MKLROOT
fi
cmake -S "$SRC_DIR" -B "$BLD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/ucrt64 \
    $CCX_CMAKE_FLAGS
'@
    $cfgEnv = @{
        "CCX_SRC_WIN"     = $sourceDir
        "CCX_BUILD_WIN"   = $buildDir
        "CCX_CMAKE_FLAGS" = $cmakeFlagsStr
        "CCX_MKL_WIN"     = $(if ($wantMkl -and $detectedMklRoot) { $detectedMklRoot } else { "" })
    }
    Invoke-MsysBashScript -ScriptContent $configureScript -ExtraEnv $cfgEnv

    # Fail-fast barrier via ccx_solvers.txt
    $solversFile = Join-Path $buildDir "ccx_solvers.txt"
    if (Test-Path $solversFile) {
        $lines = Get-Content -Path $solversFile
        if ($lines.Count -ge 1 -and $lines[0]) { $builtSolvers = $lines[0].Trim() }
        if ($lines.Count -ge 2 -and $lines[1]) { $defaultSolver = $lines[1].Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($builtSolvers) -or ($defaultSolver -eq "NONE")) {
        Fail-Install "No sparse direct solver was enabled by CMake (MUMPS/PARDISO/SPOOLES). Refusing to compile a non-functional CalculiX binary."
    }

    Write-Step "Compiling CalculiX..."
    $buildScript = @'
set -e
BLD_DIR="$(cygpath -u "$CCX_BUILD_WIN")"
if [ -n "${CCX_MKL_WIN:-}" ]; then
    export MKLROOT="$(cygpath -m "$CCX_MKL_WIN")"
else
    unset MKLROOT
fi
cmake --build "$BLD_DIR" --parallel
'@
    Invoke-MsysBashScript -ScriptContent $buildScript -ExtraEnv $cfgEnv

    $builtExe = Join-Path $buildDir "CalculiX.exe"
    if (-not (Test-Path $builtExe)) {
        Fail-Install "Build failed: $builtExe was not generated."
    }
    Write-Success "CalculiX.exe built successfully!"

    # -------------------------------------------------------------------------
    # Install Binaries & Dynamically Bundle Required UCRT64 DLLs
    # -------------------------------------------------------------------------
    Write-Step "Installing executables and runtime DLLs to $InstallDir..."
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $installedCcx = Join-Path $InstallDir "ccx.exe"
    $installedCalculiX = Join-Path $InstallDir "CalculiX.exe"
    Copy-Item -Path $builtExe -Destination $installedCalculiX -Force
    Copy-Item -Path $builtExe -Destination $installedCcx -Force
    Write-Success "Installed: $installedCalculiX"
    Write-Success "Installed: $installedCcx"

    $bfsScript = @'
set -e
EXE_PATH="$(cygpath -u "$CCX_EXE_WIN")"
declare -A seen
queue=("$EXE_PATH")
while [ ${#queue[@]} -gt 0 ]; do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")
    while IFS= read -r dll; do
        [ -n "$dll" ] || continue
        if [ -z "${seen[$dll]+x}" ]; then
            seen[$dll]=1
            if [ -f "/ucrt64/bin/$dll" ]; then
                echo "$dll"
                queue+=("/ucrt64/bin/$dll")
            fi
        fi
    done < <(objdump -p "$cur" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p' | tr -d '\r')
done | sort
'@
    $dllLines = Invoke-MsysBashScript -ScriptContent $bfsScript -ExtraEnv @{ "CCX_EXE_WIN" = $installedCcx } -CaptureOutput
    $ucrtBin = Join-Path $script:MsysRoot "ucrt64\bin"
    $copiedDlls = @()
    foreach ($line in $dllLines) {
        $dllName = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($dllName)) { continue }
        $srcDll = Join-Path $ucrtBin $dllName
        if (Test-Path $srcDll) {
            Copy-Item -Path $srcDll -Destination $InstallDir -Force
            $copiedDlls += $dllName
        }
    }
    if ($copiedDlls.Count -eq 0) {
        Fail-Install "Failed to discover UCRT64 runtime DLL dependencies for $installedCcx."
    }
    Write-Success "Bundled $($copiedDlls.Count) UCRT64 runtime DLLs: $($copiedDlls -join ', ')"

    # -------------------------------------------------------------------------
    # PATH Configuration (and MKL runtime PATH when PARDISO is built)
    # -------------------------------------------------------------------------
    $builtList = @($builtSolvers -split ',' | Where-Object { $_ })
    $mklRuntimeDirs = @()
    if ($builtList -contains "PARDISO") {
        if ($detectedMklRoot) {
            $mklBin = Join-Path $detectedMklRoot "bin"
            if (Test-Path $mklBin) { $mklRuntimeDirs += $mklBin }
        }
        $ompBin = Find-IntelCompilerBin
        if ($ompBin) { $mklRuntimeDirs += $ompBin }
    }

    if ($addPath) {
        $dirsForUserPath = @($InstallDir) + $mklRuntimeDirs
        Add-ToUserPath $dirsForUserPath
    }

    # -------------------------------------------------------------------------
    # Standalone Verification Test (with MSYS2 stripped from PATH)
    # -------------------------------------------------------------------------
    Write-Step "Running standalone verification test (achtel2.inp)..."
    $deckSrc = Join-Path $sourceDir "test\achtel2.inp"
    if (-not (Test-Path $deckSrc)) {
        Write-Warn "Verification deck not found at $deckSrc; skipping."
    } else {
        $verifyDir = Join-Path $tempRoot "verify"
        New-Item -ItemType Directory -Path $verifyDir -Force | Out-Null
        Copy-Item -Path $deckSrc -Destination (Join-Path $verifyDir "achtel2.inp") -Force

        $stdoutLog = Join-Path $verifyDir "verify.out"
        $stderrLog = Join-Path $verifyDir "verify.err"

        $savedProcPath = $env:Path
        try {
            $msysEscaped = [regex]::Escape($script:MsysRoot)
            $cleanPathParts = @($env:Path -split ';' | Where-Object { $_ -and ($_ -notmatch "^$msysEscaped") })
            $prepDirs = @($InstallDir) + $mklRuntimeDirs
            $env:Path = ($prepDirs + $cleanPathParts) -join ';'

            $proc = Start-Process -FilePath $installedCcx `
                -ArgumentList "achtel2" `
                -WorkingDirectory $verifyDir `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $stdoutLog `
                -RedirectStandardError $stderrLog
        } finally {
            $env:Path = $savedProcPath
        }

        $datFile = Join-Path $verifyDir "achtel2.dat"
        $jobFinished = (Test-Path $stdoutLog) -and (Select-String -Path $stdoutLog -Pattern "Job finished" -SimpleMatch -Quiet)

        if (($proc.ExitCode -ne 0) -or -not (Test-Path $datFile) -or -not $jobFinished) {
            $hexCode = ("0x{0:X8}" -f ($proc.ExitCode -band 0xFFFFFFFF))
            Write-Err "Standalone verification failed (exit code: $($proc.ExitCode) / $hexCode)."
            if (Test-Path $stdoutLog) {
                Write-Host "--- stdout (tail) ---" -ForegroundColor Gray
                Get-Content $stdoutLog -Tail 20 | ForEach-Object { Write-Host $_ }
            }
            if (Test-Path $stderrLog) {
                $errContent = Get-Content $stderrLog -Raw
                if (-not [string]::IsNullOrWhiteSpace($errContent)) {
                    Write-Host "--- stderr ---" -ForegroundColor Gray
                    Write-Host $errContent
                }
            }
            Fail-Install "Standalone verification test failed for $installedCcx."
        }
        Write-Success "Verification test passed (achtel2.inp solved successfully)!"
    }
} finally {
    if (Test-Path $tempRoot) {
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# Summary
# =============================================================================
$builtList = @($builtSolvers -split ',' | Where-Object { $_ })
$defaultDesc = switch ($defaultSolver) {
    "PARDISO" { "Intel oneMKL PARDISO (x86_64 AVX2/AVX-512)" }
    "MUMPS"   { "MUMPS 5.x (Open-Source Multi-Threaded)" }
    "SPOOLES" { "SPOOLES 2.2 (Classic Built-in)" }
    default   { $defaultSolver }
}

Write-Header "CalculiX CrunchiX (CCX) Installed Successfully!"
Write-Host "Install directory   : $InstallDir" -ForegroundColor Cyan
Write-Host "Direct solvers built: $builtSolvers" -ForegroundColor Green
Write-Host "Default solver      : $defaultDesc" -ForegroundColor Cyan
Write-Host "                      (used automatically whenever an input deck omits 'SOLVER=')" -ForegroundColor Gray

if ($wantMumps -and ($builtList -notcontains "MUMPS")) {
    Write-Warn "MUMPS was requested but could not be enabled (see CMake output above)."
}
if ($wantMkl -and ($builtList -notcontains "PARDISO")) {
    Write-Warn "PARDISO was requested but could not be enabled (see CMake output above)."
}
if ($wantSpooles -and ($builtList -notcontains "SPOOLES")) {
    Write-Warn "SPOOLES was requested but could not be enabled (see CMake output above)."
}

if (($builtList -contains "PARDISO") -and (-not $addPath) -and ($mklRuntimeDirs.Count -gt 0)) {
    $missingRuntime = @($mklRuntimeDirs | Where-Object { -not (Test-PathEntryPresent (Get-AllPathEntries) $_) })
    if ($missingRuntime.Count -gt 0) {
        Write-Warn "Intel oneMKL runtime dirs are not in PATH; run Intel setvars.bat or add: $($missingRuntime -join '; ')"
    }
}

Write-Host "`nTo run a simulation from any Command Prompt or PowerShell:" -ForegroundColor Green
Write-Host "   ccx input_deck_name       (without .inp extension)" -ForegroundColor Cyan
Write-Host "   CalculiX input_deck_name" -ForegroundColor Cyan

if ($builtList.Count -gt 1) {
    Write-Host "`nSelecting Alternative Solvers in Your Input Decks (*.inp):" -ForegroundColor Yellow
    if ($builtList -contains "MUMPS") {
        Write-Host "  *STATIC, SOLVER=MUMPS       -> MUMPS 5.x (Open-Source Multi-Threaded)" -ForegroundColor White
    }
    if ($builtList -contains "PARDISO") {
        Write-Host "  *STATIC, SOLVER=PARDISO     -> Intel oneMKL PARDISO (x86_64 AVX2/AVX-512)" -ForegroundColor White
    }
    if ($builtList -contains "SPOOLES") {
        Write-Host "  *STATIC, SOLVER=SPOOLES     -> SPOOLES 2.2 (Classic Built-in)" -ForegroundColor White
    }
}

Write-Host "`nSee README.md for complete solver benchmarks and documentation." -ForegroundColor Gray
Write-Host "================================================================`n" -ForegroundColor Cyan

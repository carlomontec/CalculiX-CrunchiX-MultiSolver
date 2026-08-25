# ==============================================================================
# CalculiX CrunchiX (CCX) Multi-Solver - Windows PowerShell Universal Installer
#
# 1-Liner Usage (from PowerShell as User):
#   irm https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.ps1 | iex
#
# Local Usage (from cloned repo):
#   .\install.ps1
#
# Options:
#   .\install.ps1 -Solver mumps -NonInteractive
#   .\install.ps1 -Solver pardiso
#   .\install.ps1 -Solver spooles
# ==============================================================================

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("auto", "mumps", "pardiso", "spooles")]
    [string]$Solver = "auto",

    [Parameter(Mandatory=$false)]
    [string]$InstallDir = "$env:USERPROFILE\.local\bin",

    [Parameter(Mandatory=$false)]
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

# Helper for formatted console messages
function Write-Header($msg) {
    Write-Host "`n================================================================" -ForegroundColor Cyan
    Write-Host "   $msg" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
}

function Write-Step($msg) {
    Write-Host "`n--> $msg" -ForegroundColor Yellow
}

function Write-Success($msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Magenta
}

function Write-Err($msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
}

function Prompt-User($promptMsg, $defaultVal = "Y") {
    if ($NonInteractive) {
        return $defaultVal
    }
    $val = Read-Host "$promptMsg [$defaultVal]"
    if ([string]::IsNullOrWhiteSpace($val)) {
        return $defaultVal
    }
    return $val
}

Write-Header "CalculiX CrunchiX (CCX) Multi-Solver - Windows Installer"

# -----------------------------------------------------------------------------
# 1. Architecture Check
# -----------------------------------------------------------------------------
$is64Bit = [Environment]::Is64BitOperatingSystem
if (-not $is64Bit) {
    Write-Err "CalculiX Multi-Solver requires a 64-bit Windows operating system (x86_64)."
    exit 1
}
Write-Host "Detected Platform: Windows (x86_64 64-bit)" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. MSYS2 Detection & Auto-Installation
# -----------------------------------------------------------------------------
Write-Step "Checking for MSYS2 MinGW-w64 environment..."

$msysCandidates = @(
    "C:\msys64",
    "$env:LOCALAPPDATA\Programs\msys64",
    "C:\tools\msys64",
    "D:\msys64"
)

$msysRoot = $null
foreach ($path in $msysCandidates) {
    if (Test-Path "$path\usr\bin\bash.exe") {
        $msysRoot = $path
        break
    }
}

if (-not $msysRoot) {
    Write-Warn "MSYS2 was not found on your system."
    Write-Host "MSYS2 provides the native open-source GCC/gfortran and UCRT64 toolchain required to compile CalculiX on Windows."
    
    $installMsys = Prompt-User "Would you like to download and install MSYS2 automatically now? (Y/n)" "Y"
    if ($installMsys -notmatch "^[Yy]$") {
        Write-Err "MSYS2 is required to build CalculiX on Windows. Please install MSYS2 from https://www.msys2.org and re-run this script."
        exit 1
    }

    # Attempt winget first
    $hasWinget = (Get-Command winget -ErrorAction SilentlyContinue) -ne $null
    if ($hasWinget) {
        Write-Host "Installing MSYS2 via Windows Package Manager (winget)..." -ForegroundColor Cyan
        & winget install MSYS2.MSYS2 --silent --accept-package-agreements --accept-source-agreements
        if (Test-Path "C:\msys64\usr\bin\bash.exe") {
            $msysRoot = "C:\msys64"
        }
    }

    # Fallback to direct official installer
    if (-not $msysRoot) {
        $msysInstallerUrl = "https://github.com/msys2/msys2-installer/releases/latest/download/msys2-x86_64-latest.exe"
        $installerTemp = "$env:TEMP\msys2-installer.exe"
        Write-Host "Downloading MSYS2 installer from official GitHub release..." -ForegroundColor Cyan
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $msysInstallerUrl -OutFile $installerTemp -UseBasicParsing
        
        Write-Host "Running MSYS2 silent installer (installing to C:\msys64)..." -ForegroundColor Cyan
        Start-Process -FilePath $installerTemp -ArgumentList "in", "--confirm-command", "--accept-messages", "--root", "C:\msys64" -Wait -NoNewWindow
        Remove-Item $installerTemp -Force -ErrorAction SilentlyContinue

        if (Test-Path "C:\msys64\usr\bin\bash.exe") {
            $msysRoot = "C:\msys64"
        }
    }

    if (-not $msysRoot) {
        Write-Err "Failed to automatically install MSYS2. Please install MSYS2 manually from https://www.msys2.org."
        exit 1
    }
    Write-Success "MSYS2 successfully installed at $msysRoot"
} else {
    Write-Success "Found MSYS2 at $msysRoot"
}

# Helper to run bash commands inside MSYS2 UCRT64 environment
function Invoke-MsysBash($cmd) {
    $bashExe = "$msysRoot\usr\bin\bash.exe"
    $env:MSYSTEM = "UCRT64"
    $env:CHERE_INVOKING = "1"
    & $bashExe -l -c "$cmd"
    if ($LASTEXITCODE -ne 0) {
        throw "MSYS2 command failed with exit code ${LASTEXITCODE}: $cmd"
    }
}

# -----------------------------------------------------------------------------
# 3. MinGW-w64 UCRT64 Dependencies Check
# -----------------------------------------------------------------------------
Write-Step "Checking MinGW-w64 (UCRT64) build tools & libraries..."

$requiredPackages = @(
    "git", 
    "mingw-w64-ucrt-x86_64-gcc",
    "mingw-w64-ucrt-x86_64-gcc-fortran",
    "mingw-w64-ucrt-x86_64-cmake",
    "mingw-w64-ucrt-x86_64-ninja",
    "mingw-w64-ucrt-x86_64-openblas",
    "mingw-w64-ucrt-x86_64-arpack",
    "mingw-w64-ucrt-x86_64-mumps",
    "mingw-w64-ucrt-x86_64-metis",
    "mingw-w64-ucrt-x86_64-scotch"
)

$pkgListStr = $requiredPackages -join " "
$installPkgs = Prompt-User "Ensure required MinGW-w64 compiler, MUMPS solver, and math packages are installed via pacman? (Y/n)" "Y"
if ($installPkgs -match "^[Yy]$") {
    Write-Host "Updating pacman and installing packages (including MUMPS 5.x)..." -ForegroundColor Cyan
    Invoke-MsysBash "pacman -Sy --noconfirm --needed $pkgListStr"
    Write-Success "Core build tools, linear algebra, and MUMPS 5.x libraries verified."
}

# Check for AMD CPU architecture
$isAmd = ($env:PROCESSOR_IDENTIFIER -match "AMD") -or 
         ((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Manufacturer -match "AMD")

if ($isAmd) {
    Write-Host "`nAMD Zen CPU Architecture Detected (Ryzen/EPYC/Threadripper):" -ForegroundColor Cyan
    Write-Host "  AMD provides AOCL-BLIS (open-source linear algebra tuned for AMD CPUs)."
    Write-Host "  Learn more: https://www.amd.com/en/developer/aocl.html" -ForegroundColor Cyan
    $useAocl = Prompt-User "Would you like to install and enable AMD BLIS via MSYS2 pacman? (Y/n)" "Y"
    if ($useAocl -match "^[Yy]$") {
        Write-Host "Installing AMD BLIS linear algebra library..." -ForegroundColor Cyan
        Invoke-MsysBash "pacman -S --noconfirm --needed mingw-w64-ucrt-x86_64-blis"
        Write-Success "AMD BLIS package installed."
    }
}

# -----------------------------------------------------------------------------
# 4. Solver Backend Selection
# -----------------------------------------------------------------------------
Write-Step "Configuring Sparse Direct Solvers on Windows."
Write-Host "`nCalculiX Direct Solver Configuration:" -ForegroundColor Cyan
Write-Host "  * Primary Open-Source Solver: MUMPS 5.x (installed via MSYS2)" -ForegroundColor Green

Write-Host "`nIntel oneMKL PARDISO Solver Option:" -ForegroundColor Yellow
Write-Host "  Intel oneMKL is proprietary (not open-source), but generally provides"
Write-Host "  higher performance on Intel and AMD x86_64 CPUs with AVX2/AVX-512 acceleration."
Write-Host "  Learn more: https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl.html" -ForegroundColor Cyan
Write-Host "  (MUMPS 5.x remains fully available as open-source Option B in any case)."

$enableMkl = "N"
if ($Solver -eq "pardiso") {
    $enableMkl = "Y"
} elseif ($Solver -eq "mumps") {
    $enableMkl = "N"
} else {
    $enableMkl = Prompt-User "Would you like to enable Intel oneMKL PARDISO? (y/N)" "N"
}

$cmakeSolverFlags = ""
$solverDisplayName = ""

if ($enableMkl -match "^[Yy]$") {
    $defaultMklPath = "C:\Program Files (x86)\Intel\oneAPI\mkl\latest"
    
    # Auto-set the environment variable if the folder exists but the var is missing
    if (($env:MKLROOT -eq $null) -and (Test-Path $defaultMklPath)) {
        Write-Host "Auto-configuring MKLROOT environment variable..." -ForegroundColor Cyan
        [Environment]::SetEnvironmentVariable("MKLROOT", $defaultMklPath, [EnvironmentVariableTarget]::User)
        $env:MKLROOT = $defaultMklPath
    }

    # Now check if we successfully have MKL
    $hasMkl = ($env:MKLROOT -ne $null) -or (Test-Path "$msysRoot\ucrt64\include\mkl.h")
    
    if ($hasMkl) {
        $cmakeSolverFlags = "-DCCX_USE_PARDISO=ON -DCCX_USE_MUMPS=ON"
        $solverDisplayName = "Intel oneMKL PARDISO + MUMPS 5.x"
        Write-Success "Intel oneMKL successfully detected and configured!"
    } else {
        Write-Warn "Intel oneMKL was not detected in standard paths or MKLROOT."
        Write-Host "To use oneMKL on Windows, install Intel oneAPI Base Toolkit or oneMKL from:" -ForegroundColor Yellow
        Write-Host "  https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl-download.html" -ForegroundColor Cyan
        Write-Host "Falling back to MUMPS 5.x as primary solver for this build." -ForegroundColor Yellow
        $cmakeSolverFlags = "-DCCX_USE_MUMPS=ON"
        $solverDisplayName = "MUMPS 5.x (Open-Source Default)"
    }

    # Give the user time to read the MKL status before compiling
    if (-not $NonInteractive) {
        Write-Host ""
        Read-Host "Press Enter to continue..."
    }

} else {
    $cmakeSolverFlags = "-DCCX_USE_MUMPS=ON"
    $solverDisplayName = "MUMPS 5.x (Open-Source Default)"
}

Write-Success "Configured Solver Backends: $solverDisplayName"

# -----------------------------------------------------------------------------
# 5. Clone Repository or Use Local Source
# -----------------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue
$sourceDir = $null
$isTempClone = $false

if ($scriptDir -and (Test-Path "$scriptDir\CMakeLists.txt") -and (Test-Path "$scriptDir\src")) {
    $sourceDir = $scriptDir
    Write-Host "Building from local repository: $sourceDir" -ForegroundColor Cyan
} else {
    $tempDir = "$env:TEMP\CalculiX_build_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Write-Step "Cloning CalculiX-CrunchiX-MultiSolver repository..."
    Invoke-MsysBash "git clone --depth 1 https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver.git '$(($tempDir -replace '\\','/'))/ccx'"
    $sourceDir = "$tempDir\ccx"
    $isTempClone = $true
}

# Convert Windows path to MSYS path (e.g. C:\foo -> /c/foo)
$sourceDirMsys = $sourceDir -replace "^([A-Za-z]):", '/$1' -replace "\\", "/"
$sourceDirMsys = $sourceDirMsys.Substring(0,1).ToLower() + $sourceDirMsys.Substring(1)

# -----------------------------------------------------------------------------
# 6. Configure & Build via CMake inside MSYS2 UCRT64
# -----------------------------------------------------------------------------
Write-Step "Configuring and compiling CalculiX CrunchiX with Ninja..."

# Convert Windows path to POSIX forward slashes for MSYS2/CMake
$mklRootPosix = $env:MKLROOT -replace "\\", "/"

# Export the variable directly inside the MSYS2 subshell
$buildCmd = "export MKLROOT='$mklRootPosix' && cd '$sourceDirMsys' && rm -rf build && cmake -B build -G Ninja $cmakeSolverFlags && cmake --build build"
Invoke-MsysBash $buildCmd

$builtExe = "$sourceDir\build\CalculiX.exe"
if (-not (Test-Path $builtExe)) {
    Write-Err "Build failed: $builtExe was not generated."
    exit 1
}
Write-Success "CalculiX.exe built successfully!"

# -----------------------------------------------------------------------------
# 7. Installation & PATH Setup
# -----------------------------------------------------------------------------
Write-Step "Installing executables to $InstallDir..."

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Copy-Item -Path $builtExe -Destination "$InstallDir\CalculiX.exe" -Force
Copy-Item -Path $builtExe -Destination "$InstallDir\ccx.exe" -Force

Write-Success "Installed: $InstallDir\CalculiX.exe"
Write-Success "Installed: $InstallDir\ccx.exe"

# Copy required runtime DLLs from UCRT64 bin to InstallDir so ccx.exe runs standalone from CMD/PowerShell
Write-Host "Copying UCRT64 runtime libraries for standalone execution..." -ForegroundColor Cyan
$ucrtBin = "$msysRoot\ucrt64\bin"
$runtimeDlls = @(
    "libgfortran-*.dll",
    "libquadmath-*.dll",
    "libgcc_s_seh-*.dll",
    "libwinpthread-*.dll",
    "libgomp-*.dll",
    "libopenblas.dll",
    "libarpack-*.dll",
    "libdmumps*.dll",
    "libmumps_common*.dll",
    "libpord*.dll",
    "libmetis*.dll",
    "libscotch*.dll"
)

foreach ($pattern in $runtimeDlls) {
    Get-ChildItem -Path $ucrtBin -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $InstallDir -Force -ErrorAction SilentlyContinue
    }
}

# Check and update Windows User PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
if ($userPath -split ";" -notcontains $InstallDir) {
    Write-Warn "$InstallDir is not in your Windows User PATH."
    $addPath = Prompt-User "Add $InstallDir to your Windows User PATH environment variable? (Y/n)" "Y"
    if ($addPath -match "^[Yy]$") {
        $newPath = "$userPath;$InstallDir"
        [Environment]::SetEnvironmentVariable("Path", $newPath, [EnvironmentVariableTarget]::User)
        $env:Path = "$env:Path;$InstallDir"
        Write-Success "Added $InstallDir to User PATH. (Open a new terminal session for changes to take full effect)."
    }
}

# -----------------------------------------------------------------------------
# 8. Quick Verification Test
# -----------------------------------------------------------------------------
Write-Step "Running quick verification test (achtel2.inp)..."

$testDir = "$sourceDir\test"
if (Test-Path "$testDir\achtel2.inp") {
    Push-Location $testDir
    try {
        & "$InstallDir\ccx.exe" achtel2 | Out-Null
        if (Test-Path "achtel2.dat") {
            Write-Success "Verification test passed (achtel2.inp solved successfully)!"
            Remove-Item achtel2.dat, achtel2.frd, achtel2.sta, achtel2.cvg -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warn "Verification test finished without creating output dat file."
        }
    } catch {
        Write-Warn "Verification test execution encountered an error: $_"
    } finally {
        Pop-Location
    }
}

# Cleanup temporary clone if used
if ($isTempClone -and (Test-Path $tempDir)) {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Header "CalculiX CrunchiX (CCX) Installed Successfully!"
Write-Host "To run a simulation from any Command Prompt or PowerShell:" -ForegroundColor Green
Write-Host "   ccx input_deck_name       (without .inp extension)" -ForegroundColor Cyan
Write-Host "   CalculiX input_deck_name" -ForegroundColor Cyan
Write-Host "`nSelecting Solvers in Your Input Decks (*.inp):" -ForegroundColor Yellow
Write-Host "  *STATIC, SOLVER=MUMPS       -> MUMPS 5.x (Open-Source Multi-Threaded)" -ForegroundColor White
Write-Host "  *STATIC, SOLVER=PARDISO     -> Intel oneMKL PARDISO (x86_64 AVX-512)" -ForegroundColor White
Write-Host "  *STATIC, SOLVER=SPOOLES     -> SPOOLES 2.2 (Classic Built-in)" -ForegroundColor White
Write-Host "`nSee README.md for complete solver benchmarks and documentation." -ForegroundColor Gray
Write-Host "================================================================`n" -ForegroundColor Cyan


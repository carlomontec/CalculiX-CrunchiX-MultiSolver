# ==============================================================================
# CalculiX CrunchiX (CCX) Multi-Solver - Windows PowerShell Universal Installer
#
# 1-Liner Usage (from Windows PowerShell or PowerShell 7):
#   irm https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.ps1 | iex
#
# Actions (asked in a menu, or given with -Action / $env:CCX_ACTION):
#   1) stable        Build the latest stable release, optimized for this computer [default]
#   2) binary        Download the latest stable prebuilt binary (portable, SHA-256 checked)
#   3) edge          Build the bleeding edge ('main'), installed as 'ccx_dev'
#   4) uninstall     Remove what this installer installed
#   check-update     Compare the installed versions with the latest ones, then exit
#
# Environment Variables (for 1-liner customization):
#   $env:CCX_ACTION          = "stable" # stable | binary | edge | uninstall | check-update
#   $env:CCX_REF             = ""       # Build this branch, tag or commit instead
#   $env:CCX_SOLVER          = "auto"   # auto | mumps | pardiso | spooles
#   $env:CCX_INSTALL_DIR     = "$env:USERPROFILE\.local\bin"
#   $env:CCX_NON_INTERACTIVE = "1"      # Accept defaults without prompting
#
# Local Usage (from a cloned repo):
#   .\install.ps1
#   .\install.ps1 -Action edge
#   .\install.ps1 -Action check-update
#   .\install.ps1 -Local -Solver mumps -NonInteractive   # build this checkout
#   .\install.ps1 -Ref v2.24-multisolver-0.2
# ==============================================================================
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("stable", "binary", "edge", "uninstall", "check-update")]
    [string]$Action = $(if ($env:CCX_ACTION) { $env:CCX_ACTION } else { "" }),

    [Parameter(Mandatory=$false)]
    [ValidateSet("auto", "mumps", "pardiso", "spooles")]
    [string]$Solver = $(if ($env:CCX_SOLVER) { $env:CCX_SOLVER } else { "auto" }),

    [Parameter(Mandatory=$false)]
    [string]$InstallDir = $(if ($env:CCX_INSTALL_DIR) { $env:CCX_INSTALL_DIR } else { "$env:USERPROFILE\.local\bin" }),

    [Parameter(Mandatory=$false)]
    [string]$Ref = $(if ($env:CCX_REF) { $env:CCX_REF } else { "" }),

    [Parameter(Mandatory=$false)]
    [switch]$Local,

    [Parameter(Mandatory=$false)]
    [switch]$Portable,

    [Parameter(Mandatory=$false)]
    [switch]$Force,

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
# Releases, Manifests, Uninstall and Update Check
# =============================================================================
$script:Repo = "carlomontec/CalculiX-CrunchiX-MultiSolver"
$script:RepoUrl = "https://github.com/$($script:Repo).git"
$script:ApiUrl = "https://api.github.com/repos/$($script:Repo)"
$script:Platform = "windows-x86_64"
$script:DataDir = Join-Path $env:LOCALAPPDATA "ccx-multisolver"      # manifests + source/build cache
$script:CacheDir = Join-Path $script:DataDir "cache"

function Get-StableTag {
    try {
        $rel = Invoke-RestMethod -Uri "$($script:ApiUrl)/releases/latest" -UseBasicParsing -TimeoutSec 15
        return [string]$rel.tag_name
    } catch {
        return ""
    }
}

function Get-EdgeSha {
    try {
        $c = Invoke-RestMethod -Uri "$($script:ApiUrl)/commits/main" -UseBasicParsing -TimeoutSec 15
        return ([string]$c.sha).Substring(0, 7)
    } catch {
        return ""
    }
}

function Get-ReleaseAssetUrl([string]$tag, [string]$name) {
    return "https://github.com/$($script:Repo)/releases/download/$tag/$name"
}

function Test-BinaryAvailable([string]$tag) {
    if (-not $tag) { return $false }
    try {
        Invoke-WebRequest -Uri (Get-ReleaseAssetUrl $tag "ccx-$($script:Platform).zip") -Method Head -UseBasicParsing -TimeoutSec 15 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-ManifestPath([string]$channel) {
    return Join-Path $script:DataDir "manifest-$channel.txt"
}

function Read-Manifest([string]$channel) {
    $path = Get-ManifestPath $channel
    if (-not (Test-Path $path)) { return $null }
    $m = @{ files = @(); path_dirs = @() }
    foreach ($line in (Get-Content -Path $path)) {
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $line.Substring(0, $i); $v = $line.Substring($i + 1)
        if ($k -eq "file") { $m.files += $v }
        elseif ($k -eq "path_dir") { $m.path_dirs += $v }
        elseif (-not $m.ContainsKey($k)) { $m[$k] = $v }
    }
    return $m
}

function Write-Manifest([string]$channel, [hashtable]$info, [string[]]$files, [string[]]$pathDirs) {
    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    $lines = @("channel=$channel")
    foreach ($k in @("method", "version", "ref", "commit", "solvers", "default_solver", "native", "prefix")) {
        $lines += "$k=$($info[$k])"
    }
    $lines += "date=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    foreach ($d in $pathDirs) { if ($d) { $lines += "path_dir=$d" } }
    foreach ($f in $files) { if ($f) { $lines += "file=$f" } }
    Set-Content -Path (Get-ManifestPath $channel) -Value $lines -Encoding UTF8
}

# 'ccx -v' prints "MultiSolver edition <x>" and "Direct solvers: A,B (default: A)"
function Get-CcxInfo([string]$exe) {
    $r = @{ edition = ""; solvers = ""; default = "" }
    if (-not (Test-Path $exe)) { return $r }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = & $exe -v 2>&1 | ForEach-Object { [string]$_ }
    } catch {
        $out = @()
    } finally {
        $ErrorActionPreference = $prevEap
    }
    foreach ($line in $out) {
        if ($line -match '^MultiSolver edition (\S+)') { $r.edition = $Matches[1] }
        if ($line -match '^Direct solvers: (.*) \(default: (\w+)\)') { $r.solvers = $Matches[1]; $r.default = $Matches[2] }
    }
    return $r
}

function Get-SolverDesc([string]$s) {
    switch ($s) {
        "ACCELERATE" { "Apple Accelerate (macOS Hardware)" }
        "PARDISO"    { "Intel oneMKL PARDISO (x86_64 AVX2/AVX-512)" }
        "MUMPS"      { "MUMPS 5.x (Open-Source Multi-Threaded)" }
        "SPOOLES"    { "SPOOLES 2.2 (Classic Built-in)" }
        default      { $s }
    }
}

function Show-SolverPlan([string]$solvers, [string]$default) {
    Write-Step "Direct solvers"
    Write-Host "  Solvers          : $($solvers -replace ',', ', ')"
    Write-Host "  Default solver   : $(Get-SolverDesc $default)" -ForegroundColor Green
    Write-Host "                     used when a deck has no SOLVER= on *STATIC, *FREQUENCY, ..." -ForegroundColor Gray
    Write-Host "  Order            : Accelerate > PARDISO > MUMPS > SPOOLES (fixed when ccx is compiled)" -ForegroundColor Gray
    Write-Host "  Choose per deck  : e.g. *STATIC, SOLVER=MUMPS" -ForegroundColor Gray
}

function Remove-FromUserPath([string[]]$dirs) {
    $userRaw = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    if (-not $userRaw) { return }
    $entries = @($userRaw -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $kept = @($entries | Where-Object { -not (Test-PathEntryPresent $dirs $_) })
    if ($kept.Count -ne $entries.Count) {
        [Environment]::SetEnvironmentVariable("Path", ($kept -join ';'), [EnvironmentVariableTarget]::User)
        foreach ($d in $dirs) { Write-Success "Removed $d from User PATH." }
    }
}

function Invoke-Uninstall([string]$fallbackDir) {
    Write-Step "Uninstall"
    $files = @(); $pathDirs = @(); $manifests = @()
    foreach ($ch in @("stable", "edge")) {
        $m = Read-Manifest $ch
        if ($m) {
            $manifests += (Get-ManifestPath $ch)
            $files += $m.files
            $pathDirs += $m.path_dirs
            Write-Host "  $($ch): $($m.version) ($($m.method), $($m.prefix))"
        }
    }
    if ($manifests.Count -eq 0) {
        foreach ($n in @("CalculiX.exe", "ccx.exe", "ccx_dev.exe")) {
            $p = Join-Path $fallbackDir $n
            if (Test-Path $p) { $files += $p }
        }
        if ($files.Count -eq 0) {
            Write-Host "Nothing to uninstall (no manifest in $($script:DataDir), no ccx in $fallbackDir)."
            Write-Host "Installed somewhere else? Run again with -Action uninstall -InstallDir <dir>."
            return
        }
        Write-Warn "No installer manifest found; these files look like a previous install (runtime DLLs next to them are left in place)."
    }

    $files = @($files | Select-Object -Unique)
    $pathDirs = @($pathDirs | Select-Object -Unique)
    Write-Host "`nWill remove:"
    foreach ($f in @($files | Where-Object { $_ -notmatch '\.dll$' })) { Write-Host "  $f" }
    $dllCount = @($files | Where-Object { $_ -match '\.dll$' }).Count
    if ($dllCount -gt 0) { Write-Host "  $dllCount runtime DLLs (kept if other programs remain in their folder)" }
    foreach ($d in $pathDirs) { Write-Host "  User PATH entry $d (kept if other programs remain there)" }
    if (Test-Path $script:CacheDir) { Write-Host "  build cache $($script:CacheDir)" }

    if (-not $Force -and -not $NonInteractive) {
        if (-not (Confirm-User "Uninstall CalculiX MultiSolver?" "N")) { Write-Host "Cancelled."; return }
    }
    # Runtime DLLs are shared with other programs in the same folder (e.g. CalculiX GraphiX):
    # remove them only when no other executable is left there.
    $exes = @($files | Where-Object { $_ -notmatch '\.dll$' })
    $dlls = @($files | Where-Object { $_ -match '\.dll$' })
    foreach ($f in $exes) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
    $keptDlls = 0
    foreach ($dir in @($dlls | ForEach-Object { Split-Path -Parent $_ } | Select-Object -Unique)) {
        $others = @(Get-ChildItem -Path $dir -Filter "*.exe" -ErrorAction SilentlyContinue)
        $here = @($dlls | Where-Object { (Split-Path -Parent $_) -eq $dir })
        if ($others.Count -eq 0) {
            foreach ($f in $here) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
        } else {
            $keptDlls += $here.Count
            Write-Host "  Kept $($here.Count) runtime DLLs in $dir; other programs there may use them ($(($others | Select-Object -ExpandProperty Name) -join ', '))." -ForegroundColor Gray
        }
    }
    # Only drop the PATH entry when the folder holds nothing else
    $pathDirs = @($pathDirs | Where-Object { -not (Test-Path $_) -or -not (Get-ChildItem -Path $_ -Filter "*.exe" -ErrorAction SilentlyContinue) })
    if ($pathDirs.Count -gt 0) { Remove-FromUserPath $pathDirs }
    Remove-Item -Path $script:CacheDir -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($m in $manifests) { Remove-Item -Path $m -Force -ErrorAction SilentlyContinue }
    if ((Test-Path $script:DataDir) -and -not (Get-ChildItem $script:DataDir)) { Remove-Item $script:DataDir -Force }
    Write-Success "CalculiX MultiSolver removed."
    Write-Host "MSYS2, its packages and Intel oneMKL were left in place; remove them separately if nothing else needs them." -ForegroundColor Gray
}

# True if release $a is newer than $b (v2.24-multisolver-0.2 style)
function ConvertTo-ReleaseVersion([string]$v) {
    if ($v -match '(\d+)\.(\d+)-multisolver-(\d+)\.(\d+)') {
        return [version]("{0}.{1}.{2}.{3}" -f $Matches[1], $Matches[2], $Matches[3], $Matches[4])
    }
    return $null
}

function Test-VersionNewer([string]$a, [string]$b) {
    $va = ConvertTo-ReleaseVersion $a
    $vb = ConvertTo-ReleaseVersion $b
    if ($va -and $vb) { return ($va -gt $vb) }
    return ($a -ne $b)
}

function Invoke-CheckUpdate {
    Write-Step "Checking for updates"
    $tag = Get-StableTag
    $sha = Get-EdgeSha
    Write-Host "  Latest stable release : $(if ($tag) { $tag } else { 'unknown (offline?)' })"
    Write-Host "  Bleeding edge (main)  : $(if ($sha) { $sha } else { 'unknown' })`n"
    $found = $false
    $m = Read-Manifest "stable"
    if ($m) {
        $found = $true
        if ($tag -and (Test-VersionNewer $tag $m.version)) {
            Write-Host "  ccx     : $($m.version) ($($m.ref)) -> update available: $tag" -ForegroundColor Yellow
            Write-Host "            re-run the installer and choose 1 (or: -Action stable)"
        } else {
            Write-Host "  ccx     : $($m.version) ($($m.ref)) up to date" -ForegroundColor Green
        }
    }
    $m = Read-Manifest "edge"
    if ($m) {
        $found = $true
        $c = if ($m.commit.Length -ge 7) { $m.commit.Substring(0, 7) } else { $m.commit }
        if ($sha -and ($c -ne $sha)) {
            Write-Host "  ccx_dev : main @ $c -> newer main: $sha" -ForegroundColor Yellow
            Write-Host "            re-run the installer and choose 3 (or: -Action edge)"
        } else {
            Write-Host "  ccx_dev : main @ $c up to date" -ForegroundColor Green
        }
    }
    if (-not $found) {
        $cmd = Get-Command ccx -ErrorAction SilentlyContinue
        if ($cmd) {
            $ci = Get-CcxInfo $cmd.Source
            Write-Host "  ccx at $($cmd.Source): $(if ($ci.edition) { $ci.edition } else { 'unknown version' }) (no installer manifest)."
            Write-Host "  Latest stable is $(if ($tag) { $tag } else { 'unknown' })."
        } else {
            Write-Host "  No CalculiX MultiSolver installation found."
        }
    }
}
# =============================================================================
# Banner & Platform Detection
# =============================================================================
Write-Host ''
Write-Host '  ____  ____ __  __ ' -ForegroundColor Cyan
Write-Host ' / ___|/ ___|\ \/ / ' -ForegroundColor Cyan
Write-Host '| |   | |     \  /  ' -ForegroundColor Cyan
Write-Host '| |___| |___  /  \  ' -ForegroundColor Cyan
Write-Host ' \____|\____|/_/\_\ ' -ForegroundColor Cyan
Write-Header "CalculiX CrunchiX (CCX) Multi-Solver - Windows Installer"

if (-not [Environment]::Is64BitOperatingSystem) {
    Fail-Install "CalculiX Multi-Solver requires a 64-bit Windows operating system (x86_64)."
}
Write-Host "Detected Platform: Windows (x86_64 64-bit)" -ForegroundColor Green

if ($Action -and ($Action -notin @("stable", "binary", "edge", "uninstall", "check-update"))) {
    Fail-Install "Unknown action '$Action' (stable | binary | edge | uninstall | check-update)."
}
if ($Ref -and $Local) {
    Fail-Install "Use either -Ref or -Local, not both."
}
# An explicit ref or a local checkout means a source build of that code
if ($Ref -or $Local) {
    if (-not $Action) { $Action = "stable" }
    if ($Action -notin @("stable", "edge")) {
        Fail-Install "-Ref/-Local only apply to source builds (-Action stable or edge)."
    }
}

if ($Action -eq "check-update") {
    Invoke-CheckUpdate
    if ($script:IsScriptFile) { exit 0 }
    return
}

$isCheckout = ($scriptDir -and (Test-Path (Join-Path $scriptDir "CMakeLists.txt")) -and (Test-Path (Join-Path $scriptDir "src")))
if ($Local -and -not $isCheckout) {
    Fail-Install "-Local: this script is not inside a CalculiX MultiSolver checkout."
}

# Keep stable and bleeding edge side by side in the directory used before
$existingDir = $null
foreach ($ch in @("stable", "edge")) {
    $m = Read-Manifest $ch
    if ($m -and $m.prefix) { $existingDir = $m.prefix; break }
}
$installDirGiven = $PSBoundParameters.ContainsKey("InstallDir") -or $env:CCX_INSTALL_DIR
if ($existingDir -and -not $installDirGiven) { $InstallDir = $existingDir }

$stableTag = ""
$edgeSha = ""
$binaryAvailable = $false
if (-not $Action) {
    $stableTag = Get-StableTag
    $edgeSha = Get-EdgeSha
    $binaryAvailable = Test-BinaryAvailable $stableTag
    if ($isCheckout) {
        Write-Host "[INFO] Running from a checkout; use -Local to build this checkout instead." -ForegroundColor Cyan
    }
    $stableLbl = if ($stableTag) { $stableTag } else { "latest release" }
    $edgeLbl = if ($edgeSha) { "main @ $edgeSha" } else { "main" }
    Write-Host "`nChoose action:" -ForegroundColor Cyan
    Write-Host "  1) Build latest stable ($stableLbl, optimized for this computer) " -NoNewline
    Write-Host "[Default]" -ForegroundColor Green
    Write-Host "  2) Download latest stable binary ($stableLbl, prebuilt, portable)" -NoNewline
    if ($binaryAvailable) { Write-Host "" } else { Write-Host " (not available for $($script:Platform) yet)" -ForegroundColor Yellow }
    Write-Host "  3) Build bleeding edge ($edgeLbl) -> installed as 'ccx_dev'"
    Write-Host "  4) Uninstall"
    $choice = Prompt-Value "Select [1/2/3/4]" "1"
    switch ($choice) {
        "1" { $Action = "stable" }
        "2" { $Action = "binary" }
        "3" { $Action = "edge" }
        "4" { $Action = "uninstall" }
        default { Fail-Install "Invalid selection: $choice" }
    }
} elseif ($Action -eq "stable" -and -not $Ref -and -not $Local) {
    $stableTag = Get-StableTag
} elseif ($Action -eq "binary") {
    $stableTag = Get-StableTag
    $binaryAvailable = Test-BinaryAvailable $stableTag
}

if ($Action -eq "uninstall") {
    Invoke-Uninstall (Resolve-NormalizedPath $InstallDir)
    if ($script:IsScriptFile) { exit 0 }
    return
}

$isBinary = ($Action -eq "binary")
$channel = if ($Action -eq "edge") { "edge" } else { "stable" }
$exeName = if ($channel -eq "edge") { "ccx_dev.exe" } else { "ccx.exe" }

if ($isBinary -and -not $binaryAvailable) {
    Fail-Install "No prebuilt binary for $($script:Platform) in release $(if ($stableTag) { $stableTag } else { '?' }) yet. Choose 1 (build latest stable) instead."
}
if ($channel -eq "stable" -and -not $isBinary -and -not $Ref -and -not $Local -and -not $stableTag) {
    Fail-Install "Could not find the latest stable release (no network?). Use -Ref <tag> or -Action edge."
}
$sourceRef = if ($Ref) { $Ref } elseif ($channel -eq "edge") { "main" } else { $stableTag }

$script:MsysRoot = Find-MsysRoot
$detectedMklRoot = Find-MklRoot

if ($isBinary) {
    Write-Host "Source Mode      : Prebuilt binary ($stableTag)" -ForegroundColor Cyan
} elseif ($Local) {
    Write-Host "Source Mode      : Local repository ($scriptDir)" -ForegroundColor Cyan
} else {
    Write-Host "Source Mode      : GitHub ($sourceRef), cached in $($script:CacheDir)" -ForegroundColor Cyan
}

if (-not $isBinary) {
    if ($script:MsysRoot) {
        Write-Host "MSYS2 Detected   : $script:MsysRoot" -ForegroundColor Green
    } else {
        Write-Host "MSYS2 Detected   : Not found (will install automatically)" -ForegroundColor Yellow
    }
    if ($detectedMklRoot) {
        Write-Host "Intel oneMKL     : Found at $detectedMklRoot" -ForegroundColor Green
    }
}
# =============================================================================
# Phase 1: Ask All Questions Up Front
# =============================================================================
if (-not $installDirGiven -and -not $existingDir) {
    $InstallDir = Prompt-Value "`nInstall directory (executables go here)" $InstallDir
}
$InstallDir = Resolve-NormalizedPath $InstallDir

# Existing installation of the same channel: replace / cancel / uninstall
$existing = Read-Manifest $channel
$existingDesc = $null
if ($existing) {
    $existingDesc = "$($existing.version) ($($existing.method), $(Join-Path $existing.prefix $exeName))"
} elseif (Test-Path (Join-Path $InstallDir $exeName)) {
    $existingDesc = "$(Join-Path $InstallDir $exeName) (installed without a manifest)"
}
if ($existingDesc) {
    Write-Host "`nExisting installation found: $existingDesc" -ForegroundColor Yellow
    if (-not $Force -and -not $NonInteractive) {
        $answer = Prompt-Value "Replace it, cancel, or uninstall? (Y=replace, n=cancel, u=uninstall)" "Y"
        if ($answer -match '^[Uu]') { Invoke-Uninstall $InstallDir; if ($script:IsScriptFile) { exit 0 }; return }
        if ($answer -notmatch '^[Yy]') { Write-Host "Cancelled."; if ($script:IsScriptFile) { exit 0 }; return }
    }
}

$doInstallMsys = $false
$doUpdatePkgs = $false
$wantMumps = $false
$wantMkl = $false
$wantSpooles = $false

if ($isBinary) {
    $metaText = ""
    try {
        $metaText = [string](Invoke-WebRequest -Uri (Get-ReleaseAssetUrl $stableTag "ccx-$($script:Platform).solvers.txt") -UseBasicParsing -TimeoutSec 15).Content
    } catch { }
    $metaLines = @($metaText -split "`r?`n" | Where-Object { $_ })
    if ($metaLines.Count -ge 2) { Show-SolverPlan $metaLines[0] $metaLines[1] }
    Write-Host "  Prebuilt binaries are portable (not tuned for this CPU) and include only" -ForegroundColor Yellow
    Write-Host "  freely redistributable solvers. For PARDISO, SPOOLES or CPU tuning, choose 1." -ForegroundColor Yellow
} else {
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


    $plannedList = @()
    if ($wantMkl) { $plannedList += "PARDISO" }
    if ($wantMumps) { $plannedList += "MUMPS" }
    if ($wantSpooles) { $plannedList += "SPOOLES" }
    $plannedDefault = if ($plannedList.Count -gt 0) { $plannedList[0] } else { "NONE" }
    Show-SolverPlan ($plannedList -join ",") $plannedDefault
    if (-not $Portable) {
        Write-Host "  CPU tuning       : on (-march=native; use -Portable to switch off)" -ForegroundColor Gray
    }
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

if (-not (Confirm-User "`nProceed?" "Y")) {
    Write-Host "Cancelled."
    if ($script:IsScriptFile) { exit 0 }
    return
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
    $installedFiles = @()
    $installedRef = ""
    $installedCommit = ""
    if ($isBinary) {
        # ---------------------------------------------------------------------
        # Prebuilt binary from the latest release, checked against SHA256SUMS.txt
        # ---------------------------------------------------------------------
        $asset = "ccx-$($script:Platform).zip"
        $zipPath = Join-Path $tempRoot $asset
        $sumsPath = Join-Path $tempRoot "SHA256SUMS.txt"
        Write-Step "Downloading $asset ($stableTag)..."
        Invoke-WebRequest -Uri (Get-ReleaseAssetUrl $stableTag $asset) -OutFile $zipPath -UseBasicParsing
        try {
            Invoke-WebRequest -Uri (Get-ReleaseAssetUrl $stableTag "SHA256SUMS.txt") -OutFile $sumsPath -UseBasicParsing
        } catch {
            Fail-Install "SHA256SUMS.txt is missing from release $stableTag; refusing to install an unchecked binary."
        }
        $expected = $null
        foreach ($line in (Get-Content $sumsPath)) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2 -and ($parts[1].TrimStart('*') -eq $asset)) { $expected = $parts[0].ToLower(); break }
        }
        if (-not $expected) { Fail-Install "$asset is not listed in SHA256SUMS.txt." }
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) { Fail-Install "SHA-256 mismatch for $asset (expected $expected, got $actual)." }
        Write-Success "SHA-256 verified."

        $extractDir = Join-Path $tempRoot "bin"
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        $exeSrc = Get-ChildItem -Path $extractDir -Recurse -Include "ccx.exe", "CalculiX.exe" | Select-Object -First 1
        if (-not $exeSrc) { Fail-Install "No ccx.exe found in $asset." }

        Write-Step "Installing executables and runtime DLLs to $InstallDir..."
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        $installedCcx = Join-Path $InstallDir "ccx.exe"
        $installedCalculiX = Join-Path $InstallDir "CalculiX.exe"
        Copy-Item -Path $exeSrc.FullName -Destination $installedCcx -Force
        Copy-Item -Path $exeSrc.FullName -Destination $installedCalculiX -Force
        $installedFiles = @($installedCcx, $installedCalculiX)
        foreach ($dll in (Get-ChildItem -Path $exeSrc.DirectoryName -Filter "*.dll")) {
            Copy-Item -Path $dll.FullName -Destination $InstallDir -Force
            $installedFiles += (Join-Path $InstallDir $dll.Name)
        }
        Write-Success "Installed: $installedCcx (and CalculiX.exe, $($installedFiles.Count - 2) DLLs)"
        $info = Get-CcxInfo $installedCcx
        $builtSolvers = $info.solvers
        $defaultSolver = $info.default
        $installMethod = "binary"
        $installedNative = "0"
        $installedRef = $stableTag
        $sourceDir = $null
        $mklRuntimeDirs = @()
    } else {
        if ($Local) {
            $sourceDir = $scriptDir
            $buildDir = Join-Path $tempRoot "build"
            Write-Step "Using local repository: $sourceDir"
            $installedRef = "local"
        } else {
            # Cached checkout: rebuilds only fetch what changed and compile incrementally
            $sourceDir = Join-Path $script:CacheDir "src"
            $buildDir = Join-Path $script:CacheDir "build-$channel"
            New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
            Write-Step "Fetching CalculiX-CrunchiX-MultiSolver ($sourceRef) into $sourceDir..."
            $fetchScript = @'
set -e
SRC="$(cygpath -u "$CCX_SRC_WIN")"
URL="https://github.com/carlomontec/CalculiX-CrunchiX-MultiSolver.git"
if [ -d "$SRC/.git" ] && git -C "$SRC" fetch --tags --force --prune origin; then
    :
else
    rm -rf "$SRC"
    git clone --filter=blob:none "$URL" "$SRC"
fi
if git -C "$SRC" rev-parse --verify -q "refs/remotes/origin/$CCX_REF" >/dev/null; then
    TARGET="origin/$CCX_REF"
elif git -C "$SRC" rev-parse --verify -q "$CCX_REF^{commit}" >/dev/null; then
    TARGET="$CCX_REF"
else
    git -C "$SRC" fetch origin "$CCX_REF"
    TARGET="FETCH_HEAD"
fi
git -C "$SRC" checkout --quiet --force --detach "$TARGET"
git -C "$SRC" clean -fdxq
'@
            Invoke-MsysBashScript -ScriptContent $fetchScript -ExtraEnv @{
                "CCX_SRC_WIN" = $sourceDir
                "CCX_REF"     = $sourceRef
            }
            $installedRef = $sourceRef
        }
        $commitOut = Invoke-MsysBashScript -ScriptContent 'git -C "$(cygpath -u "$CCX_SRC_WIN")" rev-parse HEAD' -ExtraEnv @{ "CCX_SRC_WIN" = $sourceDir } -CaptureOutput -AllowNonZero
        $installedCommit = ([string](@($commitOut) | Select-Object -Last 1)).Trim()
    if ($installedCommit -notmatch '^[0-9a-f]{40}$') { $installedCommit = "unknown" }

        # Build CMake flags explicitly
        $onOff = { param([bool]$b) if ($b) { "ON" } else { "OFF" } }
        $cmakeFlags = @(
            "-DCCX_SOLVERS_STRICT=OFF",
            "-DCCX_USE_ACCELERATE=OFF",
            "-DCCX_USE_ARPACK=ON",
            "-DCCX_USE_MUMPS=$(& $onOff $wantMumps)",
            "-DCCX_USE_PARDISO=$(& $onOff $wantMkl)",
            "-DCCX_USE_SPOOLES=$(& $onOff $wantSpooles)",
            "-DCCX_NATIVE=$(& $onOff (-not $Portable))"
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

        $installedCcx = Join-Path $InstallDir $exeName
        Copy-Item -Path $builtExe -Destination $installedCcx -Force
        Write-Success "Installed: $installedCcx"
        $installedFiles = @($installedCcx)
        if ($channel -eq "stable") {
            $installedCalculiX = Join-Path $InstallDir "CalculiX.exe"
            Copy-Item -Path $builtExe -Destination $installedCalculiX -Force
            Write-Success "Installed: $installedCalculiX"
            $installedFiles += $installedCalculiX
        }

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
        $installedFiles += @($copiedDlls | ForEach-Object { Join-Path $InstallDir $_ })
        $installMethod = "source"
        # Native only if this source knows CCX_NATIVE and the compiler accepted the flag
        $cacheFile = Join-Path $buildDir "CMakeCache.txt"
        $installedNative = if (-not $Portable -and (Test-Path $cacheFile) -and (Select-String -Path $cacheFile -Pattern '^CCX_C_HAS_NATIVE:INTERNAL=1' -Quiet)) { "1" } else { "0" }
    }

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

    $pathDirsAdded = @()
    if ($addPath) {
        $dirsForUserPath = @($InstallDir) + $mklRuntimeDirs
        $pathBefore = Get-AllPathEntries
        $pathDirsAdded = @($dirsForUserPath | Where-Object { $_ -and -not (Test-PathEntryPresent $pathBefore $_) })
        Add-ToUserPath $dirsForUserPath
    }

    # -------------------------------------------------------------------------
    # Manifest (used by -Action uninstall and -Action check-update)
    # -------------------------------------------------------------------------
    $ccxInfo = Get-CcxInfo $installedCcx
    $installedVersion = if ($ccxInfo.edition) { $ccxInfo.edition } else { $installedRef }
    $prevManifest = Read-Manifest $channel
    if ($prevManifest) { $pathDirsAdded = @($pathDirsAdded + $prevManifest.path_dirs | Select-Object -Unique) }
    Write-Manifest $channel @{
        method = $installMethod; version = $installedVersion; ref = $installedRef; commit = $installedCommit
        solvers = $builtSolvers; default_solver = $defaultSolver; native = $installedNative; prefix = $InstallDir
    } $installedFiles $pathDirsAdded

    # -------------------------------------------------------------------------
    # Standalone Verification Test (with MSYS2 stripped from PATH)
    # -------------------------------------------------------------------------
    Write-Step "Running standalone verification test (achtel2.inp)..."
    $deckSrc = if ($sourceDir) { Join-Path $sourceDir "test\achtel2.inp" } else { Join-Path $tempRoot "achtel2.inp" }
    if (-not $sourceDir) {
        try {
            $deckRef = if ($installedRef) { $installedRef } else { "main" }
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$($script:Repo)/$deckRef/test/achtel2.inp" -OutFile $deckSrc -UseBasicParsing -TimeoutSec 30
        } catch { }
    }
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
$defaultDesc = Get-SolverDesc $defaultSolver
$tuning = if ($installedNative -eq "1") { ", optimized for this computer" } else { "" }

Write-Header "CalculiX CrunchiX (CCX) Installed Successfully!"
Write-Host "Version             : $installedVersion ($installMethod$tuning)" -ForegroundColor Cyan
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
Write-Host "   $($exeName -replace '\.exe$', '') input_deck_name       (without .inp extension)" -ForegroundColor Cyan

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

Write-Host "`nCheck for updates : .\install.ps1 -Action check-update" -ForegroundColor Gray
Write-Host "Uninstall         : .\install.ps1 -Action uninstall" -ForegroundColor Gray
Write-Host "================================================================`n" -ForegroundColor Cyan

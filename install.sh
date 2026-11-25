#!/usr/bin/env bash
# ==============================================================================
# CalculiX CrunchiX (CCX) Multi-Solver — Universal Installer (macOS / Linux)
#
# 1-LINER USAGE:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
#
# ACTIONS (asked in a menu, or given as a flag):
#   1) --stable      Build the latest stable release, optimized for this computer [default]
#   2) --binary      Download the latest stable prebuilt binary (portable, SHA-256 checked)
#   3) --edge        Build the bleeding edge ('main'), installed as 'ccx_dev'
#   4) --uninstall   Remove what this installer installed
#   --check-update   Compare the installed versions with the latest ones, then exit
#
#   Design: all questions are asked first, then the installation runs
#   unattended. Library detection is done by CMake (CCX_SOLVERS_STRICT=OFF turns
#   a missing optional solver into a warning; the solvers actually built are
#   reported at the end).
#
# OTHER OPTIONS:
#   -b, --ref, --branch, --tag <ref>   Build this git branch, tag or commit (env: CCX_REF)
#   --local                            Build the checkout this script lives in
#   --prefix <dir>                     Install prefix; binaries go to <dir>/bin (default: ~/.local)
#   --portable                         Source builds without -march/-mcpu=native
#   -y, --yes, --non-interactive       Accept all defaults without prompting (env: NON_INTERACTIVE=1)
#   -f, --force                        Replace an existing installation without asking
#   -j, --jobs <n>                     Parallel build jobs (default: all cores)
#   -h, --help                         Show this help
# ==============================================================================

set -Eeo pipefail

REPO="carlomontec/CalculiX-CrunchiX-MultiSolver"
GITHUB_REPO_URL="https://github.com/${REPO}.git"
GITHUB_API_URL="https://api.github.com/repos/${REPO}"
RELEASE_TAG_PATTERN='v*-multisolver-*'

# Where the installer keeps its own state
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ccx-multisolver"   # manifests
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ccx-multisolver"         # source + build cache
PATH_MARKER="# CalculiX Multi-Solver (added by install.sh)"

# Color formatting
BOLD="\033[1m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
MAGENTA="\033[1;35m"
NC="\033[0m"

info()  { echo -e "${BOLD}${CYAN}--> $*${NC}"; }
ok()    { echo -e "${GREEN}[OK] $*${NC}"; }
warn()  { echo -e "${YELLOW}Warning: $*${NC}"; }
die()   { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

TEMP_ROOT=""
cleanup() {
    if [ -n "$TEMP_ROOT" ] && [ -d "$TEMP_ROOT" ]; then
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT
trap 'echo -e "${RED}Installation failed near line ${LINENO} (exit code $?).${NC}" >&2' ERR

# -----------------------------------------------------------------------------
# Prompt helpers
# -----------------------------------------------------------------------------
NON_INTERACTIVE="${NON_INTERACTIVE:-}"

# Prints prompt and stores the answer (or default) in the variable named by $3.
ask_value() {
    local prompt_msg="$1" default_val="$2" var_name="$3" input_val=""
    if [ -z "$NON_INTERACTIVE" ]; then
        if [ -t 0 ]; then
            read -r -p "$prompt_msg" input_val || true
        elif { : < /dev/tty; } 2>/dev/null; then
            read -r -p "$prompt_msg" input_val < /dev/tty || true
        fi
    fi
    printf -v "$var_name" '%s' "${input_val:-$default_val}"
}

# confirm "question" Y|N  -> returns 0 for yes, 1 for no
confirm() {
    local question="$1" default="$2" hint answer
    if [ "$default" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    ask_value "${question} ${hint}: " "$default" answer
    [[ "$answer" =~ ^[Yy] ]]
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
ACTION=""            # stable | binary | edge | uninstall | check-update
CCX_REF="${CCX_REF:-}"
USE_LOCAL=0
PREFIX="${HOME}/.local"
PREFIX_SET=0
NATIVE=1
FORCE=0
NPROC=""

usage() {
    sed -n '3,29p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//' || true
}

set_action() {
    if [ -n "$ACTION" ] && [ "$ACTION" != "$1" ]; then
        die "Choose only one action (got --${ACTION} and --$1)."
    fi
    ACTION="$1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stable)              set_action stable; shift ;;
            --binary|--download)   set_action binary; shift ;;
            --edge|--head|--dev)   set_action edge; shift ;;
            -u|--uninstall)        set_action uninstall; shift ;;
            --check-update|--check-updates) set_action check-update; shift ;;
            -b|--branch|-r|--ref|--tag)
                [ -n "$2" ] || die "Option $1 requires a value."
                CCX_REF="$2"; shift 2 ;;
            --local)
                USE_LOCAL=1; shift ;;
            --prefix)
                [ -n "$2" ] || die "Option $1 requires a value."
                PREFIX="$2"; PREFIX_SET=1; shift 2 ;;
            --portable)
                NATIVE=0; shift ;;
            -j|--jobs)
                [ -n "$2" ] || die "Option $1 requires a value."
                NPROC="$2"; shift 2 ;;
            -y|--yes|--non-interactive)
                NON_INTERACTIVE=1; shift ;;
            -f|--force)
                FORCE=1; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                die "Unknown option: $1 (see --help)" ;;
        esac
    done
    # An explicit ref or a local checkout means a source build of that code.
    if [ -n "$CCX_REF" ] || [ "$USE_LOCAL" -eq 1 ]; then
        case "$ACTION" in
            ""|stable|edge) ;;
            *) die "--ref/--local only apply to source builds (--stable or --edge)." ;;
        esac
        [ -n "$ACTION" ] || ACTION="stable"
    fi
    if [ -n "$CCX_REF" ] && [ "$USE_LOCAL" -eq 1 ]; then
        die "Use either --ref or --local, not both."
    fi
}

# -----------------------------------------------------------------------------
# Platform detection
# -----------------------------------------------------------------------------
detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    echo -e "Detected Platform: ${BOLD}${GREEN}${OS} (${ARCH})${NC}"

    if [ "${OS}" = "Darwin" ] && [ "${ARCH}" != "arm64" ]; then
        die "This project currently supports Apple Silicon macOS only (arm64)."
    fi
    if [ "${OS}" != "Darwin" ] && [ "${OS}" != "Linux" ]; then
        die "Unsupported operating system: ${OS}"
    fi

    # Name used for release assets: ccx-<PLATFORM>.tar.gz
    case "${OS}:${ARCH}" in
        Darwin:arm64)          PLATFORM="macos-arm64" ;;
        Linux:x86_64)          PLATFORM="linux-x86_64" ;;
        Linux:aarch64|Linux:arm64) PLATFORM="linux-arm64" ;;
        *)                     PLATFORM="$(echo "${OS}-${ARCH}" | tr '[:upper:]' '[:lower:]')" ;;
    esac

    if [ -z "$NPROC" ]; then
        if [ "${OS}" = "Darwin" ]; then
            NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
        else
            NPROC=$(nproc 2>/dev/null || echo 4)
        fi
    fi
}

# -----------------------------------------------------------------------------
# Linux package manager abstraction (single place for apt / dnf / pacman)
# -----------------------------------------------------------------------------
PM=""
SUDO=""
APT_UPDATED=0

detect_pm() {
    if   command -v apt-get &>/dev/null; then PM=apt
    elif command -v dnf     &>/dev/null; then PM=dnf
    elif command -v pacman  &>/dev/null; then PM=pacman
    else PM=""
    fi

    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    elif command -v sudo &>/dev/null; then
        SUDO="sudo"
    else
        SUDO=""
        if [ -n "$PM" ]; then
            warn "'sudo' not found and not running as root; package installation will fail."
        fi
    fi
}

aur_helper() {
    if   command -v paru &>/dev/null; then echo paru
    elif command -v yay  &>/dev/null; then echo yay
    fi
}

# Maps a logical package name to the distribution package name(s).
pkg_names() {
    case "$PM:$1" in
        apt:cmake)      echo "cmake" ;;
        apt:gfortran)   echo "gfortran" ;;
        apt:cc)         echo "build-essential" ;;
        apt:make)       echo "make" ;;
        apt:git)        echo "git" ;;
        apt:pkgconf)    echo "pkg-config" ;;
        apt:blas)       echo "libopenblas-dev liblapack-dev" ;;
        apt:arpack)     echo "libarpack2-dev" ;;
        apt:mumps)      echo "libmumps-seq-dev" ;;
        apt:spooles)    echo "libspooles-dev" ;;
        apt:blis)       echo "libblis-openmp-dev libflame-dev" ;;
        apt:blis_alt)   echo "libblis-dev" ;;
        apt:mkl)        echo "intel-oneapi-mkl-devel" ;;
        apt:gnupg)      echo "gnupg" ;;

        dnf:cmake)      echo "cmake" ;;
        dnf:gfortran)   echo "gcc-gfortran" ;;
        dnf:cc)         echo "gcc" ;;
        dnf:make)       echo "make" ;;
        dnf:git)        echo "git" ;;
        dnf:pkgconf)    echo "pkgconf-pkg-config" ;;
        dnf:blas)       echo "openblas-devel lapack-devel" ;;
        dnf:arpack)     echo "arpack-devel" ;;
        dnf:mumps)      echo "MUMPS-devel" ;;
        dnf:spooles)    echo "spooles-devel" ;;
        dnf:blis)       echo "blis-devel libflame-devel" ;;
        dnf:gnupg)      echo "gnupg2" ;;

        pacman:cmake)    echo "cmake" ;;
        pacman:gfortran) echo "gcc-fortran" ;;
        pacman:cc)       echo "base-devel" ;;
        pacman:make)     echo "base-devel" ;;
        pacman:git)      echo "git" ;;
        pacman:pkgconf)  echo "pkgconf" ;;
        pacman:blas)     echo "openblas lapack" ;;
        pacman:arpack)   echo "arpack" ;;
        pacman:mumps)    echo "mumps-seq" ;;
        pacman:spooles)  echo "spooles" ;;
        pacman:blis)     echo "blis" ;;
        pacman:mkl)      echo "intel-oneapi-mkl" ;;
        pacman:gnupg)    echo "gnupg" ;;
        *) echo "" ;;
    esac
}

pkg_installed() {
    case "$PM" in
        apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
        dnf)    rpm -q "$1" &>/dev/null ;;
        pacman) pacman -Qq "$1" &>/dev/null ;;
        *)      return 1 ;;
    esac
}

all_installed() {
    local p
    for p in "$@"; do pkg_installed "$p" || return 1; done
    return 0
}

pm_install() {
    case "$PM" in
        apt)
            if [ "$APT_UPDATED" -eq 0 ]; then
                $SUDO apt-get update || warn "'apt-get update' failed; continuing with the existing package cache."
                APT_UPDATED=1
            fi
            $SUDO apt-get install -y "$@" ;;
        dnf)
            $SUDO dnf install -y "$@" ;;
        pacman)
            if $SUDO pacman -S --needed --noconfirm "$@"; then
                return 0
            fi
            # Possibly an AUR package; AUR helpers must not run as root.
            local aur
            aur="$(aur_helper)"
            if [ -n "$aur" ] && [ "$(id -u)" -ne 0 ]; then
                "$aur" -S --needed --noconfirm "$@"
            else
                return 1
            fi ;;
        *)
            return 1 ;;
    esac
}

# install_optional <logical>: installs the package(s) if missing; returns non-zero on failure.
install_optional() {
    local names
    names="$(pkg_names "$1")"
    [ -n "$names" ] || return 1
    # shellcheck disable=SC2086
    if all_installed $names; then return 0; fi
    # Arch: the 'mumps' (MPI) package also satisfies the build
    if [ "$PM:$1" = "pacman:mumps" ] && pacman -Qq mumps &>/dev/null; then return 0; fi
    # shellcheck disable=SC2086
    pm_install $names
}

# Installs missing base build tools and mandatory libraries (git, cmake, compilers, BLAS/LAPACK, ARPACK).
install_linux_base() {
    info "Checking prerequisites and build tools..."
    local missing="" t logical cmd names l
    for t in cmake:cmake gfortran:gfortran cc:gcc make:make git:git pkgconf:pkg-config; do
        logical="${t%%:*}"; cmd="${t#*:}"
        if ! command -v "$cmd" &>/dev/null; then
            missing="${missing} $(pkg_names "$logical")"
        fi
    done
    for l in blas arpack; do
        names="$(pkg_names "$l")"
        # shellcheck disable=SC2086
        all_installed $names || missing="${missing} ${names}"
    done
    # de-duplicate
    missing="$(echo "$missing" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"

    if [ -z "$missing" ]; then
        ok "Base Linux build tools, linear algebra, and ARPACK found."
        return 0
    fi

    echo -e "${YELLOW}Missing build packages:${NC} ${missing}"
    if [ -z "$PM" ]; then
        die "No supported package manager (apt, dnf, pacman) found. Please install manually: cmake, gcc, gfortran, make, git, pkg-config, BLAS/LAPACK (OpenBLAS), ARPACK."
    fi
    if confirm "Install required packages via ${PM}$([ -n "$SUDO" ] && echo ' (requires sudo)')?" Y; then
        # shellcheck disable=SC2086
        pm_install $missing || die "Failed to install required packages: ${missing}"
    else
        die "Required packages are missing; cannot continue."
    fi
}

# Adds the Intel oneAPI repository (apt) and installs oneMKL. Returns non-zero on failure.
install_mkl() {
    case "$PM" in
        apt)
            command -v gpg &>/dev/null || pm_install "$(pkg_names gnupg)" || return 1
            curl -fsSL https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
                | gpg --dearmor | $SUDO tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null || return 1
            echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" \
                | $SUDO tee /etc/apt/sources.list.d/oneAPI.list > /dev/null
            APT_UPDATED=0
            install_optional mkl ;;
        pacman)
            install_optional mkl ;;
        *)
            warn "Automatic oneMKL installation is not supported for this package manager (Intel repository setup required)."
            return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Questions (all prompts are asked here, before any installation work starts)
# -----------------------------------------------------------------------------
WANT_MUMPS=0
WANT_SPOOLES=0
WANT_AOCL=0
WANT_MKL=0
ADD_PATH=0
HAVE_MKL=0

detect_shell_rc() {
    SHELL_RC=""
    case "$(basename "${SHELL:-}")" in
        fish) SHELL_RC="${HOME}/.config/fish/config.fish" ;;
        zsh)  SHELL_RC="${HOME}/.zshrc" ;;
        bash) SHELL_RC="${HOME}/.bashrc" ;;
    esac
}

ask_prefix() {
    if [ "$PREFIX_SET" -eq 0 ] && [ -z "$EXISTING_PREFIX" ]; then
        ask_value "Install prefix (binaries go to <prefix>/bin)? [${PREFIX}]: " "${PREFIX}" PREFIX
    elif [ "$PREFIX_SET" -eq 0 ]; then
        PREFIX="$EXISTING_PREFIX"   # keep stable and bleeding edge side by side
    fi
    PREFIX="${PREFIX/#\~/$HOME}"
    BIN_DIR="${PREFIX}/bin"
}

ask_path() {
    detect_shell_rc
    if [ -n "$SHELL_RC" ]; then
        case ":${PATH}:" in
            *":${BIN_DIR}:"*) ;;  # already on PATH
            *) if confirm "Add ${BIN_DIR} to PATH in ${SHELL_RC}?" Y; then ADD_PATH=1; fi ;;
        esac
    fi
}

ask_solver_questions() {
    echo -e "\n${BOLD}${CYAN}--> Sparse direct solver selection${NC}"
    if [ "${OS}" = "Darwin" ]; then
        echo -e "${GREEN}[INFO] macOS Detected:${NC}"
        echo -e "  * ${BOLD}Apple Accelerate${NC} is always built (native, part of macOS)."
        echo -e "  * An open-source solver (${BOLD}MUMPS 5.x${NC}) is available as an option.\n"
        if confirm "Also build MUMPS 5.x as an additional open-source solver?" N; then WANT_MUMPS=1; fi
    else
        echo -e "${GREEN}[INFO] Linux Detected:${NC}"
        if confirm "Enable MUMPS 5.x as an open-source multi-threaded direct solver?" Y; then WANT_MUMPS=1; fi

        if [ "${ARCH}" = "x86_64" ]; then
            if grep -qi "authenticamd" /proc/cpuinfo 2>/dev/null; then
                echo -e "\n${BOLD}${YELLOW}AMD Zen CPU detected:${NC} AMD AOCL-BLIS is open-source linear algebra tuned for AMD CPUs."
                if confirm "Install AMD BLIS/libflame (CMake selects it automatically when present)?" Y; then WANT_AOCL=1; fi
            fi

            echo -e "\n${BOLD}${BLUE}Intel oneMKL PARDISO (optional):${NC} proprietary, but often faster on x86_64 CPUs with AVX2/AVX-512."
            if [ -n "$MKLROOT" ] || [ -d "/opt/intel/oneapi/mkl" ] || [ -f "/usr/include/mkl/mkl.h" ] || [ -f "/usr/include/mkl.h" ]; then
                HAVE_MKL=1
                if confirm "Found Intel oneMKL on your system. Enable PARDISO?" Y; then WANT_MKL=1; fi
            else
                if confirm "Install and enable Intel oneMKL PARDISO?" N; then WANT_MKL=1; fi
            fi
        else
            echo -e "\n${CYAN}[INFO] Linux ${ARCH} detected: Intel oneMKL is not available on this architecture.${NC}"
        fi

        if confirm "Also enable legacy SPOOLES solver via system library?" N; then WANT_SPOOLES=1; fi

        if [ "$WANT_MUMPS" -eq 0 ] && [ "$WANT_MKL" -eq 0 ] && [ "$WANT_SPOOLES" -eq 0 ]; then
            echo -e "\n${BOLD}${RED}[WARNING] No direct sparse solver selected!${NC}"
            echo -e "CalculiX requires at least one direct sparse solver (MUMPS, PARDISO, or SPOOLES) to solve standard FEA models."
            echo -e "Without one, CCX falls back to an internal iterative solver that fails on most simulations.\n"
            if confirm "Would you like to enable MUMPS 5.x (strongly recommended)?" Y; then
                WANT_MUMPS=1
            else
                die "Installation aborted: At least one direct solver must be enabled to build a functional CCX installation."
            fi
        fi
    fi
}

solver_desc() {
    case "$1" in
        ACCELERATE) echo "Apple Accelerate (macOS Hardware)" ;;
        PARDISO)    echo "Intel oneMKL PARDISO (x86_64 AVX2/AVX-512)" ;;
        MUMPS)      echo "MUMPS 5.x (Open-Source Multi-Threaded)" ;;
        SPOOLES)    echo "SPOOLES 2.2 (Classic Built-in)" ;;
        *)          echo "$1" ;;
    esac
}

# Solvers and default from the answers, with the same order as src/ini_cal.c
# and CMakeLists.txt: Accelerate > PARDISO > MUMPS > SPOOLES.
planned_solvers() {
    local list=""
    if [ "${OS}" = "Darwin" ]; then list="ACCELERATE"; fi
    [ "$WANT_MKL" -eq 1 ]     && list="${list:+$list,}PARDISO"
    [ "$WANT_MUMPS" -eq 1 ]   && list="${list:+$list,}MUMPS"
    [ "$WANT_SPOOLES" -eq 1 ] && list="${list:+$list,}SPOOLES"
    PLANNED_SOLVERS="$list"
    PLANNED_DEFAULT="${list%%,*}"
}

# show_solver_plan <csv> <default>
show_solver_plan() {
    echo -e "\n${BOLD}${CYAN}--> Direct solvers${NC}"
    echo -e "  Solvers          : ${BOLD}${1//,/, }${NC}"
    echo -e "  Default solver   : ${BOLD}${GREEN}$(solver_desc "$2")${NC}"
    echo -e "                     used when a deck has no SOLVER= on *STATIC, *FREQUENCY, ..."
    echo -e "  Order            : Accelerate > PARDISO > MUMPS > SPOOLES (fixed when ccx is compiled)"
    echo -e "  Choose per deck  : e.g. ${CYAN}*STATIC, SOLVER=MUMPS${NC}"
}

# -----------------------------------------------------------------------------
# Dependency installation (driven by the answers above)
# -----------------------------------------------------------------------------
install_macos_deps() {
    info "Checking prerequisites and build tools..."
    if ! command -v brew &>/dev/null; then
        if   [ -x "/opt/homebrew/bin/brew" ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x "/usr/local/bin/brew" ];    then eval "$(/usr/local/bin/brew shellenv)"
        else
            echo -e "\n${YELLOW}Homebrew is recommended to install build tools (cmake, gcc, arpack).${NC}"
            if confirm "Install Homebrew now?" Y; then
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                if   [ -x "/opt/homebrew/bin/brew" ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
                elif [ -x "/usr/local/bin/brew" ];    then eval "$(/usr/local/bin/brew shellenv)"
                fi
            fi
        fi
    fi

    command -v brew &>/dev/null || die "Homebrew is required to install build tools on macOS."

    local missing=""
    command -v cmake    &>/dev/null || missing="${missing} cmake"
    command -v gfortran &>/dev/null || missing="${missing} gcc"
    brew list arpack    &>/dev/null || missing="${missing} arpack"

    if [ -n "$missing" ]; then
        echo -e "${YELLOW}Missing packages:${NC}${missing}"
        if confirm "Install missing packages via Homebrew?" Y; then
            # shellcheck disable=SC2086
            brew install ${missing}
        else
            die "Required packages are missing; cannot continue."
        fi
    else
        ok "All macOS build tools and ARPACK found."
    fi
}

install_linux_solver_deps() {
    if [ "$WANT_MUMPS" -eq 1 ]; then
        info "Installing MUMPS..."
        if ! install_optional mumps; then
            warn "MUMPS could not be installed (on Arch it may require an AUR helper, e.g. 'yay -S mumps-seq'). Skipping MUMPS."
            WANT_MUMPS=0
        fi
    fi

    if [ "$WANT_AOCL" -eq 1 ]; then
        info "Installing AMD BLIS/libflame..."
        if ! install_optional blis && ! install_optional blis_alt; then
            echo -e "${YELLOW}[INFO] BLIS could not be installed. CMake will fall back to OpenBLAS.${NC}"
        fi
    fi

    if [ "$WANT_MKL" -eq 1 ] && [ "$HAVE_MKL" -eq 0 ]; then
        info "Installing Intel oneMKL..."
        if ! install_mkl || [ ! -d "/opt/intel/oneapi/mkl" ]; then
            warn "Intel oneMKL could not be installed. Skipping PARDISO."
            WANT_MKL=0
        fi
    fi

    if [ "$WANT_SPOOLES" -eq 1 ]; then
        info "Installing SPOOLES..."
        if ! install_optional spooles && [ ! -d "/usr/include/spooles" ]; then
            warn "SPOOLES could not be installed (on Arch it may require an AUR helper, e.g. 'yay -S spooles'). Skipping SPOOLES."
            WANT_SPOOLES=0
        fi
    fi

    if [ "$WANT_MUMPS" -eq 0 ] && [ "$WANT_MKL" -eq 0 ] && [ "$WANT_SPOOLES" -eq 0 ]; then
        die "No direct sparse solver is installed or enabled (MUMPS/PARDISO/SPOOLES). Cannot build a functional CalculiX binary."
    fi
}

# -----------------------------------------------------------------------------
# Latest stable release and bleeding edge
# -----------------------------------------------------------------------------
STABLE_TAG=""
EDGE_SHA=""
BINARY_AVAILABLE=0

# Latest stable = latest GitHub release; fallback: highest multisolver tag.
resolve_stable_tag() {
    local json tag=""
    if command -v curl &>/dev/null; then
        json="$(curl -fsSL --max-time 15 "${GITHUB_API_URL}/releases/latest" 2>/dev/null || true)"
        tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
    fi
    if [ -z "$tag" ] && command -v git &>/dev/null; then
        tag="$(git ls-remote --tags --refs "${GITHUB_REPO_URL}" "${RELEASE_TAG_PATTERN}" 2>/dev/null \
               | sed 's|.*refs/tags/||' | sort -V | tail -n 1)"
    fi
    STABLE_TAG="$tag"
}

resolve_edge_sha() {
    if command -v git &>/dev/null; then
        EDGE_SHA="$(git ls-remote "${GITHUB_REPO_URL}" refs/heads/main 2>/dev/null | cut -c1-7)"
    fi
}

release_asset_url() { echo "https://github.com/${REPO}/releases/download/${STABLE_TAG}/$1"; }

check_binary_available() {
    BINARY_AVAILABLE=0
    [ -n "$STABLE_TAG" ] || return 0
    command -v curl &>/dev/null || return 0
    if curl -fsIL --max-time 15 -o /dev/null "$(release_asset_url "ccx-${PLATFORM}.tar.gz")" 2>/dev/null; then
        BINARY_AVAILABLE=1
    fi
}

# -----------------------------------------------------------------------------
# Manifests: one per channel (stable / edge), so uninstall and --check-update
# know exactly what was installed.
#   ${DATA_DIR}/manifest-<channel>.txt   key=value lines, 'file=' repeated
# -----------------------------------------------------------------------------
manifest_path() { echo "${DATA_DIR}/manifest-$1.txt"; }

manifest_get() {   # manifest_get <file> <key>  (first value)
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

write_manifest() {   # write_manifest <channel> <file>...
    local channel="$1"; shift
    mkdir -p "$DATA_DIR"
    {
        echo "channel=${channel}"
        echo "method=${INSTALL_METHOD}"
        echo "version=${INSTALLED_VERSION}"
        echo "ref=${INSTALLED_REF}"
        echo "commit=${INSTALLED_COMMIT}"
        echo "solvers=${BUILT_SOLVERS}"
        echo "default_solver=${DEFAULT_SOLVER}"
        echo "native=${INSTALLED_NATIVE}"
        echo "prefix=${PREFIX}"
        echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [ "$ADD_PATH" -eq 1 ] && echo "path_rc=${SHELL_RC}"
        local f
        for f in "$@"; do echo "file=${f}"; done
    } > "$(manifest_path "$channel")"
}

EXISTING_PREFIX=""
find_existing_prefix() {
    local m
    for m in "$(manifest_path stable)" "$(manifest_path edge)"; do
        if [ -f "$m" ]; then EXISTING_PREFIX="$(manifest_get "$m" prefix)"; return 0; fi
    done
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------
choose_action() {
    [ -z "$ACTION" ] || return 0
    local stable_lbl="${STABLE_TAG:-latest release}"
    local edge_lbl="main${EDGE_SHA:+ @ ${EDGE_SHA}}"
    local bin_note=""
    if [ "$BINARY_AVAILABLE" -eq 0 ]; then
        bin_note=" ${YELLOW}(not available for ${PLATFORM} yet)${NC}"
    fi
    echo -e "\n${BOLD}Choose action:${NC}"
    echo -e "  ${BOLD}1) Build latest stable${NC} (${stable_lbl}, optimized for this computer) ${GREEN}[Default]${NC}"
    echo -e "  ${BOLD}2) Download latest stable binary${NC} (${stable_lbl}, prebuilt, portable)${bin_note}"
    echo -e "  ${BOLD}3) Build bleeding edge${NC} (${edge_lbl}) -> installed as '${BOLD}ccx_dev${NC}'"
    echo -e "  ${BOLD}4) Uninstall${NC}"
    local choice
    ask_value "Select [1/2/3/4] (Default: 1): " "1" choice
    case "$choice" in
        1) ACTION="stable" ;;
        2) ACTION="binary" ;;
        3) ACTION="edge" ;;
        4) ACTION="uninstall" ;;
        *) die "Invalid selection: ${choice}" ;;
    esac
}

channel_of_action() { if [ "$ACTION" = "edge" ]; then echo edge; else echo stable; fi; }
exe_name_of_channel() { if [ "$1" = "edge" ]; then echo ccx_dev; else echo ccx; fi; }

# Existing installation of the same channel: replace / cancel / uninstall
check_existing_installation() {
    local channel exe m
    channel="$(channel_of_action)"
    exe="$(exe_name_of_channel "$channel")"
    m="$(manifest_path "$channel")"
    local found=""
    if [ -f "$m" ]; then
        found="$(manifest_get "$m" version) ($(manifest_get "$m" method), $(manifest_get "$m" prefix)/bin/${exe})"
    elif [ -e "${BIN_DIR}/${exe}" ]; then
        found="${BIN_DIR}/${exe} (installed without a manifest)"
    fi
    [ -n "$found" ] || return 0

    echo -e "\n${YELLOW}Existing installation found:${NC} ${found}"
    if [ "$FORCE" -eq 1 ] || [ -n "$NON_INTERACTIVE" ]; then
        info "Replacing it."
        return 0
    fi
    local answer
    ask_value "Replace it, cancel, or uninstall? [Y/n/u] (Y=replace, n=cancel, u=uninstall): " "Y" answer
    case "$answer" in
        [Yy]*) ;;
        [Uu]*) do_uninstall; exit 0 ;;
        *)     echo "Cancelled."; exit 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# Source checkout (cached in ${CACHE_DIR}/src so rebuilds are incremental)
# -----------------------------------------------------------------------------
script_dir() {
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        (cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    fi
}

fetch_source() {
    TEMP_ROOT="$(mktemp -d -t ccx_build_XXXXXX)"
    local channel
    channel="$(channel_of_action)"

    if [ "$USE_LOCAL" -eq 1 ]; then
        SOURCE_DIR="$(script_dir)"
        [ -n "$SOURCE_DIR" ] && [ -f "${SOURCE_DIR}/CMakeLists.txt" ] && [ -d "${SOURCE_DIR}/src" ] \
            || die "--local: this script is not inside a CalculiX MultiSolver checkout."
        BUILD_DIR="${TEMP_ROOT}/build"
        INSTALLED_REF="local:$(git -C "${SOURCE_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        INSTALLED_COMMIT="$(git -C "${SOURCE_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo -e "Building from local checkout: ${CYAN}${SOURCE_DIR}${NC} (${BOLD}${GREEN}${INSTALLED_REF#local:}${NC})"
        return 0
    fi

    local ref
    if [ -n "$CCX_REF" ]; then
        ref="$CCX_REF"
    elif [ "$channel" = "edge" ]; then
        ref="main"
    else
        [ -n "$STABLE_TAG" ] || die "Could not find the latest stable release (no network?). Use --ref <tag> or --edge."
        ref="$STABLE_TAG"
    fi

    SOURCE_DIR="${CACHE_DIR}/src"
    BUILD_DIR="${CACHE_DIR}/build-${channel}"
    mkdir -p "$CACHE_DIR"
    if [ -d "${SOURCE_DIR}/.git" ] && git -C "${SOURCE_DIR}" remote get-url origin &>/dev/null; then
        info "Updating cached source in ${SOURCE_DIR}..."
        if ! git -C "${SOURCE_DIR}" fetch --tags --force --prune origin; then
            warn "Fetching into the cache failed; cloning again."
            rm -rf "${SOURCE_DIR}"
        fi
    else
        rm -rf "${SOURCE_DIR}"
    fi
    if [ ! -d "${SOURCE_DIR}/.git" ]; then
        info "Cloning CalculiX MultiSolver into ${SOURCE_DIR}..."
        git clone --filter=blob:none "${GITHUB_REPO_URL}" "${SOURCE_DIR}"
    fi

    # Branch -> origin/<branch>; tag or commit as is (a PR head commit may need an explicit fetch)
    local target="$ref"
    if git -C "${SOURCE_DIR}" rev-parse --verify -q "refs/remotes/origin/${ref}" >/dev/null; then
        target="origin/${ref}"
    elif ! git -C "${SOURCE_DIR}" rev-parse --verify -q "${ref}^{commit}" >/dev/null; then
        git -C "${SOURCE_DIR}" fetch origin "${ref}" || die "Unknown branch, tag or commit: ${ref}"
        target="FETCH_HEAD"
    fi
    git -C "${SOURCE_DIR}" checkout --quiet --force --detach "${target}"
    git -C "${SOURCE_DIR}" clean -fdxq
    INSTALLED_REF="$ref"
    INSTALLED_COMMIT="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
    echo -e "Source: ${BOLD}${GREEN}${ref}${NC} @ ${INSTALLED_COMMIT:0:7}"
}

# -----------------------------------------------------------------------------
# Build, install, verify
# -----------------------------------------------------------------------------
on_off() { if [ "$1" -eq 1 ]; then echo ON; else echo OFF; fi; }

build_from_source() {
    local flags="-DCCX_SOLVERS_STRICT=OFF -DCCX_NATIVE=$(on_off $NATIVE)"

    if [ "${OS}" = "Darwin" ]; then
        flags="${flags} -DCCX_USE_ACCELERATE=ON -DCCX_USE_MUMPS=$(on_off $WANT_MUMPS)"
    else
        flags="${flags} -DCCX_USE_ACCELERATE=OFF -DCCX_USE_MUMPS=$(on_off $WANT_MUMPS)"
        flags="${flags} -DCCX_USE_PARDISO=$(on_off $WANT_MKL) -DCCX_USE_SPOOLES=$(on_off $WANT_SPOOLES)"
    fi

    info "Configuring CalculiX..."
    # shellcheck disable=SC2086
    cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" ${flags}

    # Solvers actually enabled by CMake
    BUILT_SOLVERS=""
    DEFAULT_SOLVER=""
    if [ -f "${BUILD_DIR}/ccx_solvers.txt" ]; then
        BUILT_SOLVERS="$(sed -n '1p' "${BUILD_DIR}/ccx_solvers.txt" | tr -d '\r\n')"
        DEFAULT_SOLVER="$(sed -n '2p' "${BUILD_DIR}/ccx_solvers.txt" | tr -d '\r\n')"
    fi

    if [ -z "$BUILT_SOLVERS" ] || [ "$DEFAULT_SOLVER" = "NONE" ]; then
        die "No sparse direct solver is enabled (MUMPS/PARDISO/SPOOLES/Accelerate). Refusing to compile a non-functional CCX binary."
    fi
    if [ "$DEFAULT_SOLVER" != "$PLANNED_DEFAULT" ]; then
        warn "The default solver is ${DEFAULT_SOLVER}, not ${PLANNED_DEFAULT} as planned (a requested solver was not found; see CMake warnings above)."
    fi

    info "Building CalculiX (${NPROC} parallel jobs)..."
    cmake --build "${BUILD_DIR}" -j"${NPROC}"

    INSTALL_METHOD="source"
    # Native only if this source knows CCX_NATIVE and the compiler accepted the flag
    INSTALLED_NATIVE=0
    if [ "$NATIVE" -eq 1 ] && grep -q '^CCX_C_HAS_NATIVE:INTERNAL=1' "${BUILD_DIR}/CMakeCache.txt" 2>/dev/null; then
        INSTALLED_NATIVE=1
    fi
    INSTALLED_VERSION="$(edition_of "${BUILD_DIR}/CalculiX")"
    [ -n "$INSTALLED_VERSION" ] || INSTALLED_VERSION="$INSTALLED_REF"
    install_binary "${BUILD_DIR}/CalculiX"
}

# Edition string printed by 'ccx -v' (e.g. v2.24-multisolver-0.2)
edition_of() {
    "$1" -v 2>/dev/null | sed -n 's/^MultiSolver edition //p' | head -n 1 || true
}

# install_binary <built executable>: stable -> CalculiX + ccx link; edge -> ccx_dev
install_binary() {
    local src="$1" channel files=()
    channel="$(channel_of_action)"
    info "Installing to ${BIN_DIR}..."
    mkdir -p "${BIN_DIR}"
    if [ "$channel" = "edge" ]; then
        rm -f "${BIN_DIR}/ccx_dev"
        cp "$src" "${BIN_DIR}/ccx_dev"; chmod 755 "${BIN_DIR}/ccx_dev"
        files=("${BIN_DIR}/ccx_dev")
        INSTALLED_EXE="${BIN_DIR}/ccx_dev"
        ok "Installed: ${BIN_DIR}/ccx_dev"
    else
        rm -f "${BIN_DIR}/CalculiX" "${BIN_DIR}/ccx"   # replace any binary or link from a previous install
        cp "$src" "${BIN_DIR}/CalculiX"; chmod 755 "${BIN_DIR}/CalculiX"
        ln -s CalculiX "${BIN_DIR}/ccx"
        files=("${BIN_DIR}/CalculiX" "${BIN_DIR}/ccx")
        INSTALLED_EXE="${BIN_DIR}/ccx"
        ok "Installed: ${BIN_DIR}/CalculiX (and 'ccx')"
    fi
    INSTALLED_FILES=("${files[@]}")
}

sha256_of() {
    if command -v sha256sum &>/dev/null; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Option 2: prebuilt binary from the latest release, checked against SHA256SUMS.txt
download_binary() {
    [ "$BINARY_AVAILABLE" -eq 1 ] || die "No prebuilt binary for ${PLATFORM} in release ${STABLE_TAG:-?} yet. Use option 1 (build latest stable) instead."
    TEMP_ROOT="$(mktemp -d -t ccx_dl_XXXXXX)"
    local asset="ccx-${PLATFORM}.tar.gz" d="${TEMP_ROOT}/dl"
    mkdir -p "$d"
    info "Downloading ${asset} (${STABLE_TAG})..."
    curl -fL --progress-bar "$(release_asset_url "$asset")" -o "${d}/${asset}"
    curl -fsSL "$(release_asset_url SHA256SUMS.txt)" -o "${d}/SHA256SUMS.txt" \
        || die "SHA256SUMS.txt is missing from release ${STABLE_TAG}; refusing to install an unchecked binary."

    local expected actual
    expected="$(awk -v f="$asset" '$2==f || $2=="*"f {print $1}' "${d}/SHA256SUMS.txt" | head -n 1)"
    [ -n "$expected" ] || die "${asset} is not listed in SHA256SUMS.txt."
    actual="$(sha256_of "${d}/${asset}")"
    [ "$expected" = "$actual" ] || die "SHA-256 mismatch for ${asset} (expected ${expected}, got ${actual})."
    ok "SHA-256 verified."

    tar -xzf "${d}/${asset}" -C "$d"
    local exe
    exe="$(find "$d" -type f \( -name CalculiX -o -name ccx \) -perm -u+x | head -n 1)"
    [ -n "$exe" ] || die "No ccx executable found in ${asset}."
    [ "${OS}" = "Darwin" ] && xattr -d com.apple.quarantine "$exe" 2>/dev/null || true

    INSTALL_METHOD="binary"
    INSTALLED_NATIVE=0
    INSTALLED_REF="$STABLE_TAG"
    INSTALLED_COMMIT=""
    INSTALLED_VERSION="$(edition_of "$exe")"
    [ -n "$INSTALLED_VERSION" ] || INSTALLED_VERSION="$STABLE_TAG"
    local line
    line="$("$exe" -v 2>/dev/null | sed -n 's/^Direct solvers: //p' | head -n 1 || true)"
    BUILT_SOLVERS="${line%% (default:*}"
    DEFAULT_SOLVER="$(echo "$line" | sed -n 's/.*(default: \([A-Z]*\)).*/\1/p')"
    install_binary "$exe"
}

# Release metadata ccx-<platform>.solvers.txt: line 1 solvers, line 2 default
show_binary_solver_plan() {
    local meta
    meta="$(curl -fsSL --max-time 15 "$(release_asset_url "ccx-${PLATFORM}.solvers.txt")" 2>/dev/null || true)"
    if [ -n "$meta" ]; then
        show_solver_plan "$(echo "$meta" | sed -n 1p | tr -d '\r')" "$(echo "$meta" | sed -n 2p | tr -d '\r')"
    fi
    echo -e "  ${YELLOW}Prebuilt binaries are portable (not tuned for this CPU) and include only${NC}"
    echo -e "  ${YELLOW}freely redistributable solvers. For PARDISO, SPOOLES or CPU tuning, choose 1.${NC}"
}

verify_install() {
    info "Running quick solver verification..."
    TEMP_ROOT="${TEMP_ROOT:-$(mktemp -d -t ccx_verify_XXXXXX)}"
    local vdir="${TEMP_ROOT}/verify" deck_url
    mkdir -p "$vdir"
    if [ -n "${SOURCE_DIR:-}" ] && [ -f "${SOURCE_DIR}/test/achtel2.inp" ]; then
        cp "${SOURCE_DIR}/test/achtel2.inp" "$vdir/"
    else
        deck_url="https://raw.githubusercontent.com/${REPO}/${INSTALLED_REF:-main}/test/achtel2.inp"
        if ! curl -fsSL --max-time 30 "$deck_url" -o "$vdir/achtel2.inp" 2>/dev/null; then
            warn "Verification deck not available; skipping."
            return 0
        fi
    fi
    if ( cd "$vdir" && "${INSTALLED_EXE}" achtel2 > run.log 2>&1 ) && grep -q "Job finished" "$vdir/run.log"; then
        ok "Verification test passed (achtel2.inp solved successfully)."
    else
        warn "Verification test FAILED. The installed binary may be broken; see output below."
        tail -n 20 "$vdir/run.log" 2>/dev/null || true
    fi
}

setup_path() {
    [ "$ADD_PATH" -eq 1 ] || return 0
    mkdir -p "$(dirname "${SHELL_RC}")"
    if [ -f "${SHELL_RC}" ] && grep -qF "$PATH_MARKER" "${SHELL_RC}"; then
        ok "PATH entry already present in ${SHELL_RC}."
        return 0
    fi
    {
        echo ""
        echo "$PATH_MARKER"
        if [[ "$SHELL_RC" == *fish* ]]; then
            echo "fish_add_path ${BIN_DIR}"
        else
            echo "export PATH=\"${BIN_DIR}:\$PATH\""
        fi
    } >> "${SHELL_RC}"
    ok "Added to ${SHELL_RC}. Run 'source ${SHELL_RC}' or open a new terminal."
}

# -----------------------------------------------------------------------------
# Uninstall
# -----------------------------------------------------------------------------
remove_path_entry() {   # remove_path_entry <rc file>
    local rc="$1" tmp
    [ -f "$rc" ] && grep -qF "$PATH_MARKER" "$rc" || return 0
    tmp="$(mktemp)"
    # Drop the marker line, the PATH line after it, and the blank line setup_path put before it
    awk -v m="$PATH_MARKER" '
        skip         { skip=0; next }
        $0==m        { held=0; skip=1; next }
        held         { print ""; held=0 }
        $0==""       { held=1; next }
                     { print }
        END          { if (held) print "" }' "$rc" > "$tmp"
    cat "$tmp" > "$rc"; rm -f "$tmp"
    ok "Removed PATH entry from ${rc}."
}

do_uninstall() {
    echo -e "\n${BOLD}${CYAN}--> Uninstall${NC}"
    local files=() rcs=() manifests=() m f
    for m in "$(manifest_path stable)" "$(manifest_path edge)"; do
        [ -f "$m" ] || continue
        manifests+=("$m")
        while IFS= read -r f; do files+=("$f"); done < <(sed -n 's/^file=//p' "$m")
        f="$(manifest_get "$m" path_rc)"; [ -n "$f" ] && rcs+=("$f")
        echo -e "  $(manifest_get "$m" channel): $(manifest_get "$m" version) ($(manifest_get "$m" method), $(manifest_get "$m" prefix))"
    done

    if [ ${#manifests[@]} -eq 0 ]; then
        # Installs made before manifests existed
        local bd="${PREFIX/#\~/$HOME}/bin"
        for f in "$bd/CalculiX" "$bd/ccx" "$bd/ccx_dev"; do [ -e "$f" ] || [ -L "$f" ] && files+=("$f"); done
        detect_shell_rc
        [ -n "$SHELL_RC" ] && rcs+=("$SHELL_RC")
        if [ ${#files[@]} -eq 0 ]; then
            echo "Nothing to uninstall (no manifest in ${DATA_DIR}, no ccx in ${bd})."
            echo "Installed somewhere else? Run again with --uninstall --prefix <dir>."
            return 0
        fi
        warn "No installer manifest found; these files look like a previous install."
    fi

    echo -e "\nWill remove:"
    for f in "${files[@]}"; do echo "  $f"; done
    for f in "${rcs[@]}"; do grep -qF "$PATH_MARKER" "$f" 2>/dev/null && echo "  PATH entry in $f"; done
    [ -d "$CACHE_DIR" ] && echo "  build cache ${CACHE_DIR} ($(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1))"

    if [ "$FORCE" -eq 0 ] && [ -z "$NON_INTERACTIVE" ]; then
        confirm "Uninstall CalculiX MultiSolver?" N || { echo "Cancelled."; return 0; }
    fi

    for f in "${files[@]}"; do rm -f "$f"; done
    for f in "${rcs[@]}"; do remove_path_entry "$f"; done
    rm -rf "$CACHE_DIR"
    for m in "${manifests[@]}"; do rm -f "$m"; done
    rmdir "$DATA_DIR" 2>/dev/null || true
    ok "CalculiX MultiSolver removed."
    echo -e "System packages installed as dependencies (Homebrew / apt / dnf / pacman: cmake, gcc,"
    echo -e "arpack, MUMPS, OpenBLAS, oneMKL, ...) were left in place; remove them with your package"
    echo -e "manager if nothing else needs them."
}

# -----------------------------------------------------------------------------
# Check for updates
# -----------------------------------------------------------------------------
# version_newer A B: true if release A is newer than B (v2.24-multisolver-0.2 style)
version_newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

do_check_update() {
    echo -e "\n${BOLD}${CYAN}--> Checking for updates${NC}"
    resolve_stable_tag
    resolve_edge_sha
    echo -e "  Latest stable release : ${BOLD}${STABLE_TAG:-unknown (offline?)}${NC}"
    echo -e "  Bleeding edge (main)  : ${BOLD}${EDGE_SHA:-unknown}${NC}\n"

    local m found=0 v ref commit
    m="$(manifest_path stable)"
    if [ -f "$m" ]; then
        found=1
        v="$(manifest_get "$m" version)"; ref="$(manifest_get "$m" ref)"
        if [ -n "$STABLE_TAG" ] && version_newer "$STABLE_TAG" "$v"; then
            echo -e "  ccx     : ${v} (${ref}) -> ${YELLOW}${BOLD}update available: ${STABLE_TAG}${NC}"
            echo -e "            re-run the installer and choose 1 (or: install.sh --stable)"
        else
            echo -e "  ccx     : ${v} (${ref}) ${GREEN}up to date${NC}"
        fi
    fi
    m="$(manifest_path edge)"
    if [ -f "$m" ]; then
        found=1
        commit="$(manifest_get "$m" commit)"
        if [ -n "$EDGE_SHA" ] && [ "${commit:0:7}" != "$EDGE_SHA" ]; then
            echo -e "  ccx_dev : main @ ${commit:0:7} -> ${YELLOW}${BOLD}newer main: ${EDGE_SHA}${NC}"
            echo -e "            re-run the installer and choose 3 (or: install.sh --edge)"
        else
            echo -e "  ccx_dev : main @ ${commit:0:7} ${GREEN}up to date${NC}"
        fi
    fi
    if [ "$found" -eq 0 ]; then
        if command -v ccx &>/dev/null; then
            v="$(edition_of "$(command -v ccx)")"
            echo -e "  ccx at $(command -v ccx): ${v:-unknown version} (not installed by this installer's"
            echo -e "  current version, so no manifest). Latest stable is ${STABLE_TAG:-unknown}."
        else
            echo "  No CalculiX MultiSolver installation found."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
    local exe
    exe="$(exe_name_of_channel "$(channel_of_action)")"
    echo -e "\n${BOLD}${BLUE}================================================================${NC}"
    echo -e "${BOLD}${GREEN}   CalculiX CrunchiX (CCX) Installed Successfully!              ${NC}"
    echo -e "${BOLD}${BLUE}================================================================${NC}"
    echo -e "Version              : ${BOLD}${INSTALLED_VERSION}${NC} (${INSTALL_METHOD}$( [ "$INSTALLED_NATIVE" = 1 ] && echo ', optimized for this computer'))"
    echo -e "To run a simulation  : ${CYAN}${exe} input_deck_name${NC}  (without .inp extension)"
    echo -e "\nDirect solvers built : ${BOLD}${GREEN}${BUILT_SOLVERS:-unknown}${NC}"
    if [ -n "$DEFAULT_SOLVER" ] && [ "$DEFAULT_SOLVER" != "NONE" ]; then
        echo -e "Default solver       : ${BOLD}${CYAN}$(solver_desc "$DEFAULT_SOLVER")${NC}"
        echo -e "                       (used automatically whenever an input deck omits 'SOLVER=')"
    fi

    # Warn about requested-but-missing solvers (CMake disables them in non-strict mode)
    if [ "$INSTALL_METHOD" = "source" ]; then
        local s
        for s in MUMPS:$WANT_MUMPS PARDISO:$WANT_MKL SPOOLES:$WANT_SPOOLES; do
            if [ "${s#*:}" -eq 1 ] && [[ ",${BUILT_SOLVERS}," != *",${s%%:*},"* ]]; then
                warn "${s%%:*} was requested but could not be enabled (see CMake warnings above)."
            fi
        done
    fi

    if [[ "$BUILT_SOLVERS" == *,* ]]; then
        echo -e "\n${BOLD}Selecting Alternative Solvers in Your Input Decks (*.inp):${NC}"
        [[ ",${BUILT_SOLVERS}," == *",MUMPS,"*      ]] && echo -e "  *STATIC, SOLVER=MUMPS       -> $(solver_desc MUMPS)"
        [[ ",${BUILT_SOLVERS}," == *",PARDISO,"*    ]] && echo -e "  *STATIC, SOLVER=PARDISO     -> $(solver_desc PARDISO)"
        [[ ",${BUILT_SOLVERS}," == *",ACCELERATE,"* ]] && echo -e "  *STATIC, SOLVER=ACCELERATE  -> $(solver_desc ACCELERATE)"
        [[ ",${BUILT_SOLVERS}," == *",SPOOLES,"*    ]] && echo -e "  *STATIC, SOLVER=SPOOLES     -> $(solver_desc SPOOLES)"
    fi
    echo -e "\nCheck for updates : ${CYAN}install.sh --check-update${NC}"
    echo -e "Uninstall         : ${CYAN}install.sh --uninstall${NC}"
    echo -e "${BOLD}${BLUE}================================================================${NC}\n"
}

banner() {
    echo -e "${BOLD}${CYAN}"
    echo -e "  ____  ____ __  __ "
    echo -e " / ___|/ ___|\\ \\/ / "
    echo -e "| |   | |     \\  /  "
    echo -e "| |___| |___  /  \\  "
    echo -e " \\____|\\____|/_/\\_\\ "
    echo -e "${NC}"
    echo -e "${BOLD}${BLUE}================================================================${NC}"
    echo -e "${BOLD}${MAGENTA}   CalculiX CrunchiX (CCX) Multi-Solver — Universal Installer  ${NC}"
    echo -e "${BOLD}${BLUE}================================================================${NC}"
}

main() {
    parse_args "$@"
    banner
    detect_platform

    if [ "$ACTION" = "check-update" ]; then do_check_update; exit 0; fi

    find_existing_prefix
    if [ -z "$ACTION" ]; then
        resolve_stable_tag
        resolve_edge_sha
        check_binary_available
        local sd; sd="$(script_dir)"
        if [ -n "$sd" ] && [ -f "${sd}/CMakeLists.txt" ] && [ -d "${sd}/src" ]; then
            echo -e "${CYAN}[INFO] Running from a checkout; use --local to build this checkout instead.${NC}"
        fi
        choose_action
    elif [ "$ACTION" = "stable" ] && [ -z "$CCX_REF" ] && [ "$USE_LOCAL" -eq 0 ]; then
        resolve_stable_tag
    elif [ "$ACTION" = "binary" ]; then
        resolve_stable_tag
        check_binary_available
    fi

    if [ "$ACTION" = "uninstall" ]; then
        [ -z "$EXISTING_PREFIX" ] || [ "$PREFIX_SET" -eq 1 ] || PREFIX="$EXISTING_PREFIX"
        do_uninstall
        exit 0
    fi
    if [ "$ACTION" = "binary" ] && [ "$BINARY_AVAILABLE" -eq 0 ]; then
        die "No prebuilt binary for ${PLATFORM} in release ${STABLE_TAG:-?} yet. Choose 1 (build latest stable) instead."
    fi

    # Phase 1: ask everything up front
    ask_prefix
    check_existing_installation
    if [ "$ACTION" = "binary" ]; then
        show_binary_solver_plan
    else
        if [ "${OS}" = "Linux" ]; then detect_pm; fi
        ask_solver_questions
        planned_solvers
        show_solver_plan "$PLANNED_SOLVERS" "$PLANNED_DEFAULT"
        if [ "$NATIVE" -eq 1 ]; then
            echo -e "  CPU tuning       : ${BOLD}on${NC} (-march/-mcpu=native; use --portable to switch off)"
        fi
    fi
    ask_path
    if [ -z "$NON_INTERACTIVE" ]; then
        confirm "Proceed?" Y || { echo "Cancelled."; exit 0; }
    fi

    # Phase 2: unattended installation
    if [ "$ACTION" = "binary" ]; then
        download_binary
    else
        if [ "${OS}" = "Darwin" ]; then
            install_macos_deps
        else
            install_linux_base
            install_linux_solver_deps
        fi
        planned_solvers
        fetch_source
        build_from_source
    fi
    write_manifest "$(channel_of_action)" "${INSTALLED_FILES[@]}"
    verify_install
    setup_path
    print_summary
}

main "$@"

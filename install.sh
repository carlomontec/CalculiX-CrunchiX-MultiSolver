#!/usr/bin/env bash
# ==============================================================================
# CalculiX CrunchiX (CCX) Multi-Solver — Universal Installer
#
# DESCRIPTION:
#   Downloads, configures, and builds CCX with support for multiple sparse
#   direct solvers (Apple Accelerate, PARDISO, MUMPS, SPOOLES) depending on
#   the detected OS and CPU architecture.
#
#   Design: all questions are asked first, then the installation runs
#   unattended. This script only installs packages and states intent; library
#   detection is done by CMake (CCX_SOLVERS_STRICT=OFF turns a missing optional
#   solver into a warning, and the solvers actually built are reported at the end).
#
# 1-LINER USAGE (Defaults to 'main' branch):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
#
# EXPERT USAGE (Selecting a specific branch, tag, or commit):
#   - Via curl:
#       CCX_REF=fix_accelerate_contact /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
#   - Via local script:
#       ./install.sh --ref v2.21
#       ./install.sh -b fix_accelerate_contact
#
# OPTIONS:
#   -b, --ref, --branch, --tag <ref>   Git branch, tag or commit (default: main, env: CCX_REF)
#   --prefix <dir>                     Install prefix; binary goes to <dir>/bin (default: ~/.local)
#   -y, --yes, --non-interactive       Accept all defaults without prompting (env: NON_INTERACTIVE=1)
#   -j, --jobs <n>                     Parallel build jobs (default: all cores)
#   -h, --help                         Show this help
# ==============================================================================

set -Eeo pipefail

REPO="carlomontec/CalculiX-CrunchiX-MultiSolver"
GITHUB_REPO_URL="https://github.com/${REPO}.git"

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
CCX_REF="${CCX_REF:-main}"
PREFIX="${HOME}/.local"
PREFIX_SET=0
NPROC=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--branch|-r|--ref|--tag)
                [ -n "$2" ] || die "Option $1 requires a value."
                CCX_REF="$2"; shift 2 ;;
            --prefix)
                [ -n "$2" ] || die "Option $1 requires a value."
                PREFIX="$2"; PREFIX_SET=1; shift 2 ;;
            -j|--jobs)
                [ -n "$2" ] || die "Option $1 requires a value."
                NPROC="$2"; shift 2 ;;
            -y|--yes|--non-interactive)
                NON_INTERACTIVE=1; shift ;;
            -h|--help)
                echo "Usage: $0 [--ref <branch|tag|commit>] [--prefix <dir>] [--yes] [--jobs <n>]"
                exit 0 ;;
            *)
                die "Unknown option: $1 (see --help)" ;;
        esac
    done
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

ask_questions() {
    echo ""
    if [ "$PREFIX_SET" -eq 0 ]; then
        ask_value "Install prefix (binary goes to <prefix>/bin)? [${PREFIX}]: " "${PREFIX}" PREFIX
    fi
    PREFIX="${PREFIX/#\~/$HOME}"
    BIN_DIR="${PREFIX}/bin"

    echo -e "\n${BOLD}${CYAN}--> Sparse direct solver selection${NC}"
    if [ "${OS}" = "Darwin" ]; then
        echo -e "${GREEN}[INFO] macOS Detected:${NC}"
        echo -e "  * Default Solver: ${BOLD}Apple Accelerate${NC} (native, zero external dependencies)."
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
    fi

    # PATH setup question
    SHELL_RC=""
    case "$(basename "${SHELL:-}")" in
        fish) SHELL_RC="${HOME}/.config/fish/config.fish" ;;
        zsh)  SHELL_RC="${HOME}/.zshrc" ;;
        bash) SHELL_RC="${HOME}/.bashrc" ;;
    esac
    if [ -n "$SHELL_RC" ]; then
        case ":${PATH}:" in
            *":${BIN_DIR}:"*) ;;  # already on PATH
            *) if confirm "Add ${BIN_DIR} to PATH in ${SHELL_RC}?" Y; then ADD_PATH=1; fi ;;
        esac
    fi
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
}

# -----------------------------------------------------------------------------
# Source checkout
# -----------------------------------------------------------------------------
fetch_source() {
    local script_dir=""
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    TEMP_ROOT="$(mktemp -d -t ccx_build_XXXXXX)"
    BUILD_DIR="${TEMP_ROOT}/build"

    if [ -n "$script_dir" ] && [ -f "${script_dir}/CMakeLists.txt" ] && [ -d "${script_dir}/src" ]; then
        SOURCE_DIR="${script_dir}"
        local ref
        ref="$(git -C "${SOURCE_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'local')"
        echo -e "Building from local repository: ${CYAN}${SOURCE_DIR}${NC} (branch/ref: ${BOLD}${GREEN}${ref}${NC})"
    else
        # NOTE (maintainer): fetch the latest GitHub Release instead of 'main' once official releases are published.
        info "Cloning CalculiX repository (Ref: ${CCX_REF})..."
        SOURCE_DIR="${TEMP_ROOT}/src"
        if [ "$CCX_REF" = "main" ]; then
            git clone --depth 1 "${GITHUB_REPO_URL}" "${SOURCE_DIR}"
        elif ! git clone --depth 1 --branch "${CCX_REF}" "${GITHUB_REPO_URL}" "${SOURCE_DIR}" 2>/dev/null; then
            # Not a branch/tag: assume a raw commit SHA
            rm -rf "${SOURCE_DIR}"
            git clone "${GITHUB_REPO_URL}" "${SOURCE_DIR}"
            git -C "${SOURCE_DIR}" checkout "${CCX_REF}"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Build, install, verify
# -----------------------------------------------------------------------------
on_off() { if [ "$1" -eq 1 ]; then echo ON; else echo OFF; fi; }

build_and_install() {
    local flags="-DCCX_SOLVERS_STRICT=OFF"

    if [ "${OS}" = "Darwin" ]; then
        flags="${flags} -DCCX_USE_ACCELERATE=ON -DCCX_USE_MUMPS=$(on_off $WANT_MUMPS)"
    else
        flags="${flags} -DCCX_USE_ACCELERATE=OFF -DCCX_USE_MUMPS=$(on_off $WANT_MUMPS)"
        flags="${flags} -DCCX_USE_PARDISO=$(on_off $WANT_MKL) -DCCX_USE_SPOOLES=$(on_off $WANT_SPOOLES)"
    fi

    info "Configuring and building CalculiX (${NPROC} parallel jobs)..."
    # shellcheck disable=SC2086
    cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" ${flags}
    cmake --build "${BUILD_DIR}" -j"${NPROC}"

    info "Installing to ${BIN_DIR}..."
    mkdir -p "${BIN_DIR}"
    rm -f "${BIN_DIR}/ccx"   # replace any binary or link from a previous install
    cmake --install "${BUILD_DIR}" --prefix "${PREFIX}"
    ok "Installed executables: ${BIN_DIR}/CalculiX (and 'ccx')"

    # Solvers actually compiled in (reported by CMake)
    BUILT_SOLVERS=""
    DEFAULT_SOLVER=""
    if [ -f "${BUILD_DIR}/ccx_solvers.txt" ]; then
        BUILT_SOLVERS="$(sed -n '1p' "${BUILD_DIR}/ccx_solvers.txt" | tr -d '\r\n')"
        DEFAULT_SOLVER="$(sed -n '2p' "${BUILD_DIR}/ccx_solvers.txt" | tr -d '\r\n')"
    fi
}

verify_install() {
    info "Running quick solver verification..."
    local deck="${SOURCE_DIR}/test/achtel2.inp"
    if [ ! -f "$deck" ]; then
        warn "Verification deck not found; skipping."
        return 0
    fi
    local vdir="${TEMP_ROOT}/verify"
    mkdir -p "$vdir"
    cp "$deck" "$vdir/"
    if ( cd "$vdir" && "${BIN_DIR}/ccx" achtel2 > run.log 2>&1 ) && grep -q "Job finished" "$vdir/run.log"; then
        ok "Verification test passed (achtel2.inp solved successfully)."
    else
        warn "Verification test FAILED. The installed binary may be broken; see output below."
        tail -n 20 "$vdir/run.log" 2>/dev/null || true
    fi
}

setup_path() {
    [ "$ADD_PATH" -eq 1 ] || return 0
    local marker="# CalculiX Multi-Solver (added by install.sh)"
    mkdir -p "$(dirname "${SHELL_RC}")"
    if [ -f "${SHELL_RC}" ] && grep -qF "$marker" "${SHELL_RC}"; then
        ok "PATH entry already present in ${SHELL_RC}."
        return 0
    fi
    {
        echo ""
        echo "$marker"
        if [[ "$SHELL_RC" == *fish* ]]; then
            echo "fish_add_path ${BIN_DIR}"
        else
            echo "export PATH=\"${BIN_DIR}:\$PATH\""
        fi
    } >> "${SHELL_RC}"
    ok "Added to ${SHELL_RC}. Run 'source ${SHELL_RC}' or open a new terminal."
}

print_summary() {
    echo -e "\n${BOLD}${BLUE}================================================================${NC}"
    echo -e "${BOLD}${GREEN}   CalculiX CrunchiX (CCX) Installed Successfully!              ${NC}"
    echo -e "${BOLD}${BLUE}================================================================${NC}"
    echo -e "To run a simulation:"
    echo -e "  ${CYAN}ccx input_deck_name${NC}  (without .inp extension)"
    echo -e "  or"
    echo -e "  ${CYAN}CalculiX input_deck_name${NC}"
    echo -e "\nDirect solvers built : ${BOLD}${GREEN}${BUILT_SOLVERS:-none (internal fallback only)}${NC}"
    if [ -n "$DEFAULT_SOLVER" ] && [ "$DEFAULT_SOLVER" != "NONE" ]; then
        local def_desc="$DEFAULT_SOLVER"
        case "$DEFAULT_SOLVER" in
            ACCELERATE) def_desc="Apple Accelerate (macOS Hardware)" ;;
            PARDISO)    def_desc="Intel oneMKL PARDISO (x86_64 AVX2/AVX-512)" ;;
            MUMPS)      def_desc="MUMPS 5.x (Open-Source Multi-Threaded)" ;;
            SPOOLES)    def_desc="SPOOLES 2.2 (Classic Built-in)" ;;
        esac
        echo -e "Default solver       : ${BOLD}${CYAN}${def_desc}${NC}"
        echo -e "                       (used automatically whenever an input deck omits 'SOLVER=')"
    fi

    # Warn about requested-but-missing solvers (CMake disables them in non-strict mode)
    local s
    for s in MUMPS:$WANT_MUMPS PARDISO:$WANT_MKL SPOOLES:$WANT_SPOOLES; do
        if [ "${s#*:}" -eq 1 ] && [[ ",${BUILT_SOLVERS}," != *",${s%%:*},"* ]]; then
            warn "${s%%:*} was requested but could not be enabled (see CMake warnings above)."
        fi
    done
    if [ -z "$BUILT_SOLVERS" ]; then
        warn "No sparse direct solver was built. Re-run the installer and enable MUMPS or another solver."
    fi

    if [[ "$BUILT_SOLVERS" == *,* ]]; then
        echo -e "\n${BOLD}Selecting Alternative Solvers in Your Input Decks (*.inp):${NC}"
        [[ ",${BUILT_SOLVERS}," == *",MUMPS,"*      ]] && echo -e "  *STATIC, SOLVER=MUMPS       -> MUMPS 5.x (Open-Source Multi-Threaded)"
        [[ ",${BUILT_SOLVERS}," == *",PARDISO,"*    ]] && echo -e "  *STATIC, SOLVER=PARDISO     -> Intel oneMKL PARDISO (x86_64 AVX2/AVX-512)"
        [[ ",${BUILT_SOLVERS}," == *",ACCELERATE,"* ]] && echo -e "  *STATIC, SOLVER=ACCELERATE  -> Apple Accelerate (macOS Hardware)"
        [[ ",${BUILT_SOLVERS}," == *",SPOOLES,"*    ]] && echo -e "  *STATIC, SOLVER=SPOOLES     -> SPOOLES 2.2 (Classic Built-in)"
    fi
    echo -e "\nSee README.md for complete solver benchmarks and documentation."
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
    if [ "${OS}" = "Linux" ]; then detect_pm; fi

    # Phase 1: ask everything up front
    ask_questions

    # Phase 2: unattended installation
    if [ "${OS}" = "Darwin" ]; then
        install_macos_deps
    else
        install_linux_base
        install_linux_solver_deps
    fi
    fetch_source
    build_and_install
    verify_install
    setup_path
    print_summary
}

main "$@"

#!/usr/bin/env bash
# ==============================================================================
# CalculiX CrunchiX (CCX) Multi-Solver — Universal Installer
#
# DESCRIPTION:
#   Downloads, configures, and builds CCX with support for multiple sparse 
#   direct solvers (Apple Accelerate, PARDISO, MUMPS, SPOOLES) depending on 
#   the detected OS and CPU architecture.
#
# 1-LINER USAGE (Defaults to 'main' branch):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
#
# EXPERT USAGE (Selecting a specific branch, tag, or commit):
#   You can bypass the default 'main' branch by exporting CCX_REF or passing flags.
#   - Via curl:
#       CCX_REF=fix_accelerate_contact /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
#   - Via local script:
#       ./install.sh --ref v2.21
#       ./install.sh -b fix_accelerate_contact
# ==============================================================================

set -e

REPO="carlomontec/CalculiX-CrunchiX-MultiSolver"
GITHUB_REPO_URL="https://github.com/${REPO}.git"

# Default Git reference (branch, tag, or commit)
CCX_REF="${CCX_REF:-main}"

# Parse optional command-line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--branch|-r|--ref|--tag)
            CCX_REF="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--ref <branch|tag|commit>]"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Color formatting
BOLD="\033[1m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
MAGENTA="\033[1;35m"
NC="\033[0m" # No Color

# Helper for interactive reading
prompt_read() {
    local prompt_msg="$1"
    local default_val="$2"
    local var_name="$3"
    local input_val=""

    if [ -n "$NON_INTERACTIVE" ]; then
        eval "$var_name=\"$default_val\""
        return 0
    fi

    if [ -t 0 ]; then
        read -r -p "$prompt_msg" input_val
    elif [ -c /dev/tty ]; then
        read -r -p "$prompt_msg" input_val < /dev/tty
    else
        input_val="$default_val"
    fi

    input_val="${input_val:-$default_val}"
    eval "$var_name=\"$input_val\""
}

# ASCII Banner
echo -e "${BOLD}${CYAN}"
echo -e "  ____  ____ __  __ "
echo -e " / ___|/ ___|\ \/ / "
echo -e "| |   | |     \  /  "
echo -e "| |___| |___  /  \  "
echo -e " \____|\____|/_/\_\ "
echo -e "${NC}"
echo -e "${BOLD}${BLUE}================================================================${NC}"
echo -e "${BOLD}${MAGENTA}   CalculiX CrunchiX (CCX) Multi-Solver — Universal Installer  ${NC}"
echo -e "${BOLD}${BLUE}================================================================${NC}"

# Detect OS and Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"
echo -e "Detected Platform: ${BOLD}${GREEN}${OS} (${ARCH})${NC}"

if [ "${OS}" = "Darwin" ] && [ "${ARCH}" != "arm64" ]; then
    echo -e "${RED}This project currently supports Apple Silicon macOS only (arm64).${NC}"
    exit 1
fi

# Determine number of build jobs
if [ "${OS}" = "Darwin" ]; then
    NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
else
    NPROC=$(nproc 2>/dev/null || echo 4)
fi

# -----------------------------------------------------------------------------
# 1. Target Install Directory Configuration
# -----------------------------------------------------------------------------
DEFAULT_INSTALL_DIR="${HOME}/.local/bin"
echo -e ""
prompt_read "Where should the binary be installed? [${DEFAULT_INSTALL_DIR}]: " "${DEFAULT_INSTALL_DIR}" INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
mkdir -p "${INSTALL_DIR}"

# -----------------------------------------------------------------------------
# 2. Source Directory & Git Checkout Management
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
TEMP_BUILD_DIR=""

cleanup() {
    if [ -n "$TEMP_BUILD_DIR" ] && [ -d "$TEMP_BUILD_DIR" ]; then
        rm -rf "$TEMP_BUILD_DIR"
    fi
}
trap cleanup EXIT

if [ -f "${SCRIPT_DIR}/CMakeLists.txt" ] && [ -d "${SCRIPT_DIR}/src" ]; then
    SOURCE_DIR="${SCRIPT_DIR}"
    CURRENT_GIT_REF="$(git -C "${SOURCE_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'local')"
    echo -e "Building from local repository: ${CYAN}${SOURCE_DIR}${NC} (branch/ref: ${BOLD}${GREEN}${CURRENT_GIT_REF}${NC})"
else
    echo -e "\n${YELLOW}[TODO: CARLO] Reminder: Update this script to fetch the latest GitHub Release instead of 'main' once official releases are published!${NC}"
    
    TEMP_BUILD_DIR="$(mktemp -d -t ccx_build_XXXXXX)"
    echo -e "\n${BOLD}${CYAN}--> Cloning CalculiX repository (Ref: ${CCX_REF})...${NC}"
    
    if [ "$CCX_REF" = "main" ]; then
        git clone --depth 1 "${GITHUB_REPO_URL}" "${TEMP_BUILD_DIR}/ccx"
    else
        # Try shallow branch/tag clone first; fallback to full clone + checkout if it's a raw commit SHA
        if ! git clone --depth 1 --branch "${CCX_REF}" "${GITHUB_REPO_URL}" "${TEMP_BUILD_DIR}/ccx" 2>/dev/null; then
            git clone "${GITHUB_REPO_URL}" "${TEMP_BUILD_DIR}/ccx"
            git -C "${TEMP_BUILD_DIR}/ccx" checkout "${CCX_REF}"
        fi
    fi

    SOURCE_DIR="${TEMP_BUILD_DIR}/ccx"
fi

# -----------------------------------------------------------------------------
# 3. Dependency Management
# -----------------------------------------------------------------------------
check_dependencies() {
    echo -e "\n${BOLD}${CYAN}--> Checking prerequisites and build tools...${NC}"

    if [ "${OS}" = "Darwin" ]; then
        if ! command -v brew &>/dev/null; then
            if [ -x "/opt/homebrew/bin/brew" ]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [ -x "/usr/local/bin/brew" ]; then
                eval "$(/usr/local/bin/brew shellenv)"
            else
                echo -e "\n${YELLOW}Homebrew is recommended to install build tools (cmake, gcc, arpack).${NC}"
                prompt_read "Install Homebrew now? [Y/n] " "Y" INSTALL_BREW
                if [[ "$INSTALL_BREW" =~ ^[Yy]$ ]]; then
                    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                    if [ -x "/opt/homebrew/bin/brew" ]; then
                        eval "$(/opt/homebrew/bin/brew shellenv)"
                    elif [ -x "/usr/local/bin/brew" ]; then
                        eval "$(/usr/local/bin/brew shellenv)"
                    fi
                fi
            fi
        fi

        MISSING_BREW=""
        command -v cmake &>/dev/null || MISSING_BREW="${MISSING_BREW} cmake"
        command -v gfortran &>/dev/null || MISSING_BREW="${MISSING_BREW} gcc"
        brew list arpack &>/dev/null 2>&1 || MISSING_BREW="${MISSING_BREW} arpack"

        if [ -n "${MISSING_BREW}" ]; then
            echo -e "${YELLOW}Missing packages:${NC}${MISSING_BREW}"
            prompt_read "Install missing packages via Homebrew? [Y/n] " "Y" INSTALL_PKGS
            if [[ "$INSTALL_PKGS" =~ ^[Yy]$ ]]; then
                brew install ${MISSING_BREW}
            fi
        else
            echo -e "${GREEN}[OK] All macOS build tools and ARPACK found.${NC}"
        fi

    elif [ "${OS}" = "Linux" ]; then
        if command -v apt-get &>/dev/null; then
            MISSING_APT=""
            command -v cmake &>/dev/null || MISSING_APT="${MISSING_APT} cmake"
            command -v gfortran &>/dev/null || MISSING_APT="${MISSING_APT} gfortran"
            command -v gcc &>/dev/null || MISSING_APT="${MISSING_APT} build-essential"
            dpkg -l | grep -q "libopenblas-dev" || MISSING_APT="${MISSING_APT} libopenblas-dev"
            dpkg -l | grep -q "liblapack-dev" || MISSING_APT="${MISSING_APT} liblapack-dev"
            dpkg -l | grep -q "libarpack2-dev" || MISSING_APT="${MISSING_APT} libarpack2-dev"

            if [ -n "${MISSING_APT}" ]; then
                echo -e "${YELLOW}Missing build packages:${NC}${MISSING_APT}"
                prompt_read "Install required packages via apt (requires sudo)? [Y/n] " "Y" INSTALL_PKGS
                if [[ "$INSTALL_PKGS" =~ ^[Yy]$ ]]; then
                    sudo apt-get update && sudo apt-get install -y ${MISSING_APT}
                fi
            else
                echo -e "${GREEN}[OK] Base Linux build tools found.${NC}"
            fi
        elif command -v dnf &>/dev/null; then
            MISSING_DNF=""
            command -v cmake &>/dev/null || MISSING_DNF="${MISSING_DNF} cmake"
            command -v gfortran &>/dev/null || MISSING_DNF="${MISSING_DNF} gcc-gfortran"
            command -v gcc &>/dev/null || MISSING_DNF="${MISSING_DNF} gcc"

            if [ -n "${MISSING_DNF}" ]; then
                echo -e "${YELLOW}Missing build packages:${NC}${MISSING_DNF}"
                prompt_read "Install required packages via dnf (requires sudo)? [Y/n] " "Y" INSTALL_PKGS
                if [[ "$INSTALL_PKGS" =~ ^[Yy]$ ]]; then
                    sudo dnf install -y ${MISSING_DNF} openblas-devel lapack-devel arpack-devel
                fi
            fi
        elif command -v pacman &>/dev/null; then
            MISSING_PAC=""
            command -v cmake &>/dev/null || MISSING_PAC="${MISSING_PAC} cmake"
            command -v gfortran &>/dev/null || MISSING_PAC="${MISSING_PAC} gcc-fortran"

            if [ -n "${MISSING_PAC}" ]; then
                prompt_read "Install required packages via pacman (requires sudo)? [Y/n] " "Y" INSTALL_PKGS
                if [[ "$INSTALL_PKGS" =~ ^[Yy]$ ]]; then
                    sudo pacman -S --needed base-devel gcc-fortran cmake openblas lapack arpack
                fi
            fi
        fi
    fi
}

check_dependencies

# -----------------------------------------------------------------------------
# 4. Solver Backend Configuration & Dependencies
# -----------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}--> Configuring Sparse Direct Solvers...${NC}"

# 1. Initialize ALL solvers to OFF to prevent dirty CMake cache issues
CMAKE_SOLVER_FLAGS="-DCCX_USE_ACCELERATE=OFF -DCCX_USE_MUMPS=OFF -DCCX_USE_PARDISO=OFF -DCCX_USE_SPOOLES=OFF"
SOLVER_NAME="None Selected (Fallback to internal)"

if [ "${OS}" = "Darwin" ]; then
    echo -e "${GREEN}[INFO] macOS Detected:${NC}"
    echo -e "  * Default Solver: ${BOLD}Apple Accelerate${NC} (Native hardware acceleration, zero external dependencies)."
    echo -e "  * An open-source solver (${BOLD}MUMPS 5.x${NC}) is also available as an option.\n"

    prompt_read "Also build MUMPS 5.x as an additional open-source solver? [y/N]: " "N" ENABLE_MUMPS
    if [[ "$ENABLE_MUMPS" =~ ^[Yy]$ ]]; then
        CMAKE_SOLVER_FLAGS="${CMAKE_SOLVER_FLAGS} -DCCX_USE_ACCELERATE=ON -DCCX_USE_MUMPS=ON"
        SOLVER_NAME="Apple Accelerate (Default) + vendored MUMPS 5.x"
    else
        CMAKE_SOLVER_FLAGS="${CMAKE_SOLVER_FLAGS} -DCCX_USE_ACCELERATE=ON"
        SOLVER_NAME="Apple Accelerate (Native)"
    fi

elif [ "${OS}" = "Linux" ]; then
    echo -e "${GREEN}[INFO] Linux Detected:${NC}"
    
    # --- MUMPS ---
    prompt_read "Enable MUMPS 5.x as an open-source multi-threaded direct solver? [Y/n]: " "Y" USE_MUMPS
    if [[ "$USE_MUMPS" =~ ^[Yy]$ ]]; then
        echo -e "${MAGENTA}Installing MUMPS...${NC}"
        MUMPS_INSTALLED=true
        if command -v apt-get &>/dev/null; then
            dpkg -l | grep -q "libmumps-seq-dev" || sudo apt-get install -y libmumps-seq-dev || MUMPS_INSTALLED=false
        elif command -v dnf &>/dev/null; then
            rpm -q MUMPS-devel &>/dev/null || sudo dnf install -y MUMPS-devel || MUMPS_INSTALLED=false
        elif command -v pacman &>/dev/null; then
            # Checks for either mumps or mumps-seq
            pacman -Qs mumps &>/dev/null || sudo pacman -S --needed mumps-seq || MUMPS_INSTALLED=false
        fi
        
        if [ "$MUMPS_INSTALLED" = true ]; then
            CMAKE_SOLVER_FLAGS="${CMAKE_SOLVER_FLAGS} -DCCX_USE_MUMPS=ON"
            SOLVER_NAME="MUMPS 5.x"
        else
            echo -e "${YELLOW}Warning: 'mumps' could not be installed (likely requires AUR on Arch: e.g., yay -S mumps). Skipping MUMPS.${NC}"
        fi
    fi

    if [ "${ARCH}" = "x86_64" ]; then
        IS_AMD=false
        if grep -q -i "authenticamd" /proc/cpuinfo 2>/dev/null || (command -v lscpu &>/dev/null && lscpu | grep -q -i "AMD"); then
            IS_AMD=true
        fi

        if [ "$IS_AMD" = true ]; then
            echo -e "\n${BOLD}${YELLOW}AMD Zen CPU Architecture Detected (Ryzen/EPYC/Threadripper):${NC}"
            echo -e "  AMD provides ${BOLD}AOCL-BLIS${NC} (open-source linear algebra tuned specifically for AMD CPUs)."
            prompt_read "Would you like to install and enable AMD AOCL (BLIS)? [Y/n]: " "Y" USE_AOCL
            if [[ "$USE_AOCL" =~ ^[Yy]$ ]]; then
                echo -e "${MAGENTA}Installing AMD BLIS/AOCL linear algebra libraries...${NC}"
                if command -v apt-get &>/dev/null; then
                    sudo apt-get install -y libblis-openmp-dev libflame-dev 2>/dev/null || sudo apt-get install -y libblis-dev 2>/dev/null || true
                elif command -v dnf &>/dev/null; then
                    sudo dnf install -y blis-devel libflame-devel 2>/dev/null || true
                elif command -v pacman &>/dev/null; then
                    sudo pacman -S --needed blis 2>/dev/null || true
                fi
            fi
        fi

        echo -e "\n${BOLD}${BLUE}Intel oneMKL PARDISO Solver Option:${NC}"
        echo -e "  Intel oneMKL is ${BOLD}proprietary (not open-source)${NC}, but generally provides"
        echo -e "  ${BOLD}higher performance${NC} on Intel and AMD x86_64 CPUs with AVX2/AVX-512 acceleration."
        
        HAS_MKL=false
        if [ -n "$MKLROOT" ] || [ -d "/opt/intel/oneapi/mkl" ] || [ -f "/usr/include/mkl/mkl.h" ] || [ -f "/usr/include/mkl.h" ]; then
            HAS_MKL=true
        fi

        if [ "$HAS_MKL" = true ]; then
            prompt_read "Found Intel oneMKL on your system. Enable Intel oneMKL PARDISO? [Y/n]: " "Y" USE_MKL
        else
            prompt_read "Would you like to install and enable Intel oneMKL PARDISO? [y/N]: " "N" USE_MKL
            if [[ "$USE_MKL" =~ ^[Yy]$ ]]; then
                echo -e "${MAGENTA}Installing Intel oneMKL...${NC}"
                if command -v apt-get &>/dev/null; then
                    wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | gpg --dearmor | sudo tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null
                    echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | sudo tee /etc/apt/sources.list.d/oneAPI.list
                    sudo apt-get update && sudo apt-get install -y intel-oneapi-mkl-devel || true
                elif command -v dnf &>/dev/null; then
                    sudo dnf install -y intel-oneapi-mkl-devel || true
                elif command -v pacman &>/dev/null; then
                    sudo pacman -S --needed intel-oneapi-mkl || echo -e "${YELLOW}Warning: 'intel-oneapi-mkl' may require AUR on Arch.${NC}"
                fi
                HAS_MKL=true
            fi
        fi

        if [[ "$USE_MKL" =~ ^[Yy]$ ]]; then
            CMAKE_SOLVER_FLAGS="${CMAKE_SOLVER_FLAGS} -DCCX_USE_PARDISO=ON"
            if [[ "$SOLVER_NAME" == "MUMPS 5.x" ]]; then
                SOLVER_NAME="Intel oneMKL PARDISO + MUMPS 5.x"
            else
                SOLVER_NAME="Intel oneMKL PARDISO"
            fi
        fi

        # --- SPOOLES (x86_64) ---
        prompt_read "Also enable legacy SPOOLES solver via system library (libspooles-dev)? [y/N]: " "N" USE_SPOOLES
        if [[ "$USE_SPOOLES" =~ ^[Yy]$ ]]; then
            SPOOLES_INSTALLED=true
            if command -v apt-get &>/dev/null; then
                sudo apt-get install -y libspooles-dev || SPOOLES_INSTALLED=false
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y spooles-devel || SPOOLES_INSTALLED=false
            elif command -v pacman &>/dev/null; then
                pacman -Qi spooles &>/dev/null || sudo pacman -S --needed spooles || SPOOLES_INSTALLED=false
            fi
            
            if [ "$SPOOLES_INSTALLED" = true ]; then
                CMAKE_SOLVER_FLAGS="${CMAKE_SOLVER_FLAGS} -DCCX_USE_SPOOLES=ON"
                if [[ "$SOLVER_NAME" == "None Selected"* ]]; then
                    SOLVER_NAME="SPOOLES 2.2"
                else
                    SOLVER_NAME="${SOLVER_NAME} + SPOOLES 2.2"
                fi
            else
                echo -e "${YELLOW}Warning: 'spooles' could not be installed (likely requires AUR on Arch: e.g., yay -S spooles). Skipping SPOOLES.${NC}"
            fi
        fi

    else
        # Linux ARM64 (aarch64)
        echo -e "\n${CYAN}[INFO] Linux ARM64 architecture detected.${NC}"
        echo -e "  Intel oneMKL is not available on Linux ARM64."

        # --- SPOOLES (ARM64) ---
        prompt_read "Also enable legacy SPOOLES solver via system library (libspooles-dev)? [y/N]: " "N" USE_SPOOLES
        if [[ "$USE_SPOOLES" =~ ^[Yy]$ ]]; then
            SPOOLES_INSTALLED=true
            if command -v apt-get &>/dev/null; then
                sudo apt-get install -y libspooles-dev || SPOOLES_INSTALLED=false
            elif command -v pacman &>/dev/null; then
                pacman -Qi spooles &>/dev/null || sudo pacman -S --needed spooles || SPOOLES_INSTALLED=false
            fi
            
            if [ "$SPOOLES_INSTALLED" = true ]; then
                CMAKE_SOLVER_FLAGS="${CMAKE_SOLVER_FLAGS} -DCCX_USE_SPOOLES=ON"
                if [[ "$SOLVER_NAME" == "None Selected"* ]]; then
                    SOLVER_NAME="SPOOLES 2.2"
                else
                    SOLVER_NAME="${SOLVER_NAME} + SPOOLES 2.2"
                fi
            else
                echo -e "${YELLOW}Warning: 'spooles' could not be installed (likely requires AUR on Arch). Skipping SPOOLES.${NC}"
            fi
        fi
    fi
fi

echo -e "Configured Solver Backends: ${BOLD}${GREEN}${SOLVER_NAME}${NC}"

# -----------------------------------------------------------------------------
# 5. Compilation & Build
# -----------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}--> Configuring and building CalculiX (${NPROC} parallel jobs)...${NC}"



cd "${SOURCE_DIR}"

rm -rf build

cmake -B build ${CMAKE_SOLVER_FLAGS}
cmake --build build -j"${NPROC}"

# -----------------------------------------------------------------------------
# 6. Installation
# -----------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}--> Installing binary to ${INSTALL_DIR}...${NC}"

cp "${SOURCE_DIR}/build/CalculiX" "${INSTALL_DIR}/ccx"
chmod +x "${INSTALL_DIR}/ccx"

echo -e "${GREEN}[OK] Installed executable: ${INSTALL_DIR}/ccx${NC}"

# -----------------------------------------------------------------------------
# 7. Shell Configuration (Aliases & PATH)
# -----------------------------------------------------------------------------
SHELL_RC=""
if [[ "$SHELL" == *"fish"* ]] || [ -f "${HOME}/.config/fish/config.fish" ]; then
    SHELL_RC="${HOME}/.config/fish/config.fish"
elif [[ "$SHELL" == *"zsh"* ]] || [ -n "$ZSH_VERSION" ] || [ -f "${HOME}/.zshrc" ]; then
    SHELL_RC="${HOME}/.zshrc"
elif [[ "$SHELL" == *"bash"* ]] || [ -n "$BASH_VERSION" ] || [ -f "${HOME}/.bashrc" ]; then
    SHELL_RC="${HOME}/.bashrc"
fi

if [ -n "$SHELL_RC" ]; then
    echo -e ""
    prompt_read "Add ${INSTALL_DIR} to PATH and create 'CalculiX' alias in ${SHELL_RC}? [Y/n] " "Y" ADD_ALIAS
    if [[ "$ADD_ALIAS" =~ ^[Yy]$ ]]; then
        echo -e "\n# CalculiX Multi-Solver" >> "${SHELL_RC}"
        if [[ "$SHELL_RC" == *"fish"* ]]; then
            echo -e "fish_add_path ${INSTALL_DIR}" >> "${SHELL_RC}"
            echo -e "alias CalculiX 'ccx'" >> "${SHELL_RC}"
        else
            echo -e "export PATH=\"${INSTALL_DIR}:\$PATH\"" >> "${SHELL_RC}"
            echo -e "alias CalculiX='ccx'" >> "${SHELL_RC}"
        fi
        echo -e "${GREEN}[OK] Added to ${SHELL_RC}. Run 'source ${SHELL_RC}' or open a new terminal.${NC}"
    fi
fi

# -----------------------------------------------------------------------------
# 8. Quick Sanity Check
# -----------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}--> Running quick solver verification...${NC}"
if [ -d "${SOURCE_DIR}/test" ] && [ -f "${SOURCE_DIR}/test/achtel2.inp" ]; then
    (
        cd "${SOURCE_DIR}/test"
        "${INSTALL_DIR}/ccx" achtel2 >/dev/null 2>&1 || true
        if [ -f "achtel2.dat" ]; then
            echo -e "${GREEN}[OK] Verification test passed (achtel2.inp solved successfully)!${NC}"
            rm -f achtel2.dat achtel2.frd achtel2.sta achtel2.cvg
        fi
    )
fi

# -----------------------------------------------------------------------------
# 9. Source Code Cleanup
# -----------------------------------------------------------------------------
if [ -n "$TEMP_BUILD_DIR" ] && [ -d "$TEMP_BUILD_DIR" ]; then
    echo -e "\n${BOLD}${CYAN}--> Cleaning up temporary build files...${NC}"
    rm -rf "$TEMP_BUILD_DIR"
    TEMP_BUILD_DIR=""
    echo -e "${GREEN}[OK] Temporary source code removed.${NC}"
fi

echo -e "\n${BOLD}${BLUE}================================================================${NC}"
echo -e "${BOLD}${GREEN}   CalculiX CrunchiX (CCX) Installed Successfully!              ${NC}"
echo -e "${BOLD}${BLUE}================================================================${NC}"
echo -e "To run a simulation:"
echo -e "  ${CYAN}ccx input_deck_name${NC}  (without .inp extension)"
echo -e "  or"
echo -e "  ${CYAN}CalculiX input_deck_name${NC}"
echo -e "\n${BOLD}Selecting Solvers in Your Input Decks (*.inp):${NC}"
echo -e "  *STATIC, SOLVER=MUMPS       -> MUMPS 5.x (Open-Source Multi-Threaded)"
echo -e "  *STATIC, SOLVER=PARDISO     -> Intel oneMKL PARDISO (x86_64 AVX-512)"
echo -e "  *STATIC, SOLVER=ACCELERATE  -> Apple Accelerate (macOS Hardware)"
echo -e "  *STATIC, SOLVER=SPOOLES     -> SPOOLES 2.2 (Classic Built-in)"
echo -e "\nSee README.md for complete solver benchmarks and documentation."
echo -e "${BOLD}${BLUE}================================================================${NC}\n"

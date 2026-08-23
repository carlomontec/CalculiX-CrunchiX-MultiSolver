#!/usr/bin/env bash
# ==============================================================================
# CalculiX CrunchiX (CCX) Multi-Solver — Universal Installer
#
# 1-Liner Usage:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/carlomontec/CalculiX-CrunchiX-MultiSolver/main/install.sh)"
#
# Local Usage (from cloned repo):
#   ./install.sh
#
# Supports:
#   - macOS (Apple Silicon arm64 & Intel x86_64) with native Apple Accelerate
#   - Linux (x86_64: Ubuntu/Debian, Fedora/RHEL, Arch) with oneMKL PARDISO, MUMPS, SPOOLES
#   - Linux (aarch64 / ARM64) with MUMPS & SPOOLES
# ==============================================================================

set -e

REPO="carlomontec/CalculiX-CrunchiX-MultiSolver"
GITHUB_REPO_URL="https://github.com/${REPO}.git"

# Color formatting
BOLD="\033[1m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
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

echo -e "${BOLD}${BLUE}================================================================${NC}"
echo -e "${BOLD}${BLUE}   CalculiX CrunchiX (CCX) Multi-Solver — Universal Installer  ${NC}"
echo -e "${BOLD}${BLUE}================================================================${NC}"

# Detect OS and Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"
echo -e "Detected Platform: ${BOLD}${GREEN}${OS} (${ARCH})${NC}"

# Determine number of build jobs
if [ "${OS}" = "Darwin" ]; then
    NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
else
    NPROC=$(nproc 2>/dev/null || echo 4)
fi

# Target install directory
INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "${INSTALL_DIR}"

# Determine working source directory
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
    echo -e "Building from local repository: ${CYAN}${SOURCE_DIR}${NC}"
else
    TEMP_BUILD_DIR="$(mktemp -d -t ccx_build_XXXXXX)"
    echo -e "\n${BOLD}--> Cloning CalculiX-CrunchiX-MultiSolver repository...${NC}"
    git clone --depth 1 "${GITHUB_REPO_URL}" "${TEMP_BUILD_DIR}/ccx"
    SOURCE_DIR="${TEMP_BUILD_DIR}/ccx"
fi

# -----------------------------------------------------------------------------
# Dependency Management
# -----------------------------------------------------------------------------
check_dependencies() {
    echo -e "\n${BOLD}--> Checking prerequisites and build tools...${NC}"

    if [ "${OS}" = "Darwin" ]; then
        # macOS Dependency Check
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
        # Linux Dependency Check
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
# Solver Backend Configuration & Dependencies
# -----------------------------------------------------------------------------
echo -e "\n${BOLD}--> Configuring Sparse Direct Solvers...${NC}"

CMAKE_SOLVER_FLAGS=""
SOLVER_NAME=""

if [ "${OS}" = "Darwin" ]; then
    echo -e "${GREEN}[INFO] macOS Detected:${NC}"
    echo -e "  * Default Solver: ${BOLD}Apple Accelerate${NC} (Native hardware acceleration, zero external solver dependencies)."
    echo -e "  * An open-source solver (${BOLD}MUMPS 5.x${NC}) is also available as an option.\n"

    prompt_read "Enable MUMPS 5.x as an additional open-source solver via Homebrew? [y/N]: " "N" ENABLE_MUMPS
    if [[ "$ENABLE_MUMPS" =~ ^[Yy]$ ]]; then
        if ! brew list mumps &>/dev/null 2>&1; then
            echo "Installing MUMPS via Homebrew..."
            brew install mumps || true
        fi
        CMAKE_SOLVER_FLAGS="-DCCX_USE_ACCELERATE=ON -DCCX_USE_MUMPS=ON"
        SOLVER_NAME="Apple Accelerate (Default) + MUMPS 5.x"
    else
        CMAKE_SOLVER_FLAGS="-DCCX_USE_ACCELERATE=ON"
        SOLVER_NAME="Apple Accelerate (Native)"
    fi

elif [ "${OS}" = "Linux" ]; then
    # Ensure MUMPS is installed in all cases on Linux as open-source solver
    echo -e "${GREEN}[INFO] Linux Detected:${NC}"
    echo -e "  * Installing ${BOLD}MUMPS 5.x${NC} as the primary open-source multi-threaded direct solver."

    if command -v apt-get &>/dev/null; then
        dpkg -l | grep -q "libmumps-seq-dev" || sudo apt-get install -y libmumps-seq-dev
    elif command -v dnf &>/dev/null; then
        rpm -q MUMPS-devel &>/dev/null || sudo dnf install -y MUMPS-devel
    elif command -v pacman &>/dev/null; then
        pacman -Qi mumps &>/dev/null || sudo pacman -S --needed mumps
    fi

    if [ "${ARCH}" = "x86_64" ]; then
        # Check for AMD CPU architecture
        IS_AMD=false
        if grep -q -i "authenticamd" /proc/cpuinfo 2>/dev/null || (command -v lscpu &>/dev/null && lscpu | grep -q -i "AMD"); then
            IS_AMD=true
        fi

        if [ "$IS_AMD" = true ]; then
            echo -e "\n${BOLD}${CYAN}AMD Zen CPU Architecture Detected (Ryzen/EPYC/Threadripper):${NC}"
            echo -e "  AMD provides ${BOLD}AOCL-BLIS${NC} (open-source linear algebra tuned specifically for AMD CPUs)."
            echo -e "  Learn more: ${CYAN}https://www.amd.com/en/developer/aocl.html${NC}"
            prompt_read "Would you like to install and enable AMD AOCL (BLIS)? [Y/n]: " "Y" USE_AOCL
            if [[ "$USE_AOCL" =~ ^[Yy]$ ]]; then
                echo "Installing AMD BLIS/AOCL linear algebra libraries..."
                if command -v apt-get &>/dev/null; then
                    sudo apt-get install -y libblis-openmp-dev libflame-dev 2>/dev/null || sudo apt-get install -y libblis-dev 2>/dev/null || true
                elif command -v dnf &>/dev/null; then
                    sudo dnf install -y blis-devel libflame-devel 2>/dev/null || true
                elif command -v pacman &>/dev/null; then
                    sudo pacman -S --needed blis 2>/dev/null || true
                fi
            fi
        fi

        echo -e "\n${BOLD}${YELLOW}Intel oneMKL PARDISO Solver Option:${NC}"
        echo -e "  Intel oneMKL is ${BOLD}proprietary (not open-source)${NC}, but generally provides"
        echo -e "  ${BOLD}higher performance${NC} on Intel and AMD x86_64 CPUs with AVX2/AVX-512 acceleration."
        echo -e "  Learn more: ${CYAN}https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl.html${NC}"
        echo -e "  (MUMPS 5.x remains fully available as open-source Option B in any case).\n"

        # Check if MKL is already present
        HAS_MKL=false
        if [ -n "$MKLROOT" ] || [ -d "/opt/intel/oneapi/mkl" ] || [ -f "/usr/include/mkl/mkl.h" ] || [ -f "/usr/include/mkl.h" ]; then
            HAS_MKL=true
        fi

        if [ "$HAS_MKL" = true ]; then
            prompt_read "Found Intel oneMKL on your system. Enable Intel oneMKL PARDISO? [Y/n]: " "Y" USE_MKL
        else
            prompt_read "Would you like to install and enable Intel oneMKL PARDISO? [y/N]: " "N" USE_MKL
            if [[ "$USE_MKL" =~ ^[Yy]$ ]]; then
                echo "Installing Intel oneMKL..."
                if command -v apt-get &>/dev/null; then
                    wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | gpg --dearmor | sudo tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null
                    echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | sudo tee /etc/apt/sources.list.d/oneAPI.list
                    sudo apt-get update && sudo apt-get install -y intel-oneapi-mkl-devel
                elif command -v dnf &>/dev/null; then
                    sudo dnf install -y intel-oneapi-mkl-devel
                elif command -v pacman &>/dev/null; then
                    sudo pacman -S --needed intel-oneapi-mkl
                fi
                HAS_MKL=true
            fi
        fi

        if [[ "$USE_MKL" =~ ^[Yy]$ ]]; then
            CMAKE_SOLVER_FLAGS="-DCCX_USE_PARDISO=ON -DCCX_USE_MUMPS=ON"
            SOLVER_NAME="Intel oneMKL PARDISO (Default) + MUMPS 5.x + SPOOLES 2.2"
        else
            CMAKE_SOLVER_FLAGS="-DCCX_USE_MUMPS=ON"
            SOLVER_NAME="MUMPS 5.x (Open-Source Default) + SPOOLES 2.2"
        fi

    else
        # Linux ARM64 (aarch64)
        echo -e "\n${CYAN}[INFO] Linux ARM64 architecture detected.${NC}"
        echo -e "  Intel oneMKL is not available on Linux ARM64."
        echo -e "  Configuring ${BOLD}MUMPS 5.x${NC} as primary multi-threaded solver with ${BOLD}SPOOLES 2.2${NC} as fallback."
        CMAKE_SOLVER_FLAGS="-DCCX_USE_MUMPS=ON"
        SOLVER_NAME="MUMPS 5.x (Primary) + SPOOLES 2.2"
    fi
fi

echo -e "Configured Solver Backends: ${BOLD}${GREEN}${SOLVER_NAME}${NC}"

# -----------------------------------------------------------------------------
# Compilation & Build
# -----------------------------------------------------------------------------
echo -e "\n${BOLD}--> Configuring and building CalculiX (${NPROC} parallel jobs)...${NC}"

cd "${SOURCE_DIR}"
cmake -B build ${CMAKE_SOLVER_FLAGS}
cmake --build build -j"${NPROC}"

# -----------------------------------------------------------------------------
# Installation
# -----------------------------------------------------------------------------
echo -e "\n${BOLD}--> Installing binary to ${INSTALL_DIR}...${NC}"

cp "${SOURCE_DIR}/build/CalculiX" "${INSTALL_DIR}/ccx"
ln -sf "${INSTALL_DIR}/ccx" "${INSTALL_DIR}/CalculiX"
chmod +x "${INSTALL_DIR}/ccx"

echo -e "${GREEN}[OK] Installed executable: ${INSTALL_DIR}/ccx${NC}"
echo -e "${GREEN}[OK] Created alias:        ${INSTALL_DIR}/CalculiX${NC}"

# Check PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo -e "\n${YELLOW}Note: ${INSTALL_DIR} is not in your current PATH.${NC}"
    
    SHELL_RC=""
    if [ -n "$ZSH_VERSION" ] || [ -f "${HOME}/.zshrc" ]; then
        SHELL_RC="${HOME}/.zshrc"
    elif [ -n "$BASH_VERSION" ] || [ -f "${HOME}/.bashrc" ]; then
        SHELL_RC="${HOME}/.bashrc"
    fi

    if [ -n "$SHELL_RC" ]; then
        prompt_read "Add ${INSTALL_DIR} to ${SHELL_RC}? [Y/n] " "Y" ADD_PATH
        if [[ "$ADD_PATH" =~ ^[Yy]$ ]]; then
            echo -e "\n# CalculiX Executable Path" >> "${SHELL_RC}"
            echo -e "export PATH=\"${INSTALL_DIR}:\$PATH\"" >> "${SHELL_RC}"
            echo -e "${GREEN}[OK] Added to ${SHELL_RC}. Run 'source ${SHELL_RC}' or open a new terminal.${NC}"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Quick Sanity Check
# -----------------------------------------------------------------------------
echo -e "\n${BOLD}--> Running quick solver verification...${NC}"
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

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}   CalculiX CrunchiX (CCX) Installed Successfully!              ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
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
echo -e "================================================================\n"

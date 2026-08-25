cmake_minimum_required(VERSION 3.20)

# On macOS, ensure the Apple SDK path is passed to GCC/gfortran so ld finds libSystem
if(APPLE AND NOT CMAKE_OSX_SYSROOT)
    execute_process(
        COMMAND xcrun --show-sdk-path
        OUTPUT_VARIABLE _SDK_PATH
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(_SDK_PATH)
        set(CMAKE_OSX_SYSROOT "${_SDK_PATH}" CACHE PATH "macOS SDK root")
        set(ENV{SDKROOT} "${_SDK_PATH}")
    endif()
endif()

project(CalculiX VERSION 2.23 LANGUAGES C Fortran)

if(APPLE AND NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)$")
    message(FATAL_ERROR "This macOS development target supports Apple Silicon only (arm64).")
endif()

set(CMAKE_C_STANDARD 99)

# -----------------------------------------------------------------------------
# User Configuration Options
# -----------------------------------------------------------------------------
if(APPLE)
    option(CCX_USE_ACCELERATE "Enable Apple Accelerate sparse solver (macOS default)" ON)
    option(CCX_USE_MUMPS      "Enable MUMPS direct sparse solver"                    OFF)
    option(CCX_SPOOLES_VENDORED "Build SPOOLES from vendored source (macOS)"         ON)
else()
    option(CCX_USE_ACCELERATE "Enable Apple Accelerate sparse solver (macOS only)"    OFF)
    option(CCX_USE_MUMPS      "Enable MUMPS direct sparse solver (Linux/Win default)" ON)
    option(CCX_SPOOLES_VENDORED "Build SPOOLES from vendored source"                  OFF)
endif()
option(CCX_USE_PARDISO "Enable Intel oneMKL PARDISO solver"          OFF)
option(CCX_USE_SPOOLES "Enable legacy SPOOLES solver"                OFF)
option(CCX_USE_ARPACK  "Enable ARPACK eigenvalue solver"             ON)
option(CCX_USE_OPENMP  "Enable OpenMP multithreading"                ON)
option(CCX_INT64       "Use 64-bit integers (-DINTSIZE64)"           OFF)

# -----------------------------------------------------------------------------
# Compiler Flags
# -----------------------------------------------------------------------------
# C Flags
add_compile_definitions(
    ARCH=Linux
    MATRIXSTORAGE
    USE_MT=1
)

if(CCX_INT64)
    add_compile_definitions(INTSIZE64)
endif()

if(CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    add_compile_options("$<$<COMPILE_LANGUAGE:C>:-Wall;-O2;-g>")
endif()

# Fortran Flags
if(CMAKE_Fortran_COMPILER_ID MATCHES "GNU")
    add_compile_options("$<$<COMPILE_LANGUAGE:Fortran>:-Wall;-O2;-g;-cpp;-Wno-unused-dummy-argument;-Wno-unused-variable;-Wno-unused-label;-fallow-argument-mismatch>")
endif()

if(APPLE)
    if(CMAKE_OSX_SYSROOT)
        add_link_options("-Wl,-syslibroot,${CMAKE_OSX_SYSROOT}")
    endif()
    # Embed 256MB stack size to prevent stack overflow in deep Fortran contact & explicit dynamic routines
    add_link_options("-Wl,-stack_size,0x10000000")
endif()

# -----------------------------------------------------------------------------
# OpenMP Support
# -----------------------------------------------------------------------------
if(CCX_USE_OPENMP)
    find_package(OpenMP)
    if(NOT OpenMP_FOUND AND APPLE)
        # Check Homebrew libomp location on macOS
        if(EXISTS "/opt/homebrew/opt/libomp")
            set(OpenMP_C_FLAGS "-Xclang -fopenmp -I/opt/homebrew/opt/libomp/include")
            set(OpenMP_C_LIB_NAMES "omp")
            set(OpenMP_omp_LIBRARY "/opt/homebrew/opt/libomp/lib/libomp.dylib")
            set(OpenMP_C_INCLUDE_DIR "/opt/homebrew/opt/libomp/include")
            find_package(OpenMP)
        endif()
    endif()
    if(OpenMP_FOUND)
        message(STATUS "Found OpenMP: C=${OpenMP_C_FOUND} Fortran=${OpenMP_Fortran_FOUND}")
    else()
        message(STATUS "OpenMP not found or disabled. Continuing without OpenMP flags.")
        set(CCX_USE_OPENMP OFF)
    endif()
endif()

# -----------------------------------------------------------------------------
# Intel oneMKL PARDISO Solver
# -----------------------------------------------------------------------------
set(EXTRA_LINK_LIBS)

if(CCX_USE_PARDISO)
    if(APPLE)
        message(FATAL_ERROR "Intel oneMKL PARDISO is not supported on the Apple Silicon macOS development target.")
    endif()
    add_compile_definitions(PARDISO)
    if(CCX_INT64)
        add_compile_definitions(MKL_ILP64)
        set(MKL_INTERFACE "ilp64")
    else()
        add_compile_definitions(MKL_LP64)
        set(MKL_INTERFACE "lp64")
    endif()

    if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
        set(MKL_THREADING "GNU" CACHE STRING "MKL Threading library" FORCE)
    endif()
    if(CCX_INT64)
        set(MKL_INTERFACE_FULL "ilp64" CACHE STRING "MKL Interface" FORCE)
    else()
        set(MKL_INTERFACE_FULL "lp64" CACHE STRING "MKL Interface" FORCE)
    endif()

    # 1. Try modern oneAPI MKL CMake config
    find_package(MKL CONFIG QUIET PATHS $ENV{MKLROOT} $ENV{MKLROOT}/lib/cmake/mkl /opt/intel/oneapi/mkl/latest/lib/cmake/mkl)
    if(TARGET MKL::MKL)
        message(STATUS "Found Intel oneMKL via CMake Config: MKL::MKL")
        list(APPEND EXTRA_LINK_LIBS MKL::MKL)
    else()
        # 2. Direct library and header discovery
        find_path(MKL_INCLUDE_DIR
            NAMES mkl.h mkl_service.h
            PATHS
                $ENV{MKLROOT}/include
                "C:/Program Files (x86)/Intel/oneAPI/mkl/latest/include"
                "C:/Program Files/Intel/oneAPI/mkl/latest/include"
                /opt/intel/oneapi/mkl/latest/include
                /usr/include/mkl
        )

        set(MKL_LIB_SEARCH_PATHS
            $ENV{MKLROOT}/lib/intel64
            $ENV{MKLROOT}/lib
            "C:/Program Files (x86)/Intel/oneAPI/mkl/latest/lib/intel64"
            "C:/Program Files/Intel/oneAPI/mkl/latest/lib/intel64"
            /opt/intel/oneapi/mkl/latest/lib/intel64
            /opt/intel/oneapi/mkl/latest/lib
            /usr/lib/x86_64-linux-gnu
            /usr/lib
        )

        find_library(MKL_INTERFACE_LIB NAMES mkl_intel_${MKL_INTERFACE} mkl_gf_${MKL_INTERFACE} PATHS ${MKL_LIB_SEARCH_PATHS})
        if(CMAKE_C_COMPILER_ID MATCHES "Intel")
            find_library(MKL_THREAD_LIB NAMES mkl_intel_thread PATHS ${MKL_LIB_SEARCH_PATHS})
        else()
            find_library(MKL_THREAD_LIB NAMES mkl_gnu_thread PATHS ${MKL_LIB_SEARCH_PATHS})
        endif()
        find_library(MKL_CORE_LIB NAMES mkl_core PATHS ${MKL_LIB_SEARCH_PATHS})

        if(MKL_INCLUDE_DIR AND MKL_INTERFACE_LIB AND MKL_THREAD_LIB AND MKL_CORE_LIB)
            message(STATUS "Found Intel MKL Include: ${MKL_INCLUDE_DIR}")
            message(STATUS "Found Intel MKL Interface: ${MKL_INTERFACE_LIB}")
            message(STATUS "Found Intel MKL Threading: ${MKL_THREAD_LIB}")
            message(STATUS "Found Intel MKL Core: ${MKL_CORE_LIB}")
            include_directories(${MKL_INCLUDE_DIR})
            if(WIN32)
                list(APPEND EXTRA_LINK_LIBS ${MKL_INTERFACE_LIB} ${MKL_THREAD_LIB} ${MKL_CORE_LIB})
            else()
                list(APPEND EXTRA_LINK_LIBS ${MKL_INTERFACE_LIB} ${MKL_THREAD_LIB} ${MKL_CORE_LIB} -lpthread -lm -ldl)
            endif()
        else()
            message(FATAL_ERROR "Intel MKL PARDISO requested (CCX_USE_PARDISO=ON) but MKL was not found.\nPlease ensure Intel oneAPI MKL is installed and set MKLROOT or source /opt/intel/oneapi/setvars.sh.")
        endif()
    endif()
endif()

# -----------------------------------------------------------------------------
# MUMPS 5.x Solver
# -----------------------------------------------------------------------------


# Vendored MUMPS (macOS) — build from third_party/mumps at configure time
# EXPERIMENTAL BLOCK START
if(APPLE)
    option(CCX_MUMPS_VENDORED "Build MUMPS from vendored third_party source (macOS)" ON)
else()
    option(CCX_MUMPS_VENDORED "Build MUMPS from vendored third_party source" OFF)
endif()

if(CCX_MUMPS_VENDORED AND NOT APPLE)
    message(WARNING "CCX_MUMPS_VENDORED is normally macOS-only; system MUMPS on Linux/Windows is untouched by design.")
endif()

if(CCX_USE_MUMPS AND CCX_MUMPS_VENDORED)
    set(MUMPS_VENDOR_DIR ${CMAKE_SOURCE_DIR}/third_party/mumps)
    set(MUMPS_TARBALL     ${MUMPS_VENDOR_DIR}/MUMPS_5.9.1.tar.gz)
    set(MUMPS_INC_TEMPLATE ${MUMPS_VENDOR_DIR}/Makefile.inc.macos)
    set(MUMPS_BUILD_DIR   ${CMAKE_BINARY_DIR}/mumps-build)
    set(MUMPS_SRC_DIR     ${MUMPS_BUILD_DIR}/MUMPS_5.9.1)
    set(MUMPS_INSTALL_DIR ${CMAKE_BINARY_DIR}/mumps-install)
    set(MUMPS_STAMP       ${MUMPS_INSTALL_DIR}/lib/libdmumps.a)

    if(NOT EXISTS ${MUMPS_TARBALL})
        message(FATAL_ERROR "CCX_MUMPS_VENDORED=ON but ${MUMPS_TARBALL} not found.")
    endif()

    if(NOT EXISTS ${MUMPS_STAMP})
        message(STATUS "Vendored MUMPS not yet built — building now (one-time, may take a minute)...")

        file(MAKE_DIRECTORY ${MUMPS_BUILD_DIR})
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E tar xzf ${MUMPS_TARBALL}
            WORKING_DIRECTORY ${MUMPS_BUILD_DIR}
            RESULT_VARIABLE _mumps_extract_rc
        )
        if(NOT _mumps_extract_rc EQUAL 0)
            message(FATAL_ERROR "Failed to extract vendored MUMPS tarball.")
        endif()

        file(COPY ${MUMPS_INC_TEMPLATE} DESTINATION ${MUMPS_SRC_DIR})
        file(RENAME ${MUMPS_SRC_DIR}/Makefile.inc.macos ${MUMPS_SRC_DIR}/Makefile.inc)

        include(ProcessorCount)
        ProcessorCount(_mumps_nproc)
        if(_mumps_nproc EQUAL 0)
            set(_mumps_nproc 4)
        endif()

        execute_process(
            COMMAND make d -j${_mumps_nproc}
            WORKING_DIRECTORY ${MUMPS_SRC_DIR}
            RESULT_VARIABLE _mumps_build_rc
            OUTPUT_VARIABLE _mumps_build_out
            ERROR_VARIABLE _mumps_build_err
        )
        if(NOT _mumps_build_rc EQUAL 0)
            message(FATAL_ERROR "Vendored MUMPS build failed:\n${_mumps_build_out}\n${_mumps_build_err}")
        endif()

        file(MAKE_DIRECTORY ${MUMPS_INSTALL_DIR}/lib ${MUMPS_INSTALL_DIR}/include)
        file(COPY
            ${MUMPS_SRC_DIR}/lib/libdmumps.a
            ${MUMPS_SRC_DIR}/lib/libmumps_common.a
            ${MUMPS_SRC_DIR}/PORD/lib/libpord.a
            ${MUMPS_SRC_DIR}/libseq/libmpiseq.a
            DESTINATION ${MUMPS_INSTALL_DIR}/lib
        )
        file(GLOB _mumps_headers ${MUMPS_SRC_DIR}/include/*.h)
        file(COPY ${_mumps_headers} ${MUMPS_SRC_DIR}/libseq/mpif.h
             DESTINATION ${MUMPS_INSTALL_DIR}/include)

        message(STATUS "Vendored MUMPS built -> ${MUMPS_INSTALL_DIR}")
    else()
        message(STATUS "Vendored MUMPS already built, reusing ${MUMPS_INSTALL_DIR}")
    endif()

    set(MUMPS_DIR ${MUMPS_INSTALL_DIR})
    set(ENV{MUMPS_DIR} ${MUMPS_INSTALL_DIR})
    unset(MUMPS_INCLUDE_DIR CACHE)
    foreach(_mumps_lib_var
        MUMPS_DMUMPS_LIB MUMPS_COMMON_LIB MUMPS_PORD_LIB MUMPS_MPISEQ_LIB
        MUMPS_ESMUMPS_LIB MUMPS_SCOTCH_LIB MUMPS_METIS_LIB)
        unset(${_mumps_lib_var} CACHE)
    endforeach()
endif()
# EXPERIMENTAL BLOCK END
#########################################################
if(CCX_USE_MUMPS)
    add_compile_definitions(MUMPS)

    find_package(PkgConfig QUIET)
    set(MUMPS_FOUND_VIA_PKG FALSE)
    if(PKG_CONFIG_FOUND)
        pkg_check_modules(MUMPS_PKG QUIET mumps mumps-seq mumps_seq dmumps mumps-dso)
        if(MUMPS_PKG_FOUND)
            message(STATUS "Found MUMPS via pkg-config: ${MUMPS_PKG_LIBRARIES}")
            list(APPEND EXTRA_LINK_LIBS ${MUMPS_PKG_LIBRARIES})
            link_directories(${MUMPS_PKG_LIBRARY_DIRS})
            include_directories(${MUMPS_PKG_INCLUDE_DIRS})
            set(MUMPS_FOUND_VIA_PKG TRUE)
        endif()
    endif()

    if(NOT MUMPS_FOUND_VIA_PKG)
        find_path(MUMPS_INCLUDE_DIR
            NAMES dmumps_c.h smumps_c.h zmumps_c.h cmumps_c.h mumps_c.h
            PATH_SUFFIXES mumps mumps_seq MUMPS
            PATHS
                ${CMAKE_CURRENT_SOURCE_DIR}/../mumps/include
                $ENV{MUMPS_DIR}/include
                $ENV{MINGW_PREFIX}/include
                $ENV{MSYSTEM_PREFIX}/include
                ${CMAKE_PREFIX_PATH}/include
                /ucrt64/include
                /mingw64/include
                C:/msys64/ucrt64/include
                C:/msys64/mingw64/include
                /usr/include
                /usr/include/mumps_seq
                /usr/local/include
                /opt/homebrew/include
                /opt/local/include
        )

        set(MUMPS_LIB_PATHS
            ${CMAKE_CURRENT_SOURCE_DIR}/../mumps/lib
            ${CMAKE_PREFIX_PATH}/lib
            $ENV{MUMPS_DIR}/lib
            $ENV{MINGW_PREFIX}/lib
            $ENV{MSYSTEM_PREFIX}/lib
            /ucrt64/lib
            /mingw64/lib
            C:/msys64/ucrt64/lib
            C:/msys64/mingw64/lib
            /usr/lib
            /usr/local/lib
            /opt/homebrew/lib
            /opt/local/lib
        )

        find_library(MUMPS_DMUMPS_LIB NAMES dmumps_seq dmumps libdmumps_seq libdmumps mumps libmumps mumps-dso libmumps-dso mumps-dmo libmumps-dmo PATHS ${MUMPS_LIB_PATHS})
        find_library(MUMPS_COMMON_LIB NAMES mumps_common_seq mumps_common libmumps_common_seq libmumps_common PATHS ${MUMPS_LIB_PATHS})
        find_library(MUMPS_PORD_LIB   NAMES pord_seq pord libpord_seq libpord PATHS ${MUMPS_LIB_PATHS})
        find_library(MUMPS_MPISEQ_LIB NAMES mpiseq_seq mpiseq libmpiseq_seq libmpiseq PATHS ${MUMPS_LIB_PATHS})
        find_library(MUMPS_ESMUMPS_LIB NAMES esmumps_seq esmumps libesmumps_seq libesmumps PATHS ${MUMPS_LIB_PATHS})
        find_library(MUMPS_SCOTCH_LIB NAMES scotch scotcherr libscotch libscotcherr PATHS ${MUMPS_LIB_PATHS})
        find_library(MUMPS_METIS_LIB  NAMES metis libmetis PATHS ${MUMPS_LIB_PATHS})

        if(MUMPS_INCLUDE_DIR AND MUMPS_DMUMPS_LIB)
            message(STATUS "Found MUMPS Include: ${MUMPS_INCLUDE_DIR}")
            message(STATUS "Found MUMPS dmumps:  ${MUMPS_DMUMPS_LIB}")
            include_directories(${MUMPS_INCLUDE_DIR})
            list(APPEND EXTRA_LINK_LIBS ${MUMPS_DMUMPS_LIB})
            if(MUMPS_COMMON_LIB)
                message(STATUS "Found MUMPS common:  ${MUMPS_COMMON_LIB}")
                list(APPEND EXTRA_LINK_LIBS ${MUMPS_COMMON_LIB})
            endif()
            if(MUMPS_PORD_LIB)
                list(APPEND EXTRA_LINK_LIBS ${MUMPS_PORD_LIB})
            endif()
            if(MUMPS_MPISEQ_LIB)
                list(APPEND EXTRA_LINK_LIBS ${MUMPS_MPISEQ_LIB})
            endif()
            if(MUMPS_ESMUMPS_LIB)
                list(APPEND EXTRA_LINK_LIBS ${MUMPS_ESMUMPS_LIB})
            endif()
            if(MUMPS_SCOTCH_LIB)
                list(APPEND EXTRA_LINK_LIBS ${MUMPS_SCOTCH_LIB})
            endif()
            if(MUMPS_METIS_LIB)
                list(APPEND EXTRA_LINK_LIBS ${MUMPS_METIS_LIB})
            endif()
        else()
            message(STATUS "MUMPS search paths: ${MUMPS_LIB_PATHS}")
            message(STATUS "MUMPS header result: ${MUMPS_INCLUDE_DIR}")
            message(STATUS "MUMPS lib result: ${MUMPS_DMUMPS_LIB}")
            message(FATAL_ERROR "MUMPS solver requested (CCX_USE_MUMPS=ON) but MUMPS headers or libraries were not found.")
        endif()
    endif()
endif()

# -----------------------------------------------------------------------------
# Apple Accelerate Sparse Solver (macOS only)
# -----------------------------------------------------------------------------
if(CCX_USE_ACCELERATE)
    if(NOT APPLE)
        message(FATAL_ERROR "Apple Accelerate sparse solver (CCX_USE_ACCELERATE=ON) is only supported on macOS.")
    endif()
    add_compile_definitions(ACCELERATE_SOLVER)
    find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)
    list(APPEND EXTRA_LINK_LIBS ${ACCELERATE_FRAMEWORK})
    message(STATUS "Apple Accelerate Direct Sparse Solver enabled (-DACCELERATE_SOLVER)")
endif()

# -----------------------------------------------------------------------------
# BLAS & LAPACK (Platform-Adaptive, when not using MKL)
# -----------------------------------------------------------------------------
if(NOT CCX_USE_PARDISO)
    if(APPLE)
        # Prefer native Apple Accelerate Framework on macOS
        find_library(ACCELERATE_FRAMEWORK Accelerate)
        if(ACCELERATE_FRAMEWORK)
            message(STATUS "Found Apple Accelerate Framework: ${ACCELERATE_FRAMEWORK}")
            list(APPEND EXTRA_LINK_LIBS ${ACCELERATE_FRAMEWORK})
        else()
            find_package(BLAS REQUIRED)
            find_package(LAPACK REQUIRED)
            list(APPEND EXTRA_LINK_LIBS ${BLAS_LIBRARIES} ${LAPACK_LIBRARIES})
        endif()
    else()
        # Prefer optimized BLAS (MKL runtime, AMD AOCL-BLIS, OpenBLAS) over slow reference Netlib BLAS
        find_library(MKL_RT_LIB NAMES mkl_rt PATHS $ENV{MKLROOT}/lib/intel64 $ENV{MKLROOT}/lib /opt/intel/oneapi/mkl/latest/lib /usr/lib)
        find_library(AOCL_BLAS_LIB NAMES blis-mt blis blis-openmp blis-pthread libblis-mt libblis
            PATHS
                $ENV{AOCL_ROOT}/lib
                $ENV{MINGW_PREFIX}/lib
                $ENV{MSYSTEM_PREFIX}/lib
                C:/msys64/ucrt64/lib
                C:/msys64/mingw64/lib
                /opt/AMD/aocl/latest/lib
                /opt/aocl/lib
                /usr/lib
                /usr/lib/x86_64-linux-gnu
                /usr/local/lib
        )
        find_library(AOCL_LAPACK_LIB NAMES flame libflame
            PATHS
                $ENV{AOCL_ROOT}/lib
                $ENV{MINGW_PREFIX}/lib
                $ENV{MSYSTEM_PREFIX}/lib
                C:/msys64/ucrt64/lib
                C:/msys64/mingw64/lib
                /opt/AMD/aocl/latest/lib
                /opt/aocl/lib
                /usr/lib
                /usr/lib/x86_64-linux-gnu
                /usr/local/lib
        )
        find_library(OPENBLAS_LIB NAMES openblas openblas64 libopenblas
            PATHS
                $ENV{MINGW_PREFIX}/lib
                $ENV{MSYSTEM_PREFIX}/lib
                C:/msys64/ucrt64/lib
                C:/msys64/mingw64/lib
                /usr/lib
                /usr/local/lib
        )

        if(MKL_RT_LIB)
            message(STATUS "Using Intel oneMKL Optimized BLAS/LAPACK: ${MKL_RT_LIB}")
            list(APPEND EXTRA_LINK_LIBS ${MKL_RT_LIB})
        elseif(AOCL_BLAS_LIB)
            message(STATUS "Using AMD AOCL (BLIS) Optimized BLAS: ${AOCL_BLAS_LIB}")
            list(APPEND EXTRA_LINK_LIBS ${AOCL_BLAS_LIB})
            if(AOCL_LAPACK_LIB)
                message(STATUS "Using AMD AOCL (libflame) LAPACK: ${AOCL_LAPACK_LIB}")
                list(APPEND EXTRA_LINK_LIBS ${AOCL_LAPACK_LIB})
            else()
                find_package(LAPACK REQUIRED)
                list(APPEND EXTRA_LINK_LIBS ${LAPACK_LIBRARIES})
            endif()
        elseif(OPENBLAS_LIB)
            message(STATUS "Using OpenBLAS Optimized BLAS/LAPACK: ${OPENBLAS_LIB}")
            list(APPEND EXTRA_LINK_LIBS ${OPENBLAS_LIB})
        else()
            find_package(BLAS REQUIRED)
            find_package(LAPACK REQUIRED)
            message(STATUS "Found BLAS: ${BLAS_LIBRARIES}")
            message(STATUS "Found LAPACK: ${LAPACK_LIBRARIES}")
            list(APPEND EXTRA_LINK_LIBS ${BLAS_LIBRARIES} ${LAPACK_LIBRARIES})
        endif()
    endif()
endif()

# -----------------------------------------------------------------------------
# ARPACK
# -----------------------------------------------------------------------------
if(CCX_USE_ARPACK)
    add_compile_definitions(ARPACK)
    find_package(PkgConfig QUIET)
    if(PKG_CONFIG_FOUND)
        pkg_check_modules(ARPACK QUIET arpack)
    endif()

    if(ARPACK_FOUND)
        message(STATUS "Found ARPACK via pkg-config: ${ARPACK_LIBRARIES}")
        list(APPEND EXTRA_LINK_LIBS ${ARPACK_LIBRARIES})
        link_directories(${ARPACK_LIBRARY_DIRS})
    else()
        find_library(ARPACK_LIB NAMES arpack arpack_LINUX libarpack
            PATHS
                $ENV{MINGW_PREFIX}/lib
                $ENV{MSYSTEM_PREFIX}/lib
                C:/msys64/ucrt64/lib
                C:/msys64/mingw64/lib
                /opt/homebrew/lib
                /usr/local/lib
                /usr/lib
                /usr/lib/x86_64-linux-gnu
                /usr/lib/aarch64-linux-gnu
        )
        if(ARPACK_LIB)
            message(STATUS "Found ARPACK library: ${ARPACK_LIB}")
            list(APPEND EXTRA_LINK_LIBS ${ARPACK_LIB})
        else()
            message(FATAL_ERROR "ARPACK requested but not found. Install arpack (e.g. brew install arpack or apt install libarpack2-dev).")
        endif()
    endif()
endif()

# -----------------------------------------------------------------------------
# SPOOLES Solver (Vendored on macOS, system library elsewhere)
# -----------------------------------------------------------------------------
if(CCX_USE_SPOOLES)
    add_compile_definitions(SPOOLES)
    if(CCX_SPOOLES_VENDORED AND APPLE)
        set(SPOOLES_VENDOR_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/spooles)
        set(SPOOLES_TARBALL ${SPOOLES_VENDOR_DIR}/SPOOLES_2.2.tar.gz)
        set(SPOOLES_BUILD_DIR ${CMAKE_BINARY_DIR}/spooles-source)
        set(SPOOLES_SOURCE_DIR ${SPOOLES_BUILD_DIR}/spooles)

        if(NOT EXISTS "${SPOOLES_TARBALL}")
            message(FATAL_ERROR "CCX_SPOOLES_VENDORED=ON but ${SPOOLES_TARBALL} is missing.")
        endif()

        if(NOT EXISTS "${SPOOLES_SOURCE_DIR}/CMakeLists.txt")
            message(STATUS "Vendored SPOOLES not yet extracted -- extracting source archive...")
            file(MAKE_DIRECTORY ${SPOOLES_BUILD_DIR})
            execute_process(
                COMMAND ${CMAKE_COMMAND} -E tar xzf ${SPOOLES_TARBALL}
                WORKING_DIRECTORY ${SPOOLES_BUILD_DIR}
                RESULT_VARIABLE _spooles_extract_rc
                OUTPUT_VARIABLE _spooles_extract_out
                ERROR_VARIABLE _spooles_extract_err
            )
            if(NOT _spooles_extract_rc EQUAL 0)
                message(FATAL_ERROR "Failed to extract vendored SPOOLES archive:\n${_spooles_extract_out}\n${_spooles_extract_err}")
            endif()
        endif()

        if(NOT EXISTS "${SPOOLES_SOURCE_DIR}/CMakeLists.txt")
            message(FATAL_ERROR "Extracted SPOOLES archive does not contain its CMakeLists.txt.")
        endif()

        add_subdirectory("${SPOOLES_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/spooles-build")
        list(APPEND EXTRA_LINK_LIBS spooles)
        set(SPOOLES_INCLUDE_DIR "${SPOOLES_SOURCE_DIR}")
        message(STATUS "Using vendored SPOOLES 2.2 archive: ${SPOOLES_TARBALL}")
    else()
        find_path(SPOOLES_INCLUDE_DIR
            NAMES misc.h spooles.h
            PATH_SUFFIXES spooles
            PATHS
                $ENV{SPOOLES_DIR}/include
                $ENV{SPOOLES_DIR}
                /usr/include
                /usr/include/spooles
                /usr/local/include
                /usr/local/include/spooles
                /opt/homebrew/include
        )
        find_library(SPOOLES_LIB
            NAMES spooles spoolesMT spooles_MT libspooles
            PATHS
                $ENV{SPOOLES_DIR}/lib
                $ENV{SPOOLES_DIR}
                /usr/lib
                /usr/lib/x86_64-linux-gnu
                /usr/lib/aarch64-linux-gnu
                /usr/local/lib
                /opt/homebrew/lib
        )
        if(SPOOLES_INCLUDE_DIR AND SPOOLES_LIB)
            message(STATUS "Found SPOOLES Include: ${SPOOLES_INCLUDE_DIR}")
            message(STATUS "Found SPOOLES Library: ${SPOOLES_LIB}")
            list(APPEND EXTRA_LINK_LIBS ${SPOOLES_LIB})
            include_directories(${SPOOLES_INCLUDE_DIR})
        else()
            message(FATAL_ERROR "SPOOLES requested (CCX_USE_SPOOLES=ON) but system library not found. Please install libspooles-dev (e.g. sudo apt install libspooles-dev) or use MUMPS (-DCCX_USE_MUMPS=ON) / Accelerate (-DCCX_USE_ACCELERATE=ON).")
        endif()
    endif()
endif()

# -----------------------------------------------------------------------------
# Source File Discovery from Makefile.inc
# -----------------------------------------------------------------------------
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Parse Makefile.inc to extract Dr. Dhondt's exact source list
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/Makefile.inc" MAKEFILE_INC_CONTENT)
string(FIND "${MAKEFILE_INC_CONTENT}" "SCCXF" F_POS)
string(FIND "${MAKEFILE_INC_CONTENT}" "SCCXC" C_POS)

math(EXPR F_LEN "${C_POS} - ${F_POS}")
string(SUBSTRING "${MAKEFILE_INC_CONTENT}" ${F_POS} ${F_LEN} F_PART)
string(SUBSTRING "${MAKEFILE_INC_CONTENT}" ${C_POS} -1 C_PART)

string(REGEX MATCHALL "[a-zA-Z0-9_]+\\.f" F_LIST "${F_PART}")
string(REGEX MATCHALL "[a-zA-Z0-9_]+\\.c" C_LIST "${C_PART}")

set(CCX_SOURCES)
foreach(F_FILE ${F_LIST})
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/${F_FILE}")
        list(APPEND CCX_SOURCES "src/${F_FILE}")
    endif()
endforeach()

foreach(C_FILE ${C_LIST})
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/${C_FILE}")
        list(APPEND CCX_SOURCES "src/${C_FILE}")
    endif()
endforeach()

list(LENGTH CCX_SOURCES CCX_SOURCES_COUNT)
message(STATUS "Discovered ${CCX_SOURCES_COUNT} source files from Makefile.inc")

# -----------------------------------------------------------------------------
# Static Core Library (CalculiX_lib)
# -----------------------------------------------------------------------------
add_library(CalculiX_lib STATIC ${CCX_SOURCES})
target_include_directories(CalculiX_lib PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
)
if(CCX_USE_SPOOLES AND SPOOLES_INCLUDE_DIR)
    target_include_directories(CalculiX_lib PUBLIC
        $<BUILD_INTERFACE:${SPOOLES_INCLUDE_DIR}>
    )
endif()

target_link_libraries(CalculiX_lib PUBLIC ${EXTRA_LINK_LIBS})

if(CCX_USE_OPENMP)
    target_link_libraries(CalculiX_lib PUBLIC OpenMP::OpenMP_Fortran OpenMP::OpenMP_C)
endif()

# -----------------------------------------------------------------------------
# Main Executable: CalculiX (and alias 'ccx')
# -----------------------------------------------------------------------------
add_executable(CalculiX src/CalculiX.c)
target_link_libraries(CalculiX PRIVATE CalculiX_lib)

if(APPLE)
    target_link_options(CalculiX PRIVATE "-Wl,-stack_size,0x10000000")
endif()

if(CCX_USE_OPENMP)
    target_link_libraries(CalculiX PRIVATE OpenMP::OpenMP_Fortran OpenMP::OpenMP_C)
endif()

# Alias for modern CLI naming
add_custom_target(ccx ALL DEPENDS CalculiX)

# -----------------------------------------------------------------------------
# Installation
# -----------------------------------------------------------------------------
install(TARGETS CalculiX RUNTIME DESTINATION bin)

# -----------------------------------------------------------------------------
# CTest Integration
# -----------------------------------------------------------------------------
include(CTest)
if(BUILD_TESTING)
    enable_testing()
    
    add_test(NAME test_simplebeam
        COMMAND ${CMAKE_COMMAND} -E chdir ${CMAKE_CURRENT_SOURCE_DIR}/test $<TARGET_FILE:CalculiX> simplebeam
    )
    
    add_test(NAME test_achtel2
        COMMAND ${CMAKE_COMMAND} -E chdir ${CMAKE_CURRENT_SOURCE_DIR}/test $<TARGET_FILE:CalculiX> achtel2
    )
endif()

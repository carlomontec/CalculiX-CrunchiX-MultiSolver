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

set(CMAKE_C_STANDARD 99)

# -----------------------------------------------------------------------------
# User Configuration Options
# -----------------------------------------------------------------------------
option(CCX_USE_SPOOLES "Enable SPOOLES direct sparse solver" ON)
option(CCX_USE_ARPACK  "Enable ARPACK eigenvalue solver"     ON)
option(CCX_USE_OPENMP  "Enable OpenMP multithreading"        ON)
option(CCX_INT64       "Use 64-bit integers (-DINTSIZE64)"   OFF)

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
    add_compile_options("$<$<COMPILE_LANGUAGE:Fortran>:-Wall;-O2;-g;-cpp;-Wno-unused-dummy-argument;-Wno-unused-variable;-Wno-unused-label>")
endif()

if(APPLE AND CMAKE_OSX_SYSROOT)
    add_link_options("-Wl,-syslibroot,${CMAKE_OSX_SYSROOT}")
endif()

# -----------------------------------------------------------------------------
# OpenMP Support
# -----------------------------------------------------------------------------
if(CCX_USE_OPENMP)
    find_package(OpenMP REQUIRED)
endif()

# -----------------------------------------------------------------------------
# BLAS & LAPACK (Platform-Adaptive)
# -----------------------------------------------------------------------------
set(EXTRA_LINK_LIBS)

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
    # Linux & Windows standard linear algebra
    find_package(BLAS REQUIRED)
    find_package(LAPACK REQUIRED)
    message(STATUS "Found BLAS: ${BLAS_LIBRARIES}")
    message(STATUS "Found LAPACK: ${LAPACK_LIBRARIES}")
    list(APPEND EXTRA_LINK_LIBS ${BLAS_LIBRARIES} ${LAPACK_LIBRARIES})
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
        find_library(ARPACK_LIB NAMES arpack arpack_LINUX
            PATHS
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
# SPOOLES Solver
# -----------------------------------------------------------------------------
if(CCX_USE_SPOOLES)
    add_compile_definitions(SPOOLES)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../spooles/CMakeLists.txt")
        add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../spooles" "${CMAKE_CURRENT_BINARY_DIR}/spooles_build")
        list(APPEND EXTRA_LINK_LIBS spooles)
    elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../spooles/spooles.a")
        list(APPEND EXTRA_LINK_LIBS "${CMAKE_CURRENT_SOURCE_DIR}/../../spooles/spooles.a")
        include_directories("${CMAKE_CURRENT_SOURCE_DIR}/../../spooles")
    else()
        message(FATAL_ERROR "SPOOLES not found in ../spooles or ../../spooles")
    endif()
endif()

# -----------------------------------------------------------------------------
# Source File Discovery from Makefile.inc
# -----------------------------------------------------------------------------
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../spooles
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
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../spooles>
)

if(CCX_USE_OPENMP)
    target_link_libraries(CalculiX_lib PUBLIC OpenMP::OpenMP_Fortran OpenMP::OpenMP_C)
endif()

# -----------------------------------------------------------------------------
# Main Executable: CalculiX (and alias 'ccx')
# -----------------------------------------------------------------------------
add_executable(CalculiX src/CalculiX.c)
target_link_libraries(CalculiX PRIVATE
    CalculiX_lib
    ${EXTRA_LINK_LIBS}
)

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

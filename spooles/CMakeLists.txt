cmake_minimum_required(VERSION 3.20)
project(spooles C)

set(CMAKE_C_STANDARD 99)

# Include directories
set(SPOOLES_INCLUDE_DIRS
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/A2
    ${CMAKE_CURRENT_SOURCE_DIR}/BKL
    ${CMAKE_CURRENT_SOURCE_DIR}/BPG
    ${CMAKE_CURRENT_SOURCE_DIR}/Chv
    ${CMAKE_CURRENT_SOURCE_DIR}/ChvList
    ${CMAKE_CURRENT_SOURCE_DIR}/ChvManager
    ${CMAKE_CURRENT_SOURCE_DIR}/Coords
    ${CMAKE_CURRENT_SOURCE_DIR}/DSTree
    ${CMAKE_CURRENT_SOURCE_DIR}/DV
    ${CMAKE_CURRENT_SOURCE_DIR}/DenseMtx
    ${CMAKE_CURRENT_SOURCE_DIR}/Drand
    ${CMAKE_CURRENT_SOURCE_DIR}/EGraph
    ${CMAKE_CURRENT_SOURCE_DIR}/ETree
    ${CMAKE_CURRENT_SOURCE_DIR}/FrontMtx
    ${CMAKE_CURRENT_SOURCE_DIR}/GPart
    ${CMAKE_CURRENT_SOURCE_DIR}/Graph
    ${CMAKE_CURRENT_SOURCE_DIR}/I2Ohash
    ${CMAKE_CURRENT_SOURCE_DIR}/IIheap
    ${CMAKE_CURRENT_SOURCE_DIR}/ILUMtx
    ${CMAKE_CURRENT_SOURCE_DIR}/IV
    ${CMAKE_CURRENT_SOURCE_DIR}/IVL
    ${CMAKE_CURRENT_SOURCE_DIR}/Ideq
    ${CMAKE_CURRENT_SOURCE_DIR}/InpMtx
    ${CMAKE_CURRENT_SOURCE_DIR}/Iter
    ${CMAKE_CURRENT_SOURCE_DIR}/Lock
    ${CMAKE_CURRENT_SOURCE_DIR}/MSMD
    ${CMAKE_CURRENT_SOURCE_DIR}/MT
    ${CMAKE_CURRENT_SOURCE_DIR}/Network
    ${CMAKE_CURRENT_SOURCE_DIR}/PatchAndGoInfo
    ${CMAKE_CURRENT_SOURCE_DIR}/Pencil
    ${CMAKE_CURRENT_SOURCE_DIR}/Perm
    ${CMAKE_CURRENT_SOURCE_DIR}/SemiImplMtx
    ${CMAKE_CURRENT_SOURCE_DIR}/SolveMap
    ${CMAKE_CURRENT_SOURCE_DIR}/SubMtx
    ${CMAKE_CURRENT_SOURCE_DIR}/SubMtxList
    ${CMAKE_CURRENT_SOURCE_DIR}/SubMtxManager
    ${CMAKE_CURRENT_SOURCE_DIR}/SymbFac
    ${CMAKE_CURRENT_SOURCE_DIR}/Tree
    ${CMAKE_CURRENT_SOURCE_DIR}/Utilities
    ${CMAKE_CURRENT_SOURCE_DIR}/ZV
    ${CMAKE_CURRENT_SOURCE_DIR}/misc
)

# Core SPOOLES modules (excluding MPI)
set(SPOOLES_MODULES
    A2 BKL BPG Chv ChvList ChvManager Coords DSTree DV DenseMtx
    Drand EGraph ETree FrontMtx GPart Graph I2Ohash IIheap ILUMtx
    IV IVL Ideq InpMtx Iter Lock MSMD MT Network PatchAndGoInfo
    Pencil Perm SemiImplMtx SolveMap SubMtx SubMtxList SubMtxManager
    SymbFac Tree Utilities ZV misc
)

set(SPOOLES_SOURCES)
foreach(MOD ${SPOOLES_MODULES})
    file(GLOB MOD_SRCS "${CMAKE_CURRENT_SOURCE_DIR}/${MOD}/src/*.c")
    list(FILTER MOD_SRCS EXCLUDE REGEX "/\\._")
    list(APPEND SPOOLES_SOURCES ${MOD_SRCS})
endforeach()

add_library(spooles STATIC ${SPOOLES_SOURCES})

target_include_directories(spooles PUBLIC
    $<BUILD_INTERFACE:${SPOOLES_INCLUDE_DIRS}>
    $<INSTALL_INTERFACE:include>
)

if(APPLE)
    target_compile_definitions(spooles PRIVATE _DARWIN_C_SOURCE)
elseif(UNIX)
    target_compile_definitions(spooles PRIVATE _GNU_SOURCE)
endif()

# Suppress historical C syntax warnings from 1998 code
if(CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(spooles PRIVATE
        -w
        -O2
    )
endif()

find_package(Threads REQUIRED)
target_link_libraries(spooles PUBLIC Threads::Threads)

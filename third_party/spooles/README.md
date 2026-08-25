# Vendored SPOOLES 2.2

This directory contains the SPOOLES 2.2 source archive used by CalculiX for the
macOS comparison build, together with its checksum.

The source was restored from the upstream-derived tree previously integrated in
this repository at commit `0013f6c28e6c348468adc9ea3e91c4fac60e8884`. That tree
is based on the original CalculiX distribution and its SPOOLES 2.2 sources.

The archive contains the top-level CMake build used to compile the serial
SPOOLES modules as a static library while excluding the MPI modules. CMake
extracts it into the binary directory. Linux builds continue to use the system
SPOOLES package unless `CCX_SPOOLES_VENDORED` is explicitly enabled.

The original SPOOLES notices and documentation are retained in this tree.

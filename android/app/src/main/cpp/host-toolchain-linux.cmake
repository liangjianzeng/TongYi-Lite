# Host toolchain for ggml-vulkan's `vulkan-shaders-gen` ExternalProject on
# LINUX build hosts (aarch64 / x86_64). Linux counterpart of
# host-toolchain-mingw.cmake (Windows + MinGW-w64); same semantics:
#   - plain host build, NOT a cross-compile (do not set CMAKE_SYSTEM_NAME,
#     see the identical note in host-toolchain-mingw.cmake)
#   - CMAKE_MAKE_PROGRAM must be Ninja (CACHE + FORCE, ExternalProject does
#     not forward -DCMAKE_MAKE_PROGRAM; see mingw NOTE 2)
#   - CMAKE_FIND_ROOT_PATH_MODE_* reset to NEVER because the Android toolchain
#     (inherited by ExternalProject) restricts find_* to the Android sysroot
# set(CMAKE_C_COMPILER   "cc"  CACHE FILEPATH "Host C compiler")
set(CMAKE_CXX_COMPILER "c++" CACHE FILEPATH "Host C++ compiler")

# Prefer the system ninja; fall back to nothing (cmake's own discovery) when
# it is absent. Kept CACHE+FORCE for the ExternalProject reason above.
find_program(_host_ninja NAMES ninja ninja.exe PATHS ENV PATH NO_DEFAULT_PATH)
if(_host_ninja)
    set(CMAKE_MAKE_PROGRAM "${_host_ninja}" CACHE FILEPATH "Ninja for the host sub-build" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)

# Fully static against the host libstdc++/libgcc so the generator binary
# always starts regardless of LD_LIBRARY_PATH in the ninja custom command
# (same failure mode as the MinGW DLL story on Windows).
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++")

# Native Linux host build: undo the Android cross-build find restrictions.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE NEVER)

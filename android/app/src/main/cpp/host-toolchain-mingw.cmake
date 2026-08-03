# Host toolchain for ggml-vulkan's `vulkan-shaders-gen` ExternalProject.
# This tool runs on the Windows BUILD HOST (not the Android target) to
# precompile Vulkan compute shaders into a C++ header via glslc.
# We use the portable MinGW-w64 toolchain (GCC) installed at the path below.
# NOTE: do NOT set CMAKE_SYSTEM_NAME here. The host IS Windows, and declaring
# it turns the sub-build into a "cross compile", which changes try_compile
# behaviour and breaks the compiler check. The upstream template
# (cmake/host-toolchain.cmake.in) does not set it either.
set(CMAKE_C_COMPILER   "C:/mingw64/bin/gcc.exe")
set(CMAKE_CXX_COMPILER "C:/mingw64/bin/g++.exe")
# NOTE 1: the host sub-build inherits the Ninja generator (ExternalProject
# passes -GNinja), so CMAKE_MAKE_PROGRAM must stay a Ninja binary. Setting it
# to mingw32-make makes CMake parse `make --version` as a Ninja version and
# fail with "The detected version of Ninja (GNU Make 4.4.1) is less than 1.3".
# NOTE 2: it MUST be a CACHE variable. ExternalProject does not forward
# -DCMAKE_MAKE_PROGRAM, and the generator reads it from the cache before the
# toolchain's plain variables are visible -> the build command degenerates to
# "cmTC_xxxx &&" and try_compile dies with "参数错误 / invalid argument".
set(CMAKE_MAKE_PROGRAM "C:/Users/jianz/AppData/Local/Android/Sdk/cmake/3.22.1/bin/ninja.exe"
    CACHE FILEPATH "Ninja for the host sub-build" FORCE)
set(CMAKE_CXX_STANDARD 17)

# Link the host tool fully statically. Otherwise vulkan-shaders-gen.exe depends
# on libgcc_s_seh-1.dll / libstdc++-6.dll / libwinpthread-1.dll, and the ninja
# custom command that invokes it does not necessarily have C:/mingw64/bin on
# PATH -> "the application was unable to start correctly".
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static -static-libgcc -static-libstdc++")

# Native Windows build (host != Android target). Do not apply any
# CMAKE_FIND_ROOT_PATH restrictions inherited from the Android cross build.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE NEVER)

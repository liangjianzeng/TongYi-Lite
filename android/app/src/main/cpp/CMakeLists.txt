cmake_minimum_required(VERSION 3.22.1)

project("tongyilite_native" VERSION 0.1.2 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# --------------------------------------------------------------------------
# Locate llama.cpp source (submodule at project root third_party/llama.cpp)
# --------------------------------------------------------------------------
# Go up: cpp → main → src → app → android → TongYi-Lite (project root) = 5 levels
set(PROJECT_ROOT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../..)
set(LLAMA_CPP_DIR ${PROJECT_ROOT_DIR}/third_party/llama.cpp)

if(NOT EXISTS "${LLAMA_CPP_DIR}/src/llama.cpp")
    message(FATAL_ERROR "llama.cpp not found at: ${LLAMA_CPP_DIR}")
endif()

if(NOT EXISTS ${LLAMA_CPP_DIR}/src/llama.cpp)
    message(FATAL_ERROR
        "llama.cpp not found at ${LLAMA_CPP_DIR}.\n"
        "Run: git submodule update --init --recursive"
    )
endif()

# --------------------------------------------------------------------------
# llama.cpp build options
# --------------------------------------------------------------------------
# Disable features incompatible with Android NDK cross-compilation
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP ON CACHE BOOL "" FORCE)
# ggml-cpu KleidiAI optimized kernels. llama.cpp b10176 fetches this via
# FetchContent from GitHub at configure time (ggml/src/ggml-cpu/CMakeLists.txt
# downloads kleidiai-v1.24.0-src.tar.gz). The build sandbox has no GitHub access,
# so we VENDOR the source locally (third_party/kleidiai, cloned from the official
# repo at tag v1.24.0) and point FetchContent at it via
# FETCHCONTENT_SOURCE_DIR_KLEIDIAI_DOWNLOAD -> no network needed at configure time.
set(GGML_CPU_KLEIDIAI ON CACHE BOOL "" FORCE)
set(KLEIDIAI_VENDOR_DIR ${PROJECT_ROOT_DIR}/third_party/kleidiai)
if(NOT EXISTS "${KLEIDIAI_VENDOR_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "KleidiAI source not found at ${KLEIDIAI_VENDOR_DIR}. Run: git clone --depth 1 --branch v1.24.0 https://github.com/ARM-software/kleidiai ${KLEIDIAI_VENDOR_DIR}")
endif()
set(FETCHCONTENT_SOURCE_DIR_KLEIDIAI_DOWNLOAD ${KLEIDIAI_VENDOR_DIR} CACHE STRING "" FORCE)
message(STATUS "KleidiAI vendored source -> ${KLEIDIAI_VENDOR_DIR}")
# The Android debug variant compiles with -O0 and no NDEBUG, leaving llama.cpp's
# quantized matmul kernels unoptimized -> ~0.6 tok/s on a 0.5B model. Force -O3
# -DNDEBUG for the Debug build type. NDEBUG also makes get_logits_ith return
# nullptr (not GGML_ABORT) on out-of-range, so the JNI null-check actually works.
set(CMAKE_C_FLAGS_DEBUG "-O3 -DNDEBUG" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_DEBUG "-O3 -DNDEBUG" CACHE STRING "" FORCE)
# Target the device's real microarchitecture so ggml-cpu / KleidiAI can emit
# dotprod + i8mm kernels instead of the slow armv8-a baseline. This APK only
# ships to the test device (SM8735 / Adreno 825, Armv9), so the narrower -march
# is safe. Host vulkan-shaders-gen uses its own MinGW toolchain (ExternalProject)
# and is unaffected by this flag.
#
# Set via GGML_CPU_ARM_ARCH (NOT a manual -march flag): ggml-cpu's KleidiAI
# integration reads this to decide whether to compile the +dotprod/+i8mm kernels
# (ggml/src/ggml-cpu/CMakeLists.txt:169,644-651). Adding -march to CMAKE_C_FLAGS
# did NOT reach the kai source files, so the dotprod/i8mm kernels were silently
# skipped even though GGML_USE_CPU_KLEIDIAI was defined.
set(GGML_CPU_ARM_ARCH armv8.4-a+dotprod+i8mm CACHE STRING "" FORCE)

# Vulkan GPU acceleration requires the LunarG SDK (glslc) plus a native host
# C++ compiler on the build machine (to build `vulkan-shaders-gen`).
option(GGML_VULKAN "ggml: use Vulkan for GPU acceleration" OFF)
if(DEFINED ANDROID_ABI AND ANDROID_ABI STREQUAL "arm64-v8a")
    # Host toolchain is fixed (see host-toolchain-mingw.cmake: MinGW-w64 GCC +
    # the Android SDK's ninja + fully static linking), so the Vulkan backend
    # can be enabled for arm64 devices.
    set(GGML_VULKAN ON CACHE BOOL "" FORCE)
    message(STATUS "Vulkan ENABLED (GPU backend) for arm64-v8a")

    # Point FindVulkan (glslc) and find_package(SPIRV-Headers) at the LunarG SDK.
    set(_vk_sdk "C:/VulkanSDK/1.4.357.0")
    set(ENV{VULKAN_SDK} "${_vk_sdk}")
    # Explicitly hint find_package(SPIRV-Headers) at the SDK config dir so the
    # Vulkan backend configures reliably regardless of CMAKE_PREFIX_PATH state.
    set(SPIRV-Headers_DIR "${_vk_sdk}/Lib/cmake/SPIRV-Headers" CACHE PATH "SPIRV-Headers cmake config" FORCE)

    # ggml calls find_package(SPIRV-Headers CONFIG REQUIRED). The Android
    # toolchain sets CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY, so config packages
    # living on the Windows host are invisible. Pin the directory directly.
    # (SPIRV-Headers is header-only and is not actually included by
    # ggml-vulkan.cpp -- it only needs to satisfy the find_package call.)
    if(EXISTS "${_vk_sdk}/Lib/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake")
        set(SPIRV-Headers_DIR "${_vk_sdk}/Lib/cmake/SPIRV-Headers" CACHE PATH "" FORCE)
        message(STATUS "SPIRV-Headers_DIR -> ${SPIRV-Headers_DIR}")
    else()
        message(WARNING "SPIRV-HeadersConfig.cmake not found under ${_vk_sdk}")
    endif()

    # ggml-vulkan builds `vulkan-shaders-gen` as a host (Windows) tool. The
    # build host has no MSVC/gcc, so we use the portable MinGW-w64 toolchain.
    set(_vk_host_tc "${CMAKE_CURRENT_SOURCE_DIR}/host-toolchain-mingw.cmake")
    if(EXISTS "${_vk_host_tc}")
        set(GGML_VULKAN_SHADERS_GEN_TOOLCHAIN "${_vk_host_tc}" CACHE FILEPATH "Host toolchain for vulkan-shaders-gen" FORCE)
        message(STATUS "Vulkan shaders-gen host toolchain -> ${_vk_host_tc}")
    else()
        message(WARNING "host-toolchain-mingw.cmake missing; ggml may fail to find a host C++ compiler")
    endif()

    # On Android the Vulkan loader (libvulkan.so) is provided by the OS at
    # runtime. ggml links `Vulkan::Vulkan`, which FindVulkan would otherwise
    # resolve to the Windows import lib (vulkan-1.lib) shipped in the LunarG
    # SDK. That PE/COFF lib cannot be linked by the Android (ELF/lld) linker,
    # so force the loader to the NDK stub for aarch64.
    # The NDK sysroot only ships the C header <vulkan/vulkan.h>; the C++
    # bindings <vulkan/vulkan.hpp> that ggml-vulkan.cpp includes come from the
    # LunarG SDK. CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY hides the host SDK
    # from find_path(), so pin the include dir explicitly. Using the SDK
    # headers for both .h and .hpp keeps the struct/enum definitions in sync.
    if(EXISTS "${_vk_sdk}/Include/vulkan/vulkan.hpp")
        set(Vulkan_INCLUDE_DIR "${_vk_sdk}/Include" CACHE PATH "Vulkan headers (LunarG SDK)" FORCE)
        message(STATUS "Vulkan_INCLUDE_DIR -> ${Vulkan_INCLUDE_DIR}")
    else()
        message(WARNING "vulkan.hpp not found under ${_vk_sdk}/Include")
    endif()

    if(DEFINED ANDROID_NDK)
        # Use the stub matching the app's minSdk. The API 24 stub only exports
        # Vulkan 1.0 entry points, so ggml-vulkan fails to link with
        # "undefined symbol: vkGetPhysicalDeviceFeatures2" (Vulkan 1.1, API 28+).
        if(DEFINED ANDROID_PLATFORM_LEVEL)
            set(_vk_api "${ANDROID_PLATFORM_LEVEL}")
        else()
            set(_vk_api 33)
        endif()
        set(_vk_stub "${ANDROID_NDK}/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/aarch64-linux-android/${_vk_api}/libvulkan.so")
        if(EXISTS "${_vk_stub}")
            set(Vulkan_LIBRARY "${_vk_stub}" CACHE FILEPATH "Android Vulkan loader stub" FORCE)
            message(STATUS "Vulkan loader -> ${Vulkan_LIBRARY}")
        else()
            message(WARNING "NDK Vulkan stub not found at ${_vk_stub}; linking may fail")
        endif()
    else()
        message(WARNING "ANDROID_NDK not defined; cannot pin Vulkan loader stub")
    endif()
endif()

# --------------------------------------------------------------------------
# OpenCL GPU backend (second GPU path, alongside Vulkan)
# --------------------------------------------------------------------------
# The ggml-opencl backend supports Q4_K (incl. Q4_K_M) matmul on contiguous
# F32 activations with Adreno-optimized kernels (GGML_OPENCL_USE_ADRENO_KERNELS,
# default ON). llama.rn runs Android GPU offload on this backend (Adreno 700+),
# while our Vulkan path is numerically corrupt on Adreno 825 — hence both are
# compiled so the user can pick at runtime.
option(GGML_OPENCL "ggml: use OpenCL" OFF)
if(DEFINED ANDROID_ABI AND ANDROID_ABI STREQUAL "arm64-v8a")
    set(GGML_OPENCL ON CACHE BOOL "" FORCE)
    message(STATUS "OpenCL ENABLED (GPU backend) for arm64-v8a")

    # Android NDK has no OpenCL SDK; vendor the Khronos headers (header-only)
    # and resolve the loader at runtime (dlopen) like llama.rn does. Pre-seed
    # the variables find_package(OpenCL) would produce so its REQUIRED call
    # inside ggml-opencl/CMakeLists.txt succeeds on the Android toolchain
    # (where CMAKE_FIND_ROOT_PATH_MODE_* hide host packages).
    set(_ocl_hdr "${PROJECT_ROOT_DIR}/third_party/OpenCL-Headers")
    # fallback: derive from source dir (cpp -> project root is 4 levels up)
    if(NOT EXISTS "${_ocl_hdr}/CL/cl.h")
        set(_ocl_hdr "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/OpenCL-Headers")
    endif()
    if(EXISTS "${_ocl_hdr}/CL/cl.h")
        set(OpenCL_INCLUDE_DIR "${_ocl_hdr}" CACHE PATH "Vendored Khronos OpenCL-Headers" FORCE)
        set(OpenCL_INCLUDE_DIRS "${_ocl_hdr}" CACHE PATH "Vendored Khronos OpenCL-Headers" FORCE)
        message(STATUS "OpenCL_INCLUDE_DIR -> ${_ocl_hdr}")
    else()
        message(WARNING "OpenCL-Headers not found at ${_ocl_hdr}; OpenCL backend will fail to configure")
    endif()
    # On Android the OpenCL loader (libOpenCL.so) is provided by the OS at
    # runtime; ggml-opencl links ${OpenCL_LIBRARIES} directly against cl*
    # symbols, so we must satisfy those at link time with our stub library
    # (the real libOpenCL.so from the device overrides the stub's weak
    # symbols at load time via <uses-native-library required="false">).
    # The stub target is created BEFORE add_subdirectory(llama) because
    # ggml-opencl/CMakeLists.txt does target_link_libraries(... PRIVATE
    # ${OpenCL_LIBRARIES}) during its own configure step.
    if(DEFINED ANDROID_NDK)
        add_subdirectory(${PROJECT_ROOT_DIR}/third_party/opencl-stub ${CMAKE_CURRENT_BINARY_DIR}/opencl-stub)
        set(OpenCL_LIBRARIES opencl_stub CACHE FILEPATH "OpenCL link-time stub (weak; overridden by device libOpenCL.so)" FORCE)
        set(OpenCL_LIBRARY opencl_stub CACHE FILEPATH "OpenCL link-time stub (weak; overridden by device libOpenCL.so)" FORCE)
        message(STATUS "OpenCL_LIBRARIES -> opencl_stub (weak; device libOpenCL.so at runtime)")
    else()
        set(OpenCL_LIBRARIES "" CACHE FILEPATH "OpenCL loader (none)" FORCE)
    endif()
endif()

# --------------------------------------------------------------------------
# llmlib: static library from llama.cpp
# --------------------------------------------------------------------------
add_subdirectory(${LLAMA_CPP_DIR} ${CMAKE_CURRENT_BINARY_DIR}/llama)

# --------------------------------------------------------------------------
# tongyilite_jni: our JNI bridge
# --------------------------------------------------------------------------
add_library(tongyilite_jni SHARED
    tongyilite_jni.cpp
)

target_compile_features(tongyilite_jni PRIVATE cxx_std_17)

target_include_directories(tongyilite_jni PRIVATE
    ${LLAMA_CPP_DIR}/src
    ${LLAMA_CPP_DIR}/include
    ${LLAMA_CPP_DIR}/common
    ${LLAMA_CPP_DIR}/ggml/include
    ${LLAMA_CPP_DIR}/ggml/src
)

target_link_libraries(tongyilite_jni
    llama
    android
    log
    dl
)

# --------------------------------------------------------------------------
# Build options (tune these per device tier)
# --------------------------------------------------------------------------
if(DEFINED ANDROID_ABI AND ANDROID_ABI STREQUAL "arm64-v8a")
    target_compile_definitions(tongyilite_jni PRIVATE GGML_SYSTEM_ARCH=ARM)
endif()

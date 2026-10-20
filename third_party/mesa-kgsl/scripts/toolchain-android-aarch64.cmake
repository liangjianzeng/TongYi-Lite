# Android arm64 交叉工具链（aarch64 宿主专用）· Mesa 线测量体构建用
#
# 为什么不用 NDK 自带的 build/cmake/android.toolchain.cmake：
# 该文件对 Linux 宿主**写死** `set(ANDROID_HOST_TAG linux-x86_64)`（r27 第 276 行，无 aarch64 分支），
# 于是在 DGX Spark(aarch64) 上 clang/ld 走 FEX/qemu 模拟的 x86-64 二进制，且链接期丢 compiler-rt
# （`undefined symbol: _Unwind_RaiseException` + `-l:libclang_rt.builtins-aarch64-android.a unused`）。
#
# 也不用 CMake 自带的 Platform/Android-*：它会按 NDK 老布局反推编译器路径
# （拼出 toolchains/llvm/prebuilt/linux-x86/bin/clang++ 这种不存在的东西）。
# 这里直接 Generic + 显式 --target/sysroot，用 NDK 自带的 linux-aarch64 prebuilt 原生跑。
#
# 用法：cmake -DCMAKE_TOOLCHAIN_FILE=<本文件> -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=28 ...
if(NOT ANDROID_ABI)
  set(ANDROID_ABI arm64-v8a CACHE STRING "Android ABI")
endif()
if(NOT ANDROID_PLATFORM)
  set(ANDROID_PLATFORM 28 CACHE STRING "Android API level")
endif()
if(NOT ANDROID_NDK_HOME)
  set(ANDROID_NDK_HOME "$ENV{ANDROID_NDK_HOME}")
endif()
if(NOT ANDROID_NDK_HOME)
  set(ANDROID_NDK_HOME "$ENV{HOME}/android-sdk/ndk/27.0.12077973")
endif()

set(_NDK_HOST "$ENV{NDK_HOST_TAG}")
if(NOT _NDK_HOST)
  set(_NDK_HOST "linux-aarch64")
endif()
set(ANDROID_HOST_TAG ${_NDK_HOST} CACHE STRING "NDK prebuilt host dir")
set(_PREBUILT "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${ANDROID_HOST_TAG}")
if(NOT EXISTS "${_PREBUILT}/bin/clang")
  message(FATAL_ERROR "NDK prebuilt 不存在：${_PREBUILT}/bin/clang（aarch64 宿主需 NDK 自带 linux-aarch64）")
endif()

string(REGEX REPLACE "[^0-9].*" "" _API "${ANDROID_PLATFORM}")
if(NOT _API)
  set(_API 28)
endif()
set(_TRIPLE "aarch64-linux-android${_API}")

set(CMAKE_SYSTEM_NAME Generic)          # 绕开 CMake Platform/Android 的反推
set(CMAKE_SYSTEM_VERSION ${_API})
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_SYSROOT "${_PREBUILT}/sysroot")

set(CMAKE_C_COMPILER   "${_PREBUILT}/bin/clang"   CACHE FILEPATH "NDK clang")
set(CMAKE_CXX_COMPILER "${_PREBUILT}/bin/clang++" CACHE FILEPATH "NDK clang++")
set(CMAKE_ASM_COMPILER "${_PREBUILT}/bin/clang"   CACHE FILEPATH "NDK clang (asm)")

set(_COMMON "--target=${_TRIPLE} -D__ANDROID_API__=${_API} -D_GNU_SOURCE")
# ^ _GNU_SOURCE 必须有：NDK 工具链文件平时替你加，少了它 ggml-cpu.c 的
#   cpu_set_t/CPU_SET/sched_setaffinity（亲和性钉核）在 Android 上直接编不过。
# compiler-rt 目录（clang 版本随 NDK 变，别写死 18）
# NDK 在 aarch64 宿主的 prebuilt 里**不带** lib/clang/*/lib/linux（runtime 库只随 x86_64 宿主发），
# 所以两个宿主目录都 glob；内容都是 Android 目标码，与宿主无关。
file(GLOB _CRT_LIB_DIRS
     "${_PREBUILT}/lib/clang/*/lib/linux"
     "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/*/lib/clang/*/lib/linux")
set(_CRT_FLAGS "")
set(_UNWIND "")
foreach(_d ${_CRT_LIB_DIRS})
  string(APPEND _CRT_FLAGS " -L${_d}")
  if(EXISTS "${_d}/aarch64/libunwind.a" AND NOT _UNWIND)
    string(APPEND _CRT_FLAGS " -L${_d}/aarch64")
    set(_UNWIND "-l:libunwind.a")
  endif()
endforeach()
set(CMAKE_C_FLAGS_INIT   "${_COMMON}" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_INIT "${_COMMON}" CACHE STRING "" FORCE)
set(CMAKE_ASM_FLAGS_INIT "${_COMMON}" CACHE STRING "" FORCE)
# _INIT 只在 cache 项**首次创建**时生效；构建脚本用 -DCMAKE_C_FLAGS= 传优化级会把该项预先建好，
# 于是 --target 被整体丢弃（症状：链接期 Scrt1.o/crti.o/-lc 全找不到）。这里显式补进 cache。
foreach(_v CMAKE_C_FLAGS CMAKE_CXX_FLAGS CMAKE_ASM_FLAGS)
  if(NOT "${${_v}}" MATCHES "--target=")
    set(${_v} "${_COMMON} ${${_v}}" CACHE STRING "cross flags" FORCE)
  endif()
endforeach()
if(NOT "${CMAKE_EXE_LINKER_FLAGS}" MATCHES "--target=")
  set(CMAKE_EXE_LINKER_FLAGS "${_COMMON} --sysroot=${_PREBUILT}/sysroot -static-libstdc++${_CRT_FLAGS}" CACHE STRING "cross link flags" FORCE)
endif()
if(NOT "${CMAKE_SHARED_LINKER_FLAGS}" MATCHES "--target=")
  set(CMAKE_SHARED_LINKER_FLAGS "${_COMMON} --sysroot=${_PREBUILT}/sysroot" CACHE STRING "cross link flags" FORCE)
endif()
set(CMAKE_EXE_LINKER_FLAGS_INIT
    "${_COMMON} --sysroot=${_PREBUILT}/sysroot -static-libstdc++${_CRT_FLAGS}"
    CACHE STRING "" FORCE)
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_COMMON} --sysroot=${_PREBUILT}/sysroot" CACHE STRING "" FORCE)

set(CMAKE_FIND_ROOT_PATH "${_PREBUILT}/sysroot/usr" "${_PREBUILT}/sysroot/usr/${_TRIPLE}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# llama.cpp / ggml 里大量 `if(ANDROID)` 判定：NDK 工具链文件里它们是普通变量，这里补齐
set(ANDROID TRUE)
# 静态 libc++/libc++abi 的异常/回栈符号（_Unwind_*）在 libunwind.a 里；NDK 工具链文件平时替你挂，
# 少了它 C++ 可执行文件全在链接期报 undefined symbol: _Unwind_RaiseException。
set(CMAKE_CXX_STANDARD_LIBRARIES "${_UNWIND}" CACHE STRING "unwind" FORCE)
set(ANDROID_STL c++_static CACHE STRING "NDK C++ runtime")
set(ANDROID_SUPPORTS_FLOAT16 TRUE CACHE BOOL "")
set(ANDROID_NATIVE_API_LEVEL ${_API} CACHE STRING "")
set(ANDROID_TOOLCHAIN clang CACHE STRING "")

# Install script for directory: /home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/usr/local")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "1")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "TRUE")
endif()

# Set default install directory permissions.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/home/jianzengliang/m4/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objdump")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-ndk/ggml/src/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-ndk/ggml/tests/cmake_install.cmake")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so")
    file(RPATH_CHECK
         FILE "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so"
         RPATH "")
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-ndk/ggml/src/libggml.so")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so")
    if(CMAKE_INSTALL_DO_STRIP)
      execute_process(COMMAND "/home/jianzengliang/m4/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so")
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include" TYPE FILE FILES
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-cpu.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-alloc.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-backend.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-blas.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-cann.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-cpp.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-cuda.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-opt.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-metal.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-rpc.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-virtgpu.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-sycl.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-vulkan.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-webgpu.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-zendnn.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/ggml-openvino.h"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/ggml/include/gguf.h"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so")
    file(RPATH_CHECK
         FILE "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so"
         RPATH "")
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-ndk/ggml/src/libggml-base.so")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so")
    if(CMAKE_INSTALL_DO_STRIP)
      execute_process(COMMAND "/home/jianzengliang/m4/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so")
    endif()
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/ggml" TYPE FILE FILES
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-ndk/ggml/ggml-config.cmake"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-ndk/ggml/ggml-config-version.cmake"
    )
endif()


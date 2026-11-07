# Install script for directory: /home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/third_party/llama.cpp/examples

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
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

# Set default install directory permissions.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/usr/bin/objdump")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/batched/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/debug/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/embedding/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/eval-callback/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/gguf-hash/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/gguf/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/idle/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/lookahead/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/lookup/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/parallel/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/passkey/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/retrieval/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/simple/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/simple-chat/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/speculative/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/speculative-simple/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/gen-docs/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/training/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/diffusion/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-gemm/examples/convert-llama2c-to-ggml/cmake_install.cmake")
endif()


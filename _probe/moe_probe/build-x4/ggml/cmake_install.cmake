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
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

# Set default install directory permissions.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/usr/bin/objdump")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/src/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/tests/cmake_install.cmake")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  foreach(file
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so.0.27.0"
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so.0"
      )
    if(EXISTS "${file}" AND
       NOT IS_SYMLINK "${file}")
      file(RPATH_CHECK
           FILE "${file}"
           RPATH "")
    endif()
  endforeach()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/src/libggml.so.0.27.0"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/src/libggml.so.0"
    )
  foreach(file
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so.0.27.0"
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml.so.0"
      )
    if(EXISTS "${file}" AND
       NOT IS_SYMLINK "${file}")
      file(RPATH_CHANGE
           FILE "${file}"
           OLD_RPATH "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/src:/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/src/ggml-opencl:"
           NEW_RPATH "")
      if(CMAKE_INSTALL_DO_STRIP)
        execute_process(COMMAND "/usr/bin/strip" "${file}")
      endif()
    endif()
  endforeach()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/src/libggml.so")
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
  foreach(file
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so.0.27.0"
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so.0"
      )
    if(EXISTS "${file}" AND
       NOT IS_SYMLINK "${file}")
      file(RPATH_CHECK
           FILE "${file}"
           RPATH "")
    endif()
  endforeach()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/src/libggml-base.so.0.27.0"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/src/libggml-base.so.0"
    )
  foreach(file
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so.0.27.0"
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libggml-base.so.0"
      )
    if(EXISTS "${file}" AND
       NOT IS_SYMLINK "${file}")
      if(CMAKE_INSTALL_DO_STRIP)
        execute_process(COMMAND "/usr/bin/strip" "${file}")
      endif()
    endif()
  endforeach()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/src/libggml-base.so")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/ggml" TYPE FILE FILES
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/ggml-config.cmake"
    "/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/_probe/moe_probe/build-x4/ggml/ggml-config-version.cmake"
    )
endif()


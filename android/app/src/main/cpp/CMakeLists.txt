cmake_minimum_required(VERSION 3.31.6)

project("tongyilite_native" VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# --------------------------------------------------------------------------
# Locate llama.cpp source (submodule at project root third_party/llama.cpp)
# --------------------------------------------------------------------------
set(LLAMA_CPP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../third_party/llama.cpp)

if(NOT EXISTS ${LLAMA_CPP_DIR}/src/llama.cpp)
    message(FATAL_ERROR
        "llama.cpp not found at ${LLAMA_CPP_DIR}.\n"
        "Run: git submodule update --init --recursive"
    )
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
    llama-common
    android
    log
)

# --------------------------------------------------------------------------
# Build options (tune these per device tier)
# --------------------------------------------------------------------------
if(DEFINED ANDROID_ABI AND ANDROID_ABI STREQUAL "arm64-v8a")
    target_compile_definitions(tongyilite_jni PRIVATE GGML_SYSTEM_ARCH=ARM)
    set(GGML_KLEIDIAI ON CACHE BOOL "" FORCE)
    set(GGML_OPENMP ON CACHE BOOL "" FORCE)
endif()

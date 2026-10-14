cmake_minimum_required(VERSION 3.22)
project(moe_probe CXX)
set(CMAKE_CXX_STANDARD 17)

set(LLAMA_DIR E:/DTXY/TongYi-Lite/third_party/llama.cpp)
set(OpenCL_INCLUDE_DIR E:/DTXY/TongYi-Lite/third_party/OpenCL-Headers CACHE PATH "" FORCE)
set(OpenCL_LIBRARY E:/DTXY/TongYi-Lite/_probe/oclstub_build/opencl-stub/libopencl_stub.so CACHE FILEPATH "" FORCE)
set(GGML_OPENCL ON CACHE BOOL "" FORCE)
set(GGML_OPENCL_EMBED_KERNELS ON CACHE BOOL "" FORCE)
set(GGML_OPENCL_USE_ADRENO_KERNELS ON CACHE BOOL "" FORCE)

add_subdirectory(${LLAMA_DIR}/ggml ggml)

add_executable(moe_probe moe_probe.cpp)
target_include_directories(moe_probe PRIVATE ${LLAMA_DIR}/ggml/src)
target_link_libraries(moe_probe PRIVATE ggml)

add_executable(moe_probe2 moe_probe2.cpp)
target_include_directories(moe_probe2 PRIVATE ${LLAMA_DIR}/ggml/src)
target_link_libraries(moe_probe2 PRIVATE ggml)

add_executable(moe_probe3 moe_probe3.cpp)
target_include_directories(moe_probe3 PRIVATE ${LLAMA_DIR}/ggml/src)
target_link_libraries(moe_probe3 PRIVATE ggml)

add_executable(moe_probe4 moe_probe4.cpp)
target_include_directories(moe_probe4 PRIVATE ${LLAMA_DIR}/ggml/src)
target_link_libraries(moe_probe4 PRIVATE ggml)

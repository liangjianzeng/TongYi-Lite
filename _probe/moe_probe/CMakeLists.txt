cmake_minimum_required(VERSION 3.22)
project(moe_probe CXX)
set(CMAKE_CXX_STANDARD 17)

# [2026-10-20 双宿主化 · Mesa 线接管] 路径不再写死 E:/DTXY：默认由本文件位置推导仓库根，
# Windows / Linux aarch64 共用同一份；要指别处仍可用 -DLLAMA_DIR= / -DOpenCL_LIBRARY= 覆盖。
get_filename_component(TYL_REPO_ROOT ${CMAKE_CURRENT_LIST_DIR}/../.. ABSOLUTE)
if(NOT LLAMA_DIR)
  set(LLAMA_DIR ${TYL_REPO_ROOT}/third_party/llama.cpp)
endif()
if(NOT OpenCL_INCLUDE_DIR)
  set(OpenCL_INCLUDE_DIR ${TYL_REPO_ROOT}/third_party/OpenCL-Headers CACHE PATH "" FORCE)
endif()
if(NOT OpenCL_LIBRARY)
  set(OpenCL_LIBRARY ${TYL_REPO_ROOT}/_probe/oclstub_build/opencl-stub/libopencl_stub.so CACHE FILEPATH "" FORCE)
endif()

set(GGML_OPENCL ON CACHE BOOL "" FORCE)
set(GGML_OPENCL_EMBED_KERNELS ON CACHE BOOL "" FORCE)
set(GGML_OPENCL_USE_ADRENO_KERNELS ON CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS ON CACHE BOOL "" FORCE)
# stub: tests/CMakeLists.txt uses this root-only cmake helper
macro(llama_add_compile_flags)
endmacro()

add_subdirectory(${LLAMA_DIR}/ggml ggml)

# 探针清单：源文件在位才建（历史上 probe5-9 / svm_probe 只存在于其中一台宿主，
# 缺源曾让 Linux 侧 configure 直接失败 —— Mesa 线要求"换机即可复现测量"，故在此收口）。
function(tyl_add_probe name)
  if(EXISTS ${CMAKE_CURRENT_LIST_DIR}/${name}.cpp)
    add_executable(${name} ${name}.cpp)
    target_include_directories(${name} PRIVATE
      ${LLAMA_DIR}/ggml/src ${LLAMA_DIR}/ggml/include
      ${LLAMA_DIR}/include ${LLAMA_DIR}/src ${LLAMA_DIR} ${LLAMA_DIR}/common
      ${OpenCL_INCLUDE_DIR})
    if(${ARGC} GREATER 1)
      target_link_libraries(${name} PRIVATE ${ARGN})
    else()
      target_link_libraries(${name} PRIVATE ggml)
    endif()
  else()
    message(STATUS "[moe_probe] 跳过缺失探针源：${name}.cpp")
  endif()
endfunction()

tyl_add_probe(moe_probe)
tyl_add_probe(moe_probe2)
tyl_add_probe(moe_probe3)
tyl_add_probe(moe_probe4)
tyl_add_probe(moe_probe5)
tyl_add_probe(moe_probe6)
tyl_add_probe(moe_probe7)
tyl_add_probe(moe_probe8)
tyl_add_probe(moe_probe9)
tyl_add_probe(svm_probe ${OpenCL_LIBRARY})

set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(LLAMA_SERVER OFF CACHE BOOL "" FORCE)
add_subdirectory(${LLAMA_DIR} llama-src)

if(EXISTS ${CMAKE_CURRENT_LIST_DIR}/minicpm_e2e.cpp)
  add_executable(minicpm_e2e minicpm_e2e.cpp)
  target_include_directories(minicpm_e2e PRIVATE
    ${LLAMA_DIR}/include ${LLAMA_DIR}/src ${LLAMA_DIR} ${LLAMA_DIR}/common)
  target_link_libraries(minicpm_e2e PRIVATE llama llama-common)
endif()

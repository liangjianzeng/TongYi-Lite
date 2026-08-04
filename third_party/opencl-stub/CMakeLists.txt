# OpenCL dispatch shim for Android: satisfies link-time cl* symbols by
# dlopening the device's real libOpenCL.so at call time and forwarding to it
# (the manifest declares <uses-native-library required="false"> so the vendor
# library is visible to dlopen). If no OpenCL driver exists, shim calls return
# "success with nothing" and the backend finds zero devices -> CPU fallback.
add_library(opencl_stub SHARED opencl_stub.c)
target_include_directories(opencl_stub PRIVATE ${OpenCL_INCLUDE_DIR})
target_link_libraries(opencl_stub PRIVATE dl)

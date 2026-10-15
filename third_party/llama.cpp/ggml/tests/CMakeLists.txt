# minimal: only test-backend-ops (vendored slim tree lacks other test sources)
add_executable(test-backend-ops test-backend-ops.cpp)
target_link_libraries(test-backend-ops PRIVATE ggml)

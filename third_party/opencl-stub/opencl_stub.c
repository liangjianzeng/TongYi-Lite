/*
 * OpenCL dispatch shim for Android.
 *
 * ggml-opencl references cl* symbols directly (no dlopen for the API itself).
 * Android NDK has no libOpenCL.so to link against, and the device's real
 * libOpenCL.so lives in /vendor/lib64 (provided to the app via
 * <uses-native-library required="false"> in the manifest, so it is visible to
 * dlopen). This shim resolves every cl* symbol at call time by dlopening the
 * device library and forwarding to it. If no OpenCL driver is present, the
 * shim returns CL_SUCCESS with zero platforms/errors so the backend simply
 * finds no devices and the app falls back to CPU.
 */
#include <CL/cl.h>

#include <dlfcn.h>

typedef void *(*pfn_clGetPlatformIDs)(void);
typedef void *(*pfn_clGetPlatformInfo)(void);
typedef void *(*pfn_clGetDeviceIDs)(void);
typedef void *(*pfn_clGetDeviceInfo)(void);
typedef void *(*pfn_clCreateContext)(void);
typedef void *(*pfn_clCreateCommandQueue)(void);
typedef void *(*pfn_clCreateBuffer)(void);
typedef void *(*pfn_clCreateSubBuffer)(void);
typedef void *(*pfn_clCreateImage)(void);
typedef void *(*pfn_clSetKernelArg)(void);
typedef void *(*pfn_clFinish)(void);
typedef void *(*pfn_clEnqueueBarrierWithWaitList)(void);
typedef void *(*pfn_clBuildProgram)(void);
typedef void *(*pfn_clCreateProgramWithBinary)(void);
typedef void *(*pfn_clGetProgramInfo)(void);
typedef void *(*pfn_clReleaseProgram)(void);
typedef void *(*pfn_clReleaseMemObject)(void);
typedef void *(*pfn_clReleaseCommandQueue)(void);
typedef void *(*pfn_clReleaseContext)(void);
typedef void *(*pfn_clReleaseKernel)(void);
typedef void *(*pfn_clReleaseEvent)(void);
typedef void *(*pfn_clEnqueueNDRangeKernel)(void);
typedef void *(*pfn_clEnqueueReadBuffer)(void);
typedef void *(*pfn_clEnqueueWriteBuffer)(void);
typedef void *(*pfn_clEnqueueCopyBuffer)(void);
typedef void *(*pfn_clCreateKernel)(void);
typedef void *(*pfn_clGetKernelWorkGroupInfo)(void);
typedef void *(*pfn_clGetEventInfo)(void);
typedef void *(*pfn_clWaitForEvents)(void);
typedef void *(*pfn_clGetEventProfilingInfo)(void);
typedef void *(*pfn_clGetExtensionFunctionAddressForPlatform)(void);
typedef void *(*pfn_clEnqueueMapBuffer)(void);
typedef void *(*pfn_clEnqueueUnmapMemObject)(void);
typedef void *(*pfn_clEnqueueMarkerWithWaitList)(void);
typedef void *(*pfn_clFlush)(void);
typedef void *(*pfn_clCreateBufferWithProperties)(void);
typedef void *(*pfn_clGetProgramBuildInfo)(void);
typedef void *(*pfn_clCreateProgramWithSource)(void);
typedef void *(*pfn_clEnqueueFillBuffer)(void);

static void *g_opencl_lib = NULL;

static void *cl_load(void) {
    if (g_opencl_lib) return g_opencl_lib;
    // The device's OpenCL loader; visible because the manifest declares
    // <uses-native-library android:name="libOpenCL.so" android:required="false"/>.
    const char *paths[] = {"libOpenCL.so", "/vendor/lib64/libOpenCL.so", "/system/lib64/libOpenCL.so"};
    for (size_t i = 0; i < sizeof(paths)/sizeof(paths[0]); i++) {
        void *h = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (h) { g_opencl_lib = h; return h; }
    }
    return NULL;
}

#define CL_FORWARD(name, args)                                          \
    do {                                                                \
        static pfn_##name sym = NULL;                                   \
        if (!sym) {                                                     \
            void *lib = cl_load();                                      \
            if (!lib) return 0;                                         \
            sym = (pfn_##name) dlsym(lib, #name);                       \
            if (!sym) return 0;                                         \
        }                                                               \
        return ((__typeof__(&name)) sym) args;                          \
    } while (0)

cl_int clGetPlatformIDs(cl_uint num_entries, cl_platform_id *platforms, cl_uint *num_platforms) {
    CL_FORWARD(clGetPlatformIDs, (num_entries, platforms, num_platforms));
}
cl_int clGetPlatformInfo(cl_platform_id platform, cl_platform_info param_name, size_t param_value_size, void *param_value, size_t *param_value_size_ret) {
    CL_FORWARD(clGetPlatformInfo, (platform, param_name, param_value_size, param_value, param_value_size_ret));
}
cl_int clGetDeviceIDs(cl_platform_id platform, cl_device_type device_type, cl_uint num_entries, cl_device_id *devices, cl_uint *num_devices) {
    CL_FORWARD(clGetDeviceIDs, (platform, device_type, num_entries, devices, num_devices));
}
cl_int clGetDeviceInfo(cl_device_id device, cl_device_info param_name, size_t param_value_size, void *param_value, size_t *param_value_size_ret) {
    CL_FORWARD(clGetDeviceInfo, (device, param_name, param_value_size, param_value, param_value_size_ret));
}
cl_context clCreateContext(const cl_context_properties *properties, cl_uint num_devices, const cl_device_id *devices, void (CL_CALLBACK *pfn_notify)(const char *, const void *, size_t, void *), void *user_data, cl_int *errcode_ret) {
    CL_FORWARD(clCreateContext, (properties, num_devices, devices, pfn_notify, user_data, errcode_ret));
}
cl_command_queue clCreateCommandQueue(cl_context context, cl_device_id device, cl_command_queue_properties properties, cl_int *errcode_ret) {
    CL_FORWARD(clCreateCommandQueue, (context, device, properties, errcode_ret));
}
cl_mem clCreateBuffer(cl_context context, cl_mem_flags flags, size_t size, void *host_ptr, cl_int *errcode_ret) {
    CL_FORWARD(clCreateBuffer, (context, flags, size, host_ptr, errcode_ret));
}
cl_mem clCreateSubBuffer(cl_mem buffer, cl_mem_flags flags, cl_buffer_create_type buffer_create_type, const void *buffer_create_info, cl_int *errcode_ret) {
    CL_FORWARD(clCreateSubBuffer, (buffer, flags, buffer_create_type, buffer_create_info, errcode_ret));
}
cl_mem clCreateImage(cl_context context, cl_mem_flags flags, const cl_image_format *image_format, const cl_image_desc *image_desc, void *host_ptr, cl_int *errcode_ret) {
    CL_FORWARD(clCreateImage, (context, flags, image_format, image_desc, host_ptr, errcode_ret));
}
cl_int clSetKernelArg(cl_kernel kernel, cl_uint arg_index, size_t arg_size, const void *arg_value) {
    CL_FORWARD(clSetKernelArg, (kernel, arg_index, arg_size, arg_value));
}
cl_int clFinish(cl_command_queue command_queue) {
    CL_FORWARD(clFinish, (command_queue));
}
cl_int clEnqueueBarrierWithWaitList(cl_command_queue command_queue, cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event) {
    CL_FORWARD(clEnqueueBarrierWithWaitList, (command_queue, num_events_in_wait_list, event_wait_list, event));
}
cl_int clBuildProgram(cl_program program, cl_uint num_devices, const cl_device_id *device_list, const char *options, void (CL_CALLBACK *pfn_notify)(cl_program, void *), void *user_data) {
    CL_FORWARD(clBuildProgram, (program, num_devices, device_list, options, pfn_notify, user_data));
}
cl_program clCreateProgramWithBinary(cl_context context, cl_uint num_devices, const cl_device_id *device_list, const size_t *lengths, const unsigned char **binaries, cl_int *binary_status, cl_int *errcode_ret) {
    CL_FORWARD(clCreateProgramWithBinary, (context, num_devices, device_list, lengths, binaries, binary_status, errcode_ret));
}
cl_int clGetProgramInfo(cl_program program, cl_program_info param_name, size_t param_value_size, void *param_value, size_t *param_value_size_ret) {
    CL_FORWARD(clGetProgramInfo, (program, param_name, param_value_size, param_value, param_value_size_ret));
}
cl_int clReleaseProgram(cl_program program) {
    CL_FORWARD(clReleaseProgram, (program));
}
cl_int clReleaseMemObject(cl_mem memobj) {
    CL_FORWARD(clReleaseMemObject, (memobj));
}
cl_int clReleaseCommandQueue(cl_command_queue command_queue) {
    CL_FORWARD(clReleaseCommandQueue, (command_queue));
}
cl_int clReleaseContext(cl_context context) {
    CL_FORWARD(clReleaseContext, (context));
}
cl_int clReleaseKernel(cl_kernel kernel) {
    CL_FORWARD(clReleaseKernel, (kernel));
}
cl_int clReleaseEvent(cl_event event) {
    CL_FORWARD(clReleaseEvent, (event));
}
cl_int clEnqueueNDRangeKernel(cl_command_queue command_queue, cl_kernel kernel, cl_uint work_dim, const size_t *global_work_offset, const size_t *global_work_size, const size_t *local_work_size, cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event) {
    CL_FORWARD(clEnqueueNDRangeKernel, (command_queue, kernel, work_dim, global_work_offset, global_work_size, local_work_size, num_events_in_wait_list, event_wait_list, event));
}
cl_int clEnqueueReadBuffer(cl_command_queue command_queue, cl_mem buffer, cl_bool blocking_read, size_t offset, size_t size, void *ptr, cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event) {
    CL_FORWARD(clEnqueueReadBuffer, (command_queue, buffer, blocking_read, offset, size, ptr, num_events_in_wait_list, event_wait_list, event));
}
cl_int clEnqueueWriteBuffer(cl_command_queue command_queue, cl_mem buffer, cl_bool blocking_write, size_t offset, size_t size, const void *ptr, cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event) {
    CL_FORWARD(clEnqueueWriteBuffer, (command_queue, buffer, blocking_write, offset, size, ptr, num_events_in_wait_list, event_wait_list, event));
}
cl_int clEnqueueCopyBuffer(cl_command_queue command_queue, cl_mem src_buffer, cl_mem dst_buffer, size_t src_offset, size_t dst_offset, size_t size, cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event) {
    CL_FORWARD(clEnqueueCopyBuffer, (command_queue, src_buffer, dst_buffer, src_offset, dst_offset, size, num_events_in_wait_list, event_wait_list, event));
}
cl_kernel clCreateKernel(cl_program program, const char *kernel_name, cl_int *errcode_ret) {
    CL_FORWARD(clCreateKernel, (program, kernel_name, errcode_ret));
}
cl_int clGetKernelWorkGroupInfo(cl_kernel kernel, cl_device_id device, cl_kernel_work_group_info param_name, size_t param_value_size, void *param_value, size_t *param_value_size_ret) {
    CL_FORWARD(clGetKernelWorkGroupInfo, (kernel, device, param_name, param_value_size, param_value, param_value_size_ret));
}
cl_int clGetEventInfo(cl_event event, cl_event_info param_name, size_t param_value_size, void *param_value, size_t *param_value_size_ret) {
    CL_FORWARD(clGetEventInfo, (event, param_name, param_value_size, param_value, param_value_size_ret));
}
cl_int clWaitForEvents(cl_uint num_events, const cl_event *event_list) {
    CL_FORWARD(clWaitForEvents, (num_events, event_list));
}
cl_int clGetEventProfilingInfo(cl_event event, cl_profiling_info param_name, size_t param_value_size, void *param_value, size_t *param_value_size_ret) {
    CL_FORWARD(clGetEventProfilingInfo, (event, param_name, param_value_size, param_value, param_value_size_ret));
}
void *clGetExtensionFunctionAddressForPlatform(cl_platform_id platform, const char *func_name) {
    CL_FORWARD(clGetExtensionFunctionAddressForPlatform, (platform, func_name));
}
void *clEnqueueMapBuffer(cl_command_queue command_queue, cl_mem buffer, cl_bool blocking_map, cl_map_flags map_flags, size_t offset, size_t size, cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event, cl_int *errcode_ret) {
    CL_FORWARD(clEnqueueMapBuffer, (command_queue, buffer, blocking_map, map_flags, offset, size, num_events_in_wait_list, event_wait_list, event, errcode_ret));
}
cl_int clEnqueueUnmapMemObject(cl_command_queue command_queue, cl_mem memobj, void *mapped_ptr, cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event) {
    CL_FORWARD(clEnqueueUnmapMemObject, (command_queue, memobj, mapped_ptr, num_events_in_wait_list, event_wait_list, event));
}
cl_int clEnqueueMarkerWithWaitList(cl_command_queue command_queue, cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event) {
    CL_FORWARD(clEnqueueMarkerWithWaitList, (command_queue, num_events_in_wait_list, event_wait_list, event));
}
cl_int clFlush(cl_command_queue command_queue) {
    CL_FORWARD(clFlush, (command_queue));
}
cl_mem clCreateBufferWithProperties(cl_context context, const cl_mem_properties *properties, cl_mem_flags flags, size_t size, void *host_ptr, cl_int *errcode_ret) {
    CL_FORWARD(clCreateBufferWithProperties, (context, properties, flags, size, host_ptr, errcode_ret));
}
cl_int clGetProgramBuildInfo(cl_program program, cl_device_id device, cl_program_build_info param_name, size_t param_value_size, void *param_value, size_t *param_value_size_ret) {
    CL_FORWARD(clGetProgramBuildInfo, (program, device, param_name, param_value_size, param_value, param_value_size_ret));
}
cl_program clCreateProgramWithSource(cl_context context, cl_uint count, const char **strings, const size_t *lengths, cl_int *errcode_ret) {
    CL_FORWARD(clCreateProgramWithSource, (context, count, strings, lengths, errcode_ret));
}
cl_int clEnqueueFillBuffer(cl_command_queue command_queue, cl_mem buffer, const void *pattern, size_t pattern_size, size_t offset, size_t size, cl_uint num_events_in_wait_list, const cl_event *event_wait_list, cl_event *event) {
    CL_FORWARD(clEnqueueFillBuffer, (command_queue, buffer, pattern, pattern_size, offset, size, num_events_in_wait_list, event_wait_list, event));
}

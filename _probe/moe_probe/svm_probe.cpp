// [dspark 2026-10-15] SVM FGSVM feasibility probe for GPU slot bank (M2).
// 1) CPU preadv-style writes into clSVMAlloc(FINE_GRAIN_BUFFER) memory
// 2) GPU kernel reads the SVM pointer directly -> verify checksum
// 3) Repeat fill cycles to verify CPU->GPU visibility ordering after enqueue
// 4) Measure GPU read bandwidth: SVM pointer vs regular cl_mem (perf sanity)
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <chrono>
#include <algorithm>
#include <string>
#define CL_TARGET_OPENCL_VERSION 300
#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#include <CL/cl.h>

static const char * kSrc = R"CLC(
#pragma OPENCL EXTENSION cl_khr_byte_addressable_store : enable
// read raw bytes from SVM pointer, accumulate checksum
__kernel void svm_read(__global const uchar * data, const uint n_words,
                       __global uint * out) {
    const uint i = get_global_id(0);
    if (i >= n_words) return;
    uint acc = 0;
    // strided read: each work item samples words to keep total reads bounded
    for (uint k = 0; k < 16; ++k) {
        uint idx = i * 16 + k;
        if (idx < n_words) acc ^= ((const __global uint *)data)[idx] + idx;
    }
    out[i] = acc;
}
// full-bandwidth read: contiguous per-workgroup
__kernel void svm_bw(__global const uint * data, const uint n_words,
                     __global uint * out) {
    const uint i = get_global_id(0);
    uint acc = 0;
    uint base = i * 32;
    for (uint k = 0; k < 32 && (base + k) < n_words; ++k) {
        acc ^= data[base + k];
    }
    out[i] = acc;
}
__kernel void buf_bw(__global const uint * data, const uint n_words,
                     __global uint * out) {
    const uint i = get_global_id(0);
    uint acc = 0;
    uint base = i * 32;
    for (uint k = 0; k < 32 && (base + k) < n_words; ++k) {
        acc ^= data[base + k];
    }
    out[i] = acc;
}
)CLC";

#define CHECK(x) do { cl_int _e = (x); if (_e != CL_SUCCESS) { \
    printf("FAIL %s at %d err=%d\n", #x, __LINE__, (int)_e); return 1; } } while (0)

static uint32_t host_pattern(uint32_t idx) {
    uint32_t x = idx * 2654435761u + 0x9e3779b9u;
    x ^= x >> 15; x *= 0x2c1b3c6du; x ^= x >> 12;
    return x;
}

int main() {
    setbuf(stdout, nullptr);
    cl_platform_id plat; CHECK(clGetPlatformIDs(1, &plat, nullptr));
    cl_device_id dev; CHECK(clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, nullptr));
    char name[256] = {}; clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof(name), name, nullptr);
    cl_device_svm_capabilities caps = 0;
    clGetDeviceInfo(dev, CL_DEVICE_SVM_CAPABILITIES, sizeof(caps), &caps, nullptr);
    size_t max_alloc = 0; clGetDeviceInfo(dev, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof(max_alloc), &max_alloc, nullptr);
    printf("device=%s\nsvm caps: coarse_buf=%d fine_buf=%d fine_sys=%d atomics=%d max_alloc=%.1fMiB\n",
        name,
        (int)!(caps & CL_DEVICE_SVM_COARSE_GRAIN_BUFFER), (int)!(caps & CL_DEVICE_SVM_FINE_GRAIN_BUFFER),
        (int)!(caps & CL_DEVICE_SVM_FINE_GRAIN_SYSTEM), (int)!(caps & CL_DEVICE_SVM_ATOMICS),
        max_alloc / 1048576.0);
    if (!(caps & CL_DEVICE_SVM_FINE_GRAIN_BUFFER)) {
        printf("NO FGSVM buffer support -> GPU bank needs staging fallback\n");
        return 2;
    }

    cl_int err;
    cl_context ctx = clCreateContext(nullptr, 1, &dev, nullptr, nullptr, &err); CHECK(err);
    // OpenCL 2.0+ queue (SVM pointer args need it)
    cl_queue_properties qprops[] = { CL_QUEUE_PROPERTIES, CL_QUEUE_PROFILING_ENABLE, 0 };
    cl_command_queue q = clCreateCommandQueueWithProperties(ctx, dev, qprops, &err); CHECK(err);

    cl_program prog = clCreateProgramWithSource(ctx, 1, &kSrc, nullptr, &err); CHECK(err);
    err = clBuildProgram(prog, 1, &dev, "-cl-std=CL3.0", nullptr, nullptr);
    if (err != CL_SUCCESS) {
        char log[4096] = {}; clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof(log), log, nullptr);
        printf("BUILD FAIL: %.2000s\n", log); return 1;
    }
    cl_kernel k_read = clCreateKernel(prog, "svm_read", &err); CHECK(err);
    cl_kernel k_sbw = clCreateKernel(prog, "svm_bw", &err); CHECK(err);
    cl_kernel k_bbw = clCreateKernel(prog, "buf_bw", &err); CHECK(err);

    // 8 MiB SVM bank
    const size_t bank_bytes = 8 << 20;
    const size_t n_words = bank_bytes / 4;
    void * svm = nullptr;
    {
        cl_int e2 = CL_SUCCESS;
        svm = clSVMAlloc(ctx, CL_MEM_READ_WRITE | CL_MEM_SVM_FINE_GRAIN_BUFFER, bank_bytes, 4096);
        e2 = CL_SUCCESS; // alloc returns NULL on failure, no errcode
        if (!svm) printf("clSVMAlloc 8MiB/4096 FAILED\n");
        if (!svm) { svm = clSVMAlloc(ctx, CL_MEM_READ_WRITE | CL_MEM_SVM_FINE_GRAIN_BUFFER, bank_bytes, 128); if (svm) printf("retry 128 align OK\n"); }
        if (!svm) { svm = clSVMAlloc(ctx, CL_MEM_READ_WRITE | CL_MEM_SVM_FINE_GRAIN_BUFFER, 1 << 20, 128); if (svm) printf("retry 1MiB OK\n"); }
        if (!svm) { svm = clSVMAlloc(ctx, CL_MEM_READ_WRITE, bank_bytes, 128); if (svm) printf("retry no-flag OK\n"); }
    }
    if (!svm) { printf("clSVMAlloc ALL FAILED\n"); return 1; }
    printf("svm ptr=%p\n", svm);

    // host-side expected checksum (mirrors svm_read for the sampled words)
    // Fill cycle test: 5 cycles of CPU-write -> kernel-read-verify
    uint32_t * h = (uint32_t *)svm;
    for (int cyc = 0; cyc < 5; ++cyc) {
        const uint32_t salt = (uint32_t)(cyc + 1) * 0x5bf03635u;
        for (size_t i = 0; i < n_words; ++i) h[i] = host_pattern((uint32_t)i) ^ salt;

        cl_mem out = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, 1 << 20, nullptr, &err); CHECK(err);
        uint32_t n_out = (1 << 20) / 4;
        cl_int e_svm = clSetKernelArgSVMPointer(k_read, 0, svm);
        if (e_svm != CL_SUCCESS) {
            printf("clSetKernelArgSVMPointer err=%d, fallback clSetKernelArg\n", (int)e_svm);
            CHECK(clSetKernelArg(k_read, 0, sizeof(void *), &svm));
        }
        CHECK(clSetKernelArg(k_read, 1, sizeof(uint32_t), &n_words));
        CHECK(clSetKernelArg(k_read, 2, sizeof(cl_mem), &out));
        size_t gws = n_out;
        CHECK(clEnqueueNDRangeKernel(q, k_read, 1, nullptr, &gws, nullptr, 0, nullptr, nullptr));
        // CPU reference of sampled words
        uint32_t * ref = (uint32_t *)malloc((1 << 20));
        for (uint32_t i = 0; i < n_out; ++i) {
            uint32_t acc = 0;
            for (uint32_t k = 0; k < 16; ++k) {
                uint32_t idx = i * 16 + k;
                if (idx < n_words) acc ^= h[idx] + idx;
            }
            ref[i] = acc;
        }
        cl_uint * got = (cl_uint *)clEnqueueMapBuffer(q, out, CL_TRUE, CL_MAP_READ, 0, 1 << 20, 0, nullptr, nullptr, &err);
        CHECK(err);
        int mism = 0; uint32_t first_bad = 0, got_v = 0, want_v = 0;
        for (uint32_t i = 0; i < n_out; ++i) {
            if (got[i] != ref[i]) { if (!mism) { first_bad = i; got_v = got[i]; want_v = ref[i]; } ++mism; }
        }
        clEnqueueUnmapMemObject(q, out, got, 0, nullptr, nullptr);
        clFinish(q);
        clReleaseMemObject(out);
        free(ref);
        printf("cycle %d: %s (mism=%d%s)\n", cyc, mism == 0 ? "MATCH" : "MISMATCH", mism,
            mism ? "" : "");
        if (mism) printf("  first bad idx=%u got=%08x want=%08x\n", first_bad, got_v, want_v);
        // cleanup: refill with next salt happens at loop top
    }

    // BW test: SVM pointer read vs regular cl_mem read, 64MiB each
    const size_t bw_bytes = 64 << 20;
    const size_t bw_words = bw_bytes / 4;
    void * svm2 = clSVMAlloc(ctx, CL_MEM_READ_ONLY | CL_MEM_SVM_FINE_GRAIN_BUFFER, bw_bytes, 128);
    if (!svm2) { printf("svm2 alloc FAILED, skip BW\n"); return 0; }
    cl_mem clbuf = clCreateBuffer(ctx, CL_MEM_READ_ONLY, bw_bytes, nullptr, &err); CHECK(err);
    {
        uint32_t * p1 = (uint32_t *)svm2;
        std::vector<uint32_t> tmp(bw_words);
        for (size_t i = 0; i < bw_words; ++i) tmp[i] = host_pattern((uint32_t)i);
        memcpy(p1, tmp.data(), bw_bytes);
        CHECK(clEnqueueWriteBuffer(q, clbuf, CL_TRUE, 0, bw_bytes, tmp.data(), 0, nullptr, nullptr));
    }
    cl_mem out2 = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, 16 << 20, nullptr, &err); CHECK(err);
    size_t n_out2 = (16 << 20) / 4;
    auto bench = [&](cl_kernel k, void * svm_arg, cl_mem buf_arg, const char * tag) {
        cl_event ev;
        if (svm_arg) {
            cl_int e = clSetKernelArgSVMPointer(k, 0, svm_arg);
            if (e != CL_SUCCESS) { printf("argSVMPointer err=%d\n", (int)e); return; }
        } else {
            if (clSetKernelArg(k, 0, sizeof(cl_mem), &buf_arg) != CL_SUCCESS) { printf("setarg fail\n"); return; }
        }
        if (clSetKernelArg(k, 1, sizeof(uint32_t), &bw_words) != CL_SUCCESS ||
            clSetKernelArg(k, 2, sizeof(cl_mem), &out2) != CL_SUCCESS) { printf("setarg 1/2 fail\n"); return; }
        clFinish(q);
        if (clEnqueueNDRangeKernel(q, k, 1, nullptr, &n_out2, nullptr, 0, nullptr, &ev) != CL_SUCCESS) { printf("enqueue fail\n"); return; }
        clFinish(q);
        cl_ulong t0 = 0, t1 = 0;
        clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_START, sizeof(t0), &t0, nullptr);
        clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_END, sizeof(t1), &t1, nullptr);
        clReleaseEvent(ev);
        double ms = (t1 - t0) / 1e6;
        printf("%s: %.2f ms -> %.1f GB/s\n", tag, ms, bw_bytes / ms / 1e6);
        // verify
        uint32_t * got = (uint32_t *)clEnqueueMapBuffer(q, out2, CL_TRUE, CL_MAP_READ, 0, 16 << 20, 0, nullptr, nullptr, &err);
        if (err != CL_SUCCESS || !got) { printf("map fail err=%d\n", (int)err); return; }
        int mism = 0;
        for (size_t i = 0; i < n_out2; ++i) {
            uint32_t acc = 0, base = (uint32_t)(i * 32);
            for (uint32_t k = 0; k < 32 && (base + k) < bw_words; ++k) acc ^= host_pattern(base + k);
            if (got[i] != acc) ++mism;
        }
        clEnqueueUnmapMemObject(q, out2, got, 0, nullptr, nullptr);
        clFinish(q);
        printf("  verify: %s (mism=%d)\n", mism == 0 ? "MATCH" : "MISMATCH", mism);
    };
    bench(k_sbw, svm2, nullptr, "SVM ptr read (64MiB)");
    bench(k_bbw, nullptr, clbuf, "cl_mem read (64MiB)");
    // second pass SVM to check stability
    bench(k_sbw, svm2, nullptr, "SVM ptr read #2");

    // [M2 fix] CPU write bandwidth: SVM direct vs clEnqueueSVMMemcpy vs host malloc
    {
        std::vector<uint32_t> srcbuf(bw_words);
        for (size_t i = 0; i < bw_words; ++i) srcbuf[i] = host_pattern((uint32_t)i);
        // 1) CPU memcpy directly into SVM
        {
            auto t0 = std::chrono::steady_clock::now();
            memcpy(svm2, srcbuf.data(), bw_bytes);
            auto t1 = std::chrono::steady_clock::now();
            double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
            printf("CPU memcpy -> SVM: %.2f ms -> %.1f GB/s\n", ms, bw_bytes / ms / 1e6);
        }
        // 2) clEnqueueSVMMemcpy host -> SVM (device-side path if any)
        {
            clFinish(q);
            auto h0 = std::chrono::steady_clock::now();
            CHECK(clEnqueueSVMMemcpy(q, CL_FALSE, svm2, srcbuf.data(), bw_bytes, 0, nullptr, nullptr));
            clFinish(q);
            auto h1 = std::chrono::steady_clock::now();
            double ms = std::chrono::duration<double, std::milli>(h1 - h0).count();
            printf("clEnqueueSVMMemcpy host->SVM: %.2f ms -> %.1f GB/s\n", ms, bw_bytes / ms / 1e6);
        }
        // 3) clEnqueueWriteBuffer into regular cl_mem (staging baseline)
        {
            clFinish(q);
            auto h0 = std::chrono::steady_clock::now();
            CHECK(clEnqueueWriteBuffer(q, clbuf, CL_FALSE, 0, bw_bytes, srcbuf.data(), 0, nullptr, nullptr));
            clFinish(q);
            auto h1 = std::chrono::steady_clock::now();
            double ms = std::chrono::duration<double, std::milli>(h1 - h0).count();
            printf("clEnqueueWriteBuffer host->cl_mem: %.2f ms -> %.1f GB/s\n", ms, bw_bytes / ms / 1e6);
        }
        // 4) plain malloc write baseline
        {
            std::vector<uint32_t> dst(bw_words);
            auto t0 = std::chrono::steady_clock::now();
            memcpy(dst.data(), srcbuf.data(), bw_bytes);
            auto t1 = std::chrono::steady_clock::now();
            double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
            printf("memcpy host->host: %.2f ms -> %.1f GB/s\n", ms, bw_bytes / ms / 1e6);
        }
        // 5) clEnqueueNDRangeKernel CPU overhead: tiny kernel x 2000
        {
            cl_mem tiny = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, 256, nullptr, &err); CHECK(err);
            cl_kernel k = clCreateKernel(prog, "buf_bw", &err); CHECK(err);
            uint32_t n1 = 8;
            size_t gws1 = n1;
            CHECK(clSetKernelArg(k, 0, sizeof(cl_mem), &tiny));
            CHECK(clSetKernelArg(k, 1, sizeof(uint32_t), &n1));
            CHECK(clSetKernelArg(k, 2, sizeof(cl_mem), &tiny));
            clFinish(q);
            const int N = 2000;
            auto h0 = std::chrono::steady_clock::now();
            for (int i = 0; i < N; ++i) {
                clEnqueueNDRangeKernel(q, k, 1, nullptr, &gws1, nullptr, 0, nullptr, nullptr);
            }
            clFinish(q);
            auto h1 = std::chrono::steady_clock::now();
            double ms = std::chrono::duration<double, std::milli>(h1 - h0).count();
            printf("tiny kernel enqueue x%d: %.2f ms total -> %.3f ms/enqueue (incl. exec)\n", N, ms, ms / N);
            clReleaseMemObject(tiny);
            clReleaseKernel(k);
        }
    }

    clSVMFree(ctx, svm);
    clSVMFree(ctx, svm2);
    printf("ALL DONE\n");
    return 0;
}

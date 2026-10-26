/* [P-3 A1 归因探针] LD_PRELOAD/libOpenCL 计数垫片：
 * 计数 clFlush/clFinish/clEnqueueNDRangeKernel/阻塞与非阻塞 Read·Write·Map/clWaitForEvents，
 * 每次调用现场记"自上次 flush 以来的 enqueue 数"直方图 → 归因 async 态 KGSLSUBMIT 来源。
 * 仅诊断用，不进任何背书腿。输出行前缀 [CLCOUNT]。 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <CL/cl.h>

static const char *fn = "clEnqueueReadBuffer";
static const char *fnw = "clEnqueueWriteBuffer";
static const char *fnm = "clEnqueueMapBuffer";
static const char *fnd = "clEnqueueNDRangeKernel";

static long c_nd = 0, c_flush = 0, c_finish = 0, c_wait = 0;
static long c_rb_blk = 0, c_rb_nblk = 0, c_wb_blk = 0, c_wb_nblk = 0;
static long c_map_blk = 0, c_map_nblk = 0;
static long pend = 0;            /* enqueues since last flush */
static long sum_flush_at = 0;    /* sum of pend at flush */
static long max_flush_at = 0;
static long n_flush_nonzero = 0;

#define REAL(name, args)                                          \
    static typeof(name) *r_##name = NULL;                         \
    if (!r_##name) r_##name = dlsym(RTLD_NEXT, #name);            \
    return r_##name args

CL_API_ENTRY cl_int CL_API_CALL
clEnqueueNDRangeKernel(cl_command_queue q, cl_kernel k, cl_uint wo,
                       const size_t *go, const size_t *gs, const size_t *ls,
                       cl_uint nw, const cl_event *we, cl_event *ev) {
    c_nd++; pend++;
    REAL(clEnqueueNDRangeKernel, (q, k, wo, go, gs, ls, nw, we, ev));
}

CL_API_ENTRY cl_int CL_API_CALL clFlush(cl_command_queue q) {
    c_flush++;
    if (pend > 0) { n_flush_nonzero++; sum_flush_at += pend; if (pend > max_flush_at) max_flush_at = pend; }
    pend = 0;
    REAL(clFlush, (q));
}

CL_API_ENTRY cl_int CL_API_CALL clFinish(cl_command_queue q) {
    c_finish++;
    if (pend > 0) { n_flush_nonzero++; sum_flush_at += pend; if (pend > max_flush_at) max_flush_at = pend; }
    pend = 0;
    REAL(clFinish, (q));
}

CL_API_ENTRY cl_int CL_API_CALL clWaitForEvents(cl_uint n, const cl_event *ev) {
    c_wait++;
    REAL(clWaitForEvents, (n, ev));
}

CL_API_ENTRY cl_int CL_API_CALL
clEnqueueReadBuffer(cl_command_queue q, cl_mem b, cl_bool blk, size_t off, size_t cb,
                    void *ptr, cl_uint nw, const cl_event *we, cl_event *ev) {
    if (blk == CL_TRUE) c_rb_blk++; else c_rb_nblk++;
    REAL(clEnqueueReadBuffer, (q, b, blk, off, cb, ptr, nw, we, ev));
}

CL_API_ENTRY cl_int CL_API_CALL
clEnqueueWriteBuffer(cl_command_queue q, cl_mem b, cl_bool blk, size_t off, size_t cb,
                     const void *ptr, cl_uint nw, const cl_event *we, cl_event *ev) {
    if (blk == CL_TRUE) c_wb_blk++; else c_wb_nblk++;
    REAL(clEnqueueWriteBuffer, (q, b, blk, off, cb, ptr, nw, we, ev));
}

CL_API_ENTRY void *CL_API_CALL
clEnqueueMapBuffer(cl_command_queue q, cl_mem b, cl_bool blk, cl_map_flags f,
                   size_t off, size_t cb, cl_uint nw, const cl_event *we,
                   cl_event *ev, cl_int *err) {
    if (blk == CL_TRUE) c_map_blk++; else c_map_nblk++;
    REAL(clEnqueueMapBuffer, (q, b, blk, f, off, cb, nw, we, ev, err));
}

__attribute__((destructor)) static void dump(void) {
    fprintf(stderr, "[CLCOUNT] nd=%d flush=%d finish=%d wait=%d\n",
            (int)c_nd, (int)c_flush, (int)c_finish, (int)c_wait);
    fprintf(stderr, "[CLCOUNT] read blk=%d nblk=%d | write blk=%d nblk=%d | map blk=%d nblk=%d\n",
            (int)c_rb_blk, (int)c_rb_nblk, (int)c_wb_blk, (int)c_wb_nblk,
            (int)c_map_blk, (int)c_map_nblk);
    fprintf(stderr, "[CLCOUNT] flush_with_pending: n=%d avg=%.2f max=%d (sum_pending_at_flush=%d)\n",
            (int)n_flush_nonzero,
            n_flush_nonzero ? (double)sum_flush_at / (double)n_flush_nonzero : 0.0,
            (int)max_flush_at, (int)sum_flush_at);
    fflush(stderr);
}

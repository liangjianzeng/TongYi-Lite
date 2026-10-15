#ifndef GGML_OPENCL_H
#define GGML_OPENCL_H

#include "ggml.h"
#include "ggml-backend.h"

#ifdef  __cplusplus
extern "C" {
#endif

//
// backend API
//
GGML_BACKEND_API ggml_backend_t ggml_backend_opencl_init(void);
GGML_BACKEND_API bool ggml_backend_is_opencl(ggml_backend_t backend);

GGML_BACKEND_API ggml_backend_buffer_type_t ggml_backend_opencl_buffer_type(void);
GGML_BACKEND_API ggml_backend_buffer_type_t ggml_backend_opencl_host_buffer_type(void);

// [dspark M2] GPU slot bank (FGSVM) support:
//  - svm_buft(dev): FGSVM buffer type (host-writable + GPU-readable). Returns
//    NULL when the device lacks CL_DEVICE_SVM_FINE_GRAIN_BUFFER or is not the
//    OpenCL device.
//  - buft_is_svm(buft): true for the SVM buffer type (used by llama-moe-slot
//    to decide whether per-fill plane conversion must be enqueued).
//  - cl_moe_q3k_pack_slot(soa, plane_slot, raw): enqueue the raw->plane
//    conversion kernel for one q3_K slot fill (planes lazily created on `soa`).
GGML_BACKEND_API ggml_backend_buffer_type_t ggml_backend_opencl_svm_buft(ggml_backend_dev_t dev);
GGML_BACKEND_API bool ggml_backend_opencl_buft_is_svm(ggml_backend_buffer_type_t buft);
GGML_BACKEND_API void ggml_cl_moe_q3k_pack_slot(struct ggml_tensor * soa, int plane_slot, const void * raw);
// [dspark M2 v2] staged route on the CALLER thread (after the fill wave joins):
// blocking clEnqueueWriteBuffer into the per-buffer cl_mem staging + pack
// kernel reading the cl_mem. WriteBuffer from the main thread is the standard
// set_tensor pattern; from IO threads it crashes the 740 libCB submission
// thread (bank7-10). Falls back to the SVM-pointer pack when no staging.
GGML_BACKEND_API void ggml_cl_moe_q3k_stage_pack(struct ggml_tensor * soa, int plane_slot, const void * src_host);
// [dspark M2 v3] async batched drain: enqueue the CL_FALSE write + pack and
// return the write event via ev_out (may be nullptr for fallback records).
// Caller collects events across the whole wave and waits once via
// ggml_cl_moe_q3k_stage_wait() — host staging must stay alive until then.
// Main-thread submission only (IO-thread device commands crash the 740
// libCB submission thread, bank7-10).
GGML_BACKEND_API void ggml_cl_moe_q3k_stage_pack_async(struct ggml_tensor * soa, int plane_slot, const void * src_host, void ** ev_out);
GGML_BACKEND_API void ggml_cl_moe_q3k_stage_wait(void ** evs, int n);
// eagerly create the (empty) planes for a q3_K slot-bank base tensor — must
// run at load time for EVERY family base so the batched dispatch never sees a
// planeless tensor (first compute can precede the first fill)
GGML_BACKEND_API void ggml_cl_moe_q3k_ensure_planes(struct ggml_tensor * soa);
// async host->SVM copy enqueued on the OpenCL queue (in-order: lands before
// any later pack/GEMV command)
GGML_BACKEND_API void ggml_cl_svm_memcpy_async(void * dst_svm, const void * src_host, size_t size);
// [dspark M2 fix] raw upload route for the GPU slot bank:
//   1 (default) host staging -> clEnqueueWriteBuffer -> pack kernel reads cl_mem
//               (SVMMemcpy host->FGSVM crashes the 740 libCB submission thread)
//   0           legacy preadv-writes-SVM + SVMMemcpy + SVM-pointer pack (A/B only)
GGML_BACKEND_API int ggml_cl_svm_upload_mode(void);

GGML_BACKEND_API ggml_backend_reg_t ggml_backend_opencl_reg(void);

#ifdef  __cplusplus
}
#endif

#endif // GGML_OPENCL_H

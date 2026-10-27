// vkh_instrument.h — [vkh] host-side submit-cost instrumentation for ggml-opencl.
//
// Self-contained diagnostics for the "GPU decode slower than CPU" case. Enabled only
// with GGML_OPENCL_VKH_OPTIME=1; with the env unset the hooks read one bool and
// return, so there is no behavioural or numerical change.
//
// What it answers (measured with clock() = process CPU time, so blocking waits do NOT
// count — everything printed here is host-side work, not GPU wait):
//   * per op class: host time, node count, kernel count, ms/kernel, ms/node — the
//     per-op split is mandatory before blaming "the launch path": an average
//     ms/kernel over mixed ops is meaningless (measured spread on Adreno 650:
//     GLU 0.178 … FLASH_ATTN_EXT 8.419 ms/kernel, i.e. 47x).
//   * GRAPH_TOTAL vs LOOP_TOTAL vs the sum of the op rows: separates the graph-level
//     prologue/epilogue from the per-node pre-forward code (the env-gated debug
//     branches and their `continue` paths), which was the last unattributed
//     ~130-340 ms/token region.
//
// Findings it produced (all device-labelled; a650 = mechanism evidence only, no perf
// verdicts from the availability tier):
//   - FLASH_ATTN_EXT costs ~10.9 ms of host CPU per node on the vendor FA path;
//     GGML_OPENCL_NO_FA=1 removes exactly that row (50.7% of attributed submit CPU)
//     but makes decode 34% SLOWER end-to-end (CPU attention + extra GPU nodes +
//     device round-trips) => "turn FA off" is an instrument, never a fix.
//   - llama-cli campaign legs run FA=ON while the App ships flash_attn=DISABLED:
//     campaign numbers and App-visible numbers are different measurement frames.
//
// Implementation notes / traps already paid for:
//   - The histogram table is heap-allocated and intentionally never freed. As a static
//     std::map it was destroyed by its own .fini_array entry before the dump ran, so
//     the first version silently printed nothing on device.
//   - The dump is therefore also invoked from the [host-timing] print site inside
//     ggml_backend_opencl_graph_compute, a location proven to execute; the destructor
//     is kept as a convenience only.
//   - <algorithm> is not included by ggml-opencl.cpp; the ranking uses a selection
//     sort instead of std::sort.
//
// Mounting (tracked files are edited by the repo owner only):
//   #include "vkh_instrument.h"        after the last top-level #include
//   vkh_op_timer vkh_gt("GRAPH_TOTAL", nullptr);                       // function entry
//   vkh_op_timer vkh_lt("LOOP_TOTAL", &backend_ctx->n_enqueues);       // per-node loop top
//   vkh_op_timer vkh_tf("MUL_MATx2+GLU(fused)", &backend_ctx->n_enqueues);  // fused dispatch
//   vkh_op_timer vkh_tt(ggml_op_name(node->op), &backend_ctx->n_enqueues);  // around forward
//   if (g_vkh_optime_on) { vkh_optime_dump(); }                        // at [host-timing] print

#ifndef GGML_OPENCL_VKH_INSTRUMENT_H
#define GGML_OPENCL_VKH_INSTRUMENT_H

#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <map>
#include <string>
#include <vector>

// C++17 inline variables: one instance shared by every TU that includes this header.
inline bool g_vkh_optime_on = getenv("GGML_OPENCL_VKH_OPTIME") != nullptr;

struct vkh_optime_rec {
    double ms = 0.0;
    long   n  = 0;
    long   kern = 0;
};

// Leaked on purpose — see the .fini_array ordering trap above.
inline std::map<std::string, vkh_optime_rec> * g_vkh_optime_p = nullptr;

inline std::map<std::string, vkh_optime_rec> & vkh_optime_map() {
    if (g_vkh_optime_p == nullptr) {
        g_vkh_optime_p = new std::map<std::string, vkh_optime_rec>();
    }
    return *g_vkh_optime_p;
}

// The op whose forward we are inside, so a hook deep in a shared helper can label its row
// with the owning op class. Set by vkh_op_timer unless the timer is itself a helper row
// (see set_cur); read by VKH_ENQ_TIMER.
inline const char * g_vkh_current_op = nullptr;

// "ENQ/<op>" row names, built once per op and cached: the launch hook runs ~900x/token
// and must not allocate per call.
inline const char * vkh_enq_name(const char * op) {
    static std::map<std::string, std::string> * names = nullptr;
    if (names == nullptr) {
        names = new std::map<std::string, std::string>();
    }
    const std::string key(op ? op : "?");
    std::map<std::string, std::string>::iterator it = names->find(key);
    if (it == names->end()) {
        it = names->insert(std::make_pair(key, "ENQ/" + key)).first;
    }
    return it->second.c_str();
}

// RAII: times one region of the submit loop and accumulates it under `op`.
// `enq` points at backend_ctx->n_enqueues to attribute kernel counts; pass nullptr for
// regions that span the whole graph (GRAPH_TOTAL) or for helper rows, where a delta would
// double count the parent row.
struct vkh_op_timer {
    const char * op;
    const char * prev;
    int *        enq;
    double       t0;
    long         e0;
    bool         on;
    bool         set_cur;

    explicit vkh_op_timer(const char * o, int * e, bool set_cur_ = true)
        : op(o), prev(g_vkh_current_op), enq(e), t0(0.0), e0(0), on(g_vkh_optime_on), set_cur(set_cur_) {
        if (on) {
            if (set_cur) { g_vkh_current_op = o; }
            static bool armed_printed = false;
            if (!armed_printed) {
                armed_printed = true;
                fprintf(stderr, "[vkh-optime] ARMED (first region timed)\n");
                fflush(stderr);
            }
            t0 = (double) clock() / CLOCKS_PER_SEC;
            e0 = enq ? *enq : 0;
        }
    }

    ~vkh_op_timer() {
        if (!on) { return; }
        // Restore the enclosing label so nested rows (FA/bin, ENQ_DRV, a future PRE/<op>)
        // cannot leak their label into the code that runs after them.
        if (set_cur) { g_vkh_current_op = prev; }
        vkh_optime_rec & r = vkh_optime_map()[op];
        r.ms += ((double) clock() / CLOCKS_PER_SEC - t0) * 1e3;
        r.n++;
        if (enq) { r.kern += *enq - e0; }
    }

    vkh_op_timer(const vkh_op_timer &) = delete;
    vkh_op_timer & operator=(const vkh_op_timer &) = delete;
};

// Prints the cumulative table. Safe to call repeatedly (the table is cumulative and the
// caller resets nothing); the last block before exit is the one to read.
inline void vkh_optime_dump() {
    if (!g_vkh_optime_on) { return; }
    fprintf(stderr, "[vkh-optime] DUMP called (on=1 table=%p n=%zu)\n", (void *) g_vkh_optime_p,
            g_vkh_optime_p ? g_vkh_optime_p->size() : (size_t) 0);
    if (g_vkh_optime_p == nullptr || g_vkh_optime_p->empty()) {
        fflush(stderr);
        return;
    }
    std::map<std::string, vkh_optime_rec> & tbl = *g_vkh_optime_p;
    std::vector<const std::pair<const std::string, vkh_optime_rec> *> rest;
    rest.reserve(tbl.size());
    double total = 0.0;
    long   tot_n = 0, tot_k = 0;
    for (const std::pair<const std::string, vkh_optime_rec> & kv : tbl) {
        rest.push_back(&kv);
        total += kv.second.ms;
        tot_n += kv.second.n;
        tot_k += kv.second.kern;
    }
    fprintf(stderr, "[vkh-optime] TOTAL host_ms=%.1f nodes=%ld kernels=%ld ms/kernel=%.3f op_classes=%zu\n",
            total, tot_n, tot_k, tot_k ? total / (double) tot_k : 0.0, rest.size());
    for (size_t rank = 0; rank < rest.size(); rank++) {   // selection sort: <algorithm> unavailable
        size_t bi = rank;
        for (size_t j = rank + 1; j < rest.size(); j++) {
            if (rest[j]->second.ms > rest[bi]->second.ms) { bi = j; }
        }
        if (bi != rank) {
            const std::pair<const std::string, vkh_optime_rec> * t = rest[rank];
            rest[rank] = rest[bi];
            rest[bi]   = t;
        }
        const vkh_optime_rec & r = rest[rank]->second;
        fprintf(stderr, "[vkh-optime] #%02zu op=%-24s host_ms=%9.1f nodes=%8ld kernels=%8ld ms/kernel=%7.3f ms/node=%7.3f\n",
                rank + 1, rest[rank]->first.c_str(), r.ms, r.n, r.kern,
                r.kern ? r.ms / (double) r.kern : 0.0, r.n ? r.ms / (double) r.n : 0.0);
    }
    fflush(stderr);
}

// ---- single choke-point launch hook -----------------------------------------------------
// Put VKH_ENQ_TIMER(); as the first statement of
// ggml_backend_opencl_context::enqueue_ndrange_kernel. It answers the question this whole
// case hangs on: in the App frame (FA off) every op class measures 0.45-0.61 ms per node,
// i.e. a fixed ~0.5 ms per launch — is that the driver's clEnqueueNDRangeKernel doorbell,
// or the host marshalling around it (arg setting, wgs/subgroup queries, tensor bookkeeping)?
// Rows appear as "ENQ/<OP>" and are CHILDREN of the matching "<OP>" row: never sum the two
// together. Coverage caveat: ~76 direct clEnqueueNDRangeKernel calls bypass the wrapper.
#define VKH_ENQ_TIMER() vkh_op_timer vkh_enq_guard_(vkh_enq_name(g_vkh_current_op), nullptr, false)

__attribute__((destructor, used)) static void vkh_optime_dtor(void) { vkh_optime_dump(); }

#endif  // GGML_OPENCL_VKH_INSTRUMENT_H

// vkh_instrument.h — [vkh] host-side submit-cost instrumentation for ggml-opencl.
//
// Self-contained diagnostics for the "GPU decode slower than CPU" case. Enabled only
// with GGML_OPENCL_VKH_OPTIME=1; with the env unset the hooks read one bool and
// return, so there is no behavioural or numerical change.
//
// What it answers — **v4: wall clock (CLOCK_MONOTONIC)**, and that change is itself a
// finding. v1..v3 timed with clock() = *process CPU time*, which (a) does not count
// blocking waits, (b) charges whatever the Adreno userspace driver threads burn to
// whichever row is active on the calling thread, and (c) fed a lock-free shared
// std::map. That produced rows violating additivity — inner ENQ_DRV (2430 ms) exceeding
// its own parent rows (~300 ms), and LOOP_TOTAL (5333) > its enclosing GRAPH_TOTAL
// (4902) — so every absolute "who owns this host time" verdict taken from v1..v3 is
// void; only wall-clock sources ([host-timing] host_ms, tok/s) were trustworthy. v4
// measures wall time, so clFinish / clEnqueueNDRangeKernel waits now show up honestly.
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
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <link.h>   // dl_iterate_phdr: find this .so's load bias so station offsets are addr2line-ready.
                    // Chosen over dladdr() on purpose: dladdr's home (libdl vs libc) varies by Android
                    // API level, and an unresolved symbol here means the whole backend fails to load —
                    // a build-time-cheap mistake that would burn a 740 leg.
#include <map>
#include <mutex>
#include <string>
#include <vector>

// Wall clock, monotonic, nanosecond based — see the v4 note above. clock_gettime on
// Android/Bionic is a vDSO call (no syscall), so it stays affordable at ~900 calls/token.
inline double vkh_now_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec * 1e3 + (double) ts.tv_nsec * 1e-6;
}

// The map and the ENQ-name cache are shared by every thread that reaches the hooks; the
// lock-free version lost updates (rows with few samples, e.g. GRAPH_TOTAL = 1 per graph,
// lost whole intervals to races). Recursive because the timer dtor locks and then takes
// the map.
inline std::recursive_mutex g_vkh_tbl_mtx;

// Self-check bookkeeping (see the dump's SELFCHK block). g_vkh_graph_depth tracks whether we
// are inside a GRAPH_TOTAL window; g_vkh_loop_outside_graph counts per-node iterations seen
// while it was zero. That is what separates the two ways "inner row > outer row" can happen:
// a node loop genuinely running outside graph_compute (a real code path — warn and keep
// going), versus the accounting itself being broken (numbers are void — abort on the spot,
// per R-092: better a dead run than a post-mortem over bad numbers).
// Dark-zone station labelling (R-095, parent-approved: design + compile + env gate).
// The dark zone is the window between LOOP_TOTAL's construction and the node's own op timer,
// where launches fall into ENQ/PRE_FORWARD instead of an op row (R-091: 490 launches, 1.124 ms
// each, 40 % of the submit loop with drains off — 7x a normal launch). Naming them needs no
// product-code change: VKH_ENQ_TIMER() is already mounted at the single choke point
// (ggml-opencl.cpp L1366, first statement of enqueue_ndrange_kernel), and a macro there is
// expanded inside that function's body, so __builtin_return_address(0) is the CALLER's site —
// a PC inside graph_compute. It is reported as a file-relative offset so the parent can feed it
// straight to addr2line. If the compiler inlined the choke point, every label collapses to one
// offset and the STATIONS banner says STATION_COLLAPSED instead of pretending they mean
// something. A second, inlining-proof key is the launch's order within the node iteration
// (ENQ#<n>), taken from the same n_enqueues counter LOOP_TOTAL already reads.
// OFF BY DEFAULT: every campaign leg (P0/P1/丙-IDLE0/X4) runs without a single extra row until
// VKH_DZ_TAG=1 is passed on a forensics leg only.
inline bool g_vkh_dz_tag_on = [] { const char * e = getenv("VKH_DZ_TAG"); return e != nullptr && e[0] != '0' && e[0] != '\0'; }();
inline void * g_vkh_lib_base       = nullptr;
inline bool   g_vkh_lib_base_tried = false;
inline int *  g_vkh_loop_enq_ctr   = nullptr;
inline int    g_vkh_loop_enq_base  = 0;

inline int  g_vkh_graph_depth       = 0;
inline long g_vkh_loop_outside_graph = 0;

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
    std::lock_guard<std::recursive_mutex> lk(g_vkh_tbl_mtx);
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
    std::lock_guard<std::recursive_mutex> lk(g_vkh_tbl_mtx);
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

// Load bias of the .so that contains vkh_enq_name, found by walking the program headers of every
// loaded object until one of its PT_LOAD segments covers that function. libc-only, no libdl.
struct vkh_base_ctx { uintptr_t target; uintptr_t base; };

inline int vkh_phdr_cb(struct dl_phdr_info * info, size_t size, void * data) {
    (void) size;
    vkh_base_ctx * c = (vkh_base_ctx *) data;
    for (ElfW(Half) i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) * ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD) { continue; }
        const uintptr_t lo = (uintptr_t) info->dlpi_addr + (uintptr_t) ph->p_vaddr;
        if (c->target >= lo && c->target < lo + (uintptr_t) ph->p_memsz) {
            c->base = (uintptr_t) info->dlpi_addr;
            return 1;                     // stop the walk
        }
    }
    return 0;
}

// RAII: times one region of the submit loop and accumulates it under `op`.
// `enq` points at backend_ctx->n_enqueues to attribute kernel counts; pass nullptr for
// regions that span the whole graph (GRAPH_TOTAL) or for helper rows, where a delta would
// double count the parent row.
struct vkh_op_timer {
    const char * op;
    const char * prev;
    int *        enq;
    void *       ra;
    double       t0;
    long         e0;
    bool         on;
    bool         set_cur;

    explicit vkh_op_timer(const char * o, int * e, bool set_cur_ = true, void * ra_ = nullptr)
        : op(o), prev(g_vkh_current_op), enq(e), ra(g_vkh_dz_tag_on ? ra_ : nullptr), t0(0.0), e0(0),
          on(g_vkh_optime_on), set_cur(set_cur_) {
        if (on) {
            if (set_cur) { g_vkh_current_op = o; }
            static bool armed_printed = false;
            if (!armed_printed) {
                armed_printed = true;
                fprintf(stderr, "[vkh-optime] ARMED (first region timed)\n");
                fflush(stderr);
            }
            t0 = vkh_now_ms();
            e0 = enq ? *enq : 0;
            if (op != nullptr && strcmp(op, "GRAPH_TOTAL") == 0) {
                g_vkh_graph_depth++;
            } else if (op != nullptr && strcmp(op, "LOOP_TOTAL") == 0) {
                if (g_vkh_graph_depth <= 0) { g_vkh_loop_outside_graph++; }
                if (g_vkh_dz_tag_on && enq != nullptr) {
                    g_vkh_loop_enq_ctr  = enq;    // launch order within this iteration, see ENQ#<n>
                    g_vkh_loop_enq_base = *enq;
                }
            }
        }
    }

    ~vkh_op_timer() {
        if (!on) { return; }
        const double t1 = vkh_now_ms();   // read the clock before taking the lock
        if (op != nullptr && strcmp(op, "GRAPH_TOTAL") == 0 && g_vkh_graph_depth > 0) {
            g_vkh_graph_depth--;
        }
        // Restore the enclosing label so nested rows (FA/bin, ENQ_DRV, a future PRE/<op>)
        // cannot leak their label into the code that runs after them.
        if (set_cur) { g_vkh_current_op = prev; }
        std::lock_guard<std::recursive_mutex> lk(g_vkh_tbl_mtx);
        vkh_optime_rec & r = vkh_optime_map()[op];
        r.ms += t1 - t0;
        r.n++;
        if (enq) { r.kern += *enq - e0; }
        if (ra != nullptr) {                     // VKH_DZ_TAG=1 only (ra is nulled when off)
            if (!g_vkh_lib_base_tried) {
                g_vkh_lib_base_tried = true;
                vkh_base_ctx bc;
                bc.target = (uintptr_t) (void *) &vkh_enq_name;   // a function in THIS .so
                bc.base   = 0;
                dl_iterate_phdr(vkh_phdr_cb, &bc);
                g_vkh_lib_base = (void *) bc.base;
            }
            const unsigned long long off =
                (unsigned long long) ((uintptr_t) ra - (uintptr_t) g_vkh_lib_base);
            char sname[48];
            snprintf(sname, sizeof sname, "ENQ@+0x%llx", off);
            vkh_optime_rec & s = vkh_optime_map()[sname];
            s.ms += t1 - t0;
            s.n++;
            // Cross row for the dark zone only (R-091: 490 launches, 1.124 ms each, 40 % of the
            // submit loop). ENQ@ rows carry every launch and no op label, so on their own they
            // cannot say WHICH stations make up those 490; DZ@ rows are the same stations
            // restricted to launches issued while the label was still PRE_FORWARD. Bounded, and
            // it is the row the parent addr2lines.
            if (op != nullptr && strncmp(op, "ENQ/PRE_FORWARD", 16) == 0) {
                snprintf(sname, sizeof sname, "DZ@+0x%llx", off);
                vkh_optime_rec & d = vkh_optime_map()[sname];
                d.ms += t1 - t0;
                d.n++;
            }
            if (g_vkh_loop_enq_ctr != nullptr) {
                snprintf(sname, sizeof sname, "ENQ#%d", *g_vkh_loop_enq_ctr - g_vkh_loop_enq_base);
                vkh_optime_rec & q = vkh_optime_map()[sname];
                q.ms += t1 - t0;
                q.n++;
            }
        }
    }

    vkh_op_timer(const vkh_op_timer &) = delete;
    vkh_op_timer & operator=(const vkh_op_timer &) = delete;
};

// Prints the cumulative table. Safe to call repeatedly (the table is cumulative and the
// caller resets nothing); the last block before exit is the one to read.
inline void vkh_optime_dump() {
    if (!g_vkh_optime_on) { return; }
    const double vkh_dump_t0 = vkh_now_ms();   // the printer is itself a cost the enclosing rows pay
    std::lock_guard<std::recursive_mutex> lk(g_vkh_tbl_mtx);
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
    fprintf(stderr, "[vkh-optime] TOTAL host_ms=%.1f nodes=%ld kernels=%ld ms/kernel=%.3f op_classes=%zu clock=monotonic_v4\n",
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
    // R-092 self-check: a nested row may never exceed its enclosing row. v1..v3 shipped
    // numbers that violated this (inner ENQ_DRV 8x its parents, LOOP_TOTAL > GRAPH_TOTAL) and
    // every attribution drawn from them had to be voided. Print the evidence; if the probe
    // explains it (a node loop really ran outside graph_compute) warn and continue, otherwise
    // the accounting itself is broken and the numbers are void — abort on the spot rather
    // than let a post-mortem be built on them. GGML_OPENCL_VKH_SOFT=1 downgrades to warn-only
    // so an instrument artifact can never brick a campaign leg by itself.
    {
        std::map<std::string, vkh_optime_rec> & t = *g_vkh_optime_p;
        static const char * pairs[][2] = {
            { "LOOP_TOTAL",  "GRAPH_TOTAL" }, { "MUL_MAT",     "GRAPH_TOTAL" },
            { "ENQ_DRV",     "LOOP_TOTAL"  }, { "ENQ_IDLE",    "LOOP_TOTAL"  },
            { "ENQ/MUL_MAT", "MUL_MAT"     }, { "PRE_FORWARD", "LOOP_TOTAL"  },
        };
        static const bool soft = getenv("GGML_OPENCL_VKH_SOFT") != nullptr;
        // Dumps are taken from inside graph_compute (the [host-timing] print site), so while a
        // graph is in flight its GRAPH_TOTAL window has not been recorded yet and LOOP_TOTAL
        // legitimately shows ~2x GRAPH. Judging additivity there is a false positive — on
        // device this rule aborted every GPU leg. Only closed windows (graph_depth == 0, i.e.
        // the atexit dump) may convict; mid-graph dumps report the numbers as info.
        const bool in_graph = g_vkh_graph_depth > 0;
        // The dump is called from inside graph_compute (and, for the last call, from the
        // destructor), so its own fprintf/fflush lands in whatever rows are open — which is
        // the leading suspect for LOOP_TOTAL drifting above GRAPH_TOTAL by ~5 ms/graph. Record
        // it as its own row and print the comparison, so the gap is attributable instead of
        // mysterious.
        vkh_optime_rec & dc = vkh_optime_map()["DUMP_COST"];
        dc.ms += vkh_now_ms() - vkh_dump_t0;
        dc.n++;
        std::map<std::string, vkh_optime_rec>::const_iterator it_loop = t.find("LOOP_TOTAL");
        std::map<std::string, vkh_optime_rec>::const_iterator it_gr  = t.find("GRAPH_TOTAL");
        std::map<std::string, vkh_optime_rec>::const_iterator it_dc  = t.find("DUMP_COST");
        const double gap = (it_loop != t.end() && it_gr != t.end()) ? it_loop->second.ms - it_gr->second.ms : 0.0;
        if (g_vkh_dz_tag_on) {
            long st_rows = 0, st_launches = 0, dz_rows = 0, dz_launches = 0;
            for (std::map<std::string, vkh_optime_rec>::const_iterator it = t.begin(); it != t.end(); ++it) {
                const char * k = it->first.c_str();
                if (strncmp(k, "ENQ@+0x", 7) == 0) { st_rows++; st_launches += it->second.n; }
                else if (strncmp(k, "DZ@+0x", 6) == 0) { dz_rows++; dz_launches += it->second.n; }
            }
            // One row for hundreds of launches = the choke point was inlined and every label
            // collapsed onto graph_compute's own return site. Say it out loud rather than let
            // someone addr2line a number that means nothing.
            // dz_launches should track the ENQ/PRE_FORWARD row; if it does not, the cross
            // attribution is lying and the dark-zone verdict built on it is void.
            fprintf(stderr, "[vkh-optime] STATIONS rows=%ld launches=%ld dz_rows=%ld dz_launches=%ld lib_base=%p%s\n",
                    st_rows, st_launches, dz_rows, dz_launches, g_vkh_lib_base,
                    (st_rows == 1 && st_launches > 100) ? " STATION_COLLAPSED(choke point inlined — offsets are meaningless)" : "");
        }
        fprintf(stderr, "[vkh-optime] SELFCHK graph_depth=%d loop_outside_graph=%ld mode=%s loop_minus_graph=%.1f dump_cost=%.1f/%ld\n",
                g_vkh_graph_depth, g_vkh_loop_outside_graph,
                in_graph ? "skip(in-graph)" : (soft ? "soft" : "abort"), gap,
                it_dc != t.end() ? it_dc->second.ms : 0.0, it_dc != t.end() ? it_dc->second.n : 0);
        for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
            std::map<std::string, vkh_optime_rec>::const_iterator c = t.find(pairs[i][0]);
            std::map<std::string, vkh_optime_rec>::const_iterator p = t.find(pairs[i][1]);
            if (c == t.end() || p == t.end() || c->second.ms <= p->second.ms * 1.02) { continue; }
            // Explained = the excess has a named owner: node loops outside graph_compute, or
            // the printer's own cost landing in the open LOOP_TOTAL row.
            const bool explained = in_graph || (strcmp(pairs[i][0], "LOOP_TOTAL") == 0 &&
                (g_vkh_loop_outside_graph > 0 ||
                 gap <= (it_dc != t.end() ? it_dc->second.ms : 0.0) * 1.5 + 5.0));
            fprintf(stderr, "[vkh-optime] %s child=%s(%.1f) > parent=%s(%.1f)%s\n",
                    in_graph ? "MIDGRAPH_INFO" : "ADDITIVITY_VIOLATION",
                    pairs[i][0], c->second.ms, pairs[i][1], p->second.ms,
                    explained ? " (explained: excess has a named owner — in-graph dump, loop outside graph, or the printer's own cost)" : "");
            if (!explained && !soft) {
                fprintf(stderr, "[vkh-optime] ABORT: accounting hole, table is void (set GGML_OPENCL_VKH_SOFT=1 to continue anyway)\n");
                fflush(stderr);
                abort();
            }
        }
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
// The 4th argument is evaluated in the expansion site's frame — i.e. inside
// enqueue_ndrange_kernel — so it is that function's CALLER address: the station that issued the
// launch. With VKH_DZ_TAG off the ctor drops it (ra = nullptr) and no station row is ever
// created, so campaign legs see byte-identical tables.
#define VKH_ENQ_TIMER() vkh_op_timer vkh_enq_guard_(vkh_enq_name(g_vkh_current_op), nullptr, false, __builtin_return_address(0))

__attribute__((destructor, used)) static void vkh_optime_dtor(void) { vkh_optime_dump(); }

#endif  // GGML_OPENCL_VKH_INSTRUMENT_H

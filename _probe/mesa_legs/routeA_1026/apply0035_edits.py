#!/usr/bin/env python3
# [TongYi-Lite 0035 E4 round-5 lite] after e4h killed fastpath-early-completion
# and ring destruction proved regime-independent:
#  (1) E4BOREL/REUSE decode-phase gate (e4_last_ts >= 300) — the 835 baseline
#      was deterministic model-load noise (ts=1..13 samples).
#  (2) tid= on E4FENCE/E4FAST (C) and E4FLUSH/E4WAIT (Rust) — API x worker x
#      signal thread interleaving becomes joinable on rt+tid.
#  (3) E4RGROW on fd_ringbuffer_sp_grow — rings churn a fresh gem per grow;
#      the grow-while-outstanding vector was never probed.
#  (4) E4QFLUSH in Queue::flush — ggml-side flush granularity (pend per call).
import sys, os

TREE = os.environ.get("E4TREE", "/root/mesa-26.2.4")

def edit(path, pairs):
    with open(path) as f: s = f.read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            print(f"ANCHOR FAIL count={n} in {path} :: {old[:70]!r}")
            sys.exit(1)
        s = s.replace(old, new, 1)
    with open(path, "w") as f: f.write(s)
    print("OK", path)

# (1) decode gate
FBO = TREE + "/src/freedreno/drm/freedreno_bo.c"
edit(FBO, [
    ("""void kgsl_e4_bo_released(struct fd_bo *bo);
void
kgsl_e4_bo_released(struct fd_bo *bo)
{
   if (!e4rel_on() || !bo)
      return;""",
     """/* [0035] decode-phase gate: load-era (ts<=13) releases produced the
 * deterministic 835 false baseline; observe only steady-state decode. */
#define E4_DECODE_TS 300

void kgsl_e4_bo_released(struct fd_bo *bo);
void
kgsl_e4_bo_released(struct fd_bo *bo)
{
   if (!e4rel_on() || !bo || e4_last_ts < E4_DECODE_TS)
      return;"""),
])

# (2a) tid on E4FENCE (kgsl ringbuffer submit side)
KRB = TREE + "/src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c"
edit(KRB, [
    ("""fprintf(stderr, "E4FENCE flush=%u ts=%u numsyncs=%u usefd=%d rt=%llu\\n",""",
     """fprintf(stderr, "E4FENCE flush=%u ts=%u numsyncs=%u usefd=%d rt=%llu tid=%d\\n","""),
    ("""                (int)fd_submit->out_fence->use_fence_fd, e4_now_ns());""",
     """                (int)fd_submit->out_fence->use_fence_fd, e4_now_ns(), (int)gettid());"""),
    ("""#include "kgsl_priv.h\"""",
     """#include <unistd.h> /* [0035] gettid */

#include "kgsl_priv.h\""""),
])

# (2b) tid on E4FAST ; (3) E4RGROW lives in ringbuffer file
FPR = TREE + "/src/freedreno/drm/freedreno_pipe.c"
edit(FPR, [
    ("""fprintf(stderr, "E4FAST fence=%p ufence=%u ctrl=%llu hit=%d rk=%d timeout=%llu\\n",""",
     """fprintf(stderr, "E4FAST fence=%p ufence=%u ctrl=%llu hit=%d rk=%d timeout=%llu tid=%d\\n","""),
    ("""              (unsigned long long)timeout);""",
     """              (unsigned long long)timeout, (int)gettid());"""),
    ("""#include "freedreno_priv.h\"""",
     """#include <unistd.h> /* [0035] gettid */

#include "freedreno_priv.h\""""),
])

FRB = TREE + "/src/freedreno/drm/freedreno_ringbuffer_sp.c"
edit(FRB, [
    ("""#include <assert.h>
#include <inttypes.h>
#include <pthread.h>""",
     """#include <assert.h>
#include <inttypes.h>
#include <pthread.h>
#include <unistd.h> /* [0035] gettid for E4 */
#include <stdio.h>"""),
    ("""static void
fd_ringbuffer_sp_grow(struct fd_ringbuffer *ring, uint32_t size)
{
   struct fd_ringbuffer_sp *fd_ring = to_fd_ringbuffer_sp(ring);
   struct fd_pipe *pipe = fd_ring->u.submit->pipe;

   assert(ring->flags & FD_RINGBUFFER_GROWABLE);

   finalize_current_cmd(ring);

   fd_bo_del(fd_ring->ring_bo);""",
     """static void
fd_ringbuffer_sp_grow(struct fd_ringbuffer *ring, uint32_t size)
{
   struct fd_ringbuffer_sp *fd_ring = to_fd_ringbuffer_sp(ring);
   struct fd_pipe *pipe = fd_ring->u.submit->pipe;

   assert(ring->flags & FD_RINGBUFFER_GROWABLE);

   finalize_current_cmd(ring);

   /* [TongYi-Lite 0035 E4] grow events: a brand-new ring gem replaces the
    * old one (no content copy); outstanding submits keep their own refs —
    * observe handles/sizes to correlate with E4BO/E4VERIFY nolive stats. */
   {
      static int e4g_on = -1;
      if (e4g_on < 0)
         e4g_on = (getenv("TYL_E4") && getenv("TYL_E4")[0] == '1') ? 1 : 0;
      if (e4g_on)
         fprintf(stderr, "E4RGROW ring=%p old_bo=%u new_size=%u curdw=%ld tid=%d\\n",
                 (void *)ring, fd_ring->ring_bo ? fd_ring->ring_bo->handle : 0,
                 size, (long)(ring->cur - ring->start), (int)gettid());
   }

   fd_bo_del(fd_ring->ring_bo);"""),
])

# (2c)+(4) Rust: tid on E4FLUSH/E4WAIT + E4QFLUSH
QRS = TREE + "/src/gallium/frontends/rusticl/core/queue.rs"
edit(QRS, [
    ("""eprintln!("E4FLUSH seq={} nev={} rt={}", seq, evs.len(), ns);""",
     """eprintln!("E4FLUSH seq={} nev={} rt={} tid={:?}", seq, evs.len(), ns,
                std::thread::current().id());"""),
    ("""eprintln!("E4WAIT wseq={} nev={} ok={} rt={}", wseq, events.len(), e4_ok, ns);""",
     """eprintln!("E4WAIT wseq={} nev={} ok={} rt={} tid={:?}", wseq, events.len(), e4_ok, ns,
                std::thread::current().id());"""),
    ("""    pub fn flush(&self, wait: bool) -> CLResult<()> {
        let mut state = self.state.lock().unwrap();
        let events = mem::take(&mut state.pending);""",
     """    pub fn flush(&self, wait: bool) -> CLResult<()> {
        let mut state = self.state.lock().unwrap();
        let events = mem::take(&mut state.pending);
        if e4_on() {
            eprintln!("E4QFLUSH pend={} wait={} tid={:?}", events.len(), wait,
                std::thread::current().id());
        }"""),
])

print("ALL 0035 EDITS APPLIED")

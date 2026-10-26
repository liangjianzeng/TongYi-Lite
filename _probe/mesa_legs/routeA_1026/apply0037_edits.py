#!/usr/bin/env python3
# [TongYi-Lite 0037 E4 round-7] two probes aimed at the surviving race:
#  L. E4LAG  : per-submit lead of submitted-batches over KMD-retired batches
#              (async vs fl1/fl2 discriminator — the "CPU lead" quantity).
#  C. E4CACHEBAD: at every BO_CACHE handout, count fences still unfired —
#              a *direct* in-flight handout audit that does not rely on the
#              0034 one-shot ts attribution (which was too weak: it tagged
#              only the last submit before release).
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

# --- retired-batch counter on the kgsl pipe side ---
KPC = TREE + "/src/freedreno/drm/kgsl/kgsl_pipe.c"
edit(KPC, [
    ("""static int
kgsl_pipe_wait(struct fd_pipe *pipe, const struct fd_fence *fence, uint64_t timeout)
{
    struct kgsl_pipe *kgsl_pipe = to_kgsl_pipe(pipe);
    int ret = wait_timestamp_safe(pipe->dev->fd, kgsl_pipe->queue_id, fence->kfence, timeout);""",
     """static uint64_t e4_retired_count;

uint64_t kgsl_e4_retired_count_get(void);
uint64_t
kgsl_e4_retired_count_get(void)
{
   return e4_retired_count;
}

static int
kgsl_pipe_wait(struct fd_pipe *pipe, const struct fd_fence *fence, uint64_t timeout)
{
    struct kgsl_pipe *kgsl_pipe = to_kgsl_pipe(pipe);
    int ret = wait_timestamp_safe(pipe->dev->fd, kgsl_pipe->queue_id, fence->kfence, timeout);
    if (ret == 0)
        __sync_fetch_and_add(&e4_retired_count, 1);"""),
])

# --- E4LAG next to E4FENCE ---
KRB = TREE + "/src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c"
edit(KRB, [
    ("""        fprintf(stderr, "E4FENCE flush=%u ts=%u numsyncs=%u usefd=%d rt=%llu tid=%d\\n",
                e4_flushes, req.timestamp, req.numsyncs,
                (int)fd_submit->out_fence->use_fence_fd, e4_now_ns(), (int)gettid());""",
     """        fprintf(stderr, "E4FENCE flush=%u ts=%u numsyncs=%u usefd=%d rt=%llu tid=%d\\n",
                e4_flushes, req.timestamp, req.numsyncs,
                (int)fd_submit->out_fence->use_fence_fd, e4_now_ns(), (int)gettid());
        {
            /* [TongYi-Lite 0037 E4] lead/lag: batches submitted minus batches
             * KMD-retired via kgsl_pipe_wait completions. */
            extern uint64_t kgsl_e4_retired_count_get(void);
            uint64_t ret_c = kgsl_e4_retired_count_get();
            fprintf(stderr, "E4LAG sub=%u ret=%llu lag=%lld ts=%u\\n",
                    e4_flushes, (unsigned long long)ret_c,
                    (long long)(e4_flushes - ret_c), req.timestamp);
        }"""),
])

# --- cache-handout unfired-fence audit ---
FBO = TREE + "/src/freedreno/drm/freedreno_bo.c"
edit(FBO, [
    ("""      /* [0034] BO_CACHE acquire side of the in-flight reuse probe: */
      if (cache == &dev->bo_cache && kgsl_e4_bo_reacquired)
         kgsl_e4_bo_reacquired(bo);
      return bo;""",
     """      /* [0034] BO_CACHE acquire side of the in-flight reuse probe: */
      if (cache == &dev->bo_cache && kgsl_e4_bo_reacquired)
         kgsl_e4_bo_reacquired(bo);
      /* [TongYi-Lite 0037 E4] direct audit: any fence on this bo whose
       * GPU-written stamp is still ahead of control->fence = the batch that
       * last touched it has NOT completed, yet userspace hands it out. */
      if (cache == &dev->bo_cache) {
         static int e4a_on = -1;
         if (e4a_on < 0)
            e4a_on = (getenv("TYL_E4") && getenv("TYL_E4")[0] == '1') ? 1 : 0;
         if (e4a_on) {
            unsigned unfired = 0;
            for (unsigned i = 0; i < bo->nr_fences; i++) {
               struct fd_fence *f = bo->fences[i];
               if (f && f->pipe &&
                   fd_fence_after(f->ufence, f->pipe->control->fence))
                  unfired++;
            }
            if (unfired)
               fprintf(stderr, "E4CACHEBAD bo=%u unfired=%u/%u\\n",
                       bo->handle, unfired, bo->nr_fences);
         }
      }
      return bo;"""),
])

print("ALL 0037 EDITS APPLIED")

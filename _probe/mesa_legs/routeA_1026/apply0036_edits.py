#!/usr/bin/env python3
# [TongYi-Lite 0036 E4 round-6] SA-4-guided probes for the surviving TOP1
# (batch CPU-ahead writes into not-yet-submitted / unfenced storage):
#  A. E4DEFER: defer-vs-ioctl branch + should_defer thresholds per submit.
#  B. E4PREP : fd_bo_cpu_prep IDLE early-return = unwaited passthrough
#     (SA-4 §3.1 race fuel), decode-gated.
#  F. E4CB0  : set_constant_buffer_stream upload (buf,off) identity — the
#     stream-uploader rotation depth is THE mechanism candidate for the
#     sharp fl<=2 / fl>=3 threshold.
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

FRB = TREE + "/src/freedreno/drm/freedreno_ringbuffer_sp.c"
edit(FRB, [
    # A-defer side: reuse the E4RGROW gate static from 0035 by hoisting a
    # file-scope helper; simplest is a local static here too.
    ("""      if (e4g_on)
         fprintf(stderr, "E4RGROW ring=%p old_bo=%u new_size=%u curdw=%ld tid=%d\\n",
                 (void *)ring, fd_ring->ring_bo ? fd_ring->ring_bo->handle : 0,
                 size, (long)(ring->cur - ring->start), (int)gettid());
   }""",
     """      if (e4g_on)
         fprintf(stderr, "E4RGROW ring=%p old_bo=%u new_size=%u curdw=%ld tid=%d\\n",
                 (void *)ring, fd_ring->ring_bo ? fd_ring->ring_bo->handle : 0,
                 size, (long)(ring->cur - ring->start), (int)gettid());
   }"""),
    ("""   if (!use_fence_fd && !has_shared && should_defer(submit)) {
      DEBUG_MSG("defer: %u", submit->fence);
      dev->deferred_cmds += fd_ringbuffer_cmd_count(submit->primary);
      assert(dev->deferred_cmds == fd_dev_count_deferred_cmds(dev));
      simple_mtx_unlock(&dev->submit_lock);""",
     """   if (!use_fence_fd && !has_shared && should_defer(submit)) {
      DEBUG_MSG("defer: %u", submit->fence);
      dev->deferred_cmds += fd_ringbuffer_cmd_count(submit->primary);
      assert(dev->deferred_cmds == fd_dev_count_deferred_cmds(dev));
      /* [TongYi-Lite 0036 E4] defer/merge branch: BOs referenced by this
       * batch are still nr_fences==0 until prep; observe threshold hits
       * (nr_bos>30 / deferred_cmds>128) vs the fl>=3 garble cliff. */
      {
         static int e4d_on = -1;
         if (e4d_on < 0)
            e4d_on = (getenv("TYL_E4") && getenv("TYL_E4")[0] == '1') ? 1 : 0;
         if (e4d_on)
            fprintf(stderr, "E4DEFER take=%u nr_bos=%u dcmds=%u defer=1 tid=%d\\n",
                    submit->fence, to_fd_submit_sp(submit)->nr_bos, dev->deferred_cmds,
                    (int)gettid());
      }
      simple_mtx_unlock(&dev->submit_lock);"""),
    ("""      return out_fence;
   }

   flush_deferred_submits(dev);""",
     """      return out_fence;
   }

   /* [TongYi-Lite 0036 E4] real-ioctl branch (throttled to avoid double
    * logging: only when there was a pending deferred backlog). */
   {
      static int e4d_on = -1;
      if (e4d_on < 0)
         e4d_on = (getenv("TYL_E4") && getenv("TYL_E4")[0] == '1') ? 1 : 0;
      if (e4d_on && dev->deferred_cmds > 0)
         fprintf(stderr, "E4DEFER take=%u nr_bos=%u dcmds=%u defer=0 tid=%d\\n",
                 submit->fence, to_fd_submit_sp(submit)->nr_bos,
                 dev->deferred_cmds, (int)gettid());
   }
   flush_deferred_submits(dev);"""),
])

FBO = TREE + "/src/freedreno/drm/freedreno_bo.c"
edit(FBO, [
    ("""int
fd_bo_cpu_prep(struct fd_bo *bo, struct fd_pipe *pipe, uint32_t op)
{
   enum fd_bo_state state = fd_bo_state(bo);

   if (state == FD_BO_STATE_IDLE)
      return 0;""",
     """uint32_t kgsl_e4_last_ts_get(void);

int
fd_bo_cpu_prep(struct fd_bo *bo, struct fd_pipe *pipe, uint32_t op)
{
   enum fd_bo_state state = fd_bo_state(bo);

   /* [TongYi-Lite 0036 E4] unwaited-passthrough probe (SA-4 §3.1): a bo with
    * nr_fences==0 (still deferred / never submitted) returns from cpu_prep
    * with zero acquire — decode-phase gated like E4BOREL (300 == E4_DECODE_TS,
    * literal here because the define lives further down). */
   {
      static int e4p_on = -1;
      if (e4p_on < 0)
         e4p_on = (getenv("TYL_E4") && getenv("TYL_E4")[0] == '1') ? 1 : 0;
      if (e4p_on && state == FD_BO_STATE_IDLE && op &&
          kgsl_e4_last_ts_get() >= 300)
         fprintf(stderr, "E4PREP bo=%u op=0x%x ts=%u\\n", bo->handle, op,
                 kgsl_e4_last_ts_get());
   }

   if (state == FD_BO_STATE_IDLE)
      return 0;"""),
    # accessor next to the 0034 tail table (anchor = 0034's decl line)
    ("""static uint32_t e4_last_ts, e4_last_qid;""",
     """static uint32_t e4_last_ts, e4_last_qid;

uint32_t kgsl_e4_last_ts_get(void);
uint32_t
kgsl_e4_last_ts_get(void)
{
   return e4_last_ts;
}"""),
])

CTX = TREE + "/src/gallium/frontends/rusticl/mesa/pipe/context.rs"
edit(CTX, [
    ("""            if cb.buffer.is_null() {
                return false;
            }""",
     """            if cb.buffer.is_null() {
                return false;
            }

            /* [TongYi-Lite 0036 E4] cb0 upload identity: repeated (buf,off)
             * across in-flight launches == stream-uploader self-overwrite;
             * distinct-buf rotation depth = the fl<=2/fl>=3 mechanism.
             * Local gate: mesa/ is a separate crate root (mesa/lib.rs), so
             * core::queue::e4_on is not reachable from here. */
            {
                static E4CB0: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
                let on = E4CB0.get_or_init(|| {
                    std::env::var("TYL_E4").map(|v| v == "1").unwrap_or(false)
                });
                if *on {
                    eprintln!("E4CB0 off={} sz={} buf={:p} tid={:?}",
                        cb.buffer_offset, data.len(), cb.buffer,
                        std::thread::current().id());
                }
            }"""),
])

print("ALL 0036 EDITS APPLIED")

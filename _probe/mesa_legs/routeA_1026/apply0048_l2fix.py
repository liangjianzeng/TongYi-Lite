#!/usr/bin/env python3
# [TongYi-Lite 0048 E4 r16] L2FIX: double fence emission.
# CACHE_FLUSH_TS is fire-and-forget: CP queues cache clean and continues to
# the timestamp write without waiting for flush ack => KMD can signal retire
# while dirty L2 lines still land later, clobbering host rewrites of retired
# regions (H2'). Emit the fence event TWICE so the retire-visible timestamp
# write is ordered after the first flush completes. Gate: TYL_E4_L2FIX=1.
import sys

F = "/root/mesa-26.2.4/src/freedreno/drm/freedreno_pipe.c"
s = open(F).read()

old = """uint32_t
fd_pipe_emit_fence(struct fd_pipe *pipe, struct fd_ringbuffer *ring)
{
   uint32_t fence = ++pipe->last_fence;
   unsigned gen = pipe->gen;
"""
new = """static void
fd_pipe_emit_fence_dup(struct fd_pipe *pipe, struct fd_ringbuffer *ring,
                       uint32_t fence)
{
   /* [TongYi-Lite 0048 E4] second, value-identical CACHE_FLUSH_TS: since CP
    * processes events in-order, the second event's memory write (and thus
    * the batch's retire visibility at the KMD) is ordered after the first
    * flush has actually drained. */
   static int l2fix = -1;
   if (l2fix < 0)
      l2fix = (getenv("TYL_E4_L2FIX") &&
               getenv("TYL_E4_L2FIX")[0] == '1') ? 1 : 0;
   if (!l2fix)
      return;
   unsigned gen = pipe->gen;
   if (gen >= A7XX) {
      OUT_PKT7(ring, CP_EVENT_WRITE7, 4);
      OUT_RING(ring, CP_EVENT_WRITE_0_EVENT(CACHE_FLUSH_TS) |
               CP_EVENT_WRITE7_0_WRITE_SRC(EV_WRITE_USER_32B) |
               CP_EVENT_WRITE7_0_WRITE_DST(EV_DST_RAM) |
               CP_EVENT_WRITE7_0_WRITE_ENABLED);
      OUT_RELOC(ring, control_ptr(pipe, fence));   /* ADDR_LO/HI */
      OUT_RING(ring, fence);
   } else if (gen >= A5XX) {
      OUT_PKT7(ring, CP_EVENT_WRITE, 4);
      OUT_RING(ring, CP_EVENT_WRITE_0_EVENT(CACHE_FLUSH_TS));
      OUT_RELOC(ring, control_ptr(pipe, fence));   /* ADDR_LO/HI */
      OUT_RING(ring, fence);
   }
   if (getenv("TYL_E4"))
      fprintf(stderr, "E4L2FIX dup fence=%u gen=%u\\n", fence, gen);
}

uint32_t
fd_pipe_emit_fence(struct fd_pipe *pipe, struct fd_ringbuffer *ring)
{
   uint32_t fence = ++pipe->last_fence;
   unsigned gen = pipe->gen;
"""
if s.count(old) != 1:
    print("ANCHOR FAIL head", s.count(old)); sys.exit(1)
s = s.replace(old, new, 1)

# call dup at the tail of fd_pipe_emit_fence, just before "return fence;"
old2 = """      OUT_RING(ring, fence);
   }

   return fence;
}"""
new2 = """      OUT_RING(ring, fence);
   }

   fd_pipe_emit_fence_dup(pipe, ring, fence);   /* [0048 E4] */

   return fence;
}"""
if s.count(old2) != 1:
    print("ANCHOR FAIL tail", s.count(old2)); sys.exit(1)
s = s.replace(old2, new2, 1)

if '#include <stdlib.h>' not in s:
    s = s.replace('#include "freedreno_priv.h"', '#include <stdlib.h>\n#include "freedreno_priv.h"', 1)
if '#include <stdio.h>' not in s:
    s = s.replace('#include "freedreno_priv.h"', '#include <stdio.h>\n#include "freedreno_priv.h"', 1)

open(F, "w").write(s)
print("0048 L2FIX applied")

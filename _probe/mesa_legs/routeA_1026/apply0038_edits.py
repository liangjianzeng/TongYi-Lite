#!/usr/bin/env python3
# [TongYi-Lite 0038] fix-candidate: enlarge freedreno stream_uploader slab,
# env-gated TYL_UPSZ bytes (0037 diag7 base kept). Tests the CB0 slab
# wraparound-reuse hypothesis: bigger slab => wrap distance >> GPU lag =>
# async must become correct if the theory holds.
import sys, os
TREE = os.environ.get("E4TREE", "/root/mesa-26.2.4")
F = TREE + "/src/gallium/drivers/freedreno/freedreno_context.c"
with open(F) as f: s = f.read()
old = """   pctx->stream_uploader = u_upload_create_default(pctx);"""
new = """   /* [TongYi-Lite 0038] A/B: TYL_UPSZ overrides stream uploader slab size
    * (CB0 wraparound-reuse hypothesis test); unset == stock 1MB. */
   {
      const char *upsz = getenv("TYL_UPSZ");
      if (upsz && atoi(upsz) >= 65536) {
         pctx->stream_uploader = u_upload_create(pctx, (unsigned)atoi(upsz),
            PIPE_BIND_VERTEX_BUFFER | PIPE_BIND_INDEX_BUFFER |
            PIPE_BIND_CONSTANT_BUFFER, PIPE_USAGE_STREAM, 0);
      } else {
         pctx->stream_uploader = u_upload_create_default(pctx);
      }
   }"""
n = s.count(old)
if n != 1:
    print(f"ANCHOR FAIL count={n}")
    sys.exit(1)
s = s.replace(old, new, 1)
if '#include <stdlib.h>' not in s:
    s = s.replace('#include <string.h>', '#include <string.h>\n#include <stdlib.h>', 1)
    if '#include <stdlib.h>' not in s:
        # no string.h anchor: put it after first include line
        i = s.index('#include')
        j = s.index('\n', i) + 1
        s = s[:j] + '#include <stdlib.h>\n' + s[j:]
with open(F, "w") as f: f.write(s)
print("OK 0038 applied", F)

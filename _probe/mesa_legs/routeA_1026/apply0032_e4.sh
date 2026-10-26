#!/bin/sh
# [chroot] TongYi-Lite 0032 E4 round-2 (R10 verdict probes) for routeA 1026.
# From endorsed state: restore /root/kgsl_ringbuffer_sp.c.orig, apply 0031 then
# 0032 (all TYL_E4=1-gated): E4VERIFY (IB CRC at submit vs post-KMD-completion),
# E4REUSE (ring-cache acquire vs non-blocking retire probe), E4FAST (fastpath
# completion obs at freedreno_pipe.c), E4FLUSH/E4WAIT (rusticl batch-fence join).
# Rebuilds build-cl incrementally. Mirrors apply0031_e4.sh form.
#
# Host-side invocation (DGX):
#   sudo chroot /opt/trixie-cl sh -c 'sh /root/apply0032_e4.sh'
set -e
T=/root/mesa-26.2.4
F=src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c
cd $T

echo "=== restore endorsed-state file ==="
grep -c "TongYi-Lite" $F || true
cp /root/kgsl_ringbuffer_sp.c.orig $F
grep -c "TongYi-Lite" $F || echo "TREE_CLEAN_TONGYI_MARKERS=0"

echo "=== apply 0031 E4 ==="
patch -p1 --backup < /root/0031-kgsl-e4-diag.patch
grep -c "TongYi-Lite 0031 E4" $F

echo "=== apply 0032 E4 round-2 ==="
patch -p1 --backup < /root/0032-e4-r2-diag.patch
grep -c "0032 E4" $F
grep -c "kgsl_e4_verify\|kgsl_e4_ring_reused" src/freedreno/drm/kgsl/kgsl_pipe.c src/freedreno/drm/freedreno_bo.c
grep -c "e4_fast_on" src/freedreno/drm/freedreno_pipe.c
grep -c "E4FLUSH\|E4WAIT" src/gallium/frontends/rusticl/core/queue.rs


echo "=== apply 0033 E4 round-3 (if present) ==="
if [ -f /root/0033-e4-r3-diag.patch ]; then
  patch -p1 --backup < /root/0033-e4-r3-diag.patch
  grep -c "0033" src/freedreno/drm/freedreno_bo.c
fi

B=$T/build-cl; [ -d $B ] || { echo NO_BUILD_DIR; exit 1; }
echo "=== ninja (rusticl target) ==="
ninja -C $B src/gallium/targets/rusticl/libRusticlOpenCL.so.1.0.0 2>&1 | tail -5
L=$B/src/gallium/targets/rusticl/libRusticlOpenCL.so.1.0.0
md5sum $L
for m in E4VERIFY E4REUSE E4FAST E4FLUSH E4WAIT; do echo -n "$m="; strings $L | grep -c "$m" || true; done
find $B -name "*.so*" -newer /root/0032-e4-r2-diag.patch | grep -v buildconfig > /root/0032_changed.txt || true
cat /root/0032_changed.txt
echo APPLY0032R3_DONE
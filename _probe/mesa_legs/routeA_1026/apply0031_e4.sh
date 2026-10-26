#!/bin/sh
# [chroot] TongYi-Lite 0031 E4 diagnostics for async-garbage battle (routeA 1026).
# Reverts TongYi-Lite 0030 (restores endorsed-state kgsl_ringbuffer_sp.c from
# /root/kgsl_ringbuffer_sp.c.orig), then applies 0031 (TYL_E4=1-gated P1/P2/P3a
# probes) and rebuilds build-cl incrementally. Mirrors apply0030.sh form.
#
# Host-side invocation (DGX):
#   sudo chroot /opt/trixie-cl sh -c 'sh /root/apply0031_e4.sh'
set -e
T=/root/mesa-26.2.4
F=src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c
cd $T

echo "=== revert 0030 (restore endorsed-state file) ==="
grep -c "TongYi-Lite 0030" $F || true
cp /root/kgsl_ringbuffer_sp.c.orig $F
grep -c "TongYi-Lite" $F || echo "TREE_CLEAN_TONGYI_MARKERS=0"

echo "=== apply 0031 E4 ==="
patch -p1 --backup < /root/0031-kgsl-e4-diag.patch
grep -c "TongYi-Lite 0031 E4" $F
grep -c "TYL_E4" $F

B=$T/build-cl; [ -d $B ] || { echo NO_BUILD_DIR; exit 1; }
echo "=== ninja (rusticl target) ==="
ninja -C $B src/gallium/targets/rusticl/libRusticlOpenCL.so.1.0.0 2>&1 | tail -5
L=$B/src/gallium/targets/rusticl/libRusticlOpenCL.so.1.0.0
md5sum $L
strings $L | grep -c -E 'E4MERGE|E4HIST|E4DEL|E4BO|E4FENCE' || echo E4_STRINGS_MISSING
find $B -name "*.so*" -newer /root/0031-kgsl-e4-diag.patch | grep -v buildconfig > /root/0031_changed.txt || true
cat /root/0031_changed.txt
md5sum $(cat /root/0031_changed.txt) 2>/dev/null
echo APPLY0031_DONE

#!/bin/sh
# [chroot] apply TongYi-Lite 0030 to mesa-26.2.4: kgsl flush_submit_list BO-migration fix
# (mirror MSM winsys). Produces /root/0030 patch + rebuilds build-cl incrementally.
set -e
T=/root/mesa-26.2.4
F=src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c
cd $T
cp $F /root/kgsl_ringbuffer_sp.c.orig
awk '
/list_del\(&submit->node\);/ && !done {
  print "        /* [TongYi-Lite 0030] Mirror MSM winsys: migrate ring bos and the"
  print "         * deferred submit'"'"'s bos table onto the current submit before"
  print "         * dropping it, so nothing can be freed/reused before the ioctl."
  print "         * Upstream kgsl dropped these refs in fd_submit_del() while the"
  print "         * GPU was about to read those IOVAs -> silent corruption when"
  print "         * flush_submit_list merges deferred submits (async path). */"
  print "        {"
  print "            struct fd_submit_sp *fd_deferred_submit = to_fd_submit_sp(submit);"
  print "            for (unsigned i = 0; i < deferred_primary->u.nr_cmds; i++)"
  print "                fd_submit_append_bo(fd_submit, deferred_primary->u.cmds[i].ring_bo);"
  print "            for (unsigned i = 0; i < fd_deferred_submit->nr_bos; i++)"
  print "                fd_submit_append_bo(fd_submit, fd_deferred_submit->bos[i]);"
  print "        }"
  print ""
  done=1
}
{ print }
' /root/kgsl_ringbuffer_sp.c.orig > /root/kgsl_ringbuffer_sp.c.new
diff -u /root/kgsl_ringbuffer_sp.c.orig /root/kgsl_ringbuffer_sp.c.new \
  | sed -e '1s|.*|--- a/src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c|' \
        -e '2s|.*|+++ b/src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c|' \
  > /root/0030-kgsl-ringbuffer-sp-append-bo.patch || true
cat /root/0030-kgsl-ringbuffer-sp-append-bo.patch
# restore original then apply via patch(1) to get .orig backups + convention conformance
cp /root/kgsl_ringbuffer_sp.c.orig $F
patch -p1 --backup < /root/0030-kgsl-ringbuffer-sp-append-bo.patch
grep -n "TongYi-Lite 0030" $F
B=$T/build-cl; [ -d $B ] || B=$(ls -d $T/build* 2>/dev/null | head -1)
echo "BUILD_DIR=$B"
ninja -C $B 2>&1 | tail -3
find $B -name "*.so*" -newer /root/0030-kgsl-ringbuffer-sp-append-bo.patch | grep -v buildconfig > /root/0030_changed.txt || true
cat /root/0030_changed.txt
md5sum $(cat /root/0030_changed.txt | head -6) 2>/dev/null
echo APPLY0030_DONE

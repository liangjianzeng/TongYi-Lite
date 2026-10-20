#!/system/bin/sh
# M0 probe runner: proot -> trixie rootfs -> rusticl (freedreno/kgsl)
BASE=/data/local/tmp/mesa_m0
export LD_LIBRARY_PATH=$BASE/usr/lib
export HOME=/root
export TMPDIR=/tmp
exec $BASE/bin/proot -0 -w /root \
  -b /dev -b /proc -b /sys \
  -r $BASE/rootfs \
  /bin/sh -c "$1"

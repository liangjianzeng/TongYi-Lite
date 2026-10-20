#!/bin/sh
# 在 chroot 内执行：收集 rusticl 运行时依赖 -> /tmp/clrt 精简包
set -x
apt-get install -y -qq libclc-19-dev 2>&1 | tail -2
ls /usr/lib/clc/ 2>/dev/null | head -5
dpkg -L libclc-19-dev 2>/dev/null | grep -E '\.bc$' | head -5

STG=/tmp/clrt
rm -rf $STG
LIST=/tmp/clrt_files.txt
: > $LIST

ROOTS="/root/probe_m0 /usr/bin/clinfo /usr/lib/aarch64-linux-gnu/libOpenCL.so.1 /opt/mesa-cl/lib/aarch64-linux-gnu/libRusticlOpenCL.so.1.0.0"

queue="$ROOTS"
seen=""
iter=0
while [ -n "$queue" ] && [ $iter -lt 30 ]; do
  iter=$((iter+1))
  next=""
  for f in $queue; do
    case " $seen " in *" $f "*) continue ;; esac
    seen="$seen $f"
    echo "$f" >> $LIST
    if [ -f "$f" ]; then
      for dep in $(ldd "$f" 2>/dev/null | awk '$3 ~ /^\// {print $3}'); do
        case " $seen $next " in *" $dep "*) ;; *) next="$next $dep" ;; esac
      done
    fi
  done
  queue="$next"
done

while read -r f; do
  case "$f" in /proc/*|/sys/*|/dev/*) continue ;; esac
  dest="$STG$f"
  mkdir -p "$(dirname "$dest")"
  cp -L "$f" "$dest" 2>/dev/null || echo "SKIP $f"
done < $LIST

# mesa ICD 全量（lib+etc）+ libclc 数据
mkdir -p $STG/opt/mesa-cl
cp -a /opt/mesa-cl/etc $STG/opt/mesa-cl/ 2>/dev/null
mkdir -p $STG/usr/lib/clc
cp -a /usr/lib/clc/. $STG/usr/lib/clc/ 2>/dev/null

du -sh $STG
cd /tmp && tar -cf clrt.tar clrt && xz -1 -T0 -f clrt.tar
ls -la /tmp/clrt.tar /tmp/clrt.tar.xz
echo COLLECT_DONE

#!/bin/bash
P=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/common
ls $P/*.so 2>/dev/null | head
echo "=== find canonicalize ==="
for f in $(ls /mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/common/*.so /mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/lib*.so 2>/dev/null); do
  if strings -a "$f" 2>/dev/null | grep -q canonicalizeOp; then echo "HIT: $f"; fi
done
echo "=== ldd libPyIrGraph ==="
find /mnt/d/MyLLM/qairt/2.44.0.260225/lib/python -name "libPyIrGraph*" | head -2
for f in $(find /mnt/d/MyLLM/qairt/2.44.0.260225/lib/python -name "libPyIrGraph*"); do ldd "$f" 2>&1 | grep -iE "c\+\+|not found"; done
echo "=== sudo check ==="
sudo -n true 2>&1 | head -1

#!/bin/bash
echo "=== QAIRT lib dir contents (libc*) ==="
ls -la /mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang/ | grep -i "c++\|c++abi\|python" | head
echo "=== cppx contents ==="
ls -la /mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu/ | grep -i "c++" | head
ls -la /mnt/e/MyLLM_exp/cppx/usr/lib/llvm-14/lib/ 2>/dev/null | grep -i "c++" | head
echo "=== system libc++ ==="
ls -la /usr/lib/x86_64-linux-gnu/libc++* 2>/dev/null
ls -la /usr/local/lib/libc++* 2>/dev/null
echo "=== libPyIrGraph deps ==="
ldd /mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/common/libPyIrGraph*.so 2>/dev/null | grep -i "not found\|c++" | head
echo "=== which .so has canonicalizeOp ==="
grep -rl "canonicalizeOp" /mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/common/*.so 2>/dev/null | head -3

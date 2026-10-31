#!/bin/bash
echo "=== search SDK for libc++/libunwind ==="
find /mnt/d/MyLLM/qairt/2.44.0.260225 -name "libc++*" -o -name "libunwind*" 2>/dev/null | head
echo "=== cppx libunwind? ==="
find /mnt/e/MyLLM_exp/cppx -name "libunwind*" 2>/dev/null | head
echo "=== try pip download approach: check apt availability ==="
apt-cache policy libc++1-17 libunwind-17 2>/dev/null | head -8
apt-cache policy libc++1-14 libunwind-14 2>/dev/null | head -8

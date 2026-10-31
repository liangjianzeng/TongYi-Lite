#!/bin/bash
find /mnt/d/MyLLM/qairt/2.44.0.260225/include -name "QnnDataTypes.h" 2>/dev/null
f=$(find /mnt/d/MyLLM/qairt/2.44.0.260225/include -name "QnnDataTypes.h" | head -1)
grep -nE "= 0x|0x02|0x03" "$f" | head -40

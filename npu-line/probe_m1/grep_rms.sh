#!/bin/bash
R=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters
grep -rn "RMS_NORM\|rms_norm" $R --include=*.py | grep -iv "qnn_op_def\|opdef" | head -20
echo ====
grep -rln "RMSNorm\|rms_norm" $R/implementation 2>/dev/null | head

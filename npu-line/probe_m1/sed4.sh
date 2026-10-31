#!/bin/bash
C=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters
grep -rln "ReduceMean" $C --include=*.py | head
echo =====
grep -rn "register_op_schema('ReduceMean'\|'ReduceMean'" $C/common/op_adapter.py 2>/dev/null | head -5
grep -rn "ReduceMean" $C/common/op_adapter.py | head -8
echo ===== onnx side =====
grep -rn "ReduceMean" $C/onnx/*.py | head -10

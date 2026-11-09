#!/bin/bash
C=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters
sed -n '1,80p' $C/onnx/data_translations.py
echo "===== transpose translation location ====="
grep -rn "TRANSPOSE" $C/qnn_backend/qnn_translations.py | head -8
echo "===== add_node dtype resolution in ir_to_qnn ====="
sed -n '300,345p' $C/backend/ir_to_qnn.py

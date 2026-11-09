#!/bin/bash
Q=/mnt/d/MyLLM/qairt/2.44.0.260225
grep -n "0x021\|0x022\|0x023\|0x014\|0x016" $Q/include/QNN/QnnTypes.h | head -30
echo "===== transpose add_op_to_backend ====="
C=$Q/lib/python/qti/aisw/converters
sed -n '3230,3260p' $C/qnn_backend/qnn_translations.py
echo "===== how output dtype is decided in ir_to_qnn get_ir_graph / add_output ====="
grep -n "def add_output\|outputs_info\|tensor_data_type" $C/backend/ir_to_qnn.py | head -30

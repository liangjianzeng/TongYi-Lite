#!/bin/bash
F=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/backend/ir_to_qnn.py
grep -n "def get_outputs_info\|def add_node\|def get_tensor_info\|def create_tensor_info" $F
sed -n '/def get_outputs_info/,+40p' $F | head -50

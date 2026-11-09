#!/bin/bash
F=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/qnn_backend/qnn_translations.py
sed -n '2850,2920p' $F
echo "########## op_adapter RMSNormOp"
G=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/common/converter_ir/op_adapter.py
sed -n '4725,4800p' $G

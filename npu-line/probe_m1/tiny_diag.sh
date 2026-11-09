#!/bin/bash
export LD_LIBRARY_PATH=/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang:$LD_LIBRARY_PATH
export PYTHONPATH=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python
export PYTHONIOENCODING=utf-8
CONV=/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter
cd /mnt/e/MyLLM_exp
for n in tiny_rms tiny_sm; do
  echo "########## $n"
  python3 $CONV --input_network /mnt/e/MyLLM_exp/$n.onnx --output_path /mnt/e/MyLLM_exp/${n}_qnn > ${n}_conv.log 2>&1
  echo "RC=$?"
  tail -25 ${n}_conv.log
done
echo TINY_DIAG_DONE

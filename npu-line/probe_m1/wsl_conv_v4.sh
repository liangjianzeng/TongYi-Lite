#!/bin/bash
set -x
export LD_LIBRARY_PATH=/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang:$LD_LIBRARY_PATH
export PYTHONIOENCODING=utf-8
export PYTHONPATH=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python
export ANDROID_NDK_ROOT=/home/liang/m4/android-ndk-r27c
export QNN_SDK_ROOT=/mnt/d/MyLLM/qairt/2.44.0.260225
cd /mnt/e/MyLLM_exp
python3 /mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter \
  --input_network /mnt/e/MyLLM_exp/spark_prefill_v4.onnx \
  --output_path /mnt/e/MyLLM_exp/spark_v4
echo "CONVERTER_RC=$?"
ls -la /mnt/e/MyLLM_exp/spark_v4.* 2>/dev/null
/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-model-lib-generator \
  -c /mnt/e/MyLLM_exp/spark_v4.cpp -b /mnt/e/MyLLM_exp/spark_v4.bin \
  -o /mnt/e/MyLLM_exp/v4_out -t aarch64-android
echo "MLG_RC=$?"
ls -la /mnt/e/MyLLM_exp/v4_out/aarch64-android/libspark_v4.so 2>/dev/null
echo "CONV_ALL_DONE"

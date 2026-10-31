#!/bin/bash
export LD_LIBRARY_PATH=/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang:$LD_LIBRARY_PATH
export PYTHONIOENCODING=utf-8
export PYTHONPATH=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python
python3 /mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-onnx-converter --help 2>&1 | head -120
echo "===== MLG HELP ====="
export ANDROID_NDK_ROOT=/home/liang/m4/android-ndk-r27c
export QNN_SDK_ROOT=/mnt/d/MyLLM/qairt/2.44.0.260225
/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/qnn-model-lib-generator -h 2>&1 | head -30

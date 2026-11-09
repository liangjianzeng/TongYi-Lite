#!/bin/bash
# [C32] Build a model lib WITHOUT embedding tensor data (runtime mmap via QNN_MODEL_DATA_DIR).
# Usage: build_mmap_lib.sh <model.cpp> <model.bin(tar)> <lib_name> <out_dir>
# Produces <out_dir>/libs/arm64-v8a/lib<lib_name>.so ; extract the tar to device dir at run time.
set -e
CPP_IN="$1"; BIN_IN="$2"; LIB_NAME="$3"; OUT="$4"
export ANDROID_NDK_ROOT=/home/liang/m4/android-ndk-r27c
export PATH=$ANDROID_NDK_ROOT:$PATH
export QNN_SDK_ROOT=/mnt/d/MyLLM/qairt/2.44.0.260225
J=/mnt/d/MyLLM/qairt/2.44.0.260225/share/QNN/converter/jni
B="$OUT/build"
rm -rf "$B"; mkdir -p "$B/jni"
cp "$J/Android.mk" "$J/Application.mk" "$J/QnnModel.cpp" "$J/QnnModel.hpp" \
   "$J/QnnTypeMacros.hpp" "$J/QnnWrapperUtils.cpp" "$J/QnnWrapperUtils.hpp" \
   "$J/QnnModelPal.hpp" "$B/jni/"
cp "$J/linux/QnnModelPal.cpp" "$B/jni/"
cp "$CPP_IN" "$B/jni/"
cp /mnt/e/MyLLM_exp/_repro/qnn_mmap_data.cpp "$B/jni/"
# NO .bin in jni -> Android.mk skips objcopy entirely (only a warning)
python3 /mnt/e/MyLLM_exp/_repro/patch_header_mmap.py "$B/jni/QnnWrapperUtils.hpp"
cd "$B"
export QNN_MODEL_LIB_NAME="lib${LIB_NAME}.so"
export QNN_ANDROID_APP_ABIS=arm64-v8a
ndk-build NDK_APP_OUT="$B/out" 2>&1 | tail -4
SO="$B/out/local/arm64-v8a/lib${LIB_NAME}.so"
mkdir -p "$OUT" && cp -f "$SO" "$OUT/" 2>/dev/null || true
ls -la "$OUT" | grep so || ls -la "$B/out/local/arm64-v8a/"
echo BUILD_MMAP_DONE

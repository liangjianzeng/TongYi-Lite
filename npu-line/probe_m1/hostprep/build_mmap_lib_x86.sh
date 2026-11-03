#!/bin/bash
# [C33] Host-side (x86_64-linux-clang) mmap model lib build, for HOST HTP prepare.
# Mirrors build_mmap_lib.sh but uses Makefile.linux-x86_64 + system g++ (no NDK).
# Usage: build_mmap_lib_x86.sh <model.cpp> <lib_name> <out_dir>
set -e
CPP_IN="$1"; LIB_NAME="$2"; OUT="$3"
export QNN_SDK_ROOT=/mnt/d/MyLLM/qairt/2.44.0.260225
J=$QNN_SDK_ROOT/share/QNN/converter
B="$OUT/build"
rm -rf "$B"; mkdir -p "$B/jni"
cp "$J/jni/QnnModel.cpp" "$J/jni/QnnModel.hpp" \
   "$J/jni/QnnTypeMacros.hpp" "$J/jni/QnnWrapperUtils.cpp" "$J/jni/QnnWrapperUtils.hpp" \
   "$J/jni/QnnModelPal.hpp" "$B/jni/"
cp "$J/jni/linux/QnnModelPal.cpp" "$B/jni/"
cp "$CPP_IN" "$B/jni/"
cp /mnt/e/MyLLM_exp/_repro/qnn_mmap_data.cpp "$B/jni/"
cp "$J/Makefile.linux-x86_64" "$B/"
# NO .bin in jni -> makefile skips objcopy (warning only); data comes from mmap registry
python3 /mnt/e/MyLLM_exp/_repro/patch_header_mmap.py "$B/jni/QnnWrapperUtils.hpp"
cd "$B"
QNN_MODEL_LIB_NAME="lib${LIB_NAME}.so" make CXX=g++ -f Makefile.linux-x86_64 2>&1 | tail -4
SO="$B/libs/x86_64-linux-clang/lib${LIB_NAME}.so"
mkdir -p "$OUT" && cp -f "$SO" "$OUT/"
ls -la "$OUT" | grep "$LIB_NAME" || ls -la "$B/libs/x86_64-linux-clang/"
echo BUILD_MMAP_X86_DONE

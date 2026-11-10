#!/bin/bash
# [C37-9y] Generic single-layer deepk ctx builder: $1 = K (e.g. 1 2 3).
# Expects /home/liang/models/mcp5_dec/mcp5_l{K}.onnx from mcp5_24_deepk.py K.
# Builds ctx_l{K} (pure fp16, same recipe as proven l5/l12/l20) -> serve dir.
set -e
K=$1
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
export PYTHONIOENCODING=utf-8 PYTHONPATH=$SDK/lib/python LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang:${LD_LIBRARY_PATH:-}
export TMPDIR=/home/liang/tmp_q TEMP=/home/liang/tmp_q TMP=/home/liang/tmp_q
TAG=$1
OUT=/home/liang/w4sim/ctx_${TAG}
rm -rf $OUT; mkdir -p $OUT/jni $OUT/obj/binary
ONNX=/home/liang/models/mcp5_dec2_${DEC_NC:-512}/mcp5_${TAG}.onnx
$SDK/bin/x86_64-linux-clang/qnn-onnx-converter \
  --input_network $ONNX --output_path $OUT/$TAG \
  --disable_defer_loading --float_bitwidth 16 --float_bias_bitwidth 16 \
  --disable_qnn_op_config_validation > $OUT/conv.log 2>&1 || { echo CONV_FAIL; grep -a ERROR $OUT/conv.log | head -3; exit 1; }
cp $OUT/$TAG $OUT/jni/${TAG}_off.cpp
mkdir -p $OUT/qkvbin; tar xf $OUT/$TAG.bin -C $OUT/qkvbin; mv $OUT/qkvbin/* $OUT/obj/binary/
cd $OUT
for r in obj/binary/*.raw; do objcopy -I binary -O elf64-x86-64 -B i386:x86-64 "$r" "${r%.raw}.o"; done
CXX=""; for c in /usr/bin/g++ /usr/bin/clang++; do [ -x "$c" ] && CXX="$c" && break; done
FLAGS="-std=c++11 -march=x86-64 -O2 -fPIC -mcmodel=large -fno-exceptions -fno-rtti -Wno-write-strings -fvisibility=default -I$OUT/jni -I$SDK/share/QNN/converter/jni -I$SDK/include/QNN"
$CXX $FLAGS -c jni/${TAG}_off.cpp -o model.o
$CXX $FLAGS -c $SDK/share/QNN/converter/jni/QnnWrapperUtils.cpp -o wrapper.o
$CXX $FLAGS -c $SDK/share/QNN/converter/jni/QnnModel.cpp -o qnnmodel.o
$CXX $FLAGS -c $SDK/share/QNN/converter/jni/linux/QnnModelPal.cpp -o pal.o
$CXX -shared -fPIC -o lib${TAG}.so model.o wrapper.o qnnmodel.o pal.o obj/binary/*.o
$SDK/bin/x86_64-linux-clang/qnn-context-binary-generator \
  --model $OUT/lib${TAG}.so --backend $SDK/lib/x86_64-linux-clang/libQnnHtp.so \
  --config_file "${2:-/mnt/e/MyLLM_exp/_repro/host_cfg_740.json}" \
  --binary_file ${TAG}_ctx --output_dir $OUT > $OUT/ctxgen.log 2>&1 || { echo CTXGEN_FAIL; grep -a ERROR $OUT/ctxgen.log | head -3; exit 1; }
# keep only the deliverable
rm -rf $OUT/obj $OUT/qkvbin $OUT/jni $OUT/lib*.so $OUT/*.o
md5sum $OUT/${TAG}_ctx.bin
cp $OUT/${TAG}_ctx.bin /mnt/e/MyLLM_exp/serve_dec/ && echo STAGED_${TAG}

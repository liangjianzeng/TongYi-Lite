#!/bin/bash
# [npu-line] G3 decisive test: full W8 recipe through the 92-line GREEN writer path
# (wrapper with W8_EXPORT_FMT=cpp -> cpp/bin -> objcopy .o -> g++ model.so ->
# qnn-context-binary-generator --model), bypassing the DLC compose that every red
# 93-line ctx went through. $1 = TAG; env ENCOVR (enc json), ONNXOVERRIDE.
set -e
TAG=$1
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
RBD=/mnt/e/MyLLM_exp/_repro/rb
export PYTHONIOENCODING=utf-8 PYTHONPATH=$SDK/lib/python LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang:${LD_LIBRARY_PATH:-}
export TMPDIR=/home/liang/tmp_q TEMP=/home/liang/tmp_q TMP=/home/liang/tmp_q
OUT=/home/liang/w4sim/ctx_${TAG}
rm -rf $OUT; mkdir -p $OUT/jni $OUT/obj/binary
ONNX=${ONNXOVERRIDE:-/home/liang/models/mcp5_dec2_640/mcp5_${TAG#w8cpp}.onnx}
[ -f "$ONNX" ] || { echo NO_ONNX $ONNX; exit 1; }
cd $RBD
export W8_ALLOW_FC=1 W8_EXPORT_FMT=cpp
EXTRA=()
if [ "${NOENC:-0}" = "1" ]; then
  # wrapper patches + FC fold, ZERO quantization (discriminates DLC-export poison from
  # wrapper-optimize-flow poison for the fp16-only case)
  QFLAGS=(--weights_bitwidth 16)
else
  [ -n "${ENCOVR:-}" ] || { echo NO_ENCODES; exit 1; }
  QFLAGS=(--weights_bitwidth 8 --use_per_channel_quantization --keep_weights_quantized
          --quantization_overrides "$ENCOVR" --float_fallback)
fi
python3 -u mcp5_93_conv_w8.py \
  --input_network $ONNX \
  --output_path $OUT/${TAG} \
  --float_bitwidth 16 --float_bias_bitwidth 16 \
  "${QFLAGS[@]}" --disable_qnn_op_config_validation \
  > $OUT/conv.log 2>&1 || { echo CONV_FAIL; grep -a ERROR $OUT/conv.log | head -5; exit 1; }
grep -a "CONVERSION COMPLETE" $OUT/conv.log || { echo NO_COMPLETE; tail -5 $OUT/conv.log; exit 1; }
[ -f $OUT/$TAG ] && [ -f $OUT/$TAG.bin ] || { echo NO_CPP_ARTIFACTS; ls $OUT; exit 1; }
cp $OUT/$TAG $OUT/jni/${TAG}_off.cpp
tar xf $OUT/$TAG.bin -C $OUT/qkvbin 2>/dev/null || { mkdir -p $OUT/qkvbin; tar xf $OUT/$TAG.bin -C $OUT/qkvbin; }
mv $OUT/qkvbin/* $OUT/obj/binary/
cd $OUT
for r in obj/binary/*.raw; do objcopy -I binary -O elf64-x86-64 -B i386:x86-64 "${r%.raw}.o"; done
CXX=""; for c in /usr/bin/g++ /usr/bin/clang++; do [ -x "$c" ] && CXX="$c" && break; done
FLAGS="-std=c++11 -march=x86-64 -O2 -fPIC -mcmodel=large -fno-exceptions -fno-rtti -Wno-write-strings -fvisibility=default -I$OUT/jni -I$SDK/share/QNN/converter/jni -I$SDK/include/QNN"
$CXX $FLAGS -c jni/${TAG}_off.cpp -o model.o
$CXX $FLAGS -c $SDK/share/QNN/converter/jni/QnnWrapperUtils.cpp -o wrapper.o
$CXX $FLAGS -c $SDK/share/QNN/converter/jni/QnnModel.cpp -o qnnmodel.o
$CXX $FLAGS -c $SDK/share/QNN/converter/jni/linux/QnnModelPal.cpp -o pal.o
$CXX -shared -fPIC -o lib${TAG}.so model.o wrapper.o qnnmodel.o pal.o obj/binary/*.o
$SDK/bin/x86_64-linux-clang/qnn-context-binary-generator \
  --model $OUT/lib${TAG}.so --backend $SDK/lib/x86_64-linux-clang/libQnnHtp.so \
  --config_file /mnt/e/MyLLM_exp/_repro/host_cfg_740.json \
  --binary_file ${TAG}_ctx --output_dir $OUT > $OUT/ctxgen.log 2>&1 \
  || { echo CTXGEN_FAIL; grep -a ERROR $OUT/ctxgen.log | head -5; exit 1; }
md5sum $OUT/${TAG}_ctx.bin
ls -la --block-size=M $OUT/${TAG}_ctx.bin | awk '{print $5, $9}'
cp $OUT/${TAG}_ctx.bin /mnt/e/MyLLM_exp/serve_dec/ && echo STAGED_${TAG}

#!/bin/bash
# [npu-line] Resume mcp5_93_build_w8cpp.sh after the (transient) objcopy hiccup:
# objcopy -> g++ model.so -> ctxgen --model -> stage. $1 = TAG.
set -e
TAG=$1
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
OUT=/home/liang/w4sim/ctx_${TAG}
cd $OUT
for r in obj/binary/*.raw; do
  [ -f "${r%.raw}.o" ] || objcopy -I binary -O elf64-x86-64 -B i386:x86-64 "$r" "${r%.raw}.o"
done
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

set -x
S=/mnt/d/MyLLM/qairt/2.44.0.260225/share/QNN/converter
B=/mnt/e/MyLLM_exp/v4w4_build
export ANDROID_NDK_ROOT=/home/liang/m4/android-ndk-r27c
export PATH=$ANDROID_NDK_ROOT:$PATH
rm -rf $B
mkdir -p $B/jni
cp $S/jni/*.cpp $S/jni/*.hpp $B/jni/ 2>/dev/null
cp $S/jni/linux/QnnModelPal.cpp $B/jni/ 2>/dev/null
cp $S/jni/Android.mk $B/jni/
sed -i 's|-I binary -O elf64-littleaarch64 -B aarch64)|-I binary -O elf64-littleaarch64 -B aarch64 --rename-section .data=.qnn_weights,alloc,load,readonly,data,contents)|' $B/jni/Android.mk
cat > $B/weights.ld <<'LDEOF'
SECTIONS {
  .qnn_weights : { *(.qnn_weights) }
} INSERT AFTER .bss;
LDEOF
cp /mnt/e/MyLLM_exp/spark_v4_w4_qnn $B/jni/spark_v4_w4_qnn.cpp
cp /mnt/e/MyLLM_exp/spark_v4_w4_qnn.bin $B/jni/spark_v4_w4_qnn.bin
cat > $B/jni/Application.mk <<'APPEOF'
NDK_TOOLCHAIN_VERSION := clang++
APP_PLATFORM := android-29
APP_ABI := arm64-v8a
APP_STL := c++_static
APP_CPPFLAGS += -std=c++11 -O3 -Wno-write-strings -DQNN_API="__attribute__((visibility(\"default\")))" \
                -fvisibility=hidden
APP_LDFLAGS = -lc -lm -ldl -Wl,-z,max-page-size=16384 -Wl,-T,BUILDDIR_PLACEHOLDER/weights.ld
APPEOF
sed -i "s|BUILDDIR_PLACEHOLDER|$B|" $B/jni/Application.mk
cd $B
ndk-build -j4 QNN_SDK_ROOT=/mnt/d/MyLLM/qairt/2.44.0.260225 > /mnt/e/MyLLM_exp/_repro/w4ndk.log 2>&1
echo BUILD_RC=$?
tail -12 /mnt/e/MyLLM_exp/_repro/w4ndk.log
ls -la --block-size=M $B/libs/arm64-v8a/ 2>/dev/null
echo ===END===

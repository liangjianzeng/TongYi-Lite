#!/bin/bash
# [npu-line] M2 KV bridge: build hyb_save_up/hyb_load_up against pure-upstream
# 5c200e0 (lc-up) Android CPU shared libs pulled to uplib. A6 timing variants.
set -e
NDK=/home/liang/m4/android-ndk-r27c
CXX=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++
mkdir -p /home/liang/hyb /mnt/e/MyLLM_exp/hyb/bin
cp -f /mnt/e/MyLLM_exp/hyb/hyb_save.cpp /mnt/e/MyLLM_exp/hyb/hyb_load.cpp /home/liang/hyb/
cd /home/liang/hyb
for t in hyb_save hyb_load; do
  $CXX --target=aarch64-linux-android26 -O2 -std=c++17 \
    -I/home/liang/lc-up/include -I/home/liang/lc-up/ggml/include \
    $t.cpp -L/mnt/e/MyLLM_exp/hyb/uplib -lllama -lggml -lggml-base \
    -Wl,-rpath,'$ORIGIN' -o /mnt/e/MyLLM_exp/hyb/bin/${t}_up
  echo BUILT ${t}_up
done
ls -la /mnt/e/MyLLM_exp/hyb/bin/*_up

#!/bin/bash
# [C33] Smoke: x86 mmap model lib of fc_v16 + HOST HTP prepare with soc_model=SM8550 config.
set -e
SDK=/mnt/d/MyLLM/qairt/2.44.0.260225
R=/mnt/e/MyLLM_exp/_repro
bash $R/build_mmap_lib_x86.sh $R/fc_v16.cpp fc_v16 $R/fc16x86
export LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang
export QNN_MODEL_DATA_DIR=$R/fc18raws
mkdir -p $R/fc18_host_ctx; cd $R/fc18_host_ctx
"$SDK/bin/x86_64-linux-clang/qnn-context-binary-generator" \
  --model $R/fc16x86/libfc_v16.so \
  --backend "$SDK/lib/x86_64-linux-clang/libQnnHtp.so" \
  --config_file $R/host_cfg_r2.json \
  --binary_file fc_v16_host \
  --output_dir $R/fc18_host_ctx 2>&1 | tail -25
ls -la $R/fc18_host_ctx
echo FC_HOST_SMOKE_DONE

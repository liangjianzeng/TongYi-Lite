#!/bin/bash
# [npu-line] G3 W8 decode: quantized (weights-only W8 per-channel, activations fp16) ctx
# build via the C21/C22/C25-hardened converter wrapper (RmsNorm dtype fixup, honest fp16
# external-data materialization, DLC export — the cpp/bin writer segfaults on quantized
# graphs) + qnn-context-binary-generator --dlc_path. $1 = TAG (onnx mcp5_nc640_l{N} from
# models/mcp5_dec2_640, ctx named ${TAG}_ctx.bin -> serve_dec).
# Flags proven by the spark W4I line (run_rb_build.sh).
set -e
TAG=$1
SDK=/mnt/e/MyLLM/qairt/2.44.0.260225
RBD=/mnt/e/MyLLM_exp/_repro/rb
export PYTHONIOENCODING=utf-8 PYTHONPATH=$SDK/lib/python LD_LIBRARY_PATH=$SDK/lib/x86_64-linux-clang:${LD_LIBRARY_PATH:-}
export TMPDIR=/home/liang/tmp_q TEMP=/home/liang/tmp_q TMP=/home/liang/tmp_q
OUT=/home/liang/w4sim/ctx_${TAG}
rm -rf $OUT; mkdir -p $OUT
ONNX=${ONNXOVERRIDE:-/home/liang/models/mcp5_dec2_640/mcp5_${TAG#w8}.onnx}
[ -f "$ONNX" ] || { echo NO_ONNX $ONNX; exit 1; }
cd $RBD
# ENCOVR=path/to/enc.json: real W8 packing route (param_encodings supplied -> quantizer
# packs FC int8; --float_fallback legit with overrides; keep the MATMUL_TO_FC fold via
# W8_ALLOW_FC=1). Without ENCOVR the C26 skip keeps MatMul and weights stay fp16.
EXTRA=()
if [ -n "${ENCOVR:-}" ]; then
  EXTRA=(--quantization_overrides "$ENCOVR" --float_fallback)
  # encodings + FC fold (spark-W4I packing route). NOTE the two blocked variants:
  # W8_ALLOW_FC=0 (keep MatMul): quantizer expects out-channels (130560) AND the C26
  # skip collapses the constant-fed MatMul graph (Total Params 0); FC path packs with
  # in-channels (2048) but ctxgen validator wanted n | activation dims (head shape).
  export W8_ALLOW_FC=${W8_ALLOW_FC:-1}
fi
# HTPCFG=NOOPT_AUTO: generate a per-TAG opt_level=0 ext config (graph_names must name the
# TAG exactly, so batch builds cannot share one static json).
if [ "${HTPCFG:-}" = "NOOPT_AUTO" ]; then
  HTPCFG=$OUT/htp_ext_noopt.json
  cat > "$HTPCFG" <<EOF
{
  "devices": [
    { "device_id": 0, "core_id": [0], "core_type": 0,
      "soc_model": 43, "dsp_arch": "v73", "pd_session": "unsigned" }
  ],
  "graphs": [
    { "graph_names": ["$TAG"], "optimization_level": 0 }
  ]
}
EOF
  export HTPCFG_HACK=$OUT/host_cfg_noopt.json
  cat > "$HTPCFG_HACK" <<EOF
{
  "backend_extensions": {
    "shared_library_path": "/mnt/e/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang/libQnnHtpNetRunExtensions.so",
    "config_file_path": "$HTPCFG"
  }
}
EOF
  HTPCFG=$HTPCFG_HACK
fi
# NOENC=1: all wrapper patches (C21/C25/FIXUP4/5) active but ZERO quantization —
# discriminator between "wrapper poisons the layer" and "quantized tensors poison it".
if [ "${NOENC:-0}" = "1" ]; then
  QFLAGS=(--weights_bitwidth 16)
else
  QFLAGS=(--weights_bitwidth 8 --use_per_channel_quantization --keep_weights_quantized)
fi
python3 -u mcp5_93_conv_w8.py \
  --input_network $ONNX \
  --output_path $OUT/${TAG} \
  --float_bitwidth 16 --float_bias_bitwidth 16 \
  "${QFLAGS[@]}" --disable_qnn_op_config_validation \
  "${EXTRA[@]}" \
  > $OUT/conv.log 2>&1 || { echo CONV_FAIL; grep -a ERROR $OUT/conv.log | head -5; exit 1; }
grep -a "CONVERSION COMPLETE" $OUT/conv.log || { echo NO_COMPLETE; tail -5 $OUT/conv.log; exit 1; }
$SDK/bin/x86_64-linux-clang/qnn-context-binary-generator \
  --dlc_path $OUT/${TAG} \
  --backend $SDK/lib/x86_64-linux-clang/libQnnHtp.so \
  --config_file "${HTPCFG:-/mnt/e/MyLLM_exp/_repro/host_cfg_740.json}" \
  --binary_file ${TAG}_ctx --output_dir $OUT > $OUT/ctxgen.log 2>&1 \
  || { echo CTXGEN_FAIL; grep -a ERROR $OUT/ctxgen.log | head -5; exit 1; }
md5sum $OUT/${TAG}_ctx.bin
ls -la --block-size=M $OUT/${TAG}_ctx.bin | awk '{print $5, $9}'
cp $OUT/${TAG}_ctx.bin /mnt/e/MyLLM_exp/serve_dec/ && echo STAGED_${TAG}

#!/bin/bash
# [npu-line] G3 bisection round 2 (after FIXUP5-by-type [C28]): per-FC and per-group
# device probes to localize which quantized FC poisons the layer numerics.
RBD=/mnt/e/MyLLM_exp/_repro/rb
LOG=/mnt/e/MyLLM_exp/_repro/rb/ablate2.log
: > $LOG
run() {
  echo "==== $1 ONLY=$2 ====" >> $LOG
  bash $RBD/mcp5_93_ablate.sh "$1" "$2" >> $LOG 2>&1 || echo "BUILD_FAIL $1" >> $LOG
}
run w8abq2_l0 val_6
run w8abk2_l0 val_13
run w8abg2_l0 val_112
run w8attn_l0 "val_6,val_13,val_20,attn.o_proj.weight"
run w8mlp_l0  "val_112,val_114,val_115"
echo ALLDONE >> $LOG

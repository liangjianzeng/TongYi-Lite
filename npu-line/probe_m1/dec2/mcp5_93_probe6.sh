#!/bin/bash
# [npu-line] G3: device probes with fixed devprobe (ctx push + correct pull names).
RBD=/mnt/e/MyLLM_exp/_repro/rb
LOG=$RBD/probe6.log
: > $LOG
for TAG in w8nc640_l0 w8abq2_l0 w8abk2_l0 w8abg2_l0 w8attn_l0 w8mlp_l0; do
  echo "==== $TAG ====" >> $LOG
  CTXTAG=$TAG python3 -u $RBD/mcp5_93_l0_devprobe.py >> $LOG 2>&1
done
echo ALLDONE >> $LOG

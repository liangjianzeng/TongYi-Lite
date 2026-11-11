#!/bin/bash
# [npu-line] G3 decisive trio (device): w8none (wrapper, zero quant) vs w8e0 (full W8,
# HTP prepare opt_level=0) vs control nc640_l0. Full-w8 reference = w8nc640_l0 (known red).
# Decision table:
#   w8none green + w8e0 green  => poison = HTP prepare rewrite pass; bisect optimization_level 1/2 for workaround
#   w8none green + w8e0 red    => poison = converter quantizer rewrite (Cast/Convert/fold) at DLC level
#   w8none red                 => poison = wrapper patches (diff vs mcp5_92 line)
RBD=/mnt/e/MyLLM_exp/_repro/rb
LOG=$RBD/probe_decide.log
: > $LOG
for TAG in nc640_l0 w8none_l0 w8e0_l0; do
  echo "==== $TAG ====" >> $LOG
  CTXTAG=$TAG python3 -u $RBD/mcp5_93_l0_devprobe.py >> $LOG 2>&1
done
echo ALLDONE >> $LOG

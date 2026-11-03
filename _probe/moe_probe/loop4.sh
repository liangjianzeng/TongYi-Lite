#!/system/bin/sh
# round 4: 冷态定标 —— 先冷却 240s，再冷态跑 a_io4 与 g_read6 各一次（中间冷却 120s）
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=round4_progress.txt
rm -f $P
echo "[`date +%T`] cooldown 240s" >> $P
sleep 240

echo "[`date +%T`] == cold_a start" >> $P
LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 \
  ./minicpm_e2e $M $E 0 48 > run_cold_a.txt 2>&1
grep -a "e2e" run_cold_a.txt | tail -1 >> $P
echo "[`date +%T`] == cold_a done" >> $P

echo "[`date +%T`] cooldown 120s" >> $P
sleep 120

echo "[`date +%T`] == cold_read6 start" >> $P
LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 \
  ./minicpm_e2e $M $E 0 48 > run_cold_read6.txt 2>&1
grep -a "e2e" run_cold_read6.txt | tail -1 >> $P
echo "[`date +%T`] == cold_read6 done" >> $P

# 热敏证据：抓一次当前温控状态
dumpsys thermalservice 2>/dev/null | grep -a -m 4 -E "Temperature|mValue" >> $P
echo "[`date +%T`] ALL DONE" >> $P

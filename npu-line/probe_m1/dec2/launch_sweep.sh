cd /data/local/tmp/npu_m1 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/npu_m1/lib ADSP_LIBRARY_PATH=/data/local/tmp/npu_m1/lib
mkdir -p sweep
rm -f sweep/g_dev_h_*.raw
for g in A B C; do
  CHAIN_KEEP=1 ./chain_run5 manifest_sweep_$g 1 > cr5_sw_$g.log 2>&1
  echo "== $g: $(grep -ac CR5_DONE cr5_sw_$g.log) done $(grep -a CR5_FAIL cr5_sw_$g.log | head -1)"
done
ls sweep/g_dev_h_*.raw | wc -l

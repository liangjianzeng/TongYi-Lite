cd /data/local/tmp/npu_m1 || exit 1
export LD_LIBRARY_PATH=$PWD/lib ADSP_LIBRARY_PATH=$PWD/lib
mkdir -p chain_sweep
rm -f chain_sweep/g_ch_h_*.raw g_ch_hn.raw g_ch_lit0.raw
for g in A B C T; do
  CHAIN_KEEP=1 ./chain_run5 manifest_chsw_$g 1 > cr5_cs_$g.log 2>&1
  echo "== $g: $(grep -ac CR5_DONE cr5_cs_$g.log) $(grep -a CR5_FAIL cr5_cs_$g.log | grep -av 'open ' | head -1)"
done
ls chain_sweep/g_ch_h_*.raw | wc -l

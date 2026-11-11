cd /data/local/tmp/npu_m1 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/npu_m1/lib ADSP_LIBRARY_PATH=/data/local/tmp/npu_m1/lib
cp -f d2e_hs0.raw g_hs80.raw
CHAIN_KEEP=1 ./chain_run5 manifest_nc640_probe2 1

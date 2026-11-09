cd /mnt/e/MyLLM_exp/_repro
export LD_LIBRARY_PATH=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang:$LD_LIBRARY_PATH
export PYTHONIOENCODING=utf-8
export PYTHONPATH=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python
# [C19] QAIRT copy_weights_into_temp_dir writes ~8.4GB per run into tempfile.mkdtemp();
# default lands in WSL fs => ext4.vhdx on C: bloated to 114GB. Force ALL temps to E:.
mkdir -p /mnt/f/wsl_tmp
export TMPDIR=/mnt/f/wsl_tmp
export TEMP=/mnt/f/wsl_tmp
export TMP=/mnt/f/wsl_tmp
python3 -u run_conv_fixed.py --input_network /mnt/e/MyLLM_exp/spark_prefill_v4.onnx --output_path /mnt/e/MyLLM_exp/spark_v4_w4_qnn --float_bitwidth 16 --float_bias_bitwidth 16 --weights_bitwidth 4 --use_per_channel_quantization --input_list /mnt/e/MyLLM_exp/_repro/inlist.txt > /mnt/e/MyLLM_exp/_repro/w4f.log 2>&1; echo W4FRC=$?
tail -4 /mnt/e/MyLLM_exp/_repro/w4f.log
ls -la --block-size=M /mnt/e/MyLLM_exp/spark_v4_w4_qnn.bin 2>/dev/null
echo ===END===

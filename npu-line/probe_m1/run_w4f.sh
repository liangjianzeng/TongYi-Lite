cd /mnt/e/MyLLM_exp/_repro
export LD_LIBRARY_PATH=/mnt/e/MyLLM_exp/cppx/usr/lib/x86_64-linux-gnu:/mnt/d/MyLLM/qairt/2.44.0.260225/lib/x86_64-linux-clang:$LD_LIBRARY_PATH
export PYTHONIOENCODING=utf-8
export PYTHONPATH=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python
python3 -u run_conv_fixed.py --input_network /mnt/e/MyLLM_exp/spark_prefill_v4.onnx --output_path /mnt/e/MyLLM_exp/spark_v4_w4_qnn --float_bitwidth 16 --float_bias_bitwidth 16 --weights_bitwidth 4 --pack_4_bit_weights --use_per_channel_quantization --input_list /mnt/e/MyLLM_exp/_repro/inlist.txt > /mnt/e/MyLLM_exp/_repro/w4f.log 2>&1; echo W4FRC=$?
tail -4 /mnt/e/MyLLM_exp/_repro/w4f.log
ls -la --block-size=M /mnt/e/MyLLM_exp/spark_v4_w4_qnn.bin 2>/dev/null
echo ===END===

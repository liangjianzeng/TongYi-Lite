#!/bin/bash
ls -la /mnt/e/MyLLM_exp/spark_v3* 2>/dev/null
ps aux | grep onnx-converter | grep -v grep
free -g | head -2

@echo off
if not exist D:\MyLLM\models\spark-x26-4b mkdir D:\MyLLM\models\spark-x26-4b
curl -L --retry 3 -C - -o D:\MyLLM\models\spark-x26-4b\Spark-X2.6-4B-Q4_K_M.gguf https://hf-mirror.com/bartowski/Spark-X2.6-4B-GGUF/resolve/main/Spark-X2.6-4B-Q4_K_M.gguf > D:\MyLLM\models\spark-x26-4b\dl_gguf.log 2>&1
echo DONE_CODE=%ERRORLEVEL% >> D:\MyLLM\models\spark-x26-4b\dl_gguf.log

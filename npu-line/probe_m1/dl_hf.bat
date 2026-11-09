@echo off
set BASE=https://hf-mirror.com/XHToken/Spark-X2.6-4B/resolve/main
set OUT=D:\MyLLM\models\spark-x26-4b\hf
if not exist %OUT% mkdir %OUT%
for %%F in (config.json generation_config.json model.safetensors.index.json tokenizer.json tokenizer_config.json special_tokens_map.json vocab.json merges.txt chat_template.jinja) do (
  if not exist %OUT%\%%F curl -L --retry 3 -s -o %OUT%\%%F %BASE%/%%F
)
for %%N in (1 2 3 4 5) do (
  if not exist %OUT%\model-0000%%N-of-00005.safetensors curl -L --retry 3 -C - -s -o %OUT%\model-0000%%N-of-00005.safetensors %BASE%/model-0000%%N-of-00005.safetensors
)
echo DONE_CODE=%ERRORLEVEL% > D:\MyLLM\models\spark-x26-4b\dl_hf_done.txt

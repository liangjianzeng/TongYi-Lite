#!/bin/bash
echo "=== whoami ==="
whoami
echo "=== python3 ==="
which python3; python3 --version
python3 -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())" 2>&1 | tail -2
python3 -c "import transformers; print('transformers', transformers.__version__)" 2>&1 | tail -1
python3 -c "import onnx; print('onnx', onnx.__version__)" 2>&1 | tail -1
python3 -c "import onnxsim; print('onnxsim ok')" 2>&1 | tail -1
python3 -c "import onnxruntime; print('ort', onnxruntime.__version__)" 2>&1 | tail -1
echo "=== model dir ==="
ls /mnt/d/MyLLM/models/spark-x26-4b/hf/ 2>/dev/null | head
echo "=== qairt ==="
ls /mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang/ 2>/dev/null | grep -E "converter|generator|net-run|context" | head
echo "=== ndk ==="
ls ~/m4/android-ndk-r27c/toolchains/llvm/prebuilt/ 2>/dev/null
echo "=== mem ==="
free -g | head -2
nvidia-smi --query-gpu=name,memory.total --format=csv 2>/dev/null | head -3

#!/bin/bash
C=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters
grep -n "ReduceMean\|class OnnxReduce" $C/onnx/onnx_translations.py | head -10
echo =====
awk '/class OnnxReduceMeanTranslation/,/register_translation/' $C/onnx/onnx_translations.py | head -60

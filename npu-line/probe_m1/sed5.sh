#!/bin/bash
C=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters
sed -n '1890,1995p' $C/onnx/math_translations.py

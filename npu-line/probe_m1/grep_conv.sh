#!/bin/bash
C=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters
grep -n "interpreted at conversion time" -r $C | head -5
echo =====
grep -n "class TransposeTranslation" -r $C | head
echo =====
grep -rn "def transpose" $C/qnn_backend/qnn_translations.py | head
echo ===== cast =====
grep -n "Only numerical type cast" -r $C | head -3

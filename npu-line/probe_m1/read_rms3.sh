#!/bin/bash
F=/mnt/d/MyLLM/qairt/2.44.0.260225/lib/python/qti/aisw/converters/common/converter_ir/op_graph_optimizations.py
grep -n "def match_base_rms_norm\|def match_no_beta\|def match_reciprocal\|def match_rms_with_gamma\|def match_no_affine" $F

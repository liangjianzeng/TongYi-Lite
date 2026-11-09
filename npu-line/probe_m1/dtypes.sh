#!/bin/bash
grep -nE "0x0[0-9a-fA-F]{3}" /mnt/d/MyLLM/qairt/2.44.0.260225/include/QNN/QnnTypes.h | head -50

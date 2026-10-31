#!/bin/bash
find /mnt/d/MyLLM/qairt/2.44.0.260225/include -iname "*datatypes*" -o -iname "QnnTypes.h" 2>/dev/null | head
ls /mnt/d/MyLLM/qairt/2.44.0.260225/include/ 2>/dev/null
ls /mnt/d/MyLLM/qairt/2.44.0.260225/include/QNN 2>/dev/null | head -30

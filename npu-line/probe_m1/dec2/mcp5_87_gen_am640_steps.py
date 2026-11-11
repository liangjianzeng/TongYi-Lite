#!/usr/bin/env python3
# [npu-line] Per-step amask files for the NC=640 decode chain (protocol validated by 86
# ORT replay, 8/8 cos 1.0000): roll = drop-oldest+append puts the 128 zero-pad rows at
# cache rows [512-t .. 639-t] at step t; those attention columns get -1e4. New-token
# column 640 and real rows stay 0. File g_am640_t{t}.raw, 641 fp16 each.
import numpy as np

ST = "/mnt/e/wsl_stage"
NEG = np.float16(-1e4)
for t in range(8):
    am = np.zeros(641, np.float16)
    am[512 - t:640 - t] = NEG
    am.tofile(f"{ST}/g_am640_t{t}.raw")
print("AM640_STEPS_DONE")

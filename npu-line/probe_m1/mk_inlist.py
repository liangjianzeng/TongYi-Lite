import numpy as np, random
random.seed(7)
for i in range(3):
    ids = np.array([random.randint(0, 131071) for _ in range(512)], dtype=np.int32)
    ids.tofile('/mnt/e/MyLLM_exp/_repro/calib_%d.raw' % i)

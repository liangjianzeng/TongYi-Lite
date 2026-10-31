import torch, time
for dt in (torch.float16, torch.float32):
    a = torch.randn(512, 2560, dtype=dt)
    b = torch.randn(2560, 10240, dtype=dt)
    t = time.time(); c = a @ b; el = time.time() - t
    print(dt, 'matmul 512x2560x10240:', round(el, 3), 's ->', round((2*512*2560*10240/el)/1e9, 1), 'GFLOPS')

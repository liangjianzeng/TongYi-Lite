import torch
x = torch.randn(4, 8).half()
tests = {
    'max': lambda: x.max(-1, keepdim=True).values,
    'sub': lambda: x - x.max(-1, keepdim=True).values,
    'exp': lambda: torch.exp(x - x.max(-1, keepdim=True).values),
    'div': lambda: torch.exp(x) / torch.exp(x).sum(-1, keepdim=True),
    'pow2': lambda: x.pow(2),
    'mean': lambda: x.pow(2).mean(-1, keepdim=True),
    'rsqrt': lambda: torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + 1e-6),
    'sigmoid': lambda: torch.sigmoid(x),
    'softmaxF': lambda: torch.nn.functional.softmax(x, -1),
}
for k, f in tests.items():
    try:
        print(k, '->', f().dtype)
    except Exception as e:
        print(k, '-> ERROR', str(e)[:90])

# rope math pattern check: mul with fp16 const, cat, neg
c = torch.randn(4, 8).half()
print('mul_const', (x * c).dtype)
print('cat', torch.cat((-x[..., :4], x[..., 4:]), -1).dtype)

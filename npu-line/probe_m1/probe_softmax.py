import torch
for shape in [(1,4,2048,512),(1,4,2048,256),(4,512),(1,16,512,256),(4,8)]:
    x = torch.randn(*shape).half()
    y = torch.nn.functional.softmax(x, -1)
    # manual
    mx = x.max(-1, keepdim=True).values
    ex = torch.exp(x - mx)
    p = ex / ex.sum(-1, keepdim=True)
    print(shape, 'F.softmax:', y.dtype, 'manual:', p.dtype)

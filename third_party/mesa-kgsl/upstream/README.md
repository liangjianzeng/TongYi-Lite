# upstream 参照包

- `libdrm-2.4.126.tar.xz` —— freedesktop.org/libdrm 2.4.126 原包（487 KB）。
  为什么入库：在机那颗 `libdrm_freedreno.so.1.126.0` 就是这个版本，而它的
  `freedreno/kgsl/kgsl_ringbuffer.c` 是**唯一能白拿的 kgsl 提交层参照实现**（P2 的读码底本，
  §5.1 的四条实读结论由它给出：单 ibdesc / 不支持 fence / 环不能 grow）。
  fork 自己的 `src/freedreno/drm/kgsl/*` 到手（P0-1）之前，所有"提交层该怎么写"的判断
  都先对着这份对齐，别凭记忆。
- 用法：`tar -xJf libdrm-2.4.126.tar.xz && less libdrm-2.4.126/freedreno/kgsl/kgsl_ringbuffer.c`

sha256: 6cab16d4d259b6abc9f485233863454114a3c307eca806679aad3edbe967bf42

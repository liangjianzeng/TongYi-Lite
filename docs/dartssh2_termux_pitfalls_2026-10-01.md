# dartssh2 fork + Termux sshd 的坑：排查定案与修复记录（2026-10-01）

> 背景：Dev Agent 真机验证阶段，dartssh2 fork 连手机 Termux（openssh 10.5 sshd）
> 长期"测试连接成功但真实执行失败/无响应"。本文总结全链路打通前踩到的每一层坑，
> 供后续 SSH 相关开发与排障直接对照。
>
> 终局验证：dartssh2 fork ↔ openssh 10.5 完整 KEX/认证/命令执行全通；
> `ssh-keygen -y` 可解析向导生成密钥；全量回归 402 项 + 2 skip 全绿。

## TL;DR

1. **"连上 sshd 但无响应"（不发 banner）≠ 网络或客户端 bug**——OpenSSH 10.x 默认
   开启 per-source penalty（按源 IP 的内存态惩罚），被罚的源连 TCP 都能 accept
   就是不回话；且**反复探测会续罚**，等几分钟未必过期。重启 sshd 即清零。
2. **认证被拒先验"authorized_keys 里的公钥行是否合法"**——我们向导生成的公钥
   少了 4 字节内层长度前缀，sshd 解析不了这行，当然拒。生成器与解析器自洽
   （app 内自测能过）不等于格式正确。
3. **自研编码格式必须拿 `ssh-keygen -y` 验收**——三个结构性偏差（checkint 长度、
   padding 值、PEM 尾换行）全是逐字节对比官方密钥才抓出来的，单测断言钉死了
   坏格式反而成了遮羞布。

## 一、Termux 侧的坑（openssh 10.5 sshd）

### 1.1 PerSourcePenalties：被罚的 sshd"活着但装死"

OpenSSH 9.8+ 默认 `PerSourcePenalties yes`：按**源 IP** 在 sshd 内存里记惩罚，
认证失败（authfail）、未认证就断开（noauth）、子进程崩溃（crash）等各记不同分值，
被罚期间新连接**接受 TCP 但不发送任何字节**。

- 表现：`socket.create_connection` 成功 → `recv` 20s 超时，`ps` 看 sshd 活着、
  `/proc/net/tcp` 有 `:1F56` LISTEN，一切正常唯独不说话。
- **手机场景所有连接的源都是 127.0.0.1**：adb forward 过去的连接（adbd 代连）
  和手机本机 `nc 127.0.0.1 8022` 在 sshd 眼里是同一个源——一台设备被罚 = 全部通道被罚。
- **反复探测会续罚**：authfail 单次 5s、上限 5 倍，crash 单次 90s、上限 5×90=450s；
  罚期内每一次被拒的探测都可能再记 noauth。所以"等 1-2 分钟再试"常常等不出来。
- **重启 sshd 即清零**（惩罚在内存里）。Termux 无 root 情况下的重启办法：
  ```
  adb shell am force-stop com.termux          # 连同 sshd 一起杀
  adb shell am start -n com.termux/.app.TermuxActivity
  # 等 shell 就绪（5-6s），然后注入：input text sshd; input keyevent 66
  ```
- 排障纪律：**别用连接探测轰炸被罚的 sshd**；每失败一轮先重启 sshd 再测下一假设。
  判别"是不是 penalty"换源 IP 对照（我们最终用"重启后 banner 秒回"实锤）。

### 1.2 用户名不是随便填的

Termux sshd 的登录用户名 = Termux 内 `whoami` 的输出，即 `u0_aXXX`
（`dumpsys package com.termux` 里 userId 10333 → `u0_a333`）。复现测试曾写死
别的设备的 `u0_a326`，这本身就是一个独立失败源。

### 1.3 存储与取证：adb 看不见 Termux 的家目录

- Termux home（`/data/data/com.termux/files/home`）在 app 私有沙箱里，**adb shell
  （uid 2000）既读不了也写不了**，`run-as` 也不行（Termux 非 debuggable）。
- Termux 默认**没有存储授权**，往 `/sdcard` 根写文件会静默失败——让 Termux 导出
  信息前先授全文件访问：
  ```
  adb shell appops set com.termux MANAGE_EXTERNAL_STORAGE allow
  ```
  之后在 Termux 里 `cat ~/.ssh/authorized_keys > /sdcard/ty.txt`，再用 adb 读
  `/sdcard/ty.txt`，即可完成"手机侧 ground truth"取证。
- `uiautomator dump` **读不到 Termux 终端文本**（终端自绘，text 全空），
  只能看到 extra-keys 软键盘行——终端里发生了什么只能靠文件导出间接验证。
- 往 Termux 注入命令（`input text` + `input keyevent 66`）的实操要点：
  - 冷启动后 **等 5-6 秒**再注入，太早字符会被丢；先按一次 ENTER 清掉半行更稳；
  - `input text` 里空格用 `%s`；长命令一条一条注入，别拼太长；
  - 注意 `cat ~/.ssh/...` 这类路径如果跑在 adb shell 身份下看到的是 adb 的 `~`
    （报 `No such file`），不是 Termux 的。

### 1.4 无线 adb 的 forward 会"看着在、实际断"

无线 adb（`connect <ip>:5555`）瞬断重连后，`adb forward --list` 里转发规则
**可能仍然显示存在**，但连本地端口直接 `ECONNREFUSED`。排障时先
`adb forward --remove tcp:18022 && adb forward tcp:18022 tcp:8022` 重建再测，
别被列表骗了。

## 二、dartssh2 fork / SshKeyGen 的坑（openssh-key-v1 编码）

四处在 `lib/agent/dev/ssh/ssh_credentials.dart`（生成端）与
`third_party/dartssh2/lib/src/ssh_key_pair.dart`（解析端），全部已修复。

### 2.1 checkint = 两个相同的 uint32，不是 uint64×2

openssh-key-v1 私钥段开头是 **两个 4 字节 checkint，值必须相等**（官方 sshkey.c
`buffer_get_int ×2`）。我们生成端曾写 `_u64(check) ×2`（16 字节），随后把 fork
解析端改成 `readUint64 ×2` 去"修"官方密钥报 Invalid private key 的问题——
**修错了层**：

- 生成器（16B）+ 解析器（16B）自洽 → app 内测试连接能过，掩盖了问题；
- 对官方密钥（8B）和 `ssh-keygen` 全部错位拒收；
- 最讽刺的证据：**fork 自己的 encode 端写的就是 `writeUint32 ×2`**（正确格式），
  decode 端却被改成 uint64，自相矛盾。

教训：改协议解析先读规范/官方源码，再看"自测为什么能过"——自洽的坏格式
比明显报错更隐蔽。

### 2.2 padding 字节必须 = 1,2,3,…N

私钥段末尾 padding 填充到 8 字节块，**第 i 字节的值 = i+1**（如 5 字节 padding =
`01 02 03 04 05`），且总长至少 1 字节。我们曾填常量 `padLen`（如 `05 05 05 05 05`），
新版 OpenSSH 逐字节校验，不合规直接拒。

### 2.3 公钥单行（authorized_keys 格式）少内层长度前缀

authorized_keys 每行的 blob = `string(type) + string(pubkey)`，
ed25519 = 4 + 11 + 4 + 32 = **51 字节**。我们曾 `b.add(pub)` 裸拼 32 字节公钥
（47 字节坏 blob），sshd 解析这行失败 → **publickey 认证必然被拒**。
这是整条链路里认证失败的直接根因。注意区分：私钥文件里内嵌的 pub blob 是
另用 `_writeString` 构造的（一直是对的），坏的只是 `.pub` 单行编码——
两处长得像，别改了一处就当全对。

### 2.4 PEM 末尾必须有换行符

`-----END OPENSSH PRIVATE KEY-----` 后没有 `\n` 时，OpenSSH 10.3p1 + OpenSSL 3.5
的 ssh-keygen 报：

```
Load key "xxx.pem": error in libcrypto: unsupported
  debug1: libcrypto: 'error:1E08010C:DECODER routines::unsupported:...
```

错误文案完全不指向"缺换行"。加一个尾换行立即通过。**生成 PEM 类文件一律以
换行结尾**。

### 2.5 单元测试可能把 bug 钉死成断言

修复前 `settings_service_test` 里有断言"公钥 blob 解码 47 字节"——把坏格式写成了
期望值，回归永远绿。改协议编码时，测试断言要对照**官方格式**重审，而不是对照
旧实现。

## 三、验收工具链（照抄即用）

```bash
# 1. 密钥格式验收：ssh-keygen 能提取且与 .pub 逐字一致
ssh-keygen -y -f build/ssh_repro_key.pem
diff <(ssh-keygen -y -f key.pem) <(cat key.pub)

# 2. 与官方密钥逐字段结构对比（python 解 openssh-key-v1）
#    核对：privlen(136)、checkint 相等、type/pub64/pad=0102..N、无尾部冗余

# 3. 服务器侧无响应判别：banner 抓取（6s 足够判定）
python -c "import socket;s=socket.create_connection(('127.0.0.1',18022),timeout=6);print(s.recv(64))"

# 4. 真机端到端：完整 KEX + 认证 + 执行（dartssh2 fork）
#    临时测试用后即删；复现密钥留存 build/ssh_repro_key.pem/.pub
```

排障顺序建议：**tcp 通不通 → banner 有没有（无 = penalty/装死，重启 sshd）→
握手到哪一步（dartssh2 printDebug 全开）→ 认证失败 = 查 authorized_keys 行合法性
与用户名 → 全通后查命令执行**。

## 四、对产品的影响与后续

- 向导/测试连接此前"能过"是坏格式自洽 + 未真正跨过认证造成的假象；本次修复后
  生成的密钥与 OpenSSH 全工具链互通。
- **旧向导生成的持久化密钥仍是坏格式**（私钥 + 已装到手机 authorized_keys 的坏
  公钥行）：受影响用户重跑一次"自动配置向导"即可（会重新生成并覆盖安装）；
  可考虑后续在加载配置时校验私钥格式、失配自动提示重生成。
- penalty 对正常使用影响有限（认证首试即成不记分），但 **App 端重连逻辑不要
  无间隔轰炸重试**，失败后至少退避数秒，避免自己把 127.0.0.1 罚成装死。

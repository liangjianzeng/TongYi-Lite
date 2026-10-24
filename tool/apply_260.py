#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Land map 20.45 (on-device battery: env-word trap + detach from adb) and update G-780 instrument."""
import io

MAP = 'docs/全GPU卸载_架构全景地图_2026-10-21.md'
GRID = 'docs/Mesa与Vulkan线_架构问题网格_2026-10-21.md'

SECTION = u'''

### 20.45 采集能力的地基：**腿必须脱离 adb 活着**，以及我自己踩的两个自伤坑 🟪

设备事实先摆出来：K40 每次重连只给 **20~60 秒** adbd 寿命，而九条腿要 **8~10 分钟**。
⇒ 只要腿是 `adb shell` 的子进程，**adbd 一死它们就跟着一起死**；这不是稳定性优化，是能不能拿到数据的前提。
本轮把工装改成：主机 `nohup sh k40_battery_device.sh &` **点火后 1 秒返回**，腿在手机里自己跑完；
结果写**固定名** `$G/k40_battery_latest.txt` 逐腿追加，主机任何时候 `FETCH_ONLY=1` 单独取，
**掉线不丢已完成的腿**（跑完再存一份时间戳副本）。

同一轮里我自己写的工装连绊自己两次，都值得记死，因为两者都会产出**看着像数据的空数据**：

**坑一：变量展开出来的 `NAME=value` 不是赋值词。** 设备内脚本写 `BASE="LD_LIBRARY_PATH=… HOME=… …"`，
再写 `env` 之前漏了 `env`：`$X $BASE timeout 1200 $BIN …` —— POSIX sh 里**赋值词是在展开之前按语法识别的**，
从变量里展开出来的 `LD_LIBRARY_PATH=…` 会被当成**要执行的命令名**。后果：**九条腿共用同一秒、日志全空、
`plat=0 err=0 ops=0`**，而且 `grep -ic error:` 还是 0（错误行是 `…: not found`，不含 `error:`）——
差点被读成"九条腿都跑了但 GPU 什么都没干"。**修法**：显式走 `env`；并加**进程没起来就作废**的机检
（日志 `<200 B` 直接判废并把首行打出来，让 `not found` 自己现形）。
> 顺带说明为什么主机版以前"能跑"：主机 bash 先把 `$P` 展开成字面量，设备 shell 看到的是字面赋值 ——
> **同一段文本在两层 shell 里语义不同**，这是这类"push 脚本到安卓上跑"最典型的暗坑。

**坑二（上一节已记，这里补全）：作废条件用了跨算法的指纹** —— 文本用 `sha256sum` 算，判据拿 **sha1 空串**
`da39a3ee5e…` 去比，于是 adbd 掉线造成的"三条文本全空、三个 hash 全等"没被拦住。真指纹是
**sha256 空串 `e3b0c44298fc1c14…`**，已改为同算法比对。**规矩：作废判据必须与被检对象同算法同口径；
"两个不同来源的相等"永远要问一句它们是不是都等于空。**

**通用结论（写进采集纪律）**：一条腿的有效性的最低证明是**四件结构字段 + 进程真起来过**
（`selected platform` / `splits` / `offloaded` / `tok_s` + 日志字节数量级），缺任一条当场作废并打印死因首行；
"跑得快"（0 秒）本身就是一种死法，不是成功。
'''


def main():
    s = io.open(MAP, encoding='utf-8').read()
    assert u'20.45 采集能力的地基' not in s, u'20.45 已存在'
    io.open(MAP, 'w', encoding='utf-8').write(s.rstrip('\n') + '\n' + SECTION)
    print(u'地图：20.45 已追加')

    g = io.open(GRID, encoding='utf-8').read()
    old = u'（push/执行/补取），日志在设备上落盘，掉线不丢已完成腿（§20.44）**'
    assert g.count(old) == 1
    new = (u'（push/点火/取结果）；**又根治两刀：腿必须 `nohup` 脱离 adb（这些机器每次重连只给 20~60 秒，'
           u'九条腿要 8~10 分钟 ⇒ 腿是 adb 子进程就等于必死），结果写固定名逐腿追加、任何时候 `FETCH_ONLY=1` 取；'
           u'以及 `$BASE` 展开的 `NAME=value` 被当命令名 ⇒ 九条腿 0 秒空转还 `err=0`，已改 `env` 注入 + '
           u'"日志 <200B 即作废并打首行"机检（§20.44/§20.45）**')
    io.open(GRID, 'w', encoding='utf-8').write(g.replace(old, new))
    print(u'网格：G-780 仪器口径已更新')


if __name__ == '__main__':
    main()

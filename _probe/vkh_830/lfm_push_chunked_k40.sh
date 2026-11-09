#!/usr/bin/env bash
# [vkh R-108] Chunked, throttled, resumable LFM push ONTO the K40 — queue 7b（pull 枪的镜像）。
#
# 为什么不用 `adb push`，也不用 dd seek 定位写：
#   * `adb push` 13.58 GB 单流 = 无续跑、无限速、无热闸，违反 R-090（>1GB 设备搬运一律分块+限速）；
#     tailscale/USB doze 型掉线一次就几十 GB 白费，还把设备压在持续 I/O 上。
#   * 设备侧 `dd of=.part seek=N` 会造**稀疏文件**：`.part` 的 st_size 等于 seek+写入长度，
#     于是"已落多少字节"这个续跑对账基准开始说谎（第 5 块写完、前 4 块没写，尺寸照样像整件）。
#     ⇒ 本枪**严格顺序 append**（`cat >>`），`.part` 尺寸 == 已连续落盘字节数，可直接对账。
# 纪律：绝不动屏幕（无 svc power / 无 KEYCODE_*，R-101）；热闸默认 400（比性能腿 440 更严，
# 传输腿纯 I/O 发热无测量价值）；只写 .part，全闸通过才 rename 成正式件 + .ok 哨兵。
# K40 属**正确性轨**：只落盘 + 双端校验，不在 K40 跑性能；sha256 对同一枚源站权威值留证后才许喂 B2。
#
# Verdict lines:  #### LFMPUSH_START|RESUME|TRUNCATE|CHUNK|VERIFY|VERDICT …   exit 0 ok, 非 0 = abort
set -u

DEV="${DEV:-adb -P 15037 -s <redacted-serial-k40>}"                  # K40（USB，私有 server 15037）
SRC="${SRC:-/home/jianzengliang/MyWork/TongYi-Lite/.modelxfer/lfm2.5-24b-a2b-q4_0.gguf}"
DST="${DST:-/data/local/tmp/lfmb2/lfm2.5-24b-a2b-q4_0.gguf}"   # 父裁：新辟专用 arena
DTEMP="${DTEMP:-/data/local/tmp/lfmb2/.chunk.tmp}"             # 块临时件（裸字节过 adb push，不经 PTY）
PART_EARLY=1                                                   # 下方 PART 提前定义（哑火 #20：set -u 下 dsize() 早期引用 $PART）
PART="${DST}.part"
EXPECT_SIZE="${EXPECT_SIZE:-13578190880}"
EXPECT_MD5="${EXPECT_MD5:-}"                            # 源站无 md5 ⇒ 只作 host/device 双向交叉
# [权威谱系 R-111 父裁一] 权威 = **官方整包 QAD-Q4_0 双端一致记录**（docs/lfm25-24b-a2b-q40-moe-
# smart-loading-eval-2026-10-15.md:233-235；13,578,190,880 B / sha256 d1c03f73…f8a5 双端一致；
# K90 方案 C 验收 + 740 b2_cpu 正常正文在前；GGUF 自报 general.name=LFM2.5-24B-A2B-QAD-Q4_0）。
# 旧值 b346311324dc…ec115 = hf-mirror 对 **Q4_0**（非 QAD）路径的 ETag ⇒ **错套作废留档**。
# 换权威须父裁并在此追加谱系；B2 金标闸随同一枚（见 b2_cpu_gold_k40.sh）。
EXPECT_SHA256="${EXPECT_SHA256:-d1c03f73ecaf61017d70419eec9e5dc0b05d50ae26c23d522829b934fbabf8a5}"
CHUNK="${CHUNK:-$((64 * 1024 * 1024))}"
SLEEP="${SLEEP:-0.5}"
THERMAL_MAX="${THERMAL_MAX:-400}"
HASH_CHUNKS="${HASH_CHUNKS:-0}"
RETRIES="${RETRIES:-3}"
DRY_RUN="${DRY_RUN:-0}"
SELFTEST="${SELFTEST:-0}"                               # 1 = "设备"换成本地目录，全路径离线自测
WORK="${WORK:-/tmp/lfmpush_work}"

dsize() {
    # 自测模式里没有 rename（.part 就是"设备落盘件"），必须 stat .part；
    # 上一版在这里 stat 永不转正的 $DST ⇒ device_size=na ⇒ 四案被 size_device 误杀（自测抓到，哑火 #14）。
    if [ "$SELFTEST" = 1 ]; then
        if [ -f "$DST" ]; then stat -c%s "$DST" 2>/dev/null; else stat -c%s "$PART" 2>/dev/null; fi
    else
        # [哑火 #19 2026-10-28] 真腿分支同病：终局校验发生在 rename **之前**，设备上的件是 .part，
        # 只 stat 永不存在的 $DST ⇒ device_size=na ⇒ size_device 误杀（真件排练抓到，自测分支当年已修、真腿分支漏修）。
        local _s
        _s=$($DEV shell "stat -c %s '$DST' 2>/dev/null" 2>/dev/null | tr -dc "0-9")
        [ -n "$_s" ] || _s=$($DEV shell "stat -c %s '$PART' 2>/dev/null" 2>/dev/null | tr -dc "0-9")
        echo "$_s"
    fi
}
dpart() {
    if [ "$SELFTEST" = 1 ]; then stat -c%s "$PART" 2>/dev/null; else
        $DEV shell "stat -c %s '$PART' 2>/dev/null" 2>/dev/null | tr -dc "0-9"
    fi
}
dbat() {
    [ "$SELFTEST" = 1 ] && { echo "${FAKE_BATT:-250}"; return; }
    $DEV shell 'dumpsys battery 2>/dev/null | grep -m1 temperature' 2>/dev/null | tr -dc "0-9"
}
# 把 host 侧第 n 块 append 到设备 .part；回来必须核对尺寸恰好长 cnt 字节
push_chunk() {  # $1=off $2=期望落盘后总长
    local off="$1" want="$2" cnt n tmp
    cnt=$(( (SIZE - off) < CHUNK ? (SIZE - off) : CHUNK ))
    n=$(( off / CHUNK ))
    tmp="$WORK/chunk.$$"
    mkdir -p "$WORK"
    dd if="$SRC" bs=$CHUNK skip=$n count=1 status=none > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    [ "$(stat -c%s "$tmp")" = "$cnt" ] || { rm -f "$tmp"; return 1; }
    if [ "$SELFTEST" = 1 ]; then
        cat "$tmp" >> "$PART"
    else
        # [哑火 #18 2026-10-28] adb **没有 exec-in 子命令**（首射真腿块 1 三连败，落 0 字节即证）；
        # 且二进制绝不许过 adb shell 的 PTY（\n→\r\n 翻译会把件改成哑弹，比崩更难查）。
        # 正确姿势：adb push 裸字节块 → **设备侧自己** cat >> 追加（字节全程不经 PTY），
        # 追加后仍由 dpart 尺寸闸 + 每 16 块 md5 双向交叉兜底。
        $DEV shell "mkdir -p '$(dirname "$DTEMP")'" >/dev/null 2>&1
        $DEV push "$tmp" "$DTEMP" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
        $DEV shell "cat '$DTEMP' >> '$PART'" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
        $DEV shell "rm -f '$DTEMP'" >/dev/null 2>&1
    fi
    rm -f "$tmp"
    [ "$(dpart)" = "$want" ] || return 1
    if [ "$HASH_CHUNKS" = 1 ]; then
        local hm dm
        hm=$(md5sum "$WORK/../host_probe.$$" 2>/dev/null | cut -c1-32)   # 占位：由调用方不必提供
        hm=$(dd if="$SRC" bs=$CHUNK skip=$n count=1 status=none 2>/dev/null | md5sum | cut -c1-32)
        if [ "$SELFTEST" = 1 ]; then
            dm=$(dd if="$PART" bs=$CHUNK skip=$n count=1 status=none 2>/dev/null | md5sum | cut -c1-32)
        else
            dm=$($DEV shell "dd if='$PART' bs=$CHUNK skip=$n count=1 status=none | md5sum" 2>/dev/null | cut -c1-32)
        fi
        [ "$hm" = "$dm" ] || { echo "#### LFMPUSH_CHUNK_HASH_FAIL offset=$off"; return 1; }
    fi
    return 0
}

[ -f "$SRC" ] || { echo "#### LFMPUSH_ABORT reason=no_src src=$SRC"; exit 3; }
SIZE=$(stat -c%s "$SRC")
if [ "$SIZE" != "$EXPECT_SIZE" ]; then
    echo "#### LFMPUSH_ABORT reason=size_src src=$SIZE expect=$EXPECT_SIZE"; exit 4
fi
if [ "$SELFTEST" != 1 ]; then
    DS=$(dsize)
    # [哑火 #23 2026-10-28] 哨兵在**设备**上，检查也必须在设备上做：上一版在 host 侧 `test -f` 一个设备路径
    # ⇒ 恒假 ⇒ ALREADY_OK 永不触发 ⇒ 重跑白推整件 13.58 GB。且旧日志写着"复算 sha 后再决定"却根本没复算。
    # 这次真复算（13.58 GB 设备侧 sha256 ≈ 3-4 分钟，值）：哨兵 + 尺寸 + sha 三闸齐过才认，任一不符即从零重推。
    MK="${DST}.ok"
    MKOK=$($DEV shell "[ -f '$MK' ] && echo 1 || echo 0" 2>/dev/null | tr -dc "0-1")
    if [ "${MKOK:-0}" = 1 ] && [ "${DS:-}" = "$EXPECT_SIZE" ]; then
        RSSH=$($DEV shell "sha256sum '$DST'" 2>/dev/null | cut -c1-64 | tr -dc "0-9a-f")
        if [ "${RSSH:-}" = "$EXPECT_SHA256" ]; then
            echo "#### LFMPUSH_ALREADY_OK device_size=$DS sha256=$RSSH (哨兵+尺寸+权威 sha 三闸皆过，不重推)"; exit 0
        fi
        echo "#### LFMPUSH_WARN marker_stale sha256=${RSSH:-na} want=$EXPECT_SHA256 ⇒ 不认哨兵，从零重推"
        $DEV shell "rm -f '$MK'" >/dev/null 2>&1
    fi
fi
PART="${DST}.part"   # [哑火 #20] 必须在任何 dsize()/dpart() 调用之前定义（set -u 下早期引用会炸"parameter not set"）
HAVE=$(dpart); HAVE=${HAVE:-0}
if [ "$HAVE" -gt "$SIZE" ]; then echo "#### LFMPUSH_ABORT reason=part_larger_than_src part=$HAVE"; exit 5; fi
if [ $(( HAVE % CHUNK )) != 0 ]; then
    # append 型 .part 的尾巴只可能来自**半块**（掉线），截回整块边界比 abort 更正确（13.58 GB 不重跑）。
    KEEP=$(( HAVE / CHUNK * CHUNK ))
    echo "#### LFMPUSH_TRUNCATE part=$HAVE 非 $CHUNK 整数倍 ⇒ 截回 $KEEP（掉线半块丢弃，前功不废）"
    if [ "$SELFTEST" = 1 ]; then truncate -s "$KEEP" "$PART"; else
        $DEV shell "truncate -s $KEEP '$PART'" >/dev/null 2>&1 || { echo "#### LFMPUSH_ABORT reason=truncate_failed"; exit 6; }
    fi
    HAVE=$KEEP
fi
B=$(dbat); [ -n "$B" ] || B=0
echo "#### LFMPUSH_START src=$SRC dst=$DST size=$SIZE chunk=$CHUNK sleep=$SLEEP resume_from=$HAVE batt=$B expect_md5=${EXPECT_MD5:-none} selftest=$SELFTEST"
if [ "$B" -gt "$THERMAL_MAX" ]; then echo "#### LFMPUSH_THERMAL_ABORT batt=$B max=$THERMAL_MAX 候温复再跑"; exit 7; fi
[ "$DRY_RUN" = 1 ] && { echo "#### LFMPUSH_DRYRUN chunks=$(( (SIZE + CHUNK - 1) / CHUNK )) 已核参数未推送"; exit 0; }

if [ "$SELFTEST" = 1 ]; then
    mkdir -p "$(dirname "$DST")"
else
    $DEV shell "mkdir -p \"$(dirname "$DST")\"" >/dev/null 2>&1
fi
off=$HAVE
[ "$HAVE" -gt 0 ] && echo "#### LFMPUSH_RESUME from=$HAVE ($(( HAVE / CHUNK ))/$(( (SIZE + CHUNK - 1) / CHUNK )) 块已在盘)"
while [ "$off" -lt "$SIZE" ]; do
    n=$(( off / CHUNK + 1 )); want=$(( off + ((SIZE - off) < CHUNK ? (SIZE - off) : CHUNK) ))
    ok=0; try=1
    while [ "$try" -le "$RETRIES" ]; do
        if push_chunk "$off" "$want"; then ok=1; break; fi
        echo "#### LFMPUSH_CHUNK_RETRY n=$n try=$try"; try=$((try + 1)); sleep 2
    done
    [ "$ok" = 1 ] || { echo "#### LFMPUSH_ABORT reason=chunk_failed n=$n offset=$off (已落 $off 字节可续跑)"; exit 8; }
    off=$want
    if [ $(( n % 16 )) = 0 ]; then
        B=$(dbat); [ -n "$B" ] || B=0
        echo "#### LFMPUSH_CHUNK n=$n done=$off pct=$(( off * 100 / SIZE )) batt=$B"
        if [ "$B" -gt "$THERMAL_MAX" ]; then echo "#### LFMPUSH_THERMAL_ABORT batt=$B max=$THERMAL_MAX 已落 $off 字节可续跑"; exit 7; fi
    fi
    sleep "$SLEEP"
done

HS=$(stat -c%s "$SRC"); HM=$(md5sum "$SRC" | cut -d' ' -f1)
DS=$(dsize)
if [ "$SELFTEST" = 1 ]; then
    DM=$(md5sum "$PART" 2>/dev/null | cut -d' ' -f1); DSHA=$(sha256sum "$PART" 2>/dev/null | cut -d' ' -f1)
else
    DM=$($DEV shell "md5sum '$PART'" 2>/dev/null | cut -c1-32)
    DSHA=$($DEV shell "sha256sum '$PART'" 2>/dev/null | cut -c1-64)
fi
echo "#### LFMPUSH_VERIFY host_size=$HS device_size=${DS:-na} expect_size=$EXPECT_SIZE host_md5=$HM device_md5=${DM:-na} expect_md5=${EXPECT_MD5:-none}"
echo "#### LFMPUSH_VERIFY_SHA device_sha256=${DSHA:-na} expect_sha256=$EXPECT_SHA256"
FAIL=0
[ "$HS" = "$EXPECT_SIZE" ] || { echo "#### LFMPUSH_FAIL size_src"; FAIL=1; }
[ "${DS:-}" = "$EXPECT_SIZE" ] || { echo "#### LFMPUSH_FAIL size_device"; FAIL=1; }
[ -z "$DM" ] && { echo "#### LFMPUSH_FAIL no_device_md5(掉线?) 件留 .part 可续"; exit 9; }
[ "$HM" = "$DM" ] || { echo "#### LFMPUSH_FAIL md5_cross host=$HM device=$DM"; FAIL=1; }
[ -n "$EXPECT_MD5" ] && { [ "$HM" = "$EXPECT_MD5" ] || { echo "#### LFMPUSH_FAIL md5_expect got=$HM want=$EXPECT_MD5"; FAIL=1; }; }
[ "$FAIL" = 0 ] || { echo "#### LFMPUSH_VERDICT PASS=no 件留在 .part 供验尸"; exit 10; }
if [ "${DSHA:-}" != "$EXPECT_SHA256" ]; then
    echo "#### LFMPUSH_FAIL sha256_authority got=${DSHA:-na} want=$EXPECT_SHA256"
    echo "#### LFMPUSH_DIAGNOSIS md5 双向交叉过而 K40 落盘件 sha 不符 ⇒ K40 落盘被污/源件本身坏；**禁喂 B2 CPU 金标**，halt 候父"
    echo "#### LFMPUSH_VERDICT PASS=no 件留在 .part（不许转正）"; exit 11
fi
echo "#### LFMPUSH_SHA_GATE ok=K40 落盘件对撞源站背书 sha256 通过（B2 金标解锁条件之一）"
if [ "$SELFTEST" != 1 ]; then $DEV shell "mv -f '$PART' '$DST'" >/dev/null 2>&1 || { echo "#### LFMPUSH_FAIL rename"; exit 12; }; fi
# [哑火 #23] 哨兵必须落在**设备上、与件同目录**（随件走，供取证）。上一版写 `printf … > "${DST}.ok"`，
# 而 $DST 是设备路径、重定向发生在 host ⇒ 写进 host 的 /data/local/… 被权限静默拒绝 ⇒ 设备上永无哨兵。
MK="${DST}.ok"
MKTMP="$WORK/dst.ok.$$"
mkdir -p "$WORK"
printf 'size=%s\nmd5=%s\nsha256=%s\nsrc=%s\npushed_at=%s\n' "$HS" "$HM" "$DSHA" "$SRC" "$(date -Is)" > "$MKTMP"
if [ "$SELFTEST" = 1 ]; then
    cp -f "$MKTMP" "${DST}.ok" || echo "#### LFMPUSH_WARN marker_failed (local selftest)"
else
    $DEV push "$MKTMP" "$MK" >/dev/null 2>&1 || echo "#### LFMPUSH_WARN marker_failed path=$MK (件本体已验，仅下次会白推)"
fi
rm -f "$MKTMP"
[ "$SELFTEST" != 1 ] && { MKCHK=$($DEV shell "[ -f '$MK' ] && echo 1 || echo 0" 2>/dev/null | tr -dc "0-1"); echo "#### LFMPUSH_MARKER path=$MK present=${MKCHK:-0}"; }
echo "#### LFMPUSH_VERDICT PASS=yes size=$HS md5=$HM sha256=$DSHA path=$DST"

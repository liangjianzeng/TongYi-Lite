#!/usr/bin/env bash
# [vkh 2026-10-28] Chunked, throttled, resumable LFM pull off the 740 — queue item 7.
#
# Why this exists: the last whole-file pull of the 13.58GB LFM dropped mid-flight when the device
# node went quiet. The "my pull crushed the device" charge has since been cleared (the node's own
# network went rx=0), but a single 13.58GB `adb pull` still has three real defects:
#   1. no resume — one drop costs the whole transfer;
#   2. no throttle — full-speed adb saturates the device and heats it while perf legs are pending;
#   3. no independent verification — trust depends on the transport, not on the bytes on disk.
# So: pull in fixed chunks, verify each chunk's byte count, hash-verify the whole file on BOTH
# sides at the end, and assert the size the parent dictated (13578190880).
#
# Discipline baked in:
#   * NEVER touches the screen: no svc power, no KEYCODE_*. A pull is not worth burn-in. (R-101)
#   * Thermal gate: refuses to start or continue above THERMAL_MAX (default 400 tenths — stricter
#     than the 440 perf-leg gate, because a pull is pure I/O heat with no measurement value).
#   * Only writes $DST.part and renames on success, so a half file can never masquerade as done.
#   * Run only when the perf queue is idle: it competes for adb and for device thermals.
#
# Verdict lines:  #### LFMPULL_START|RESUME|CHUNK|THROTTLE|VERIFY|VERDICT …   exit 0 ok, non-zero = abort
set -u

DEV="${DEV:-adb -P 15037 -s 100.109.138.2:5555}"      # split on purpose; keep it simple words only
# SRC/DST 承袭祖传件 _probe/mesa_legs/routeA_1026/lfm_pull_chunked_740.sh（R-090：>1GB 设备搬运
# 一律分块+限速）。祖传件在设备上 split 再拉；本件改为 host 侧 dd 分块读，不占设备第二份空间。
SRC="${SRC:-/storage/emulated/0/TongYiLite/models/lfm2.5-24b-a2b-q4_0.gguf}"
DST="${DST:-/home/jianzengliang/MyWork/TongYi-Lite/.modelxfer/lfm2.5-24b-a2b-q4_0.gguf}"
EXPECT_SIZE="${EXPECT_SIZE:-13578190880}"     # 源站背书：hf-mirror Content-Length，逐位合
EXPECT_MD5="${EXPECT_MD5:-}"                  # 源站无 md5 —— 不造假值，只作 host/device 双向交叉
# Authoritative content hash = hf-mirror HEAD ETag (LFS oid, 64 hex), per parent 2026-10-28.
# The ModelScope route answered 200 without an ETag, so hf-mirror is the ONLY authority.
EXPECT_SHA256="${EXPECT_SHA256:-b346311324dc0041f57424eae6a8a78c77dfabce71ad0ebbe8fc4ff5420ec115}"
CHUNK="${CHUNK:-$((64 * 1024 * 1024))}"       # bytes per adb trip
SLEEP="${SLEEP:-0.5}"                         # throttle: pause between chunks
THERMAL_MAX="${THERMAL_MAX:-400}"
HASH_CHUNKS="${HASH_CHUNKS:-0}"               # 1 = per-chunk device hash (doubles device read I/O)
RETRIES="${RETRIES:-3}"
DRY_RUN="${DRY_RUN:-0}"
SELFTEST="${SELFTEST:-0}"                     # exercises chunking/resume/hash/size on a local file

dsize() {
    if [ "$SELFTEST" = 1 ]; then stat -c%s "$SRC" 2>/dev/null; else
        $DEV shell "stat -c %s '$SRC' 2>/dev/null" 2>/dev/null | tr -dc "0-9"
    fi
}
dbat() {
    # FAKE_BATT lets the self-test drive the thermal gate deterministically.
    [ "$SELFTEST" = 1 ] && { echo "${FAKE_BATT:-250}"; return; }
    $DEV shell 'dumpsys battery 2>/dev/null | grep -m1 temperature' 2>/dev/null | tr -dc "0-9"
}
# fetch one chunk [offset,offset+CHUNK) into $2
fetch() {
    local off="$1" out="$2" cnt
    cnt=$(( (SIZE - off) < CHUNK ? (SIZE - off) : CHUNK ))
    if [ "$SELFTEST" = 1 ]; then
        dd if="$SRC" bs=$CHUNK skip=$((off / CHUNK)) count=1 status=none > "$out" 2>/dev/null
    else
        $DEV exec-out "dd if='$SRC' bs=$CHUNK skip=$((off / CHUNK)) count=1 status=none" > "$out"
    fi
    cnt_check() { stat -c%s "$out" 2>/dev/null; }
    [ "$(cnt_check)" = "$cnt" ] || return 1
    if [ "$HASH_CHUNKS" = 1 ]; then
        local hm dm
        hm=$(md5sum "$out" | cut -d' ' -f1)
        if [ "$SELFTEST" = 1 ]; then dm=$hm; else
            dm=$($DEV shell "dd if='$SRC' bs=$CHUNK skip=$((off / CHUNK)) count=1 status=none | md5sum" 2>/dev/null | cut -c1-32)
        fi
        [ "$hm" = "$dm" ] || { echo "#### LFMPULL_CHUNK_FAIL_OFFSET $off reason=hash"; return 1; }
    fi
    return 0
}

SIZE=$(dsize)
[ -n "${SIZE:-}" ] || { echo "#### LFMPULL_ABORT reason=device_unreachable_or_missing_src src=$SRC"; exit 3; }
if [ "$SIZE" != "$EXPECT_SIZE" ]; then
    echo "#### LFMPULL_ABORT reason=size_mismatch device=$SIZE expect=$EXPECT_SIZE src=$SRC"; exit 4
fi
mkdir -p "$(dirname "$DST")"
# Idempotence (承袭祖传件的 .ok 哨兵，但这次不只查存在——尺寸+权威 sha 复算一遍才算数)：
if [ -f "$DST" ] && [ -f "$DST.ok" ] && [ "$SELFTEST" != 1 ]; then
    OS=$(stat -c%s "$DST")
    if [ "$OS" = "$EXPECT_SIZE" ] && [ "$(sha256sum "$DST" | cut -d' ' -f1)" = "$EXPECT_SHA256" ]; then
        echo "#### LFMPULL_ALREADY_OK path=$DST size=$OS (尺寸+源站 sha256 复算通过，未拉取)"
        exit 0
    fi
    echo "#### LFMPULL_STALE_OK 正式件存在但尺寸/sha 不符 ⇒ 视同未拉，重走 .part 流程"
    rm -f "$DST" "$DST.ok"
fi
PART="$DST.part"
HAVE=$(stat -c%s "$PART" 2>/dev/null || echo 0)
if [ "$HAVE" -gt "$SIZE" ]; then echo "#### LFMPULL_ABORT reason=part_larger_than_src part=$HAVE"; exit 5; fi
if [ "$HAVE" = "$SIZE" ]; then
    # A full-size .part can only be a previously INDICTED pull (sha gate kept it for forensics).
    # Quarantine it instead of letting an unaligned leftover block every later retry (exit 6 trap).
    Q="$DST.indicted.$(date +%s)"
    mv -f "$PART" "$Q"
    echo "#### LFMPULL_QUARANTINE_PART 整块旧 .part 系先前定罪件 ⇒ 封存为 $Q 供验尸，本次从零重拉"
    HAVE=0
elif [ $((HAVE % CHUNK)) != 0 ]; then
    echo "#### LFMPULL_ABORT reason=part_not_chunk_aligned part=$HAVE chunk=$CHUNK (删 .part 重开)"
    exit 6
fi
B=$(dbat); [ -n "$B" ] || B=0
echo "#### LFMPULL_START src=$SRC dst=$DST size=$SIZE chunk=$CHUNK sleep=$SLEEP resume_from=$HAVE batt=$B expect_md5=${EXPECT_MD5:-none} selftest=$SELFTEST"
if [ "$B" -gt "$THERMAL_MAX" ]; then echo "#### LFMPULL_THERMAL_ABORT batt=$B max=$THERMAL_MAX 候温复再跑"; exit 7; fi
[ "$DRY_RUN" = 1 ] && { echo "#### LFMPULL_DRYRUN chunks=$(( (SIZE + CHUNK - 1) / CHUNK )) 已核参数未拉取"; exit 0; }

off=$HAVE
[ "$HAVE" -gt 0 ] && echo "#### LFMPULL_RESUME from=$HAVE ($(( HAVE / CHUNK ))/$(( (SIZE + CHUNK - 1) / CHUNK )) 块已在盘)"
while [ "$off" -lt "$SIZE" ]; do
    n=$(( off / CHUNK + 1 ))
    ok=0; try=1
    while [ "$try" -le "$RETRIES" ]; do
        if fetch "$off" "$PART.tmp"; then ok=1; break; fi
        echo "#### LFMPULL_CHUNK_RETRY n=$n try=$try"; try=$((try + 1)); sleep 2
    done
    [ "$ok" = 1 ] || { echo "#### LFMPULL_ABORT reason=chunk_failed n=$n offset=$off (已落 $off 字节可续跑)"; rm -f "$PART.tmp"; exit 8; }
    cat "$PART.tmp" >> "$PART"; rm -f "$PART.tmp"
    off=$(( off + CHUNK ))
    if [ $(( n % 16 )) = 0 ]; then
        B=$(dbat); [ -n "$B" ] || B=0
        echo "#### LFMPULL_CHUNK n=$n done=$off pct=$(( off * 100 / SIZE )) batt=$B"
        if [ "$B" -gt "$THERMAL_MAX" ]; then echo "#### LFMPULL_THERMAL_ABORT batt=$B max=$THERMAL_MAX 已落 $off 字节可续跑"; exit 7; fi
    fi
    sleep "$SLEEP"
done
rm -f "$PART.tmp"

HS=$(stat -c%s "$PART"); HM=$(md5sum "$PART" | cut -d' ' -f1)
DS=$(dsize)
if [ "$SELFTEST" = 1 ]; then
    DM=$(md5sum "$SRC" | cut -d' ' -f1)
    HS256=$(sha256sum "$SRC" | cut -d' ' -f1)      # 假源即"源站原件"，sha 闸在自测里走真路径
else
    echo "#### LFMPULL_VERIFY device_md5_begin (读全件一次，稍候)"
    DM=$($DEV shell "md5sum '$SRC'" 2>/dev/null | cut -c1-32)
    HS256=$(sha256sum "$PART" | cut -d' ' -f1)     # 权威闸只跑 host 侧，设备不再被读第三遍
fi
echo "#### LFMPULL_VERIFY host_size=$HS device_size=$DS expect_size=$EXPECT_SIZE host_md5=$HM device_md5=${DM:-na} expect_md5=${EXPECT_MD5:-none}"
echo "#### LFMPULL_VERIFY_SHA host_sha256=${HS256:-na} expect_sha256=${EXPECT_SHA256:-none}"
FAIL=0
[ "$HS" = "$EXPECT_SIZE" ] || { echo "#### LFMPULL_FAIL size_host"; FAIL=1; }
[ "$DS" = "$EXPECT_SIZE" ] || { echo "#### LFMPULL_FAIL size_device"; FAIL=1; }
[ "$HS" = "$DS" ] || { echo "#### LFMPULL_FAIL size_cross"; FAIL=1; }
if [ -z "$DM" ]; then echo "#### LFMPULL_FAIL no_device_md5(掉线?) 件留 .part 可续"; exit 9; fi
[ "$HM" = "$DM" ] || { echo "#### LFMPULL_FAIL md5_cross host=$HM device=$DM"; FAIL=1; }
if [ -n "$EXPECT_MD5" ]; then
    [ "$HM" = "$EXPECT_MD5" ] || { echo "#### LFMPULL_FAIL md5_expect got=$HM want=$EXPECT_MD5"; FAIL=1; }
fi
[ "$FAIL" = 0 ] || { echo "#### LFMPULL_VERDICT PASS=no 件留在 $PART 供验尸"; exit 10; }

# --- authoritative hash gate (separate exit: it indicts the SOURCE, not the transport) ---------
# md5 双向交叉过 = 设备上的原件与落盘件一致（传输无罪）；此时 sha256 仍撞不过源站 ETag，
# 只能是"原件下载即坏"或"源被换" ⇒ halt 报父复核源站，绝不带病件去喂 K40 的 B2 CPU 金标。
if [ -n "$EXPECT_SHA256" ]; then
    if [ "${HS256:-}" != "$EXPECT_SHA256" ]; then
        echo "#### LFMPULL_FAIL sha256_authority got=${HS256:-na} want=$EXPECT_SHA256"
        echo "#### LFMPULL_DIAGNOSIS md5_cross=pass 而 sha256 不符 ⇒ 设备原件本身即坏/源被换（非本次传输所致）；halt 候父复核源站，禁喂 K40 B2 金标"
        echo "#### LFMPULL_VERDICT PASS=no 件留在 $PART 供验尸（不许改名成正式件）"
        exit 11
    fi
    echo "#### LFMPULL_SHA_GATE ok=源站背书 sha256 对撞通过"
fi
mv -f "$PART" "$DST"
printf 'size=%s\nmd5=%s\nsha256=%s\nsrc=%s\npulled_at=%s\n' "$HS" "$HM" "${HS256:-na}" "$SRC" "$(date -Is)" > "$DST.ok"
echo "#### LFMPULL_VERDICT PASS=yes size=$HS md5=$HM sha256=${HS256:-na} path=$DST ok=$DST.ok"

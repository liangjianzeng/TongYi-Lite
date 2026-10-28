#!/usr/bin/env bash
# [vkh R-108] lfm_push_chunked_k40.sh 的桩自测矩阵（host 侧，**零设备接触**）。
# 与 lfm_pull_selftest.sh 同一规矩：每案**双断言**（退出码 + 判词行），桩错也算Fail（我有 N3/#13 前科）。
# 覆盖 pull 枪没有的 push 特有面：append 型 .part 的截回、稀疏文件陷阱不复现、设备侧短写。
set -u
GUN="${GUN:-$(cd "$(dirname "$0")" && pwd)/lfm_push_chunked_k40.sh}"
W=/tmp/lfmpush_selftest; rm -rf "$W"; mkdir -p "$W"
CHUNK=$((32 * 1024 * 1024)); SZ=$((100 * 1024 * 1024 + 12345))
SRC="$W/fake.gguf"; head -c "$SZ" /dev/urandom > "$SRC" || { echo "#### LFPS2_ABORT 造不出假源"; exit 2; }
TRUE_SHA=$(sha256sum "$SRC" | cut -d' ' -f1); TRUE_MD5=$(md5sum "$SRC" | cut -d' ' -f1)
FAIL=0; PASSN=0
chk() { local c="$1" erc="$2" grc="$3" re="$4" log="$5"
    if [ "$erc" != "$grc" ]; then echo "#### LFPS2_FAIL case=$c want_rc=$erc got_rc=$grc"; printf '%s\n' "$log" | tail -4 | sed 's/^/      /'; FAIL=$((FAIL+1)); return; fi
    if [ -n "$re" ] && ! printf '%s' "$log" | grep -qE "$re"; then echo "#### LFPS2_FAIL case=$c rc=$grc 缺判词 /$re/"; printf '%s\n' "$log" | tail -4 | sed 's/^/      /'; FAIL=$((FAIL+1)); return; fi
    echo "#### LFPS2_OK case=$c rc=$grc"; PASSN=$((PASSN+1)); }
run() { local d="$1"; shift; mkdir -p "$d/dev"
    ( cd "$d"; env "$@" SRC="$SRC" DST="$d/dev/lfm.gguf" SELFTEST=1 CHUNK=$CHUNK SLEEP=0 \
        EXPECT_SIZE=$SZ WORK="$W/work" bash "$GUN" 2>&1 ) ; }

# T1 全绿：落盘件字节必须与源件逐字节同（sha 闸走真路径）
L=$(run "$W/t1" EXPECT_SHA256="$TRUE_SHA"); rc=$?
chk T1 0 $rc 'LFMPUSH_VERDICT PASS=yes' "$L"
[ "$(md5sum "$W/t1/dev/lfm.gguf.part" | cut -d' ' -f1)" = "$TRUE_MD5" ] || { echo "#### LFPS2_FAIL T1 落盘件与源件不一致"; FAIL=$((FAIL+1)); }
grep -q "sha256=$TRUE_SHA" "$W/t1/dev/lfm.gguf.ok" || { echo "#### LFPS2_FAIL T1 .ok 哨兵 sha 不对"; FAIL=$((FAIL+1)); }

# T2 源件尺寸不符 ⇒ exit 4（防"拿半件喂 K40"）
L=$( ( cd "$W/t2" 2>/dev/null || mkdir -p "$W/t2" && cd "$W/t2"; env SRC="$SRC" DST="$W/t2/dev/lfm.gguf" SELFTEST=1 CHUNK=$CHUNK SLEEP=0 EXPECT_SIZE=$((SZ+1)) EXPECT_SHA256="$TRUE_SHA" WORK="$W/work" bash "$GUN" 2>&1 ) ); rc=$?
chk T2 4 $rc 'reason=size_src' "$L"

# T3 源件不存在 ⇒ exit 3
L=$( ( cd "$W"; env SRC="$W/nope.gguf" DST="$W/t3/dev/lfm.gguf" SELFTEST=1 CHUNK=$CHUNK SLEEP=0 EXPECT_SIZE=$SZ EXPECT_SHA256="$TRUE_SHA" WORK="$W/work" bash "$GUN" 2>&1 ) ); rc=$?
chk T3 3 $rc 'reason=no_src' "$L"

# T4 热闸 ⇒ exit 7
L=$(run "$W/t4" EXPECT_SHA256="$TRUE_SHA" FAKE_BATT=450 THERMAL_MAX=400); rc=$?
chk T4 7 $rc 'LFMPUSH_THERMAL_ABORT' "$L"

# T5 权威 sha 不符（md5 双向交叉会过）⇒ exit 11 + 定罪诊断 + 不许转正
L=$(run "$W/t5" EXPECT_SHA256=0000000000000000000000000000000000000000000000000000000000000000); rc=$?
chk T5 11 $rc 'LFMPUSH_DIAGNOSIS' "$L"
[ -f "$W/t5/dev/lfm.gguf.ok" ] && { echo "#### LFPS2_FAIL T5 定罪件写了 .ok（危险）"; FAIL=$((FAIL+1)); }
[ -f "$W/t5/dev/lfm.gguf" ] && { echo "#### LFPS2_FAIL T5 定罪件被转正（危险）"; FAIL=$((FAIL+1)); }

# T6 半块 .part ⇒ 截回整块边界后续跑（13.58GB 不重跑），最终字节必须全对
mkdir -p "$W/t6/dev"; head -c $(( CHUNK * 2 + 777 )) "$SRC" > "$W/t6/dev/lfm.gguf.part"
L=$( ( cd "$W/t6"; env SRC="$SRC" DST="$W/t6/dev/lfm.gguf" SELFTEST=1 CHUNK=$CHUNK SLEEP=0 EXPECT_SIZE=$SZ EXPECT_SHA256="$TRUE_SHA" WORK="$W/work" bash "$GUN" 2>&1 ) ); rc=$?
chk T6 0 $rc 'LFMPUSH_TRUNCATE' "$L"
grep -q "LFMPUSH_RESUME from=$(( CHUNK * 2 ))" <<<"$L" || { echo "#### LFPS2_FAIL T6 截回后没从整块边界续"; FAIL=$((FAIL+1)); }
[ "$(md5sum "$W/t6/dev/lfm.gguf.part" | cut -d' ' -f1)" = "$TRUE_MD5" ] || { echo "#### LFPS2_FAIL T6 截回后内容错"; FAIL=$((FAIL+1)); }

# T7 精确整块 .part ⇒ 直接 RESUME，且内容全对
mkdir -p "$W/t7/dev"; head -c $(( CHUNK * 3 )) "$SRC" > "$W/t7/dev/lfm.gguf.part"
L=$( ( cd "$W/t7"; env SRC="$SRC" DST="$W/t7/dev/lfm.gguf" SELFTEST=1 CHUNK=$CHUNK SLEEP=0 EXPECT_SIZE=$SZ EXPECT_SHA256="$TRUE_SHA" WORK="$W/work" bash "$GUN" 2>&1 ) ); rc=$?
chk T7 0 $rc "LFMPUSH_RESUME from=$(( CHUNK * 3 ))" "$L"
[ "$(md5sum "$W/t7/dev/lfm.gguf.part" | cut -d' ' -f1)" = "$TRUE_MD5" ] || { echo "#### LFPS2_FAIL T7 续跑后内容错"; FAIL=$((FAIL+1)); }

# T8 设备侧写不进去（目录只读模拟掉线/权限）⇒ 重试后 exit 8，且不留 .ok
mkdir -p "$W/t8/dev"; chmod 500 "$W/t8/dev"
L=$( ( cd "$W/t8"; env SRC="$SRC" DST="$W/t8/dev/lfm.gguf" SELFTEST=1 CHUNK=$CHUNK SLEEP=0 RETRIES=1 EXPECT_SIZE=$SZ EXPECT_SHA256="$TRUE_SHA" WORK="$W/work" bash "$GUN" 2>&1 ) ); rc=$?
chmod 700 "$W/t8/dev"
chk T8 8 $rc 'reason=chunk_failed' "$L"
[ -f "$W/t8/dev/lfm.gguf.ok" ] && { echo "#### LFPS2_FAIL T8 失败还写 .ok"; FAIL=$((FAIL+1)); }

# T9 反向闸：.part 比源件还大 ⇒ exit 5（防拿别件冒充）
mkdir -p "$W/t9/dev"; head -c $(( SZ + CHUNK )) /dev/urandom > "$W/t9/dev/lfm.gguf.part"
L=$( ( cd "$W/t9"; env SRC="$SRC" DST="$W/t9/dev/lfm.gguf" SELFTEST=1 CHUNK=$CHUNK SLEEP=0 EXPECT_SIZE=$SZ EXPECT_SHA256="$TRUE_SHA" WORK="$W/work" bash "$GUN" 2>&1 ) ); rc=$?
chk T9 5 $rc 'reason=part_larger_than_src' "$L"

echo "#### LFPS2_SUMMARY pass=$PASSN fail=$FAIL gun=$(md5sum "$GUN" | cut -c1-12) fake_md5=${TRUE_MD5:0:12}"
[ "$FAIL" = 0 ] || exit 9

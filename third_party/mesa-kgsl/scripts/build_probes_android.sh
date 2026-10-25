#!/usr/bin/env bash
# Mesa 线探针/e2e 的 Android 构建配方（Linux aarch64 与 Windows 双宿主可复现）。
#
# 为什么放在 third_party/mesa-kgsl/scripts：全 GPU 卸载 Mesa 路线的每一次性能数字都必须
# 能回答"哪个构建、什么编译开关测的"。此脚本 = 该线测量体的唯一构建入口，产出随包 BUILD_INFO
# 指纹（git rev + 编译开关 + 时间），设备侧 runner 必须把它打进日志头，无指纹的数不入档。
#
# 用法：
#   third_party/mesa-kgsl/scripts/build_probes_android.sh            # 全量（minicpm_e2e + 在位探针）
#   .../build_probes_android.sh --target minicpm_e2e                 # 只建一个目标
#   .../build_probes_android.sh --clean                              # 清缓存重配
#   JOBS=4 .../build_probes_android.sh                               # 控并发（本机常驻服务多时建议 ≤4）
#
# 依赖：NDK r27（$ANDROID_NDK_HOME 或 ~/android-sdk/ndk/27.0.12077973）、cmake ≥3.22、ninja。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
PROBE_DIR="$REPO_ROOT/_probe/moe_probe"
BUILD_DIR="$PROBE_DIR/build-android"
STUB_DIR="$REPO_ROOT/_probe/oclstub_build/opencl-stub"
TARGET=""
CLEAN=0
JOBS=${JOBS:-4}
ANDROID_ABI=${ANDROID_ABI:-arm64-v8a}
ANDROID_PLATFORM=${ANDROID_PLATFORM:-28}   # 只填数字，下方统一拼 android-$N

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET=$2; shift 2 ;;
    --clean)  CLEAN=1; shift ;;
    --jobs)   JOBS=$2; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

# ---------- NDK 定位 ----------
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  for c in "$HOME/android-sdk/ndk/27.0.12077973" "$HOME/Android/Sdk/ndk/27.0.12077973"; do
    [ -d "$c" ] && ANDROID_NDK_HOME=$c && break
  done
fi
[ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ] || {
  echo "找不到 NDK：设 ANDROID_NDK_HOME 或装 ~/android-sdk/ndk/27.0.12077973" >&2; exit 1; }
# aarch64 宿主用 linux-aarch64 prebuilt；x86-64 Linux 用 linux-x86_64；
# Windows（Git Bash/MinGW）用 windows-x86_64（2026-10-25 补：裸 bash 里 uname 是 x86_64 但
# prebuilt 目录叫 windows-x86_64，旧 grep 匹配 linux-x86_64 必空 ⇒ HOSTDIR 直接判死）
case "$(uname -m | sed 's/aarch64/linux-aarch64/;s/x86_64/linux-x86_64/');$(uname -s)" in
  *MINGW*|*MSYS*|*CYGWIN*) HOST_TAG_GUESS="windows-x86_64" ;;
  *) HOST_TAG_GUESS="$(uname -m | sed 's/aarch64/linux-aarch64/;s/x86_64/linux-x86_64/')" ;;
esac
HOSTDIR=$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/* 2>/dev/null | grep -m1 "$HOST_TAG_GUESS" || true)
[ -n "$HOSTDIR" ] || { echo "NDK 缺本机 host prebuilt（tag=$HOST_TAG_GUESS）" >&2; exit 1; }
# Windows 下 clang 是 .cmd 包装（不能直接 exec）：统一走 cmd 包装名
if [ -x "$HOSTDIR/bin/clang" ]; then
  CC="$HOSTDIR/bin/clang"
elif [ -f "$HOSTDIR/bin/clang.cmd" ]; then
  CC="$HOSTDIR/bin/clang.cmd"
else
  echo "NDK 缺 clang（$HOSTDIR/bin）" >&2; exit 1
fi
SYSROOT="$HOSTDIR/sysroot"   # 裸 clang 不会自动挂 sysroot，漏了会去吃宿主 /usr/include（glibc）

echo "== Mesa 线测量体构建 =="
echo "   仓库根 : $REPO_ROOT"
echo "   NDK    : $ANDROID_NDK_HOME ($(basename "$HOSTDIR"))"
echo "   ABI    : $ANDROID_ABI / android-$ANDROID_PLATFORM / -j$JOBS"

# [2026-10-25 Windows 宿主补] ninja/cmake/python3 都可能不在 PATH：
#   - Git Bash 宿主：Android SDK 自带 cmake+ninja（拼 PATH）；python3 用 python.exe 别名兜底
SDK_CMAKE_GUESS="${ANDROID_SDK_HOME:-$HOME/AppData/Local/Android/Sdk}/cmake"
if ! command -v ninja >/dev/null 2>&1; then
  for d in "$SDK_CMAKE_GUESS"/*/bin; do [ -x "$d/ninja" ] && export PATH="$d:$PATH" && break; done
fi
if ! command -v python3 >/dev/null 2>&1 && command -v python >/dev/null 2>&1; then
  python3() { python "$@"; }   # 仅本脚本内别名（compile-gate 机检用）
fi

# ---------- opencl stub（ggml-opencl 链接用的 ICD 转发壳） ----------
mkdir -p "$STUB_DIR"
if [ ! -f "$STUB_DIR/libopencl_stub.so" ] || [ "$REPO_ROOT/third_party/opencl-stub/opencl_stub.c" -nt "$STUB_DIR/libopencl_stub.so" ]; then
  echo "--> 编 opencl stub"
  "$CC" --target=aarch64-linux-android"$ANDROID_PLATFORM" --sysroot="$SYSROOT" \
    -shared -fPIC -O2 -Wl,-soname,libopencl_stub.so \
    -I "$REPO_ROOT/third_party/OpenCL-Headers" \
    -o "$STUB_DIR/libopencl_stub.so" "$REPO_ROOT/third_party/opencl-stub/opencl_stub.c"
  # 必须带 SONAME：否则可执行文件把**宿主的绝对构建路径**记进 DT_NEEDED，推到机上直接加载失败。
fi

# ---------- configure ----------
[ "$CLEAN" = 1 ] && rm -rf "$BUILD_DIR"
# aarch64 宿主（DGX Spark）用自带 toolchain 文件直取 linux-aarch64 prebuilt：
# NDK 的 android.toolchain.cmake 对 Linux 写死 linux-x86_64（r27 第 276 行），在 arm64 宿主上
# 既走 FEX 模拟又在链接期丢 compiler-rt（_Unwind_* undefined），测量体绝不能那么编。
if [ "$(uname -m)" = "aarch64" ] && [ -x "$HOSTDIR/bin/clang" ]; then
  TC_FILE="$SCRIPT_DIR/toolchain-android-aarch64.cmake"
  export ANDROID_NDK_HOME NDK_HOST_TAG=$(basename "$HOSTDIR")
  # CMake 自带的 Platform/Android-Determine 只认这两个变量，不给就报"没找到 NDK"
  export ANDROID_NDK="$ANDROID_NDK_HOME"
  NDK_EXTRA="-DCMAKE_ANDROID_NDK=$ANDROID_NDK_HOME -DCMAKE_ANDROID_ARCH_ABI=$ANDROID_ABI -DCMAKE_MAKE_PROGRAM=$(command -v ninja)"
else
  TC_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
  NDK_EXTRA="-DCMAKE_MAKE_PROGRAM=$(command -v ninja)"
fi
# 血泪教训（AGENTS「CMAKE_C_FLAGS_DEBUG 被 NDK 顶掉」）：优化级用 cache 变量显式钉死，
# 并在 configure 后从 compile_commands.json 机检 -O3 -DNDEBUG，否则数字全是 -O0 的。
cmake -S "$PROBE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TC_FILE" \
  $NDK_EXTRA \
  -DANDROID_ABI="$ANDROID_ABI" -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-O3 -DNDEBUG -fno-omit-frame-pointer" \
  -DCMAKE_CXX_FLAGS="-O3 -DNDEBUG -fno-omit-frame-pointer" \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--build-id=sha1" \
  -DGGML_OPENMP=OFF # NDK only ships libomp.a (static); shared libggml-cpu.so would fail CANNOT LINK

# ---------- 编译门机检（-O3 被静默顶掉 = 全线数字作废的老坑） ----------
CC_JSON="$BUILD_DIR/compile_commands.json"
[ -f "$CC_JSON" ] || cmake -S "$PROBE_DIR" -B "$BUILD_DIR" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON >/dev/null
BAD=$(python3 - "$BUILD_DIR" <<'PY'
import json,os,sys
d=os.path.join(sys.argv[1],'compile_commands.json')
if not os.path.exists(d): print("NO_COMPILE_DB"); raise SystemExit
bad=0
for e in json.load(open(d)):
    f=e.get('file','')
    if any(k in f for k in ('ggml/src','llama/src','ggml-opencl')):
        cmd=e.get('command','') or ' '.join(e.get('arguments',[]))
        if '-O3' not in cmd or '-DNDEBUG' not in cmd: bad+=1
print(bad)
PY
)
if [ "$BAD" != "0" ] && [ "$BAD" != "NO_COMPILE_DB" ]; then
  echo "!! 编译门不过：$BAD 个引擎源文件缺 -O3/-DNDEBUG（数字将不可信），中止" >&2; exit 3
fi
echo "--> 编译门 OK（引擎源文件均含 -O3 -DNDEBUG）"

# ---------- build ----------
if [ -n "$TARGET" ]; then
  cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS"
else
  cmake --build "$BUILD_DIR" -j"$JOBS"
fi

# ---------- BUILD_INFO 指纹（设备侧 runner 必须 cat 进日志头） ----------
GITREV=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
DIRTY=$(git -C "$REPO_ROOT" status --porcelain -- third_party/llama.cpp _probe 2>/dev/null | wc -l | tr -d ' ')
cat > "$BUILD_DIR/BUILD_INFO" <<EOF
git=$GITREV dirty_entries=$DIRTY
abi=$ANDROID_ABI platform=android-$ANDROID_PLATFORM jobs=$JOBS
cc=$CC
flags=-O3 -DNDEBUG -fno-omit-frame-pointer
built=$(date -Iseconds)
EOF
cp -f "$STUB_DIR/libopencl_stub.so" "$BUILD_DIR/" 2>/dev/null || true

# ---------- DT_NEEDED 归一化（否则某些测量体上机直接起不来） ----------
# 坑：某些目标把 stub 以**绝对宿主路径**链进 DT_NEEDED（test-backend-ops 就是这样），
# 而 Android linker 不按 soname 回退搜索 => 上机报 "library /home/.../libopencl_stub.so
# not found" 整条腿作废；minicpm_e2e 是 basename 能跑，所以这坑只在换测量体时踩到。
STUB_ABS="$STUB_DIR/libopencl_stub.so"
if command -v patchelf >/dev/null 2>&1; then
  for b in "$BUILD_DIR"/minicpm_e2e "$BUILD_DIR"/bin/* "$BUILD_DIR"/moe_probe*; do
    [ -f "$b" ] || continue
    if readelf -d "$b" 2>/dev/null | grep -q "$STUB_ABS"; then
      patchelf --replace-needed "$STUB_ABS" libopencl_stub.so "$b" \
        && echo "   [patchelf] DT_NEEDED -> basename: $(basename "$b")"
    fi
  done
else
  echo "   !! 无 patchelf：绝对路径 DT_NEEDED 的测量体上机会起不来（先手动 patchelf --replace-needed）" >&2
fi

echo "== 产物 =="
find "$BUILD_DIR" -maxdepth 2 -type f \( -name 'minicpm_e2e' -o -name 'moe_probe*' -o -name 'lib*.so' \) \
  -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n' | sort
echo "== 指纹 =="; cat "$BUILD_DIR/BUILD_INFO"
echo
echo "推送：adb push $BUILD_DIR/{minicpm_e2e,libggml-opencl.so,libggml.so,libggml-cpu.so,libggml-base.so,libllama.so,libllama-common.so} /data/local/tmp/<dir>/"

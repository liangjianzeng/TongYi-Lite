#!/bin/bash
# M0 probe: build mesa 26.2.4 with freedreno(kgsl) + rusticl in trixie chroot
# Run INSIDE /opt/trixie-cl. Output staged to /opt/mesa-cl
# 补丁顺序：0011 -> 0012 -> fix_fd_device.py -> 0026（见 ../README.md）
set -ex
export DEBIAN_FRONTEND=noninteractive

echo "=== deps install ==="
apt-get update -qq
apt-get install -y --no-install-recommends \
  build-essential meson ninja-build pkg-config python3-mako python3-yaml python3-ply \
  bison flex zlib1g-dev libzstd-dev libexpat1-dev libdrm-dev \
  llvm-19-dev libclang-19-dev libclang-cpp19-dev clang-19 \
  libclc-19-dev libllvmspirvlib-19-dev spirv-tools \
  cargo rustc bindgen \
  wget xz-utils ca-certificates clinfo file 2>&1 | tail -20

echo "=== tool versions ==="
meson --version || pip3 install --break-system-packages meson
rustc --version
bindgen --version || echo BINDGEN_MISSING
clang-19 --version | head -1
pkg-config --modversion libdrm

echo "=== fetch mesa ==="
cd /root
if [ ! -f mesa-26.2.4.tar.xz ]; then
  wget -q https://deb.debian.org/debian/pool/main/m/mesa/mesa_26.2.4.orig.tar.xz -O mesa-26.2.4.tar.xz
fi
if [ ! -d mesa-26.2.4 ]; then
  tar xf mesa-26.2.4.tar.xz
fi
cd mesa-26.2.4

echo "=== meson setup ==="
rm -rf build-cl
meson setup build-cl \
  --prefix=/opt/mesa-cl \
  -Dgallium-drivers=freedreno \
  -Dgallium-rusticl=true \
  -Dgallium-rusticl-enable-drivers=auto,freedreno \
  -Dfreedreno-kmds=msm,kgsl \
  -Dvulkan-drivers= \
  -Dplatforms=[] \
  -Degl=disabled \
  -Dglx=disabled \
  -Dgbm=disabled \
  -Dgles1=disabled \
  -Dgles2=disabled \
  -Dopengl=true \
  -Dllvm=enabled \
  -Dshared-llvm=enabled \
  -Dgallium-va=disabled \
  -Dexpat=enabled \
  -Dzstd=enabled \
  -Dxmlconfig=disabled \
  -Dbuild-tests=false \
  -Dbuildtype=release \
  -Db_ndebug=true \
  -Drust_std=2021 2>&1 | tail -60

echo "=== ninja ==="
ninja -C build-cl -j6 2>&1 | tail -15

echo "=== install ==="
ninja -C build-cl install 2>&1 | tail -5
ls -la /opt/mesa-cl/lib/ | head -20

echo "BUILD_ALL_DONE"

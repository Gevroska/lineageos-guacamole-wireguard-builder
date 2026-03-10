#!/usr/bin/env bash
set -euo pipefail

BRANCH="${BRANCH:-lineage-23.2}"
DEVICE="${DEVICE:-guacamole}"
WORKDIR="${WORKDIR:-/workspace/android}"
CCACHE_DIR="${CCACHE_DIR:-/ccache}"
CCACHE_SIZE="${CCACHE_SIZE:-100G}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
WG_REPO="${WG_REPO:-https://git.zx2c4.com/wireguard-linux-compat}"

export USE_CCACHE=1
export CCACHE_DIR
export CCACHE_EXEC=/usr/bin/ccache
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

mkdir -p "$WORKDIR" "$CCACHE_DIR"

ccache -M "$CCACHE_SIZE" || true

cd "$WORKDIR"

if [ ! -d .repo ]; then
  repo init -u https://github.com/LineageOS/android.git -b "$BRANCH"
fi

repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)"

source build/envsetup.sh
breakfast "$DEVICE"

KERNEL_DIR="$WORKDIR/kernel/oneplus/sm8150"
WG_DIR="/workspace/wireguard-linux-compat"

if [ ! -d "$KERNEL_DIR" ]; then
  echo "Kernel tree not found: $KERNEL_DIR" >&2
  exit 1
fi

if [ ! -d "$WG_DIR" ]; then
  git clone "$WG_REPO" "$WG_DIR"
else
  git -C "$WG_DIR" fetch --all --tags
  git -C "$WG_DIR" pull --ff-only
fi

cd "$KERNEL_DIR"

if ! grep -Rqs 'WireGuard secure network tunnel' net 2>/dev/null; then
  "$WG_DIR/kernel-tree-scripts/create-patch.sh" | patch -p1
fi

/home/builder/build/apply-config-fragment.sh \
  "$KERNEL_DIR/arch/arm64/configs/vendor/oplus.config" \
  /home/builder/patches/kernel-extra.config

cd "$WORKDIR"
source build/envsetup.sh
brunch "$DEVICE"

echo
echo "Build complete."
echo "Artifacts:"
echo "$WORKDIR/out/target/product/$DEVICE/"
echo
echo "Check merged kernel config with:"
echo "grep -E 'CONFIG_F2FS|CONFIG_WIREGUARD' $WORKDIR/out/target/product/$DEVICE/obj/KERNEL_OBJ/.config"

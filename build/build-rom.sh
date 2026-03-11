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

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_free_space() {
  local path="$1"
  local min_gb="$2"

  local avail_kb
  avail_kb="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  local min_kb=$((min_gb * 1024 * 1024))

  if [ "${avail_kb:-0}" -lt "$min_kb" ]; then
    echo "Not enough free space on $path. Need at least ${min_gb} GB free." >&2
    df -h "$path" >&2 || true
    exit 1
  fi
}

init_repo_if_needed() {
  cd "$WORKDIR"

  if [ ! -d .repo ]; then
    log "Initializing repo"
    repo init -u https://github.com/LineageOS/android.git -b "$BRANCH"
  fi
}

sync_once() {
  cd "$WORKDIR"
  repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)"
}

sync_recovery_pass() {
  cd "$WORKDIR"
  repo sync -c --no-clone-bundle --no-tags -j1 --force-sync --fail-fast
}

extract_bad_projects_from_log() {
  local logfile="$1"

  awk '
    /error: .* checkout / {
      sub(/^error: /, "", $0)
      sub(/:.*$/, "", $0)
      print
    }
    /: unparseable HEAD; trying to recover/ {
      sub(/: unparseable HEAD; trying to recover.*/, "", $0)
      sub(/^project /, "", $0)
      print
    }
  ' "$logfile" | sort -u
}

remove_bad_projects() {
  local logfile="$1"
  local removed=0

  while IFS= read -r proj; do
    [ -z "$proj" ] && continue
    if [ -d "$WORKDIR/$proj" ]; then
      log "Removing broken project checkout: $proj"
      rm -rf "$WORKDIR/$proj"
      removed=1
    fi
  done < <(extract_bad_projects_from_log "$logfile")

  return $removed
}

sync_with_recovery() {
  local log1="/tmp/repo-sync-1.log"
  local log2="/tmp/repo-sync-2.log"

  log "Checking free space before sync"
  require_free_space /workspace 120

  log "Running normal repo sync"
  if sync_once 2>&1 | tee "$log1"; then
    return 0
  fi

  log "Normal sync failed; trying single-threaded forced recovery sync"
  if sync_recovery_pass 2>&1 | tee "$log2"; then
    return 0
  fi

  log "Recovery sync failed; removing broken project directories from detected errors"
  if remove_bad_projects "$log2"; then
    log "Retrying forced recovery sync after removing broken projects"
    sync_recovery_pass
    return 0
  fi

  echo "repo sync failed and no recoverable project list was extracted." >&2
  echo "Inspect logs: $log1 and $log2" >&2
  exit 1
}

clone_or_update_wireguard() {
  local wg_dir="/workspace/wireguard-linux-compat"

  if [ ! -d "$wg_dir" ]; then
    log "Cloning wireguard-linux-compat"
    git clone "$WG_REPO" "$wg_dir"
  else
    log "Updating wireguard-linux-compat"
    git -C "$wg_dir" fetch --all --tags
    git -C "$wg_dir" pull --ff-only
  fi
}

patch_kernel_if_needed() {
  local kernel_dir="$WORKDIR/kernel/oneplus/sm8150"
  local wg_dir="/workspace/wireguard-linux-compat"

  if [ ! -d "$kernel_dir" ]; then
    echo "Kernel tree not found: $kernel_dir" >&2
    exit 1
  fi

  cd "$kernel_dir"

  if grep -Rqs 'WireGuard secure network tunnel' net 2>/dev/null; then
    log "WireGuard appears already integrated in kernel tree; skipping patch apply"
  else
    log "Applying WireGuard kernel patch"
    "$wg_dir/kernel-tree-scripts/create-patch.sh" | patch -p1
  fi

  log "Applying kernel config fragment"
  /home/builder/build/apply-config-fragment.sh \
    "$kernel_dir/arch/arm64/configs/vendor/oplus.config" \
    /home/builder/patches/kernel-extra.config
}

build_rom() {
  cd "$WORKDIR"
  source build/envsetup.sh
  breakfast "$DEVICE"
  brunch "$DEVICE"
}

main() {
  init_repo_if_needed
  sync_with_recovery

  cd "$WORKDIR"
  source build/envsetup.sh
  breakfast "$DEVICE"

  clone_or_update_wireguard
  patch_kernel_if_needed
  build_rom

  log "Build complete"
  log "Artifacts: $WORKDIR/out/target/product/$DEVICE/"
}

main "$@"

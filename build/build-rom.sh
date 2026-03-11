#!/usr/bin/env bash
set -euo pipefail

BRANCH="${BRANCH:-lineage-23.2}"
DEVICE="${DEVICE:-guacamole}"
WORKDIR="${WORKDIR:-/workspace/android}"
CCACHE_DIR="${CCACHE_DIR:-/ccache}"
CCACHE_SIZE="${CCACHE_SIZE:-100G}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
WG_REPO="${WG_REPO:-https://git.zx2c4.com/wireguard-linux-compat}"
MANIFEST_URL="${MANIFEST_URL:-https://github.com/LineageOS/android.git}"

export USE_CCACHE=1
export CCACHE_DIR
export CCACHE_EXEC=/usr/bin/ccache
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

mkdir -p "$WORKDIR" "$CCACHE_DIR"

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_git_identity() {
  git config --global user.name >/dev/null 2>&1 || git config --global user.name "Lineage Builder"
  git config --global user.email >/dev/null 2>&1 || git config --global user.email "builder@localhost"
}

init_repo() {
  cd "$WORKDIR"
  log "Initializing repo"
  yes | repo init --config-name -u "$MANIFEST_URL" -b "$BRANCH"
}

clear_repo_locks() {
  cd "$WORKDIR"
  [ -d .repo ] || return 0
  log "Clearing stale repo/git lock files"
  find .repo -type f \( -name '*.lock' -o -name 'index.lock' -o -name 'shallow.lock' \) -delete 2>/dev/null || true
}

has_repo_corruption() {
  cd "$WORKDIR"

  # If any project metadata directory is missing core git markers, treat as corrupted.
  while IFS= read -r gitdir; do
    [ -f "$gitdir/HEAD" ] || return 0
    [ -d "$gitdir/objects" ] || return 0
    [ -d "$gitdir/refs" ] || return 0
  done < <(find .repo/projects -type d -name '*.git' 2>/dev/null)

  # If any checked-out project has an invalid HEAD, treat as corrupted.
  if repo forall -c 'git rev-parse --verify -q HEAD >/dev/null || echo "$REPO_PATH"' 2>/dev/null | grep -q .; then
    return 0
  fi

  return 1
}

wipe_and_reinit_repo() {
  log "Repo corruption detected. Removing source tree and doing a full resync"
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  init_repo
}

sync_sources() {
  cd "$WORKDIR"
  clear_repo_locks

  if has_repo_corruption; then
    wipe_and_reinit_repo
  elif [ ! -d .repo ]; then
    init_repo
  fi

  log "Running repo sync"
  repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)" --force-sync --force-checkout --force-remove-dirty
}

prepare_sources() {
  cd "$WORKDIR"
  with_envsetup breakfast "$DEVICE"
}

with_envsetup() {
  local had_nounset=0
  if [[ $- == *u* ]]; then
    had_nounset=1
    set +u
  fi

  source build/envsetup.sh
  "$@"

  if [ "$had_nounset" -eq 1 ]; then
    set -u
  fi
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
  local stamp="$WORKDIR/.wg_patch_applied"

  [ -d "$kernel_dir" ] || { echo "Kernel tree not found: $kernel_dir" >&2; exit 1; }

  cd "$kernel_dir"

  if grep -Rqs 'WireGuard secure network tunnel' net 2>/dev/null; then
    log "WireGuard already appears present in kernel tree"
  elif [ -f "$stamp" ]; then
    log "WireGuard patch stamp exists; assuming already applied"
  else
    log "Applying WireGuard patch"
    "$wg_dir/kernel-tree-scripts/create-patch.sh" | patch -p1
    touch "$stamp"
  fi

  log "Applying kernel config fragment"
  /home/builder/build/apply-config-fragment.sh \
    "$kernel_dir/arch/arm64/configs/vendor/oplus.config" \
    /home/builder/patches/kernel-extra.config
}

build_rom() {
  cd "$WORKDIR"
  with_envsetup breakfast "$DEVICE"
  with_envsetup brunch "$DEVICE"
}

main() {
  require_git_identity
  ccache -M "$CCACHE_SIZE" || true
  sync_sources
  prepare_sources
  clone_or_update_wireguard
  patch_kernel_if_needed
  build_rom
  log "Build complete"
  log "Artifacts: $WORKDIR/out/target/product/$DEVICE/"
}

main "$@"

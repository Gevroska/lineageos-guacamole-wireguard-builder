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

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_git_identity() {
  if ! git config --global user.name >/dev/null; then
    git config --global user.name "Lineage Builder"
  fi
  if ! git config --global user.email >/dev/null; then
    git config --global user.email "builder@localhost"
  fi
}

require_free_space_gb() {
  local path="$1"
  local min_gb="$2"
  local avail_kb min_kb

  avail_kb="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  min_kb=$((min_gb * 1024 * 1024))

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

clear_repo_locks() {
  cd "$WORKDIR"
  log "Clearing stale repo/git lock files"
  find .repo -type f \( -name '*.lock' -o -name 'index.lock' -o -name 'shallow.lock' \) -delete 2>/dev/null || true
}

sync_aggressive_parallel() {
  cd "$WORKDIR"
  repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)" --force-sync --force-checkout --force-remove-dirty
}

sync_forced_single() {
  cd "$WORKDIR"
  repo sync -c --no-clone-bundle --no-tags -j1 --force-sync --force-checkout --force-remove-dirty --fail-fast
}

count_recovery_errors() {
  local total=0
  local logfile

  for logfile in "$@"; do
    [ -f "$logfile" ] || continue
    total=$((total + $(grep -E -c 'unparseable HEAD|Check that HEAD ref in \.git/HEAD is valid|would be overwritten by checkout| checkout [0-9a-f]{7,}' "$logfile" || true)))
  done

  echo "$total"
}

extract_bad_projects_from_log() {
  local logfile="$1"

  awk '
    /: unparseable HEAD; trying to recover/ {
      sub(/^project /, "", $0)
      sub(/: unparseable HEAD; trying to recover.*/, "", $0)
      print
    }
    /^error: .*: .* checkout [0-9a-f]+$/ {
      sub(/^error: /, "", $0)
      sub(/: .*$/, "", $0)
      print
    }
  ' "$logfile" | sort -u
}

find_invalid_head_projects() {
  cd "$WORKDIR"
  repo forall -c 'git rev-parse --verify -q HEAD >/dev/null || echo "$REPO_PATH"' 2>/dev/null || true
}

remove_bad_projects_from_logs() {
  local removed_any=1
  local proj
  local logfile

  for logfile in "$@"; do
    [ -f "$logfile" ] || continue
    while IFS= read -r proj; do
      [ -z "$proj" ] && continue
      if [ -e "$WORKDIR/$proj" ]; then
        log "Removing broken project from log ($logfile): $proj"
        rm -rf "$WORKDIR/$proj"
        removed_any=0
      fi
    done < <(extract_bad_projects_from_log "$logfile")
  done

  while IFS= read -r proj; do
    [ -z "$proj" ] && continue
    if [ -e "$WORKDIR/$proj" ]; then
      log "Removing project with invalid HEAD: $proj"
      rm -rf "$WORKDIR/$proj"
      removed_any=0
    fi
  done < <(find_invalid_head_projects)

  return "$removed_any"
}

wipe_worktrees_but_keep_repo() {
  cd "$WORKDIR"
  log "Wiping all working trees but keeping .repo"
  find . -mindepth 1 -maxdepth 1 ! -name .repo -exec rm -rf {} +
}

sync_with_recovery() {
  local log1="/tmp/repo-sync-normal.log"
  local log2="/tmp/repo-sync-recovery.log"
  local log3="/tmp/repo-sync-rebuild.log"
  local errcount=0

  require_free_space_gb /workspace 120

  clear_repo_locks

  log "Running aggressive repo sync"
  if sync_aggressive_parallel 2>&1 | tee "$log1"; then
    return 0
  fi

  log "Checking for projects with invalid Git HEAD before retry"
  if remove_bad_projects_from_logs "$log1"; then
    log "Removed broken projects; retrying forced single-thread sync"
    clear_repo_locks
    if sync_forced_single 2>&1 | tee "$log2"; then
      return 0
    fi
  fi

  clear_repo_locks

  log "Aggressive sync failed; running forced single-thread recovery sync"
  if sync_forced_single 2>&1 | tee "$log2"; then
    return 0
  fi

  errcount="$(count_recovery_errors "$log1" "$log2")"
  log "Recovery sync error count: $errcount"

  if [ "${errcount:-0}" -ge 20 ]; then
    log "Too many broken repos detected; rebuilding working tree from .repo"
    wipe_worktrees_but_keep_repo
    require_free_space_gb /workspace 120
    clear_repo_locks
    sync_forced_single 2>&1 | tee "$log3"
    return 0
  fi

  log "Trying targeted removal of broken projects"
  if remove_bad_projects_from_logs "$log1" "$log2"; then
    clear_repo_locks
    sync_forced_single 2>&1 | tee "$log3"
    return 0
  fi

  echo "repo sync failed and recovery could not fix it." >&2
  echo "Logs: $log1 $log2 $log3" >&2
  exit 1
}

prepare_sources() {
  cd "$WORKDIR"
  source build/envsetup.sh
  breakfast "$DEVICE"
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

  if [ ! -d "$kernel_dir" ]; then
    echo "Kernel tree not found: $kernel_dir" >&2
    exit 1
  fi

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
  source build/envsetup.sh
  breakfast "$DEVICE"
  brunch "$DEVICE"
}

main() {
  require_git_identity
  ccache -M "$CCACHE_SIZE" || true
  init_repo_if_needed
  sync_with_recovery
  prepare_sources
  clone_or_update_wireguard
  patch_kernel_if_needed
  build_rom
  log "Build complete"
  log "Artifacts: $WORKDIR/out/target/product/$DEVICE/"
}

main "$@"

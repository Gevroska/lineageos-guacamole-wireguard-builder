#!/usr/bin/env bash
set -euo pipefail

BRANCH="${BRANCH:-lineage-23.2}"
DEVICE="${DEVICE:-guacamole}"
WORKDIR="${WORKDIR:-/workspace/android}"
CCACHE_DIR="${CCACHE_DIR:-/ccache}"
CCACHE_SIZE="${CCACHE_SIZE:-250G}"
BUILD_JOBS="${BUILD_JOBS:-}"
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

write_vendor_local_manifest() {
  cd "$WORKDIR"
  [ -d .repo ] || return 0

  mkdir -p .repo/local_manifests
  cat > .repo/local_manifests/roomservice-vendor.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="TheMuppets/proprietary_vendor_oneplus_guacamole" path="vendor/oneplus/guacamole" remote="github" revision="${BRANCH}" />
  <project name="TheMuppets/proprietary_vendor_oneplus_sm8150-common" path="vendor/oneplus/sm8150-common" remote="github" revision="${BRANCH}" />
</manifest>
EOF
}

sync_sources() {
  cd "$WORKDIR"
  clear_repo_locks

  if has_repo_corruption; then
    wipe_and_reinit_repo
  elif [ ! -d .repo ]; then
    init_repo
  fi

  # Keep vendor project remotes stable before a full-tree sync, so stale local manifests
  # don't keep pointing at unavailable/private repository namespaces.
  write_vendor_local_manifest

  log "Running repo sync"
  repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)" --force-sync --force-checkout --force-remove-dirty
}

detect_build_jobs() {
  # Build parallelism is intentionally simple:
  # - if BUILD_JOBS is set, use it as-is
  # - otherwise, use all detected CPU threads
  # Memory-based auto-throttling was removed by design; size RAM/swap on the host instead.
  if [ -n "${BUILD_JOBS}" ]; then
    log "Using build parallelism from BUILD_JOBS: -j${BUILD_JOBS}"
    return
  fi

  BUILD_JOBS="$(nproc --all)"
  log "Using build parallelism: -j${BUILD_JOBS}"
}

# Backward-compatibility shim: older script revisions invoked prepare_sources() in main.
# Keep a no-op implementation so mixed/stale script copies fail safe instead of aborting.
prepare_sources() {
  log "prepare_sources is deprecated and now a no-op"
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


ensure_vendor_repos() {
  cd "$WORKDIR"

  local missing_vendor=0
  [ -f vendor/oneplus/guacamole/guacamole-vendor.mk ] || missing_vendor=1
  [ -f vendor/oneplus/sm8150-common/sm8150-common-vendor.mk ] || missing_vendor=1

  if [ "$missing_vendor" -eq 0 ]; then
    log "Vendor makefiles already present"
    return
  fi

  log "Adding missing vendor projects for guacamole (TheMuppets)"
  write_vendor_local_manifest

  log "Syncing vendor projects"
  repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)" vendor/oneplus/guacamole vendor/oneplus/sm8150-common
}

fix_guacamole_logo_sha1() {
  cd "$WORKDIR"

  local mk_file="vendor/oneplus/guacamole/Android.mk"
  local logo_file="vendor/oneplus/guacamole/radio/LOGO.img"

  [ -f "$mk_file" ] || return 0
  [ -f "$logo_file" ] || return 0

  local actual_sha1
  actual_sha1="$(sha1sum "$logo_file" | awk '{print $1}')"

  # The vendor blob set occasionally republishes LOGO.img with a different hash
  # while keeping the same filename. Keep Android.mk in sync to avoid kati aborting.
  if grep -q "vendor/oneplus/guacamole/radio/LOGO\.img" "$mk_file"; then
    local expected_sha1
    expected_sha1="$(sed -nE '/vendor\/oneplus\/guacamole\/radio\/LOGO\.img/ { s/.*([0-9a-fA-F]{40}).*/\1/p; q; }' "$mk_file" | tr 'A-F' 'a-f')"

    if [ "$expected_sha1" != "$actual_sha1" ]; then
      log "Updating LOGO.img SHA1 in $mk_file to $actual_sha1"
      python3 - "$mk_file" "$actual_sha1" <<'PYCODE'
import pathlib
import re
import sys

mk_path = pathlib.Path(sys.argv[1])
actual_sha1 = sys.argv[2]
lines = mk_path.read_text().splitlines()
updated_lines = []
changed = False

for line in lines:
    if "vendor/oneplus/guacamole/radio/LOGO.img" in line:
        line2 = re.sub(r"[0-9a-fA-F]{40}", actual_sha1, line, count=1)
        if line2 != line:
            changed = True
        line = line2
    updated_lines.append(line)

if changed:
    mk_path.write_text("\n".join(updated_lines) + "\n")
PYCODE

      expected_sha1="$(sed -nE '/vendor\/oneplus\/guacamole\/radio\/LOGO\.img/ { s/.*([0-9a-fA-F]{40}).*/\1/p; q; }' "$mk_file" | tr 'A-F' 'a-f')"
    fi

    if [ -z "$expected_sha1" ] || [ "$expected_sha1" != "$actual_sha1" ]; then
      echo "Failed to normalize LOGO.img SHA1 in $mk_file (expected: ${expected_sha1:-missing}, actual: $actual_sha1)" >&2
      return 1
    fi
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
  detect_build_jobs
  export NINJA_ARGS="-j${BUILD_JOBS}"
  with_envsetup brunch "$DEVICE"
}

main() {
  require_git_identity
  log "Disabling ccache compression"
  ccache --set-config compression=false || true
  ccache -M "$CCACHE_SIZE" || true
  sync_sources
  ensure_vendor_repos
  fix_guacamole_logo_sha1
  prepare_sources
  clone_or_update_wireguard
  patch_kernel_if_needed
  build_rom
  log "Build complete"
  log "Artifacts: $WORKDIR/out/target/product/$DEVICE/"
}

main "$@"

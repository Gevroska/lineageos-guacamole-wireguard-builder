#!/usr/bin/env bash
set -euo pipefail

BRANCH="${BRANCH:-lineage-23.2}"
DEVICE="${DEVICE:-guacamole}"
WORKDIR="${WORKDIR:-/workspace/android}"
CCACHE_DIR="${CCACHE_DIR:-/ccache}"
CCACHE_SIZE="${CCACHE_SIZE:-2G}"
BUILD_JOBS="${BUILD_JOBS:-}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
WG_REPO="${WG_REPO:-https://git.zx2c4.com/wireguard-linux-compat}"
MANIFEST_URL="${MANIFEST_URL:-https://github.com/LineageOS/android.git}"
KERNEL_DIR=""

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

normalize_guacamole_radio_sha1s() {
  cd "$WORKDIR"

  local mk_file="vendor/oneplus/guacamole/Android.mk"
  local radio_dir="vendor/oneplus/guacamole/radio"

  [ -f "$mk_file" ] || return 0
  [ -d "$radio_dir" ] || return 0

  # Normalize SHA1 pins for radio blobs referenced by vendor Android.mk entries
  # like: $(call add-radio-file-sha1-checked,radio/abl.img,<sha1>)
  python3 - "$mk_file" "$radio_dir" <<'PYCODE'
import hashlib
import pathlib
import re
import sys

mk_path = pathlib.Path(sys.argv[1])
radio_dir = pathlib.Path(sys.argv[2])

pattern = re.compile(r'(add-radio-file-sha1-checked\s*,\s*([^,\s)]+)\s*,\s*([0-9a-fA-F]{40}))')
lines = mk_path.read_text().splitlines()
out = []
changed = False

for line in lines:
    m = pattern.search(line)
    if not m:
        out.append(line)
        continue

    rel_path = m.group(2).strip().strip("\"'")
    expected = m.group(3).lower()

    # Vendor makefiles usually reference radio/*.img relative to vendor root.
    # Keep behavior safe by only mutating entries that resolve under radio_dir.
    candidate = rel_path
    if rel_path.startswith('vendor/oneplus/guacamole/'):
        candidate = rel_path[len('vendor/oneplus/guacamole/'):]
    blob_path = (radio_dir.parent / candidate).resolve()

    if not blob_path.exists() or not str(blob_path).startswith(str(radio_dir.parent.resolve())):
        out.append(line)
        continue

    actual = hashlib.sha1(blob_path.read_bytes()).hexdigest()
    if actual != expected:
        print(f"normalize: {rel_path} {expected} -> {actual}")
        line = line[:m.start(3)] + actual + line[m.end(3):]
        changed = True
    out.append(line)

if changed:
    mk_path.write_text("\n".join(out) + "\n")
PYCODE
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

resolve_kernel_dir() {
  if [ -n "$KERNEL_DIR" ] && [ -d "$KERNEL_DIR" ]; then
    echo "$KERNEL_DIR"
    return 0
  fi

  local candidate
  local -a kernel_candidates=(
    "$WORKDIR/kernel/oneplus/sm8150"
    "$WORKDIR/kernel/oneplus/sm8150-common"
  )

  # Learn device-declared kernel paths (if available), e.g. TARGET_KERNEL_SOURCE.
  local config_file
  while IFS= read -r config_file; do
    candidate="$(sed -n -E 's/^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*:?=[[:space:]]*([^[:space:]#]+).*/\1/p' "$config_file" | head -n1)"
    [ -n "$candidate" ] || continue
    candidate="${candidate%%/}"
    kernel_candidates+=("$WORKDIR/$candidate")
  done < <(find "$WORKDIR/device" -type f \( -name 'BoardConfig*.mk' -o -name 'lineage_*.mk' \) 2>/dev/null)

  # First pass: direct path checks.
  for candidate in "${kernel_candidates[@]}"; do
    if [ -d "$candidate" ]; then
      KERNEL_DIR="$candidate"
      echo "$KERNEL_DIR"
      return 0
    fi
  done

  # If likely paths are missing, try syncing them (best effort).
  if [ -d "$WORKDIR/.repo" ]; then
    local rel
    local -a to_sync=()
    for candidate in "${kernel_candidates[@]}"; do
      rel="${candidate#"$WORKDIR/"}"
      [ -n "$rel" ] || continue
      [ "$rel" = "$candidate" ] && continue
      case "$rel" in
        kernel/*) to_sync+=("$rel") ;;
      esac
    done

    if [ ${#to_sync[@]} -eq 0 ]; then
      to_sync=(kernel/oneplus/sm8150 kernel/oneplus/sm8150-common)
    fi

    repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)" "${to_sync[@]}" >/dev/null 2>&1 || true
  fi

  # Second pass after targeted sync.
  for candidate in "${kernel_candidates[@]}"; do
    if [ -d "$candidate" ]; then
      KERNEL_DIR="$candidate"
      echo "$KERNEL_DIR"
      return 0
    fi
  done

  # Final fallback: infer kernel root from any arch/arm64 subtree.
  candidate="$(find "$WORKDIR/kernel" -mindepth 2 -maxdepth 8 -type d -path '*/arch/arm64' -print -quit 2>/dev/null || true)"
  if [ -n "$candidate" ]; then
    KERNEL_DIR="$(dirname "$(dirname "$candidate")")"
    echo "$KERNEL_DIR"
    return 0
  fi

  return 1
}



prefer_native_wireguard_over_compat() {
  local kernel_dir
  kernel_dir="$(resolve_kernel_dir)" || return 0
  local net_wg_dir="$kernel_dir/net/wireguard"
  local drv_wg_dir="$kernel_dir/drivers/net/wireguard"
  local net_mk="$kernel_dir/net/Makefile"
  local net_kconfig="$kernel_dir/net/Kconfig"

  [ -d "$net_wg_dir" ] || return 0
  [ -d "$drv_wg_dir" ] || return 0

  log "Detected both net/wireguard and drivers/net/wireguard; preferring native drivers tree"

  # Remove compat tree to avoid duplicate symbol linkage when both implementations build.
  rm -rf "$net_wg_dir"

  # Remove compat tree hooks from net/Makefile and net/Kconfig (idempotent).
  [ ! -f "$net_mk" ] || sed -i -E '/wireguard\//d' "$net_mk"
  [ ! -f "$net_kconfig" ] || sed -i -E '/source "net\/wireguard\/Kconfig"/d' "$net_kconfig"
}

fix_wireguard_timespec_macro_conflict() {
  local kernel_dir
  kernel_dir="$(resolve_kernel_dir)" || return 0
  local compat_h="$kernel_dir/net/wireguard/compat/compat.h"

  [ -f "$compat_h" ] || return 0

  # On some 4.14 Android kernels, include/linux/time64.h defines
  # '__kernel_timespec' as a macro to 'timespec'. The compat header then
  # declares 'struct __kernel_timespec', which macro-expands into a duplicate
  # 'struct timespec' declaration and breaks WireGuard compilation.
  #
  # Make the patch idempotent: only inject the undef guard once.
  if ! grep -q 'wireguard-builder: avoid __kernel_timespec macro redefinition' "$compat_h"; then
    python3 - "$compat_h" <<'PYCODE'
import pathlib
import sys

compat_h = pathlib.Path(sys.argv[1])
text = compat_h.read_text()
needle = 'struct __kernel_timespec {'
if needle not in text:
    sys.exit(0)

replacement = (
    '#ifdef __kernel_timespec\n'
    '/* wireguard-builder: avoid __kernel_timespec macro redefinition */\n'
    '#undef __kernel_timespec\n'
    '#endif\n'
    'struct __kernel_timespec {'
)
new_text = text.replace(needle, replacement, 1)
if new_text != text:
    compat_h.write_text(new_text)
PYCODE
    log "Applied WireGuard __kernel_timespec macro conflict workaround"
  fi
}

patch_kernel_if_needed() {
  local kernel_dir
  kernel_dir="$(resolve_kernel_dir)" || {
    echo "Kernel tree not found under expected locations: $WORKDIR/kernel/oneplus/sm8150 or $WORKDIR/kernel/oneplus/sm8150-common" >&2
    exit 1
  }
  local wg_dir="/workspace/wireguard-linux-compat"
  local stamp="$WORKDIR/.wg_patch_applied"

  cd "$kernel_dir"

  if [ -d "$kernel_dir/drivers/net/wireguard" ]; then
    log "Native kernel WireGuard detected under drivers/net/wireguard; skipping compat patch"
  elif grep -Rqs 'WireGuard secure network tunnel' net 2>/dev/null; then
    log "WireGuard already appears present in kernel tree"
  elif [ -f "$stamp" ]; then
    log "WireGuard patch stamp exists; assuming already applied"
  else
    log "Applying WireGuard patch"
    "$wg_dir/kernel-tree-scripts/create-patch.sh" | patch -p1
    touch "$stamp"
  fi

  prefer_native_wireguard_over_compat
  fix_wireguard_timespec_macro_conflict

  log "Applying kernel config fragment"
  /home/builder/build/apply-config-fragment.sh \
    "$kernel_dir/arch/arm64/configs/vendor/oplus.config" \
    /home/builder/patches/kernel-extra.config
}

build_kernel() {
  cd "$WORKDIR"
  detect_build_jobs
  export NINJA_ARGS="-j${BUILD_JOBS}"

  local had_nounset=0
  if [[ $- == *u* ]]; then
    had_nounset=1
    set +u
  fi

  source build/envsetup.sh

  if declare -F breakfast >/dev/null 2>&1; then
    log "Selecting target via breakfast: ${DEVICE} userdebug"
    if breakfast "$DEVICE" userdebug; then
      :
    elif breakfast "$DEVICE"; then
      :
    else
      echo "Failed to select build target with breakfast for device: $DEVICE" >&2
      exit 1
    fi
  else
    log "Selecting target via lunch"
    if lunch "lineage_${DEVICE}-userdebug"; then
      :
    elif lunch "lineage_${DEVICE}-trunk_staging-userdebug"; then
      :
    else
      echo "Failed to select build target via lunch for device: $DEVICE" >&2
      exit 1
    fi
  fi

  # Some vendor trees regenerate/sync blobs during target setup and can
  # reintroduce stale SHA1 pins for radio blobs. Recheck right before building.
  normalize_guacamole_radio_sha1s

  local build_log="$WORKDIR/out/bootimage-build.log"
  mkdir -p "$(dirname "$build_log")"
  rm -f "$build_log"

  report_build_failure() {
    log "Build failed. Full log: $build_log"
    log "Recent error lines from build log"
    grep -En '(^|[[:space:]])(error:|fatal:|FAILED:|Killed|No space left on device|undefined reference)' "$build_log" | tail -n 40 || true
    log "Last 120 lines of build log"
    tail -n 120 "$build_log" || true
  }

  if ! mka bootimage 2>&1 | tee "$build_log"; then
    if grep -Eq "vendor/oneplus/guacamole/radio/[^ ]+ SHA1 mismatch" "$build_log"; then
      log "Detected radio blob SHA1 mismatch during build; re-normalizing and retrying once"
      normalize_guacamole_radio_sha1s
      if ! mka bootimage 2>&1 | tee -a "$build_log"; then
        report_build_failure
        return 1
      fi
    else
      report_build_failure
      return 1
    fi
  fi

  if [ "$had_nounset" -eq 1 ]; then
    set -u
  fi
}

main() {
  require_git_identity
  log "Disabling ccache compression"
  ccache --set-config compression=false || true
  ccache -M "$CCACHE_SIZE" || true
  sync_sources
  ensure_vendor_repos
  normalize_guacamole_radio_sha1s
  prepare_sources
  clone_or_update_wireguard
  patch_kernel_if_needed
  log "Running kernel-only build (bootimage)"
  build_kernel
  log "Build complete"
  log "Artifacts: $WORKDIR/out/target/product/$DEVICE/"
}

main "$@"

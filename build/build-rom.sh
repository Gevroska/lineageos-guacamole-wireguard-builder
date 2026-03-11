diff --git a/build/build-rom.sh b/build/build-rom.sh
index 7f32a3b06f46bf985fc3c5c571c7960026217f25..e67c8352ec4f953ffb3c0f33a8baa7db7688ce18 100644
--- a/build/build-rom.sh
+++ b/build/build-rom.sh
@@ -1,165 +1,318 @@
 #!/usr/bin/env bash
 set -euo pipefail
 
 BRANCH="${BRANCH:-lineage-23.2}"
 DEVICE="${DEVICE:-guacamole}"
 WORKDIR="${WORKDIR:-/workspace/android}"
 CCACHE_DIR="${CCACHE_DIR:-/ccache}"
 CCACHE_SIZE="${CCACHE_SIZE:-100G}"
 JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
 WG_REPO="${WG_REPO:-https://git.zx2c4.com/wireguard-linux-compat}"
+PREEMPTIVE_REBUILD_THRESHOLD="${PREEMPTIVE_REBUILD_THRESHOLD:-200}"
 
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
 
-sync_normal() {
+clear_repo_locks() {
   cd "$WORKDIR"
-  repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)"
+  log "Clearing stale repo/git lock files"
+  find .repo -type f \( -name '*.lock' -o -name 'index.lock' -o -name 'shallow.lock' \) -delete 2>/dev/null || true
+}
+
+sync_aggressive_parallel() {
+  cd "$WORKDIR"
+  repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)" --force-sync --force-checkout --force-remove-dirty --fail-fast
 }
 
 sync_forced_single() {
   cd "$WORKDIR"
-  repo sync -c --no-clone-bundle --no-tags -j1 --force-sync --force-checkout --fail-fast
+  repo sync -c --no-clone-bundle --no-tags -j1 --force-sync --force-checkout --force-remove-dirty --fail-fast
 }
 
 count_recovery_errors() {
-  local logfile="$1"
-  grep -E -c 'unparseable HEAD|would be overwritten by checkout| checkout [0-9a-f]{7,}' "$logfile" || true
+  local total=0
+  local logfile
+
+  for logfile in "$@"; do
+    [ -f "$logfile" ] || continue
+    total=$((total + $(grep -E -c 'unparseable HEAD|Check that HEAD ref in \.git/HEAD is valid|would be overwritten by checkout| checkout [0-9a-f]{7,}' "$logfile" || true)))
+  done
+
+  echo "$total"
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
 
-remove_bad_projects() {
+extract_broken_repo_gitdirs_from_log() {
+  local logfile="$1"
+
+  awk '
+    /not a git repository:/ {
+      if (match($0, /\047[^\047]+\047/)) {
+        p = substr($0, RSTART + 1, RLENGTH - 2)
+        print p
+      }
+    }
+  ' "$logfile" | sort -u
+}
+
+extract_failed_project_objects_from_log() {
   local logfile="$1"
+
+  awk '
+    /GitCommandError:/ && / on / && / failed/ {
+      if (match($0, / on [^ ]+ failed/)) {
+        p = substr($0, RSTART + 4, RLENGTH - 11)
+        print p
+      }
+    }
+  ' "$logfile" | sort -u
+}
+
+repair_repo_metadata_from_logs() {
+  local repaired_any=1
+  local logfile
+  local gitdir
+  local rel
+  local project
+
+  for logfile in "$@"; do
+    [ -f "$logfile" ] || continue
+
+    while IFS= read -r gitdir; do
+      [ -z "$gitdir" ] && continue
+      case "$gitdir" in
+        "$WORKDIR"/.repo/*)
+          if [ -e "$gitdir" ]; then
+            log "Removing broken repo metadata from log ($logfile): $gitdir"
+            rm -rf "$gitdir"
+            repaired_any=0
+          fi
+          rel="${gitdir#"$WORKDIR/.repo/projects/"}"
+          rel="${rel%.git}"
+          if [ -n "$rel" ] && [ "$rel" != "$gitdir" ] && [ -e "$WORKDIR/$rel" ]; then
+            log "Removing worktree for broken repo metadata: $rel"
+            rm -rf "$WORKDIR/$rel"
+            repaired_any=0
+          fi
+          ;;
+      esac
+    done < <(extract_broken_repo_gitdirs_from_log "$logfile")
+
+    while IFS= read -r project; do
+      [ -z "$project" ] && continue
+      if [ -e "$WORKDIR/.repo/project-objects/$project.git" ]; then
+        log "Removing broken project object metadata from log ($logfile): $project"
+        rm -rf "$WORKDIR/.repo/project-objects/$project.git"
+        repaired_any=0
+      fi
+    done < <(extract_failed_project_objects_from_log "$logfile")
+  done
+
+  return "$repaired_any"
+}
+
+find_invalid_head_projects() {
+  cd "$WORKDIR"
+  repo forall -c 'git rev-parse --verify -q HEAD >/dev/null || echo "$REPO_PATH"' 2>/dev/null || true
+}
+
+remove_bad_projects_from_logs() {
   local removed_any=1
+  local proj
+  local logfile
+
+  for logfile in "$@"; do
+    [ -f "$logfile" ] || continue
+    while IFS= read -r proj; do
+      [ -z "$proj" ] && continue
+      if [ -e "$WORKDIR/$proj" ]; then
+        log "Removing broken project from log ($logfile): $proj"
+        rm -rf "$WORKDIR/$proj"
+        removed_any=0
+      fi
+    done < <(extract_bad_projects_from_log "$logfile")
+  done
 
   while IFS= read -r proj; do
     [ -z "$proj" ] && continue
     if [ -e "$WORKDIR/$proj" ]; then
-      log "Removing broken project: $proj"
+      log "Removing project with invalid HEAD: $proj"
       rm -rf "$WORKDIR/$proj"
       removed_any=0
     fi
-  done < <(extract_bad_projects_from_log "$logfile")
+  done < <(find_invalid_head_projects)
 
   return "$removed_any"
 }
 
+preflight_repair_corrupt_projects() {
+  local invalid_projects=()
+  local invalid_count=0
+  local proj
+
+  mapfile -t invalid_projects < <(find_invalid_head_projects | sed '/^$/d' | sort -u)
+  invalid_count="${#invalid_projects[@]}"
+
+  if [ "$invalid_count" -eq 0 ]; then
+    return 0
+  fi
+
+  log "Preflight detected $invalid_count projects with invalid Git HEAD"
+  if [ "$invalid_count" -ge "$PREEMPTIVE_REBUILD_THRESHOLD" ]; then
+    log "Invalid HEAD count >= $PREEMPTIVE_REBUILD_THRESHOLD; wiping worktrees before sync"
+    wipe_worktrees_but_keep_repo
+    return 0
+  fi
+
+  for proj in "${invalid_projects[@]}"; do
+    if [ -e "$WORKDIR/$proj" ]; then
+      log "Preflight removing invalid-HEAD project: $proj"
+      rm -rf "$WORKDIR/$proj"
+    fi
+  done
+}
+
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
 
-  log "Running normal repo sync"
-  if sync_normal 2>&1 | tee "$log1"; then
+  clear_repo_locks
+  preflight_repair_corrupt_projects
+  clear_repo_locks
+
+  log "Running aggressive repo sync"
+  if sync_aggressive_parallel 2>&1 | tee "$log1"; then
     return 0
   fi
 
-  log "Normal sync failed; running forced single-thread recovery sync"
+  log "Checking for broken .repo metadata before retry"
+  if repair_repo_metadata_from_logs "$log1"; then
+    clear_repo_locks
+    if sync_forced_single 2>&1 | tee "$log2"; then
+      return 0
+    fi
+  fi
+
+  log "Checking for projects with invalid Git HEAD before retry"
+  if remove_bad_projects_from_logs "$log1"; then
+    log "Removed broken projects; retrying forced single-thread sync"
+    clear_repo_locks
+    if sync_forced_single 2>&1 | tee "$log2"; then
+      return 0
+    fi
+  fi
+
+  clear_repo_locks
+
+  log "Aggressive sync failed; running forced single-thread recovery sync"
   if sync_forced_single 2>&1 | tee "$log2"; then
     return 0
   fi
 
-  errcount="$(count_recovery_errors "$log2")"
+  errcount="$(count_recovery_errors "$log1" "$log2")"
   log "Recovery sync error count: $errcount"
 
   if [ "${errcount:-0}" -ge 20 ]; then
     log "Too many broken repos detected; rebuilding working tree from .repo"
     wipe_worktrees_but_keep_repo
     require_free_space_gb /workspace 120
+    clear_repo_locks
     sync_forced_single 2>&1 | tee "$log3"
     return 0
   fi
 
-  log "Trying targeted removal of broken projects"
-  if remove_bad_projects "$log2"; then
+  log "Trying targeted metadata and project cleanup"
+  if repair_repo_metadata_from_logs "$log1" "$log2" || remove_bad_projects_from_logs "$log1" "$log2"; then
+    clear_repo_locks
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
@@ -192,26 +345,96 @@ patch_kernel_if_needed() {
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
 
-main "$@"
+run_selftests() {
+  local tmp
+  local work
+  local bin
+  local logf
+
+  tmp="$(mktemp -d)"
+  work="$tmp/work"
+  bin="$tmp/bin"
+  mkdir -p "$work/.repo" "$work/external/a" "$work/external/b" "$work/external/c" "$bin"
+
+  cat >"$bin/repo" <<'EOF'
+#!/usr/bin/env bash
+set -e
+if [ "$1" = "forall" ]; then
+  printf '%s\n' "${MOCK_REPO_FORALL_OUTPUT:-}"
+  exit 0
+fi
+if [ "$1" = "sync" ]; then
+  exit 0
+fi
+exit 0
+EOF
+  chmod +x "$bin/repo"
+
+  PATH="$bin:$PATH"
+  WORKDIR="$work"
+
+  MOCK_REPO_FORALL_OUTPUT=$'external/a
+external/b' PREEMPTIVE_REBUILD_THRESHOLD=10 preflight_repair_corrupt_projects
+  [ ! -e "$work/external/a" ]
+  [ ! -e "$work/external/b" ]
+
+  mkdir -p "$work/external/d" "$work/external/e"
+  MOCK_REPO_FORALL_OUTPUT=$'external/c
+external/d
+external/e' PREEMPTIVE_REBUILD_THRESHOLD=3 preflight_repair_corrupt_projects
+  [ -d "$work/.repo" ]
+  [ ! -e "$work/external/c" ]
+  [ ! -e "$work/external/d" ]
+  [ ! -e "$work/external/e" ]
+
+  logf="$tmp/recovery.log"
+  cat >"$logf" <<'EOF'
+project external/google-fonts/fraunces: unparseable HEAD; trying to recover.
+Check that HEAD ref in .git/HEAD is valid.
+EOF
+  [ "$(count_recovery_errors "$logf")" -eq 2 ]
+
+  mkdir -p "$work/.repo/projects/external/icu.git" "$work/.repo/project-objects/platform/external/icu.git" "$work/external/icu"
+  cat >"$tmp/meta.log" <<EOF
+GitCommandError: 'fetch --quiet aosp --force --prune --recurse-submodules=no --no-tags tag android-16.0.0_r4 +refs/tags/android-16.0.0_r4:refs/tags/android-16.0.0_r4' on platform/external/icu failed
+stdout: fatal: not a git repository: '$work/.repo/projects/external/icu.git'
+EOF
+  repair_repo_metadata_from_logs "$tmp/meta.log"
+  [ ! -e "$work/.repo/projects/external/icu.git" ]
+  [ ! -e "$work/.repo/project-objects/platform/external/icu.git" ]
+  [ ! -e "$work/external/icu" ]
+
+  rm -rf "$tmp"
+  echo "Selftests passed"
+}
+
+if [ "${BUILD_ROM_SH_SELFTEST:-0}" = "1" ]; then
+  run_selftests
+  exit 0
+fi
+
+if [ "${BUILD_ROM_SH_LIB_ONLY:-0}" != "1" ]; then
+  main "$@"
+fi

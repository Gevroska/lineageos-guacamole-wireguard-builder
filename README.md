# lineageos-guacamole-wireguard-builder

Dockerized LineageOS 23.2 build environment for the OnePlus 7 Pro (`guacamole`) with:

- F2FS kept enabled for `/data`
- WireGuard backported into the kernel tree
- Docker and compose setup
- persistent source tree and ccache volumes

## Device target

- Phone: OnePlus 7 Pro
- Codename: `guacamole`
- SoC: Snapdragon 855 / SM8150
- Kernel tree: `kernel/oneplus/sm8150`

## Why this repo exists

The goal is to build a patched LineageOS kernel/boot image for `guacamole` while ensuring:

- the kernel still supports F2FS so an existing F2FS `/data` continues to mount
- WireGuard support is actually present in the kernel on the 4.14 tree

## Important note

This repo does **not** mirror all LineageOS sources. It only provides the container, scripts, and patching logic. The Android source tree is synced at build time with `repo`.

## What gets patched

### F2FS

LineageOS 23.2 for guacamole already has F2FS enabled in the active kernel config, so this repo does not try to add basic F2FS support from scratch.

Optional extra config is applied through:

- `patches/kernel-extra.config`

### WireGuard

The SM8150 Lineage kernel is based on Linux 4.14, so WireGuard must be brought in through `wireguard-linux-compat`.

The build script:

1. clones `wireguard-linux-compat`
2. generates an in-tree patch with `create-patch.sh`
3. applies it to `kernel/oneplus/sm8150`
4. ensures `CONFIG_WIREGUARD=y` remains enabled

## Repo contents

- `Dockerfile` — build image
- `compose.yaml` — Docker Compose stack definition
- `build/build-rom.sh` — automated kernel (`bootimage`) build script
- `build/apply-config-fragment.sh` — helper to merge config fragment
- `patches/kernel-extra.config` — extra kernel options to force

## Persistent host volumes (required)

The build uses mounted host directories so sources and ccache survive container restarts.

`$PWD` means your **current directory** in the shell (for example, if you are in `/home/user/lineage`, then `$PWD/workspace` resolves to `/home/user/lineage/workspace`).

Create persistent directories on the host before running the container:

```bash
# Option A: keep data under your current directory
mkdir -p "$PWD/workspace" "$PWD/ccache"

# Option B: fixed system path (example)
sudo mkdir -p /srv/lineage-guacamole/workspace /srv/lineage-guacamole/ccache
sudo chown -R 1000:1000 /srv/lineage-guacamole
```

Use whichever path layout you prefer, but keep the mounts persistent.

Docker Compose automatically reads a `.env` file in the repo root. Using one is recommended if you want to override build settings (branch/device/workdir/ccache/java/wireguard URL) without editing `compose.yaml`.

Example `.env` (same keys as the defaults):

```dotenv
BRANCH=lineage-23.2
DEVICE=guacamole
WORKDIR=/workspace/android
CCACHE_DIR=/ccache
CCACHE_SIZE=250G
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
WG_REPO=https://git.zx2c4.com/wireguard-linux-compat
# optional
# BUILD_JOBS=8
```

You can create it quickly with:

```bash
cp .env.example .env
```

## Host requirements

For reliable LineageOS 23.2 builds, use at least:

- **24 GB RAM**
- **Swap enabled/increased** (recommended: at least 16 GB swap; 24+ GB is safer for heavy Soong phases)

Lower-memory hosts may hit OOM (`Killed`) during Soong bootstrap.

### Build parallelism behavior (clarified)

The build script no longer uses RAM-based heuristics to decide `-j`.

- If `BUILD_JOBS` is set, that exact value is used.
- If `BUILD_JOBS` is not set, the script uses all CPU threads (`nproc --all`).

Example overrides:

```bash
# docker run: set BUILD_JOBS at runtime
docker run --rm -it \
  -e BUILD_JOBS=8 \
  -v "$PWD/workspace:/workspace" \
  -v "$PWD/ccache:/ccache" \
  ghcr.io/gevroska/lineageos-guacamole-wireguard-builder
```

```bash
# docker compose: set BUILD_JOBS in .env (or export it)
echo "BUILD_JOBS=8" >> .env
docker compose up --build
```

## Quick start (prebuilt image)

Run the prebuilt image (the build script starts automatically, syncs/sanitizes sources, patches kernel config/WireGuard, auto-selects the device target via `breakfast`/`lunch`, builds `bootimage`, streams logs to stdout/stderr, and exits when done):

```bash
docker run --rm -it \
  -v "$PWD/workspace:/workspace" \
  -v "$PWD/ccache:/ccache" \
  ghcr.io/gevroska/lineageos-guacamole-wireguard-builder
```

First build typically takes 1-3 hours depending on CPU/RAM.

## Build from source (advanced)

If you want to customize the image or scripts, build from source and run it with the same mounted volumes (no manual command needed):

```bash
git clone https://github.com/gevroska/lineageos-guacamole-wireguard-builder.git
cd lineageos-guacamole-wireguard-builder
docker build -t lineageos-guacamole-wireguard-builder .

docker run --rm -it \
  -v "$PWD/workspace:/workspace" \
  -v "$PWD/ccache:/ccache" \
  lineageos-guacamole-wireguard-builder
```

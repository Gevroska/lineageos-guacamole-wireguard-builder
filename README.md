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

The goal is to build a proper LineageOS ROM through the normal Lineage build system while ensuring:

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
- `build/build-rom.sh` — full automated build script
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

## Quick start (prebuilt image)

Run the build script from the prebuilt image:

```bash
docker run --rm -it \
  -v "$PWD/workspace:/workspace" \
  -v "$PWD/ccache:/ccache" \
  ghcr.io/gevroska/lineageos-guacamole-wireguard-builder \
  /home/builder/build/build-rom.sh
```

First build typically takes 1-3 hours depending on CPU/RAM.

## Build from source (advanced)

If you want to customize the image or scripts, build from source and run the same mounted volumes:

```bash
git clone https://github.com/gevroska/lineageos-guacamole-wireguard-builder.git
cd lineageos-guacamole-wireguard-builder
docker build -t lineageos-guacamole-wireguard-builder .

docker run --rm -it \
  -v "$PWD/workspace:/workspace" \
  -v "$PWD/ccache:/ccache" \
  lineageos-guacamole-wireguard-builder \
  /home/builder/build/build-rom.sh
```

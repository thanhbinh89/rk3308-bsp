#!/usr/bin/env bash
# Host entry point. Run from any directory on the Linux build server.
set -euo pipefail

die() { printf 'bsp: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: scripts/bsp.sh [command]

  image [--refresh]  Build the Docker builder; --refresh updates base/APT layers.
  build              Build rootfs; initialize defconfig only if .config is absent.
  config             Reload ihc3308gw_defconfig; back up the current .config.
  menuconfig         Open Buildroot menuconfig (requires an interactive terminal).
  savedefconfig      Save the current configuration into the external tree.
  source             Download source packages into the persistent dl/ cache.
  check              Inspect the generated toolchain, BusyBox and rootfs images.
  sdk                Run Buildroot's sdk target.
  legal-info         Run Buildroot's legal-info target.
  shell              Open a shell in the builder.
  help               Show this help.

Environment:
  BSP_JOBS=4
  BSP_OUT=out/docker-ihc3308
  BSP_BASE_IMAGE=ubuntu:22.04   (may be an Ubuntu 22.04 reference pinned by digest)

The host needs Bash, Git, Docker Engine and standard GNU utilities.
Run as the regular user that owns the BSP repository.
EOF
}

bsp_command="${1:-build}"
if (( $# > 0 )); then shift; fi
case "$bsp_command" in
    help|-h|--help) usage; exit 0 ;;
    image|build|config|menuconfig|savedefconfig|source|check|sdk|legal-info|shell) ;;
    *) usage >&2; die "unknown command: $bsp_command" ;;
esac
bsp_refresh=0
if [[ "$bsp_command" == image && "${1:-}" == --refresh ]]; then
    bsp_refresh=1
    shift
fi
(( $# == 0 )) || die 'unexpected arguments; use help for supported commands'

for bsp_tool in docker git sha256sum id uname flock; do
    command -v "$bsp_tool" >/dev/null || die "missing host command: $bsp_tool"
done
bsp_uid="$(id -u)"
bsp_gid="$(id -g)"
(( bsp_uid != 0 )) || die 'run this script as your regular host user, without sudo'
[[ "$(uname -m)" == x86_64 ]] || die 'this lab builder targets an x86_64 Linux host'
bsp_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$bsp_root" != *[[:space:],]* ]] || die 'Buildroot workspace paths must have no whitespace or commas'
bsp_out_rel="${BSP_OUT:-out/docker-ihc3308}"
[[ "$bsp_out_rel" =~ ^out/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || die 'BSP_OUT must be a directory directly under out/, e.g. out/docker-ihc3308-v2'
bsp_jobs="${BSP_JOBS:-16}"
[[ "$bsp_jobs" =~ ^[1-9][0-9]*$ ]] || die 'BSP_JOBS must be a positive integer'
bsp_base="${BSP_BASE_IMAGE:-ubuntu:22.04}"

if [[ "$bsp_command" == menuconfig && ( ! -t 0 || ! -t 1 ) ]]; then
    die 'menuconfig needs a terminal; connect with an interactive SSH session or ssh -t'
fi
docker info >/dev/null || die 'Docker is not accessible; check docker info as this host user'

# Tag the recipe plus user identity so Dockerfile edits cannot silently reuse an old builder.
bsp_recipe="$(
    {
        cat "$bsp_root/docker/Dockerfile" "$bsp_root/docker/.dockerignore"
        printf '\n%s\n%s\n%s\n' "$bsp_uid" "$bsp_gid" "$bsp_base"
    } | sha256sum
)"
bsp_recipe="${bsp_recipe%% *}"
bsp_image="rk3308-builder:lab2-${bsp_recipe:0:16}"

build_image() {
    local -a build_args=(build --platform linux/amd64
        --build-arg "BASE_IMAGE=$bsp_base"
        --build-arg "BUILD_UID=$bsp_uid"
        --build-arg "BUILD_GID=$bsp_gid"
        --tag "$bsp_image" --file "$bsp_root/docker/Dockerfile")
    if (( bsp_refresh )); then build_args+=(--pull --no-cache); fi
    docker "${build_args[@]}" "$bsp_root/docker"
}

if [[ "$bsp_command" == image ]]; then
    build_image
    docker image inspect --format '{{.Id}}' "$bsp_image"
    exit 0
fi

[[ -d "$bsp_root/buildroot/.git" || -f "$bsp_root/buildroot/.git" ]] \
    || die 'the pinned buildroot/ checkout from Lab 2.1 is missing'
[[ -f "$bsp_root/buildroot.commit" && -f "$bsp_root/buildroot.version" ]] \
    || die 'buildroot.commit or buildroot.version is missing'
bsp_expected_commit="$(tr -d '\r\n' < "$bsp_root/buildroot.commit")"
[[ "$bsp_expected_commit" =~ ^[0-9a-f]{40}$ ]] || die 'invalid buildroot.commit'
[[ "$(git -C "$bsp_root/buildroot" rev-parse HEAD)" == "$bsp_expected_commit" ]] \
    || die 'buildroot/ HEAD differs from buildroot.commit'
git -C "$bsp_root/buildroot" diff --quiet HEAD -- \
    || die 'buildroot/ has tracked changes; record your intended source revision first'
for bsp_file in external.desc Config.in external.mk; do
    [[ -f "$bsp_root/br2-external-rk3308/$bsp_file" ]] \
        || die "missing br2-external-rk3308/$bsp_file from Lab 2.1"
done

mkdir -p "$bsp_root/$bsp_out_rel/logs" "$bsp_root/dl"
exec {bsp_lock_fd}>"$bsp_root/$bsp_out_rel/host.lock"
flock -n "$bsp_lock_fd" || die "another command is using $bsp_out_rel"

if ! docker image inspect "$bsp_image" >/dev/null 2>&1; then build_image; fi
bsp_image_id="$(docker image inspect --format '{{.Id}}' "$bsp_image")"
[[ "$bsp_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'could not resolve the Docker image ID'

declare -a run_args=(run --rm --init --platform linux/amd64
    --user "$bsp_uid:$bsp_gid"
    --mount "type=bind,src=$bsp_root,dst=/work"
    --workdir /work
    --env "BSP_OUT=$bsp_out_rel"
    --env "BSP_JOBS=$bsp_jobs"
    --env "BSP_BUILDER_IMAGE_ID=$bsp_image_id"
    --env "TERM=${TERM:-xterm-256color}")
if [[ "$bsp_command" == menuconfig || "$bsp_command" == shell ]]; then
    run_args+=(--interactive)
    if [[ -t 0 && -t 1 ]]; then run_args+=(--tty); fi
fi
# Keep the host process alive to hold the output-directory lock until Docker exits.
docker "${run_args[@]}" "$bsp_image_id" /bin/bash /work/scripts/in-container.sh "$bsp_command"

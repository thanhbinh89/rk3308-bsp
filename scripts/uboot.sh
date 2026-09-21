#!/usr/bin/env bash
set -euo pipefail

die() { printf 'uboot: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: scripts/uboot.sh image
       scripts/uboot.sh import-firmware /absolute/path/to/vendor-sdk
       scripts/uboot.sh build
       scripts/uboot.sh check

UBOOT_JOBS=20
UBOOT_OUT=out/docker-uboot-ihc3308
UBOOT_BASE_IMAGE=ubuntu:22.04

Run as the regular Linux user who owns this BSP. Requires Docker, Git,
Python 3 and standard GNU utilities. Source: u-boot/ at u-boot.commit.
The original checkout is read only; builds use a snapshot under UBOOT_OUT.
EOF
}

action="${1:-build}"
if (( $# )); then shift; fi
case "$action" in
    help|-h|--help) usage; exit 0 ;;
    image|import-firmware|build|check) ;;
    *) usage >&2; die "unknown command: $action" ;;
esac
if [[ "$action" == import-firmware ]]; then
    (( $# == 1 )) || die 'import-firmware needs the vendor SDK directory'
else
    (( $# == 0 )) || die 'unexpected arguments'
fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$root" != *[[:space:],]* ]] || die 'workspace path must not contain whitespace or commas'
for tool in git sha256sum flock python3; do
    command -v "$tool" >/dev/null || die "missing host command: $tool"
done
uid="$(id -u)"
gid="$(id -g)"
(( uid > 0 && gid > 0 )) || die 'run as your regular user, without sudo'
out_rel="${UBOOT_OUT:-out/docker-uboot-ihc3308}"
[[ "$out_rel" =~ ^out/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'UBOOT_OUT must be directly under out/'
jobs="${UBOOT_JOBS:-4}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die 'UBOOT_JOBS must be positive'
mkdir -p "$root/out"
exec 9>"$root/out/.uboot-script.lock"
flock -n 9 || die 'another U-Boot script is running in this BSP'

firmware="$root/firmware/rk3308"
recipe="$root/board/ihc3308gw/uboot"
if [[ "$action" == import-firmware ]]; then
    vendor="$(realpath -- "$1")"
    [[ "$(git -C "$vendor/rkbin" rev-parse HEAD)" == "$(cat "$firmware/rkbin.commit")" ]] \
        || die 'rkbin commit differs from the audited vendor SDK'
    while read -r expected name; do
        actual="$(sha256sum "$vendor/rkbin/bin/rk33/$name")"
        [[ "${actual%% *}" == "$expected" ]] || die "vendor hash mismatch: $name"
        if [[ -e "$firmware/$name" ]]; then
            actual="$(sha256sum "$firmware/$name")"
            [[ "${actual%% *}" == "$expected" ]] || die "existing firmware differs: $name"
        fi
    done < "$firmware/SHA256SUMS"
    while read -r expected name; do
        if [[ ! -e "$firmware/$name" ]]; then
            install -m 0644 "$vendor/rkbin/bin/rk33/$name" "$firmware/$name"
        fi
    done < "$firmware/SHA256SUMS"
    (cd "$firmware" && sha256sum -c SHA256SUMS)
    exit 0
fi

command -v docker >/dev/null || die 'Docker is required'
[[ "$(uname -m)" == x86_64 ]] || die 'this Docker recipe targets an x86_64 Linux host'
docker info >/dev/null || die 'Docker is not accessible as this user'
base="${UBOOT_BASE_IMAGE:-ubuntu:22.04}"
docker_recipe="$(
    { cat "$root/docker/uboot/Dockerfile" "$root/docker/uboot/.dockerignore";
      printf '\n%s\n%s\n%s\n' "$uid" "$gid" "$base"; } | sha256sum
)"
docker_recipe="${docker_recipe%% *}"
image="rk3308-uboot-builder:lab3-${docker_recipe:0:16}"
if [[ "$action" == image ]]; then
    docker build --platform linux/amd64 \
        --build-arg "BASE_IMAGE=$base" --build-arg "BUILD_UID=$uid" \
        --build-arg "BUILD_GID=$gid" --tag "$image" "$root/docker/uboot"
    docker image inspect --format '{{.Id}}' "$image"
    exit 0
fi

expected_commit="$(cat "$recipe/upstream.commit")"
[[ "$(cat "$root/u-boot.commit")" == "$expected_commit" ]] || die 'u-boot.commit differs from the recipe'
[[ "$(git -C "$root/u-boot" rev-parse HEAD)" == "$expected_commit" ]] || die 'wrong U-Boot checkout'
git -C "$root/u-boot" diff --quiet HEAD -- || die 'tracked source is modified; keep board edits in the BSP recipe'
(cd "$firmware" && sha256sum -c SHA256SUMS) || die 'run import-firmware first'
image_id="$(docker image inspect --format '{{.Id}}' "$image")" || die 'run scripts/uboot.sh image first'
inputs="$(
    { printf '%s\n' "$expected_commit" "$image_id" "$out_rel";
      sha256sum "$recipe/"* "$firmware/SHA256SUMS" "$firmware/rkbin.commit" \
          "$root/scripts/uboot.sh" "$root/scripts/uboot-container.sh" \
          "$root/scripts/uboot-prepare.py" "$root/scripts/uboot-check.py"; } | sha256sum
)"
inputs="${inputs%% *}"
out="$root/$out_rel"
mkdir -p "$out"
if [[ -e "$out/input-id" ]]; then
    [[ "$(cat "$out/input-id")" == "$inputs" ]] \
        || die 'inputs changed; choose a new UBOOT_OUT, e.g. out/docker-uboot-ihc3308-v2'
else
    [[ "$action" == build ]] || die 'this output has not been built'
    [[ ! -e "$out/source" && ! -e "$out/build" ]] || die 'output is unmanaged; choose a new UBOOT_OUT'
    printf '%s\n' "$inputs" > "$out/input-id"
    printf 'source_commit=%s\nbuilder_image=%s\noutput=%s\n' \
        "$expected_commit" "$image_id" "$out_rel" > "$out/build-context.txt"
fi
epoch="$(git -C "$root/u-boot" show -s --format=%ct "$expected_commit")"
log="$out/${action}-$(date -u +%Y%m%dT%H%M%S)-$$.log"
docker run --rm --platform linux/amd64 --init \
    --mount "type=bind,src=$root,dst=/work" --workdir /work \
    --env "SOURCE_DATE_EPOCH=$epoch" --env KBUILD_BUILD_USER=epcb \
    --env KBUILD_BUILD_HOST=uboot-builder \
    "$image_id" bash /work/scripts/uboot-container.sh "$action" "$out_rel" "$jobs" \
    2>&1 | tee "$log"
printf 'log=%s\n' "$log"

#!/usr/bin/env bash
# E7c: build the reviewed E7b snapshot, with a separate Lab 5 manifest.
set -euo pipefail
readonly BUILDER=sha256:c77af91629b6c50b9abe5335c68355a26a9db8ba06138d0d87d648d1280960b7
readonly ROOTFS_SHA=7eb45684d0a3f879f92742950abdd6adf6c6dcbe54ba07d266a1d4c027b817c7
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -le 2 ]] || fail 'Usage: kernel-lab5-build.sh build|check [out/run-name]'
mode=${1:-help}
if [[ $mode == help || $mode == --help ]]; then
    printf 'Usage: %s build|check [out/run-name]\nRequires the reviewed E7b output.\n' "$0"
    exit 0
fi
[[ $mode == build || $mode == check ]] || fail 'Expected build or check.'
run_rel=${2:-out/kernel-6.12.111-lab5-eth-1}
[[ $run_rel =~ ^out/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 'Invalid output name.'
[[ $root != *[[:space:]]* ]] || fail 'BSP path must not contain whitespace.'
run="$root/$run_rel"
[[ ! -L "$root/out" && ! -L "$run" && -d "$run" ]] || fail 'Expected a real E7b output directory.'
if [[ $mode == check ]]; then
    (cd "$run/inputs" && sha256sum -c SHA256SUMS)
    (cd "$run/e7c-inputs" && sha256sum -c SHA256SUMS)
    (cd "$run/artifacts" && sha256sum -c SHA256SUMS)
    cat "$run/artifacts/manifest.json"
    printf 'LAB5_ARTIFACT_CHECK_PASS\n'
    exit 0
fi
[[ ! -e "$run/artifacts/manifest.json" ]] || fail 'Build already completed; use check.'
for tool in docker sha256sum python3 tee cmp; do command -v "$tool" >/dev/null || fail "Missing host tool: $tool"; done
jobs=${BSP_JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || fail 'BSP_JOBS must be positive.'
[[ $(docker image inspect --format '{{.Id}}' "$BUILDER") == "$BUILDER" ]] || fail 'Pinned builder unavailable.'
[[ -f "$run/configuration.json" && -f "$run/inputs/SHA256SUMS" ]] || fail 'Missing E7b configuration/snapshot.'
(cd "$run/inputs" && sha256sum -c SHA256SUMS)
python3 "$root/scripts/kernel-lab5-artifact-check.py" inputs "$run"
source_epoch=$(sed -n 's/^source_date_epoch=//p' "$run/build-context.txt")
[[ $source_epoch =~ ^[0-9]+$ ]] || fail 'Invalid source epoch in E7b build context.'
recipe_files=(kernel-lab5-build.sh kernel-lab5-build-container.sh kernel-lab5-artifact-check.py)
if [[ -d "$run/e7c-inputs" ]]; then
    (cd "$run/e7c-inputs" && sha256sum -c SHA256SUMS)
    for name in "${recipe_files[@]}"; do
        cmp "$root/scripts/$name" "$run/e7c-inputs/$name" || fail 'Build recipe changed; inspect before retry.'
    done
else
    rootfs=${BSP_INITRAMFS:-/srv/tftp/rk3308/lab4-6.12.111-replay-3/rootfs.cpio.gz}
    [[ -f "$rootfs" ]] || fail "Missing validated initramfs: $rootfs (BSP_INITRAMFS may specify the same payload elsewhere)."
    [[ $(sha256sum "$rootfs" | cut -d ' ' -f1) == "$ROOTFS_SHA" ]] || fail 'Initramfs hash differs from validated Lab 4 payload.'
    mkdir "$run/e7c-inputs"
    for name in "${recipe_files[@]}"; do cp "$root/scripts/$name" "$run/e7c-inputs/"; done
    cp "$rootfs" "$run/e7c-inputs/rootfs.cpio.gz"
    (cd "$run/e7c-inputs" && sha256sum "${recipe_files[@]}" rootfs.cpio.gz > SHA256SUMS)
fi
mkdir -p "$run/artifacts"
printf 'Build attempt UTC=%s jobs=%s builder=%s\n' "$(date -u +%FT%TZ)" "$jobs" "$BUILDER" | tee -a "$run/build.log"
docker run --rm --pull never --network none \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$root,dst=/work,readonly" \
    --mount "type=bind,src=$run,dst=/work/$run_rel" \
    --workdir "/work/$run_rel" \
    "$BUILDER" bash "/work/$run_rel/e7c-inputs/kernel-lab5-build-container.sh" \
    "/work/$run_rel" "$source_epoch" "$jobs" \
    2>&1 | tee -a "$run/build.log"
printf 'LAB5_BUILD_PASS\nOUTPUT=%s/artifacts\n' "$run"

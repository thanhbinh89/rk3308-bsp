#!/usr/bin/env bash
# K16: build kernel/DTB from pinned Git objects and reviewed board inputs.
set -euo pipefail
readonly PIN=e2acc2211022246c77740d5df08265cc27eedcc5
readonly BUILDER=sha256:c77af91629b6c50b9abe5335c68355a26a9db8ba06138d0d87d648d1280960b7
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
mode=${1:-help}
run_rel=${2:-out/kernel-6.12.111-replay}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -le 2 ]] || fail 'Usage: kernel-lab4.sh build|check [out/run-name]'
if [[ $mode == help || $mode == --help ]]; then
    printf 'Usage: %s build|check [out/run-name]\n' "$0"
    exit 0
fi
[[ $mode == build || $mode == check ]] || fail 'Expected build or check.'
[[ $run_rel =~ ^out/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 'Output must be one directory directly under out/.'
[[ $root != *[[:space:]]* ]] || fail 'This lab requires a BSP path without whitespace.'
run="$root/$run_rel"
if [[ $mode == check ]]; then
    [[ -f "$run/artifacts/SHA256SUMS" ]] || fail 'No completed artifact manifest in this output.'
    (cd "$run/artifacts" && sha256sum -c SHA256SUMS)
    (cd "$run/inputs" && sha256sum -c SHA256SUMS)
    cat "$run/artifacts/manifest.json"
    printf 'ARTIFACT_CHECK_PASS\n'
    exit 0
fi
[[ ! -e $run && ! -L $run ]] || fail "Output already exists; use another out/run-name: $run"
[[ ! -L "$root/out" ]] || fail 'out/ must be a real directory for this recipe.'
jobs=${BSP_JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || fail 'BSP_JOBS must be a positive integer.'
for tool in git docker tar sha256sum tee; do command -v "$tool" >/dev/null || fail "Missing host tool: $tool"; done
cache="$root/out/linux-6.12.111"
git -C "$cache" cat-file -e "$PIN^{commit}"
[[ $(docker image inspect --format '{{.Id}}' "$BUILDER") == "$BUILDER" ]] || fail 'Pinned builder image is unavailable.'
for name in ihc3308gw.fragment rk3308-ihc3308gw.dts linux-6.12.111.validated.config; do
    [[ -s "$root/board/ihc3308gw/linux/$name" ]] || fail "Missing board input: $name"
done
for name in kernel-lab4-container.sh kernel-lab4-check.py; do
    [[ -f "$root/scripts/$name" ]] || fail "Missing recipe file: $name"
done
source_epoch=$(git -C "$cache" show -s --format=%ct "$PIN")
[[ $source_epoch =~ ^[0-9]+$ ]] || fail 'Invalid source commit timestamp.'
mkdir -p "$root/out"
mkdir "$run"
mkdir "$run/src" "$run/build" "$run/inputs" "$run/artifacts"
cp "$root/board/ihc3308gw/linux/ihc3308gw.fragment" "$run/inputs/"
cp "$root/board/ihc3308gw/linux/rk3308-ihc3308gw.dts" "$run/inputs/"
cp "$root/board/ihc3308gw/linux/linux-6.12.111.validated.config" "$run/inputs/"
cp "$root/scripts/kernel-lab4.sh" "$root/scripts/kernel-lab4-container.sh" "$root/scripts/kernel-lab4-check.py" "$run/inputs/"
(cd "$run/inputs" && sha256sum ihc3308gw.fragment rk3308-ihc3308gw.dts linux-6.12.111.validated.config kernel-lab4.sh kernel-lab4-container.sh kernel-lab4-check.py > SHA256SUMS)
{
    printf 'source_commit=%s\nbuilder_image=%s\nsource_date_epoch=%s\n' "$PIN" "$BUILDER" "$source_epoch"
    printf 'source_method=git archive pinned commit; working-tree changes excluded\n'
    printf 'output=%s\njobs=%s\n' "$run_rel" "$jobs"
} > "$run/build-context.txt"
printf 'Exporting source commit %s to %s\n' "$PIN" "$run_rel/src"
git -C "$cache" archive --format=tar "$PIN" | tar -xf - -C "$run/src"
printf 'Building in %s; log: %s/build.log\n' "$run_rel" "$run"
docker run --rm --pull never --network none \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$root,dst=/work,readonly" \
    --mount "type=bind,src=$run,dst=/work/$run_rel" \
    --workdir "/work/$run_rel" \
    "$BUILDER" bash "/work/$run_rel/inputs/kernel-lab4-container.sh" \
    "/work/$run_rel" "$source_epoch" "$jobs" \
    2>&1 | tee "$run/build.log"
printf 'BUILD_CHECK_PASS\nOUTPUT=%s/artifacts\n' "$run"

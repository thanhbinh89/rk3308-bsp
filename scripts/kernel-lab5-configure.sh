#!/usr/bin/env bash
# E7b: snapshot Lab 5 inputs, export pinned source, configure; do not build Image.
set -euo pipefail
readonly PIN=e2acc2211022246c77740d5df08265cc27eedcc5
readonly BSP_BASELINE=cf4190d
readonly BUILDER=sha256:c77af91629b6c50b9abe5335c68355a26a9db8ba06138d0d87d648d1280960b7
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || fail 'Usage: kernel-lab5-configure.sh [out/run-name]'
if [[ ${1:-} == --help ]]; then
    printf 'Usage: %s [out/run-name]\nCreates a new output; stops after olddefconfig and configuration checks.\n' "$0"
    exit 0
fi
run_rel=${1:-out/kernel-6.12.111-lab5-eth-1}
[[ $run_rel =~ ^out/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 'Output must be one directory directly under out/.'
[[ $root != *[[:space:]]* ]] || fail 'This lab requires a BSP path without whitespace.'
run="$root/$run_rel"
[[ ! -e $run && ! -L $run ]] || fail "Output already exists; choose a new name: $run_rel"
[[ ! -L "$root/out" ]] || fail 'out/ must be a real directory.'
for tool in git docker tar sha256sum tee python3; do
    command -v "$tool" >/dev/null || fail "Missing host tool: $tool"
done
cache="$root/out/linux-6.12.111"
git -C "$cache" cat-file -e "$PIN^{commit}"
baseline=$(git -C "$root" rev-parse --verify "$BSP_BASELINE^{commit}")
[[ $(docker image inspect --format '{{.Id}}' "$BUILDER") == "$BUILDER" ]] || fail 'Pinned builder image is unavailable.'
[[ -x "$root/out/docker-ihc3308/host/bin/aarch64-buildroot-linux-musl-gcc" ]] || fail 'Buildroot cross compiler is unavailable.'
for name in ihc3308gw.fragment rk3308-ihc3308gw.dts; do
    [[ -s "$root/board/ihc3308gw/linux/lab5/$name" ]] || fail "Missing Lab 5 input: $name"
done
[[ -s "$root/scripts/kernel-lab5-configure-container.sh" ]] || fail 'Missing container script.'
# Check only the Lab 4 inputs/scripts we are preserving. Unrelated edits stay untouched.
git -C "$root" diff --quiet "$baseline" -- \
    board/ihc3308gw/linux/rk3308-ihc3308gw.dts \
    board/ihc3308gw/linux/ihc3308gw.fragment \
    board/ihc3308gw/linux/linux-6.12.111.validated.config \
    scripts/kernel-lab4.sh scripts/kernel-lab4-container.sh scripts/kernel-lab4-check.py \
    || fail 'Lab 4 inputs/scripts differ from cf4190d; inspect before using this recipe.'
source_epoch=$(git -C "$cache" show -s --format=%ct "$PIN")
[[ $source_epoch =~ ^[0-9]+$ ]] || fail 'Invalid source commit timestamp.'
mkdir -p "$root/out"
mkdir "$run"
mkdir "$run/src" "$run/build" "$run/inputs"
cp "$root/board/ihc3308gw/linux/lab5/ihc3308gw.fragment" "$run/inputs/"
cp "$root/board/ihc3308gw/linux/lab5/rk3308-ihc3308gw.dts" "$run/inputs/"
cp "$root/scripts/kernel-lab5-configure.sh" "$root/scripts/kernel-lab5-configure-container.sh" "$run/inputs/"
git -C "$root" show "$baseline:board/ihc3308gw/linux/linux-6.12.111.validated.config" > "$run/inputs/lab4.validated.config"
git -C "$root" show "$baseline:board/ihc3308gw/linux/rk3308-ihc3308gw.dts" > "$run/inputs/lab4.dts"
git -C "$root" show "$baseline:board/ihc3308gw/linux/ihc3308gw.fragment" > "$run/inputs/lab4.fragment"
git -C "$root" status --short > "$run/bsp-status.txt"
python3 - "$run/inputs" <<'PY'
import difflib, pathlib, sys
p = pathlib.Path(sys.argv[1])
for before, after, out in [
    ('lab4.dts', 'rk3308-ihc3308gw.dts', 'dts-vs-lab4.diff'),
    ('lab4.fragment', 'ihc3308gw.fragment', 'fragment-vs-lab4.diff'),
]:
    (p/out).write_text(''.join(difflib.unified_diff(
        (p/before).read_text().splitlines(keepends=True),
        (p/after).read_text().splitlines(keepends=True),
        fromfile=before, tofile='lab5/'+after)))
PY
(cd "$run/inputs" && sha256sum ihc3308gw.fragment rk3308-ihc3308gw.dts \
    lab4.validated.config lab4.dts lab4.fragment kernel-lab5-configure.sh \
    kernel-lab5-configure-container.sh dts-vs-lab4.diff fragment-vs-lab4.diff > SHA256SUMS)
{
    printf 'source_commit=%s\nbsp_baseline=%s\nbuilder_image=%s\nsource_date_epoch=%s\n' "$PIN" "$baseline" "$BUILDER" "$source_epoch"
    printf 'source_method=git archive pinned commit\nconfig_seed=cf4190d full validated Lab 4 config\noutput=%s\nstage=configuration only\n' "$run_rel"
} > "$run/build-context.txt"
printf 'Exporting source commit %s to %s/src\n' "$PIN" "$run_rel"
git -C "$cache" archive --format=tar "$PIN" | tar -xf - -C "$run/src"
printf 'Configuring; log: %s/configure.log\n' "$run"
docker run --rm --pull never --network none \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$root,dst=/work,readonly" \
    --mount "type=bind,src=$run,dst=/work/$run_rel" \
    --workdir "/work/$run_rel" \
    "$BUILDER" bash "/work/$run_rel/inputs/kernel-lab5-configure-container.sh" \
    "/work/$run_rel" "$source_epoch" \
    2>&1 | tee "$run/configure.log"
printf 'E7B_CONFIG_READY\nOUTPUT=%s\n' "$run"

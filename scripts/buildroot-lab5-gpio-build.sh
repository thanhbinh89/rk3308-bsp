#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

self=$(readlink -f "${BASH_SOURCE[0]}")
bsp=$(cd "$(dirname "$self")/.." && pwd -P)
rel=out/buildroot-lab5-gpio-1
run="$bsp/$rel"
cr="/work/$rel"
pin=d030e36bbc9669230c015be971b14b6e062cfdde
image=sha256:c77af91629b6c50b9abe5335c68355a26a9db8ba06138d0d87d648d1280960b7

for tool in git docker tar python3 sha256sum flock gzip; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done

[[ ! -L "$bsp/out" && ! -L "$run" ]] ||
    fail "Output path must not be a symlink."

for d in src build inputs artifacts; do
    [[ -d "$run/$d" && ! -L "$run/$d" ]] ||
        fail "Invalid G5 directory: $d"
done

exec 9>"$run/.g6.lock"
flock -n 9 || fail "Another G6 process is running."

for d in dl g6-runs; do
    [[ ! -L "$run/$d" ]] || fail "$d must not be a symlink."
    mkdir -p "$run/$d"
done

tag="$(date -u +%Y%m%dT%H%M%SZ)-$$"
e="$run/g6-runs/$tag"
ce="$cr/g6-runs/$tag"
mkdir "$e"
cp "$self" "$e/recipe.sh"
cp "$run/configuration.json" "$e/g5-configuration.json"

exec > >(tee "$e/session.log") 2>&1
trap 'rc=$?; printf "G6_EXIT_CODE=%s\n" "$rc" > "$e/exit-status.txt"' EXIT
printf 'EVIDENCE=%s\n' "$e"

check_inputs() {
    (
        cd "$run"
        sha256sum -c <<'HASHES'
ee3331b171704efc49bd19bb3a791c82e2ad5516f6ab68a3b9e531cb741d5f57  inputs/baseline.config
40bc527eab36aceb79a61669a3498c0fe0de4cebb64bdf69ccd8e757511fbd4b  build/.config
83dd5860d1f6e6c63f3ae6d035ebf60406171665c65dfaa0078c94c14dc25138  artifacts/ihc3308gw_gpio_defconfig
b4b5b7b7c4bc0c22d2dafc5b80cce7037dd87010e3919dc549f9580f6b21d35d  inputs/SHA256SUMS
HASHES
        cd inputs
        sha256sum -c SHA256SUMS
    )
    cmp "$bsp/out/docker-ihc3308/.config" "$run/inputs/baseline.config"
    cmp "$bsp/br2-external-rk3308/configs/ihc3308gw_defconfig" \
        "$run/inputs/baseline.defconfig"
}

check_inputs

[[ "$(git -C "$bsp/buildroot" rev-parse HEAD)" == "$pin" ]] ||
    fail "Buildroot HEAD differs from pin."
git -C "$bsp/buildroot" diff --exit-code HEAD --

[[ "$(docker image inspect --format '{{.Id}}' "$image")" == "$image" ]] ||
    fail "Pinned builder unavailable."

# Compare the actual G5 source with a fresh archive of the pinned commit.
git -C "$bsp/buildroot" archive "$pin" > "$e/buildroot-reference.tar"

python3 - "$run/src" "$e/buildroot-reference.tar" <<'PY'
import os
from pathlib import Path
import sys
import tarfile

root = Path(sys.argv[1])
expected = set()

with tarfile.open(sys.argv[2]) as archive:
    for member in archive:
        if member.isdir():
            continue
        path = root / member.name
        expected.add(member.name)
        if member.isfile():
            if path.is_symlink() or not path.is_file():
                raise SystemExit(f"SOURCE_TYPE_MISMATCH: {member.name}")
            if path.read_bytes() != archive.extractfile(member).read():
                raise SystemExit(f"SOURCE_CONTENT_MISMATCH: {member.name}")
            if (path.stat().st_mode & 0o111) != (member.mode & 0o111):
                raise SystemExit(f"SOURCE_MODE_MISMATCH: {member.name}")
        elif member.issym():
            if not path.is_symlink() or os.readlink(path) != member.linkname:
                raise SystemExit(f"SOURCE_LINK_MISMATCH: {member.name}")
        else:
            raise SystemExit(f"UNEXPECTED_ARCHIVE_ENTRY: {member.name}")

actual = {
    p.relative_to(root).as_posix()
    for p in root.rglob("*")
    if p.is_file() or p.is_symlink()
}
if actual != expected:
    raise SystemExit(f"SOURCE_EXTRA_OR_MISSING: {sorted(actual ^ expected)[:20]}")
print("SOURCE_PIN_PASS")
PY

cat > "$e/context.txt" <<CONTEXT
buildroot_commit=$pin
builder_image=$image
uid=$(id -u)
gid=$(id -g)
output=$rel
download_cache=$rel/dl
jlevel=4
g5_diff_review=PASS
runtime=not-tested
CONTEXT

git -C "$bsp" status --short > "$e/bsp-status.txt"
df -h "$run"

# BSP/source/inputs stay read-only. Only build/cache/evidence are writable.
dock=(
    docker run --rm --pull never
    --user "$(id -u):$(id -g)"
    --mount "type=bind,src=$bsp,dst=/work,readonly"
    --mount "type=bind,src=$run/build,dst=$cr/build"
    --mount "type=bind,src=$run/dl,dst=$cr/dl"
    --mount "type=bind,src=$e,dst=$ce"
    --workdir "$cr"
    --env LC_ALL=C --env HOME=/tmp
    --env http_proxy --env https_proxy --env no_proxy
    --env HTTP_PROXY --env HTTPS_PROXY --env NO_PROXY
)

phase() {
    local network=$1 target=$2
    "${dock[@]}" --network "$network" "$image" \
        bash -euc '
            run=$1
            target=$2
            exec make -C "$run/src" \
                O="$run/build" \
                BR2_EXTERNAL="$run/inputs/br2-external-rk3308" \
                BR2_DL_DIR="$run/dl" \
                BR2_JLEVEL=4 "$target"
        ' g6 "$cr" "$target" 2>&1 | tee "$e/$target.log"
}

phase bridge source
check_inputs

mapfile -d '' headers < <(
    find "$run/dl" -type f -name linux-6.12.111.tar.xz -print0
)
[[ ${#headers[@]} -eq 1 ]] ||
    fail "Expected exactly one Linux 6.12.111 tar.xz."

printf '%s  %s\n' \
    9e59dc67624188fa12a6601f9598499cd6662a9066be572b59f935e3d7849810 \
    "${headers[0]}" | sha256sum -c -

(
    cd "$run/dl"
    find . -type f ! -name '*.lock' -print0 |
        sort -z | xargs -0 -r sha256sum
) > "$e/downloads.SHA256SUMS"

printf 'G6_SOURCE_PASS\n'
phase none all
check_inputs

rootfs="$run/build/images/rootfs.cpio.gz"
[[ -s "$rootfs" ]] || fail "Missing rootfs.cpio.gz."
gzip -t "$rootfs"
sha256sum "$rootfs" | tee "$e/rootfs.SHA256SUMS"
wc -c "$rootfs" | tee "$e/rootfs-size.txt"

printf 'built-not-validated\n' > "$e/stage.txt"
printf 'G6_BUILD_PASS\nEVIDENCE=%s\nROOTFS=%s\n' "$e" "$rootfs"

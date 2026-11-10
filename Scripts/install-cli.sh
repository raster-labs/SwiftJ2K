#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool=swiftj2k-cli
prefix=/usr/local
stage="${DESTDIR:-}"
binary=
scratch="$repo/.build/cli-install"
disable_sandbox=0
usage() {
    cat <<EOF
Usage: Scripts/install-cli.sh [options]
Build and install $tool and its matching man(1) page together; rerun to update both.
  --prefix PATH    Absolute installation prefix (default /usr/local)
  --destdir PATH   Absolute staging root, also accepted as DESTDIR
  --binary PATH    Install an already built binary of this exact VERSION
  --scratch-path PATH  SwiftPM build directory
  --disable-package-sandbox  Explicit workaround for nested sandbox restrictions
  -h, --help       Show help
For an unprivileged install: --prefix "\$HOME/.local".
No sudo is run. The chosen prefix must be writable. Man page: PREFIX/share/man/man1/$tool.1.
EOF
}
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --prefix|--destdir|--binary|--scratch-path)
            if (($# < 2)) || [[ -z "$2" ]]; then printf '%s\n' 'Missing option value.' >&2; exit 2; fi
            case "$1" in --prefix) prefix="$2";; --destdir) stage="$2";; --binary) binary="$2";; --scratch-path) scratch="$2";; esac
            shift 2 ;;
        --disable-package-sandbox) disable_sandbox=1; shift ;;
        *) printf '%s\n' 'Unknown installer option; use --help.' >&2; exit 2 ;;
    esac
done
[[ "$prefix" = /* && ( -z "$stage" || "$stage" = /* ) ]] || { printf '%s\n' 'Prefix and nonempty staging root must be absolute.' >&2; exit 2; }
if [[ -z "$binary" ]]; then
    swift_command=(swift)
    if [[ "$(uname -s)" = Darwin ]]; then swift_command=(xcrun swift); fi
    build=(build --package-path "$repo" --scratch-path "$scratch" --configuration release --product "$tool" --build-system swiftbuild --jobs 2)
    if ((disable_sandbox)); then build+=(--disable-sandbox); fi
    "${swift_command[@]}" "${build[@]}"
    binary="$("${swift_command[@]}" "${build[@]}" --show-bin-path)/$tool"
fi
[[ -f "$binary" && -x "$binary" ]] || { printf '%s\n' 'Executable not found.' >&2; exit 6; }
release_version="$(cat "$repo/VERSION")"
expected="$tool $release_version"
[[ "$("$binary" --version)" = "$expected" ]] || { printf '%s\n' 'Binary version does not match this source and manual.' >&2; exit 2; }
manual="$repo/ManPages/$tool.1"
[[ -f "$manual" ]] || { printf '%s\n' 'Matching manual page is missing.' >&2; exit 6; }
IFS= read -r header < "$manual"
[[ "$header" = .TH* && "$header" = *"\"$release_version\""* ]] || { printf '%s\n' 'Manual version does not match VERSION.' >&2; exit 2; }
destination="${stage%/}${prefix%/}"
[[ -n "$destination" ]] || destination=/
bin_dir="$destination/bin"
man_dir="$destination/share/man/man1"
mkdir -p "$bin_dir" "$man_dir"
for target in "$bin_dir/$tool" "$man_dir/$tool.1"; do
    [[ ! -L "$target" && ! -d "$target" ]] || { printf '%s\n' 'Refusing to replace a symlink or directory; choose a separate prefix.' >&2; exit 6; }
done
bin_temp="$(mktemp "$bin_dir/.$tool.XXXXXX")"
man_temp=
trap 'rm -f -- "$bin_temp" ${man_temp:+"$man_temp"}' EXIT
man_temp="$(mktemp "$man_dir/.$tool.XXXXXX")"
install -m 755 "$binary" "$bin_temp"
install -m 644 "$manual" "$man_temp"
# Prepare both files before replacing either. Each rename is atomic on its filesystem.
mv -f -- "$man_temp" "$man_dir/$tool.1"
mv -f -- "$bin_temp" "$bin_dir/$tool"
printf 'Installed %s\nManual: %s\n' "$bin_dir/$tool" "$man_dir/$tool.1"
printf 'Read with: man -M "%s/share/man" %s\n' "$destination" "$tool"

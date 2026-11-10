#!/bin/bash
# SPDX-License-Identifier: MIT
# Selects Xcode per process; never changes xcode-select or falls back to native.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/validate-swift64.py" "$@"

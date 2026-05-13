#!/usr/bin/env bash
# Lint: a leading top-level Zig module doc block (//! ...) must be followed
# by exactly one blank line before the first declaration or import.
#
# Scope: build.zig + src/**/*.zig (matches `zig fmt --check src/ build.zig`).
# Only the initial leading //! block at file start is checked; mid-file
# container docs (e.g. //! attached to a nested struct) are ignored.
#
# Diagnostics: path:line: message
# Exit status: 0 if clean, 1 if any violation is reported.

set -euo pipefail

cd "$(dirname "$0")/.."

# Lint targets. Kept in sync with the `zig fmt --check` argument list.
# Built with a portable read loop so this script works under macOS system
# Bash 3.2 as well as the Nix-provided Bash 5.
files=()
if [[ -f build.zig ]]; then
    files+=( build.zig )
fi
if [[ -d src ]]; then
    while IFS= read -r path; do
        files+=( "$path" )
    done < <(find src -name '*.zig' | sort)
fi

if [[ ${#files[@]} -eq 0 ]]; then
    exit 0
fi

exec awk '
# State machine, run independently for each input file:
#
#   PRE         - have not yet read any line from this file
#   IN_DOC      - reading the leading //! block
#   AFTER_BLANK - just consumed the required single blank line; the
#                 next line must be a real declaration, not another blank
#   DONE        - leading block fully processed (or absent); skip the rest

BEGIN {
    violations = 0
    state = "PRE"
    prev_file = ""
}

# Reset the state machine whenever awk advances to a new file.
FILENAME != prev_file {
    state = "PRE"
    prev_file = FILENAME
}

state == "DONE" { next }

# PRE: classify the file by its first line.
state == "PRE" {
    if (/^\/\/!/) {
        state = "IN_DOC"
        next
    }
    # File does not open with a //! block - nothing to enforce here.
    state = "DONE"
    next
}

# IN_DOC: consume more //! lines, watch for the blank that should close the block.
state == "IN_DOC" {
    if (/^\/\/!/) {
        next
    }
    if (/^$/) {
        state = "AFTER_BLANK"
        next
    }
    # First non-//! line came with no separating blank.
    printf "%s:%d: missing blank line after //! block\n", FILENAME, FNR
    violations++
    state = "DONE"
    next
}

# AFTER_BLANK: anything other than a second blank line means we are done.
state == "AFTER_BLANK" {
    if (/^$/) {
        printf "%s:%d: excess blank lines after //! block\n", FILENAME, FNR
        violations++
    }
    state = "DONE"
    next
}

END {
    exit violations > 0 ? 1 : 0
}
' "${files[@]}"

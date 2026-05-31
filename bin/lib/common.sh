# shellcheck shell=bash
# common.sh — leaf helpers shared by tart-up / tart-new / tart-ssh-sync. Sourced,
# never on PATH / executable; bash-3.2-safe (macOS system bash). Pulls in the
# config-path resolver so a script sourcing this gets both. The line-format
# parsers stay in their owning scripts — test/parsing.sh and test/tart-new.sh
# extract them textually.

# shellcheck source=bin/lib/config.sh
. "${BASH_SOURCE[0]%/*}/config.sh"

# tart_need_cmd <tool> [install-hint] — preflight; exit 1 if the tool is missing.
tart_need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "${prog:-${0##*/}}: '$1' not on PATH. ${2:-}" >&2; exit 1; }; }

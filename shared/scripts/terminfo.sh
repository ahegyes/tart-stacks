#!/usr/bin/env bash
# Lives in shared/scripts/ rather than a platform tree because it runs verbatim
# on linux and darwin alike. That directory's contract is "both platforms", not
# "unmarked" — a platform-specific script belongs under shared/<platform>/scripts/.
# terminfo.sh — compile terminfo entries the packaged ncurses-term lacks. Runs as root
# via sudo, after the file provisioner uploads the source to /tmp.
#
# ncurses-term (00-base.sh) ships most terminals but NOT xterm-ghostty — Ghostty's entry
# is newer than the base ncurses, so without this an interactive `ssh tart-<name>` from
# Ghostty dies with "'xterm-ghostty': unknown terminal type". Compiling a vendored copy
# into the system terminfo makes every clone work regardless of the ncurses version.
# `tic` ships with ncurses (installed in 00-base.sh, which runs first).

set -euo pipefail

SRC=/tmp/xterm-ghostty.terminfo
echo "==> Compiling xterm-ghostty terminfo (ncurses-term omits it)..."
tic -x "$SRC"

if ! infocmp -x xterm-ghostty >/dev/null 2>&1; then
  echo "ERROR: xterm-ghostty terminfo not found after 'tic $SRC'" >&2
  exit 1
fi
echo "==> xterm-ghostty terminfo installed."

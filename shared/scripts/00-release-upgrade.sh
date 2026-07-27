#!/usr/bin/env bash
# 00-release-upgrade.sh — FIRST. Lifts the guest to the release the image ships as,
# before anything is installed on top of it. Runs as root; stack-agnostic and
# distro-agnostic, with the release policy itself in distro-lib.sh.
#
# Why ahead of 00-base.sh rather than inside it: 00-base.sh's first act is a full
# system update, and updating a release that is about to be replaced downloads a
# set of packages the upgrade immediately discards.
#
# This script REBOOTS the guest and never returns. It therefore has to stay in a
# provisioner block of its own with expect_disconnect set — anything placed after
# it in the same block would never run.
#
# No distro assertion here, deliberately: 00-base.sh owns that check, and the
# family dispatch below already makes a wrong guest harmless (an apt guest no-ops).
# The only cost of catching it there instead is the upgrade's couple of minutes.
set -euo pipefail
# shellcheck source=/dev/null
source /tmp/distro-lib.sh

pkg_release_upgrade

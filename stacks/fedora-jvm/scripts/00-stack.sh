#!/usr/bin/env bash
# 00-stack.sh — fedora-jvm has no native build dependencies. All JVM
# runtimes (Temurin, Maven, sbt, scala-cli) ship as pre-built aarch64
# binaries via mise; there's no compile-from-source step like
# fedora-php's asdf-php plugin. shared/scripts/00-base.sh's gcc +
# autotools + standard headers already covers the rare native-image /
# JNI build path.
#
# This file exists as a placeholder so stack.pkr.hcl's provisioner
# chain stays uniform across stacks. Add stack-specific `dnf install`
# lines here when first needed (e.g., xmlstarlet for `pom.xml` editing,
# graphviz for rendering `mvn dependency:tree` output).

set -euo pipefail

echo "==> 00-stack.sh (fedora-jvm) — no stack-specific packages."

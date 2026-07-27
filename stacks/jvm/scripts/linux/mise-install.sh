#!/usr/bin/env bash
# mise-install.sh (linux) — Install the JVM-stack runtimes declared in the global
# mise.toml and hard-gate on a smoke test, so the base image ships them ready to
# use (and every cloned VM inherits them). The darwin peer at
# ../darwin/mise-install.sh is the same payload — every JVM tool here is a
# pre-built mise binary download, with nothing OS-specific to compile.
#
# Runs as the unprivileged SSH user (mise installs to ~/.local/share/mise/). The
# shared mechanism (install/activate, smoke loop) lives in /tmp/mise-lib.sh, uploaded
# by the Packer template; this file is just the jvm payload + the Maven wiring check.
#
# Timing: all tools are pre-built aarch64 binary downloads. Temurin JDK is the
# largest (~200 MB extracted); end-to-end install + smoke is roughly 3-5 min on
# Apple Silicon with a fast connection.

set -euo pipefail
# /tmp/mise-lib.sh is staged on the guest by the Packer template (absent at lint time).
# shellcheck source=/dev/null
source /tmp/mise-lib.sh

mise_runtime_setup

smoke_gate "tool version checks" \
  -- java --version \
  -- mvn -v \
  -- gradle --version \
  -- sbt --script-version \
  -- scala-cli version \
  -- kotlinc -version \
  -- uv --version \
  -- node --version

# Maven hello-world build — proves the toolchain actually wires up, not just that
# the binaries are present. Catches the case where Java + Maven are individually
# installed but JAVA_HOME / PATH state leaves Maven unable to find a compiler. Side
# effect: warms ~/.m2/repository so the first real Maven build in a clone is faster.
#
# `release=21` keeps the smoke independent of whatever maven-compiler-plugin version
# Maven's default bindings ship; we're proving the toolchain wires, not flexing Java 25.
echo ""
echo "==> Maven hello-world build (proves toolchain wires correctly)..."
SMOKE_DIR=$(mktemp -d)
trap 'rm -rf "$SMOKE_DIR"' EXIT

mkdir -p "$SMOKE_DIR/src/main/java/smoke"
cat > "$SMOKE_DIR/pom.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>smoke</groupId>
  <artifactId>hello</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
  <properties>
    <maven.compiler.release>21</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
</project>
EOF
cat > "$SMOKE_DIR/src/main/java/smoke/Hello.java" <<'EOF'
package smoke;
public class Hello {
  public static void main(String[] args) {
    System.out.println("hello from java " + System.getProperty("java.version"));
  }
}
EOF

if (cd "$SMOKE_DIR" && mvn -B package); then
  if [ ! -f "$SMOKE_DIR/target/hello-1.0.0.jar" ]; then
    echo "ERROR: mvn package returned 0 but target/hello-1.0.0.jar is missing." >&2
    exit 1
  fi
  echo "  mvn package: BUILD SUCCESS"
else
  echo "ERROR: Maven hello-world build failed." >&2
  exit 1
fi

echo ""
echo "==> mise-install.sh complete."

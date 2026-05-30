#!/usr/bin/env bash
# mise-install.sh — Install language runtimes declared in the global
# mise.toml so the base image ships with them ready to use (and every
# VM cloned from this base inherits them).
#
# Runs as the unprivileged SSH user (mise installs to ~/.local/share/mise/).
#
# Timing: all six tools are pre-built aarch64 binary downloads. Temurin
# JDK is the largest (~200 MB extracted); end-to-end install + smoke
# test is roughly 3–5 min on Apple Silicon with a fast connection.

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

echo "==> Installing language runtimes per global mise.toml..."

# `mise install` reads ~/.config/mise/config.toml and installs all declared
# tools. -y auto-accepts plugin trust prompts. --verbose surfaces actual
# errors if a tool install fails (otherwise mise summarizes them out of
# the build log).
mise install -y --verbose

echo ""
echo "==> Installed tools:"
mise list

# Activate mise so all mise-managed tool binaries (java, mvn, sbt,
# scala-cli, uv, node, corepack) are on PATH and JAVA_HOME is set for
# the rest of this script.
eval "$(mise activate bash)"

# Enable Corepack — Node ships it bundled; this flips the symlinks so
# `pnpm` and `yarn` shim to whatever version each project's
# `package.json` "packageManager" field declares. Mixed JVM+JS projects
# (e.g., Spring backend with a Vite frontend) get per-project shimming
# without polluting the global Node install.
echo ""
echo "==> Enabling Corepack for per-project pnpm/yarn shimming..."
corepack enable

# Smoke test — HARD GATE. The Packer build fails if any expected tool
# is missing or its version check errors. Mirrors fedora-php's pattern.
echo ""
echo "==> Smoke test (hard gate): tool version checks"

declare -a checks=(
  "java --version"
  "mvn -v"
  "gradle --version"
  "sbt --script-version"
  "scala-cli version"
  "kotlinc -version"
  "uv --version"
  "node --version"
)

# `awk` filter prints the first non-empty, non-separator line so commands
# like `gradle --version` (which leads with `------------`) display
# something meaningful instead of just the box border.
failed=0
for cmd in "${checks[@]}"; do
  printf "  %-26s " "$cmd"
  if output=$(eval "$cmd" 2>&1); then
    echo "$output" | awk '/^[^-]/ && NF { print; exit }'
  else
    echo "FAILED"
    echo "$output" >&2
    failed=$((failed + 1))
  fi
done

if [ "$failed" -gt 0 ]; then
  echo "" >&2
  echo "ERROR: $failed tool(s) failed their version check." >&2
  exit 1
fi

# Maven hello-world build — proves the toolchain actually wires up, not
# just that the binaries are present. Catches the case where Java +
# Maven are individually installed but JAVA_HOME / PATH state leaves
# Maven unable to find a compiler. Side effect: warms ~/.m2/repository
# so the first real Maven build in a cloned VM is much faster.
#
# `release=21` keeps the smoke independent of whatever maven-compiler-plugin
# version Maven's default-bindings ship; we're proving the toolchain wires,
# not flexing Java 25 syntax.
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

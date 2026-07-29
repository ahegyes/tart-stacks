# jvm

JVM development stack. Builds a `<os>-jvm` Tart image (e.g. `fedora-jvm`) preconfigured with Temurin 25 (current Java LTS), Maven, Gradle, sbt, Scala CLI, Kotlin, plus uv (Python project manager) and Node LTS. Intended as a per-project clone source for Java/Scala/Kotlin/mixed-runtime work.

For host setup, build flow, daily use, and persistent terminal sessions (zellij), see the [top-level README](../../README.md). This file documents what's in *this* stack specifically.

## What's in this stack

The inventory below is generated from [`tools`](./tools), the stack's canonical tool declaration: every row is hard-gated at build (the installers' `smoke_gate` calls are held to it by the test suite) and probed at runtime (`make smoke` runs each Runtime probe over a non-interactive ssh).

<!-- tools:begin -->
<!-- Generated from ./tools by script/stack-docs — edit that file, then run `make docs`. -->
| Tool | Managed by | Build gate | Runtime probe | Purpose |
|---|---|---|---|---|
| java | mise (`java = temurin-25`) | smoke_gate | `java --version` | Temurin JDK, the current Java LTS |
| maven | mise (`maven = latest`) | smoke_gate | `mvn -v` | standard JVM build tool |
| gradle | mise (`gradle = latest`) | smoke_gate | `gradle --version` | default build tool for modern Kotlin and Android projects |
| sbt | mise (`sbt = latest`) | smoke_gate | `sbt --script-version` | Scala build tool launcher; projects pin the real sbt per repo |
| scala-cli | mise (`asdf:mise-plugins/mise-scala-cli = latest`) | smoke_gate | `scala-cli version` | modern Scala command-line tool |
| kotlin | mise (`kotlin = latest`) | smoke_gate | `kotlinc -version` | standalone Kotlin compiler for ad-hoc work |
| uv | mise (`uv = latest`) | smoke_gate | `uv --version` | Python project manager |
| node | mise (`node = lts`) | smoke_gate | `node --version` | JS runtime for mixed projects and npm-shipped build tooling |
| corepack | Corepack (enabled at build by mise_runtime_setup) | smoke_gate | `corepack --version` | package-manager shim dispatcher, ships with Node 24 and earlier |
| pnpm | Corepack (enabled at build by mise_runtime_setup) | smoke_gate | `command -v pnpm` | Corepack shim; resolves per-project via package.json packageManager |
| yarn | Corepack (enabled at build by mise_runtime_setup) | smoke_gate | `command -v yarn` | Corepack shim; resolves per-project via package.json packageManager |
<!-- tools:end -->

**Notes**

- **Temurin JDK 25** (Eclipse Adoptium). mise's `java` backend resolves `temurin-25` to the latest 25.x patch from the Adoptium API. Picked over Corretto/Zulu/Liberica for vendor-neutral Eclipse governance and broadest third-party-library compatibility. 25 is the current LTS (Sep 2025 → Sep 2030 community support).
- **Gradle** — real projects pin via `./gradlew`; this global is the convenience tool for bootstrapping wrappers and ad-hoc use.
- **sbt** — the bundled binary is the launcher only; actual sbt + Scala compiler versions are pinned per project by each project's `project/build.properties` and resolved on first invocation.
- **Scala CLI** — self-bootstraps the compiler version each script or project declares. Replaces the legacy system `scala` package.
- **Kotlin** — standalone `kotlinc` for ad-hoc / single-file work and bootstrapping. Real Kotlin projects pin the compiler via Gradle's `kotlin` plugin or Maven's `kotlin-maven-plugin`.
- **uv** — the base image provides a system Python for OS tooling; uv handles per-project Pythons via `python-build-standalone`.
- **Node** — whichever LTS line mise's `lts` alias currently points to (`node = "lts"` in `files/mise.toml`). Useful for mixed-runtime projects (Java backend + JS frontend) and for build tooling that ships as npm packages.
- **Corepack shims** — `pnpm`/`yarn` resolve per project via `package.json`'s `packageManager`. The shims exist for Nodes that bundle Corepack (24 and earlier); a project-pinned Node 25+ gets no shims from either the mise setting or the build's enable step — provision Corepack yourself in that case.

**Stack-specific build dependencies** (installed by [`scripts/00-stack.sh`](./scripts/00-stack.sh))

None currently. All JVM runtimes ship as pre-built aarch64 binaries via mise; there's no compile-from-source step like the php stack's. The `shared/linux/scripts/00-base.sh` baseline already provides `gcc` + autotools + standard headers for the rare native-image / JNI build that needs them. `00-stack.sh` stays as a placeholder so the provisioner chain matches the other stacks; add stack-specific package install lines there when first needed (e.g., `xmlstarlet` for `pom.xml` editing, `graphviz` for rendering `mvn dependency:tree`).

## Customization

- **Tool versions**: [`files/mise.toml`](./files/mise.toml).
- **Per-project JDK pin**: drop a `.mise.toml` in the project repo root and commit it, then run `mise trust` once inside the repo — project configs are deliberately untrusted until you do (that prompt is the supply-chain gate; a non-interactive agent runs `mise trust` as an explicit step). How much the gate covers moves with the mise release the image happened to install — see the note in [`files/mise.toml`](./files/mise.toml). mise honors the closest trusted `.mise.toml` walking up from CWD, so per-project pins win over the global default.
  ```toml
  [tools]
  java = "temurin-17"   # or temurin-21, etc.
  ```
- **Private Maven repos** (e.g., a corporate Nexus): not baked into the base image — the VM stays reusable. Drop `~/.m2/settings.xml` (with the relevant `<servers>` block) into each clone that needs it, outside the Packer build.
- **sbt credentials**: same pattern — per-clone `~/.sbt/<sbt-version>/credentials.sbt` or `~/.sbt/global.sbt`. Don't bake them into the base.
- **Shell baseline**: [`shared/files/zshrc`](../../shared/files/zshrc) (affects every stack; edit there only if it's not stack-specific).

## Troubleshooting

- **`java` resolves to system Java, not Temurin** → mise didn't activate. `which java` should resolve under `~/.local/share/mise/installs/`. If not, `eval "$(mise activate bash)"` then re-test. The zsh activation ships in the uploaded [`shared/files/zshrc`](../../shared/files/zshrc) baseline (the VM's `~/.zshrc`); `shared/linux/scripts/user-config.sh` adds the bash equivalent to `~/.bashrc` (and puts `~/.local/bin` on PATH via `~/.zshenv`). A corrupted clone's shell rc may have lost either.
- **First `sbt` invocation in a project is slow** → expected. The mise-installed `sbt` is just the launcher; on first run it downloads the project's pinned sbt build + Scala compiler into `~/.sbt/` and `~/.cache/coursier/`. Subsequent invocations hit the cache.
- **`mvn` can't resolve a private dependency** → `~/.m2/settings.xml` isn't baked into the base. Drop it into the clone (`~/.m2/settings.xml`) with the relevant `<servers>` and `<profiles>`.

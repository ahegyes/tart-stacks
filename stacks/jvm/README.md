# jvm

JVM development stack. Builds a `<os>-jvm` Tart image (e.g. `fedora-jvm`) preconfigured with Temurin 25 (current Java LTS), Maven, Gradle, sbt, Scala CLI, Kotlin, plus uv (Python project manager) and Node LTS. Intended as a per-project clone source for Java/Scala/Kotlin/mixed-runtime work.

For host setup, build flow, daily use, and persistent terminal sessions (zellij), see the [top-level README](../../README.md). This file documents what's in *this* stack specifically.

## What's in this stack

**Version-managed runtimes** (via mise — installed by [`scripts/linux/mise-install.sh`](./scripts/linux/mise-install.sh) / [`scripts/darwin/mise-install.sh`](./scripts/darwin/mise-install.sh) per [`files/mise.toml`](./files/mise.toml))

- **Temurin JDK 25** (Eclipse Adoptium). mise's `java` backend resolves `temurin-25` to the latest 25.x patch from the Adoptium API. Picked over Corretto/Zulu/Liberica for vendor-neutral Eclipse governance and broadest third-party-library compatibility. 25 is the current LTS (Sep 2025 → Sep 2030 community support).
- **Maven** (latest GA). Standard JVM build tool.
- **Gradle** (latest GA). Default build tool for most modern Kotlin and Android templates; common in Java projects too. Real projects pin via `./gradlew`; this global is the convenience tool for bootstrapping wrappers and ad-hoc use.
- **sbt** (latest launcher). The bundled binary is the sbt launcher only; actual sbt + Scala compiler versions are pinned per project by each project's `project/build.properties` and resolved on first invocation.
- **Scala CLI** (latest). Modern Scala command-line tool — self-bootstraps the compiler version each script or project declares. Replaces the legacy system `scala` package.
- **Kotlin** (latest `kotlinc`). Standalone Kotlin compiler for ad-hoc / single-file work and for bootstrapping. Real Kotlin projects pin the compiler via Gradle's `kotlin` plugin or Maven's `kotlin-maven-plugin`.
- **uv** (latest). Python project manager. The base image provides a system Python for OS tooling; uv handles per-project Pythons via `python-build-standalone`.
- **Node** — whichever LTS line mise's `lts` alias currently points to (`node = "lts"` in `files/mise.toml`). Useful for mixed-runtime projects (Java backend + JS frontend) and for build tooling that ships as npm packages.

**Toolchain extras**

- **Corepack** enabled — `pnpm` / `yarn` shim to whatever version each project's `package.json` `"packageManager"` field declares.

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

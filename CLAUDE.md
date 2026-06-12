# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A collection of setup shell scripts published via **GitHub Pages** and consumed remotely by piping into a shell:

```sh
curl -fsSL https://lumivero.github.io/scripts/setup.sh | sh
```

`lumivero.github.io/scripts/` maps directly to the root of this repo (`LUMIVERO/scripts`). There is **no build step** — whatever is committed at the repo root is what gets served and executed by end users. Editing a script and pushing to `main` is the deploy.

## Critical constraints

These follow from the `curl … | sh` delivery model and override convenience:

- **POSIX `sh` only — no bashisms.** Scripts run under whatever `sh` the user's system provides (dash, etc.), not bash. The shebang is `#!/usr/bin/env sh` and was deliberately changed from `bash` (see commit `01f553c`). Avoid `[[ ]]`, arrays, `local` outside functions that guarantee it, `${var,,}`, etc.
- **Self-contained.** A script may be piped into a shell with no repository checkout, so it cannot source sibling files or assume any repo layout. Everything a script needs must be inline.
- **Safe under `set -eu`.** Scripts run with `set -eu` (exit on error, error on unset variable). Reference optional environment variables with defaults (`${VAR:-}`) and guard commands that may legitimately fail (e.g. `grep … 2>/dev/null`).
- **Fail loudly with a clear message and non-zero exit.** Use the `fail()` pattern (writes to stderr, `exit 1`) rather than letting a script continue in an unsupported state.

## Working with the scripts

- **Run / test:** `sh setup.sh` (execute it directly to see detection output). There is no test framework — verify by running.
- **Lint:** `shellcheck setup.sh`. The codebase already uses inline directives (`# shellcheck disable=SC1091` where `/etc/os-release` is sourced), so shellcheck is the expected linter.

## `setup.sh` architecture

`setup.sh` is currently an **environment-detection gate**: it identifies the OS/distro and either confirms a supported environment or fails. Supported matrix:

- **macOS** (`uname -s` = `Darwin`)
- **Debian Linux** and **Ubuntu Linux** (read from `/etc/os-release` `ID`)
- **Ubuntu under Windows WSLg** — the only supported Windows path

Explicitly rejected: Cygwin/MinGW/MSYS bash environments, and any other distro/OS.

WSL detection lives in helper functions: `is_wsl()` (checks `WSL_INTEROP`/`WSL_DISTRO_NAME` env vars and `/proc/version`) and `is_wslg()` (checks WSLg display markers). Note `is_wslg()` is defined but not yet wired into the main `case` block.

When extending a script beyond detection (installing tools, configuring the machine), keep the detection-then-act structure: validate the environment up front, then perform actions only for confirmed-supported environments.

## Conventions

- Commit messages are written in **English**.

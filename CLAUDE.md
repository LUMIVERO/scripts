# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A collection of setup shell scripts published via **GitHub Pages** and consumed remotely by piping into a shell:

```sh
curl -fsSL https://lumivero.github.io/scripts/lumivero-api_setup.sh | sh
```

`lumivero.github.io/scripts/` maps directly to the root of this repo (`LUMIVERO/scripts`). There is **no build step** — whatever is committed at the repo root is what gets served and executed by end users. Editing a script and pushing to `main` is the deploy.

### One script per app

This repository hosts a setup script **per app**, not a single shared script. Scripts follow the naming convention:

```
<app>_setup.sh
```

and are served at `https://lumivero.github.io/scripts/<app>_setup.sh`. The first such script is `lumivero-api_setup.sh` (the Lumivero API environment checklist). To onboard another app, add a new `<app>_setup.sh` at the repo root and list it in [`README.md`](README.md); every script must independently satisfy the constraints below, since each is fetched and run on its own.

## Critical constraints

These follow from the `curl … | sh` delivery model and override convenience:

- **POSIX `sh` only — no bashisms.** Scripts run under whatever `sh` the user's system provides (dash, etc.), not bash. The shebang is `#!/usr/bin/env sh` and was deliberately changed from `bash` (see commit `01f553c`). Avoid `[[ ]]`, arrays, `local` outside functions that guarantee it, `${var,,}`, etc.
- **Self-contained.** A script may be piped into a shell with no repository checkout, so it cannot source sibling files or assume any repo layout. Everything a script needs must be inline.
- **Safe under `set -eu`.** Scripts run with `set -eu` (exit on error, error on unset variable). Reference optional environment variables with defaults (`${VAR:-}`) and guard commands that may legitimately fail (e.g. `grep … 2>/dev/null`).
- **Fail loudly with a clear message and non-zero exit.** Use the `fail()` pattern (writes to stderr, `exit 1`) rather than letting a script continue in an unsupported state.

## Working with the scripts

- **Run / test:** `sh lumivero-api_setup.sh` (execute it directly to see detection output). There is no test framework — verify by running.
- **Lint:** `shellcheck lumivero-api_setup.sh`. The codebase already uses inline directives (`# shellcheck disable=SC1091` where `/etc/os-release` is sourced), so shellcheck is the expected linter.

## `lumivero-api_setup.sh` architecture

`lumivero-api_setup.sh` is a **requirements checklist**: it runs an ordered list of checks (required tools + environment settings), prints a coloured pass/fail/warn line per item with emoji status icons, and — where a fix is known — offers to install or repair the missing piece. The final exit status is non-zero if any **required** check is unsatisfied.

### Adding a check

> Full recipe, building blocks, and gotchas: [`.claude/rules/setup-sh-checks.md`](.claude/rules/setup-sh-checks.md). Read it before adding a check or fix.

Each item is a single `run_check` line in `main()`:

```sh
run_check "<label>" <check_fn> [<fix_fn>] [required|optional]
```

- `check_fn` returns `0` when satisfied and may set `CHECK_DETAIL` to a short string shown beside the result (e.g. the detected version or the reason it failed).
- `fix_fn` is optional. When the check fails, the user is asked (via `confirm`) whether to run it; afterwards the check is re-run to confirm. Returns `0` on success.
- Severity `required` (default) counts a miss as a failure (❌, exits non-zero); `optional` counts it as a warning (⚠️) and does not fail the run.

`run_check` itself always returns `0`, so one failing check never aborts the run under `set -e` — every item is evaluated and the summary/exit code is derived from `FAIL_COUNT` in `main()`.

### Building blocks for checks

- `have_cmd <name>` — true if a command is on `PATH`.
- `install_pkg <brew-formula> <apt-package>` — installs via Homebrew on macOS or `apt-get` on Debian/Ubuntu, keyed off `OS_FAMILY` (set by `check_os`). Sets `CHECK_DETAIL` and returns non-zero when it can't install.

A worked template (`check_git`/`fix_git`) is in the comment block in `main()`.

### Check #1: operating system (`check_os`)

The OS check is always first because it sets `OS_FAMILY` (`macos` | `debian`), which the package-installer relies on. It has no fix (you can't install an OS). Supported matrix:

- **macOS** (`uname -s` = `Darwin`) → `OS_FAMILY=macos`
- **Debian Linux** and **Ubuntu Linux** (`/etc/os-release` `ID`) → `OS_FAMILY=debian`
- **Ubuntu under Windows WSL** — the only supported Windows path → `OS_FAMILY=debian`

Explicitly rejected: Cygwin/MinGW/MSYS bash environments, and any other distro/OS.

WSL detection lives in the `is_wsl()` helper (checks `WSL_INTEROP`/`WSL_DISTRO_NAME` env vars and `/proc/version`). Plain WSL is sufficient — there is no separate WSLg (graphical) requirement.

### Presentation & interaction notes

- **Colour degrades gracefully:** ANSI colour is emitted only when stdout is a TTY, `NO_COLOR` is unset, and `TERM` isn't `dumb`. Emoji icons are always printed (they're plain UTF-8). Transient "⏳ …" progress lines are shown only on a TTY and overwritten by the result.
- **Prompts read from `/dev/tty`,** not stdin, so they work under `curl … | sh` (where the script itself occupies stdin). `confirm` probes that `/dev/tty` can actually be opened and declines quietly otherwise (headless/CI).
- **Unattended runs:** set `SETUP_ASSUME_YES=1` to auto-accept every fix prompt.
- **Maze animation:** on an interactive TTY the checks are framed as a labyrinth — a developer 🧑‍💻 walks the corridors (turning corners) toward a central trophy 🏆, advancing with each check, while results accumulate below; a failed check shows a dragon 🐉 on the developer's cell with a cheerful "Quest" fix hint. It's a full-screen redraw per step, so it runs **only** when stdout is a TTY and degrades to the plain line-by-line output otherwise (CI, pipes). `SETUP_NO_MAZE=1` opts out. The maze and its solution route are fixed data; `MAZE_TOTAL` in `main()` paces the hops to the check count (see the rule file).

## Conventions

- Commit messages are written in **English**.

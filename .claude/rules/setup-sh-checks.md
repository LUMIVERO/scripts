---
description: How to add checks and fixes to a <app>_setup.sh script
globs: "*_setup.sh"
alwaysApply: false
---

# Rule: Adding checks and fixes to a `<app>_setup.sh` script

How to add a new requirement to an app's setup script (e.g.
`lumivero-api_setup.sh`). Follow this exactly — the patterns exist for a reason
(see "Constraints" and "Gotchas").

## Mental model

A `<app>_setup.sh` is a **requirements checklist**. It runs an ordered list of checks,
prints one coloured pass/fail/warn line per item, and — where a fix is known —
offers to install/repair it. The run exits non-zero iff any **required** check
is unsatisfied. `run_check` always returns `0`, so one failure never aborts the
run under `set -e`; the exit code is derived from `FAIL_COUNT` in `main()`.

## Constraints (these override convenience)

The script is served from GitHub Pages and run as `curl -fsSL … | sh`:

- **POSIX `sh` only.** No `[[ ]]`, arrays, `${var,,}`, `source`, `local` outside
  functions. Shebang is `#!/usr/bin/env sh`.
- **Self-contained.** No sourcing sibling files, no repo layout assumptions.
  Prefer installers that bundle their own deps over ones needing npm/pip/etc.
- **Safe under `set -eu`.** Reference optional env vars with defaults (`${VAR:-}`).
  Guard commands that may fail (`grep … 2>/dev/null`). For command substitution
  that may fail, use `x="$(cmd 2>/dev/null)" || x=""`.
- **Fail loudly.** Set a clear `CHECK_DETAIL` and `return 1` rather than limping on.

## Recipe: add one check

1. **Write `check_<name>`** — returns `0` when satisfied, sets `CHECK_DETAIL`
   to a short context string (version on success, reason on failure). Distinguish
   failure *states* if the fix needs to know which (e.g. "not installed" vs
   "installed but not on PATH").

2. **Write `fix_<name>`** (optional) — attempts to satisfy the requirement,
   returns `0` on success. Place it right after its `check_`. The driver re-runs
   `check_<name>` afterwards to confirm, so the fix must make the *current
   process* pass (not just leave instructions for a future shell).

3. **Register it** in `main()` as one line, numbered in a comment:

   ```sh
   # N. <thing> — <one-line what>.
   run_check "<label>" check_<name> fix_<name> required
   ```

   Severity `required` (default) → a miss is ❌ and exits non-zero. `optional`
   → a miss is ⚠️ and does not fail the run. Use `optional` for nice-to-haves.
   The driver prints one coloured pass/fail/warn line per check, so a new check
   needs no extra wiring beyond its `run_check` line.

4. **Verify**: `shellcheck <app>_setup.sh && sh <app>_setup.sh` (e.g.
   `shellcheck lumivero-api_setup.sh && sh lumivero-api_setup.sh`). Both must be
   clean. (Project memory: always do this after editing a setup script.)

## Building blocks (already in the script — reuse, don't reinvent)

- `have_cmd <name>` — true if a command is on PATH.
- `install_pkg <brew-formula> <apt-package>` — installs via Homebrew (macOS) or
  apt (Debian/Ubuntu), keyed off `OS_FAMILY`. Sets `CHECK_DETAIL`, returns
  non-zero when it can't. Use this for fixes whenever a distro package exists.
- `ensure_line_in_file <file> <line>` — idempotent append (creates file if
  missing, skips if line already present). The low-level primitive; prefer the
  two helpers below for shell-startup lines so the right files are picked.
- `persist_env_line <line>` — append a regular env-var export (`export VAR=…`)
  to the always-sourced files: zsh `~/.zshenv` + bash `~/.bash_profile`.
- `persist_path_line <line>` — append a PATH edit (`export PATH=…:$PATH`) to the
  login files: zsh `~/.zprofile` + bash `~/.bash_profile`. Login (not `.zshenv`)
  so a nested non-login shell doesn't re-prepend and duplicate the entry.
- `CHECK_DETAIL` — the per-check context string. Reset to "" by the driver
  before each check and each fix re-check; just assign it.
- `OS_FAMILY` — `macos` | `debian`, set by `check_os` (always check #1). Branch
  on it when behaviour differs per OS (see `check_docker`/`fix_docker`).
- `RESTART_REQUIRED` — set this (to an explanatory message) from a fix whose
  effect only reaches a *fresh login session*, so the immediate re-check can't
  pass no matter what — e.g. `fix_docker`'s new `docker` group membership. The
  driver counts the check as fixed, prints the message via
  `finish_restart_required`, and exits 0; the remaining checks are skipped
  (they'd fail in this session anyway). Use it only when a restart is genuinely
  unavoidable — a normal PATH/env fix should make the current process pass.

## Worked references in the file

- **`check_git`/`fix_git`** — minimal template in the `main()` comment block.
- **`check_docker`/`fix_docker`** — installed *and* daemon-reachable; per-OS
  detail strings; Linux-only auto-install via official convenience script.
- **`check_devcontainer`/`fix_devcontainer`** — installs a CLI and repairs PATH.

## Gotchas (learned the hard way)

- **`curl … | sh` can't mutate the parent shell.** A fix that puts a binary on
  PATH must do *both*: (a) persist the `export PATH=…` line via `persist_path_line`
  for future sessions, and (b) `export PATH=…` in the current process so the
  re-check passes now. Do **not** use `source ~/.zprofile` — `source` is a bashism
  and sourcing a startup file under non-interactive `sh` is unreliable.
- **Put each export in the file its kind belongs in**, per shell convention:
  regular env vars via `persist_env_line` (zsh `~/.zshenv`, bash `~/.bash_profile`),
  PATH edits via `persist_path_line` (zsh `~/.zprofile`, bash `~/.bash_profile`).
  Both helpers cover bash *and* zsh, so a fix run under either sets up the other.
- **Literal `$HOME`/`$PATH` in startup lines must stay unexpanded** so the startup
  shell expands them later. Single-quote the line and silence the resulting
  shellcheck warning with an inline `# shellcheck disable=SC2016` (the repo
  already uses inline directives, e.g. `SC1091`). Do not "fix" it to double quotes.
- **Guard PATH dedup** before exporting: `case ":$PATH:" in *":$dir:"*) ;; *) … ;; esac`.
- **Prefer self-contained installers.** E.g. the devcontainers install script
  bundles its own Node, so the check needs no system npm — keeps the constraint.
- **Prompts** must come from `confirm` (reads `/dev/tty`, honours
  `SETUP_ASSUME_YES=1`, declines quietly when headless). Never read from stdin —
  the script itself occupies stdin under `curl … | sh`.

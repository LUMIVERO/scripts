---
description: How to add checks and fixes to setup.sh
globs: setup.sh
alwaysApply: false
---

# Rule: Adding checks and fixes to `setup.sh`

How to add a new requirement to `setup.sh`. Follow this exactly — the patterns
exist for a reason (see "Constraints" and "Gotchas").

## Mental model

`setup.sh` is a **requirements checklist**. It runs an ordered list of checks,
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

4. **Verify**: `shellcheck setup.sh && sh setup.sh`. Both must be clean.
   (Project memory: always do this after editing `setup.sh`.)

## Building blocks (already in the script — reuse, don't reinvent)

- `have_cmd <name>` — true if a command is on PATH.
- `install_pkg <brew-formula> <apt-package>` — installs via Homebrew (macOS) or
  apt (Debian/Ubuntu), keyed off `OS_FAMILY`. Sets `CHECK_DETAIL`, returns
  non-zero when it can't. Use this for fixes whenever a distro package exists.
- `ensure_line_in_file <file> <line>` — idempotent append (creates file if
  missing, skips if line already present). Use for PATH/env lines in shell rc files.
- `CHECK_DETAIL` — the per-check context string. Reset to "" by the driver
  before each check and each fix re-check; just assign it.
- `OS_FAMILY` — `macos` | `debian`, set by `check_os` (always check #1). Branch
  on it when behaviour differs per OS (see `check_docker`/`fix_docker`).

## Worked references in the file

- **`check_git`/`fix_git`** — minimal template in the `main()` comment block.
- **`check_docker`/`fix_docker`** — installed *and* daemon-reachable; per-OS
  detail strings; Linux-only auto-install via official convenience script.
- **`check_devcontainer`/`fix_devcontainer`** — installs a CLI and repairs PATH.

## Gotchas (learned the hard way)

- **`curl … | sh` can't mutate the parent shell.** A fix that puts a binary on
  PATH must do *both*: (a) persist the `export PATH=…` line into shell rc files
  for future sessions, and (b) `export PATH=…` in the current process so the
  re-check passes now. Do **not** use `source ~/.bashrc` — `source` is a bashism
  and sourcing an rc file under non-interactive `sh` is unreliable.
- **Support bash *and* zsh** when persisting env: append to both `~/.bashrc` and
  `~/.zshrc` via `ensure_line_in_file`.
- **Literal `$HOME`/`$PATH` in rc lines must stay unexpanded** so the interactive
  shell expands them at startup. Single-quote the line and silence the resulting
  shellcheck warning with an inline `# shellcheck disable=SC2016` (the repo
  already uses inline directives, e.g. `SC1091`). Do not "fix" it to double quotes.
- **Guard PATH dedup** before exporting: `case ":$PATH:" in *":$dir:"*) ;; *) … ;; esac`.
- **Prefer self-contained installers.** E.g. the devcontainers install script
  bundles its own Node, so the check needs no system npm — keeps the constraint.
- **Prompts** must come from `confirm` (reads `/dev/tty`, honours
  `SETUP_ASSUME_YES=1`, declines quietly when headless). Never read from stdin —
  the script itself occupies stdin under `curl … | sh`.

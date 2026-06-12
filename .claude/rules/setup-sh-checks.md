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
  to the files every shell reads: zsh `~/.zshenv` (always sourced) + bash
  `~/.bash_profile` (login) and `~/.bashrc` (interactive non-login). Covering
  both bash files is what lets a bare `bash` see the var — `~/.bash_profile`
  alone reaches only login shells (a fresh WSL window), not a `bash` started in
  the current session.
- `persist_path_line <line>` — append a PATH edit to the same reach as
  `persist_env_line`: zsh `~/.zprofile` (login) + bash `~/.bash_profile` (login)
  and `~/.bashrc` (interactive non-login). Because `~/.bashrc` is re-sourced by
  every nested interactive shell, the line **must** be the self-guarding one-line
  `case` form (see `DEVCONTAINER_PATH_LINE` / `CLAUDE_PATH_LINE`) so it prepends
  only when the directory is absent — an unguarded `export PATH=…:$PATH` here
  would stack a duplicate every time.
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
- **`check_devcontainer`/`fix_devcontainer`** — installs a CLI and repairs PATH;
  the check passes on the live PATH *or* on "installed at its known dir + PATH
  line persisted" (see `path_line_persisted`), so a fixed install is not
  re-fixed every run. `check_claude`/`fix_claude` follow the same shape.

## Gotchas (learned the hard way)

- **`curl … | sh` can't mutate the parent shell.** A fix that puts a binary on
  PATH must do *both*: (a) persist the `export PATH=…` line via `persist_path_line`
  for future sessions, and (b) `export PATH=…` in the current process so the
  re-check passes now. Do **not** use `source ~/.zprofile` — `source` is a bashism
  and sourcing a startup file under non-interactive `sh` is unreliable.
- **A `check_` for a persisted tool must not depend on the *live* PATH only.**
  Same root cause as above, but for the *check*: a later `curl … | sh` is a
  fresh `sh` whose PATH comes from the parent shell, which may not have sourced
  the file the fix wrote — so `have_cmd` stays false and the fix re-runs *every
  run*. Mirror the env-var checks (which grep the dotfile, not the live env):
  treat "binary at its known install dir **and** its PATH line present in the
  startup files" as satisfied. Use `path_line_persisted "$THE_LINE"`, and share
  one constant for the persisted line between the check and the fix (as
  `DEVCONTAINER_PATH_LINE` / `CLAUDE_PATH_LINE` / `GITHUB_TOKEN_LINE` do) so the
  grep and the append can never drift.
- **A login-only write doesn't reach a bare `bash`.** Writing a var or PATH edit
  to `~/.bash_profile` alone means a fresh WSL window (a *login* shell) sees it but
  typing `bash` in the current session (an *interactive non-login* shell, which
  reads only `~/.bashrc`) does not — the developer is told to "open a new terminal"
  and it still doesn't work until a full re-login. So `persist_env_line` /
  `persist_path_line` write `~/.bashrc` **and** `~/.bash_profile` for bash (zsh's
  `~/.zshenv` is already always-sourced). A `check_` that greps the persisted
  files must grep all of them (including `~/.bashrc`) so an install persisted
  before `~/.bashrc` was added re-runs its fix once to backfill, then stays
  satisfied — share one file list between the check loop and the helper.
- **Literal `$HOME`/`$PATH` in startup lines must stay unexpanded** so the startup
  shell expands them later. Single-quote the line and silence the resulting
  shellcheck warning with an inline `# shellcheck disable=SC2016` (the repo
  already uses inline directives, e.g. `SC1091`). Do not "fix" it to double quotes.
- **A persisted PATH line must self-guard** because `~/.bashrc` re-sources it on
  every interactive shell (and nested ones): persist the one-line form
  `case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$dir:$PATH" ;; esac` (literal
  `$dir`/`$PATH`/`$HOME` — see above), not a bare `export PATH=…:$PATH`, so it
  prepends only when the directory is absent and can't stack duplicates. The
  separate `export PATH=…` a fix runs to update the *current* process keeps its
  own inline `case ":$PATH:" in *":$dir:"*) ;; *) … ;; esac` guard.
- **Prefer self-contained installers.** E.g. the devcontainers install script
  bundles its own Node, so the check needs no system npm — keeps the constraint.
- **Prompts** must come from `confirm` (reads `/dev/tty`, honours
  `SETUP_ASSUME_YES=1`, declines quietly when headless). Never read from stdin —
  the script itself occupies stdin under `curl … | sh`.

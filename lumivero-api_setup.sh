#!/usr/bin/env sh

#
# lumivero-api_setup.sh — Lumivero API environment checklist.
#
# Walks a list of requirements (tools + environment settings), reports the
# status of each with a clear pass/fail/warn marker and, where a fix is known,
# offers to install or repair it.
#
# Delivery model: this script is served from GitHub Pages and run with
#   curl -fsSL https://lumivero.github.io/scripts/lumivero-api_setup.sh | sh
# so it must stay POSIX-sh clean, self-contained, and safe under `set -eu`.
#

set -eu

# ----------------------------------------------------------------------------
# Presentation: ANSI colour + emoji status icons. Degrades gracefully when
# stdout is not a terminal, when NO_COLOR is set, or on a dumb terminal.
# ----------------------------------------------------------------------------

ESC=$(printf '\033')

# The line-clear sequence is only meaningful on a terminal.
if [ -t 1 ]; then
  CLR="${ESC}[2K"
else
  CLR=""
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  RESET="${ESC}[0m"
  BOLD="${ESC}[1m"
  DIM="${ESC}[2m"
  RED="${ESC}[31m"
  GREEN="${ESC}[32m"
  YELLOW="${ESC}[33m"
  BLUE="${ESC}[34m"
else
  RESET=""
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
fi

ICON_PASS="✅"
ICON_FAIL="❌"
ICON_WARN="⚠️ "
ICON_FIX="🔧"
ICON_PEND="⏳"
ICON_INFO="ℹ️ "
ICON_DONE="🚀"

# ----------------------------------------------------------------------------
# Shared state.
# ----------------------------------------------------------------------------

OS_FAMILY=""        # macos | debian — set by check_os, consumed by install_pkg
CHECK_DETAIL=""     # short context a check may surface beside its result
PROFILES_CHANGED="" # shell-startup files actually modified this run (space-separated)
RESTART_REQUIRED="" # set by a fix whose effect only reaches a fresh login session
REPO_DIR=""         # where check_repo found the repo; consumed by branch selection

CHECK_TOTAL=0
PASS_COUNT=0
FIXED_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# ----------------------------------------------------------------------------
# Output helpers.
# ----------------------------------------------------------------------------

clear_line() {
  if [ -t 1 ]; then
    printf '\r%s' "$CLR"
  fi
}

# Transient "in progress" line, only shown on a terminal; replaced by the result.
print_pending() {
  if [ -t 1 ]; then
    printf '   %s  %s%s …%s' "$ICON_PEND" "$DIM" "$1" "$RESET"
  fi
}

# print_result <ok|fixed|warn|fail|info> <label> [detail]
print_result() {
  _state="$1"
  _label="$2"
  _detail="${3:-}"

  clear_line

  case "$_state" in
    ok)    _icon="$ICON_PASS"; _color="$GREEN" ;;
    fixed) _icon="$ICON_FIX";  _color="$GREEN" ;;
    warn)  _icon="$ICON_WARN"; _color="$YELLOW" ;;
    fail)  _icon="$ICON_FAIL"; _color="$RED" ;;
    *)     _icon="$ICON_INFO"; _color="$BLUE" ;;
  esac

  if [ -n "$_detail" ]; then
    printf '   %s  %s%s%s %s(%s)%s\n' "$_icon" "$_color" "$_label" "$RESET" "$DIM" "$_detail" "$RESET"
  else
    printf '   %s  %s%s%s\n' "$_icon" "$_color" "$_label" "$RESET"
  fi
}

print_fixing() {
  printf '   %s  %sFixing: %s …%s\n' "$ICON_FIX" "$DIM" "$1" "$RESET"
}

banner() {
  printf '\n%s%s  Lumivero environment checklist%s\n' "$BOLD" "$ICON_DONE" "$RESET"
  printf '%sChecking required tools and settings …%s\n\n' "$DIM" "$RESET"
}

print_summary() {
  printf '\n%s%s%s\n' "$DIM" "────────────────────────────────────────────" "$RESET"
  printf '%sSummary%s  %d checks   ' "$BOLD" "$RESET" "$CHECK_TOTAL"
  printf '%s%s %d passed%s' "$GREEN" "$ICON_PASS" "$PASS_COUNT" "$RESET"
  if [ "$FIXED_COUNT" -gt 0 ]; then
    printf '   %s%s %d fixed%s' "$GREEN" "$ICON_FIX" "$FIXED_COUNT" "$RESET"
  fi
  if [ "$WARN_COUNT" -gt 0 ]; then
    printf '   %s%s %d warning(s)%s' "$YELLOW" "$ICON_WARN" "$WARN_COUNT" "$RESET"
  fi
  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '   %s%s %d failed%s' "$RED" "$ICON_FAIL" "$FAIL_COUNT" "$RESET"
  fi
  printf '\n'
}

# When a fix actually wrote to a shell-startup file this run, the exported
# variables and PATH edits only reach *new* shells — the developer's current
# session won't see them. Print a closing notice naming the files that changed
# so they know to open a new terminal. No-op when nothing was modified.
print_reload_notice() {
  [ -n "$PROFILES_CHANGED" ] || return 0

  _files=""
  # shellcheck disable=SC2086  # deliberate word-splitting over the file list
  for _f in $PROFILES_CHANGED; do
    _files="${_files}${_files:+, }${_f##*/}"
  done

  printf '\n%s%s  Shell profile updated — open a new terminal%s\n' \
    "$BOLD" "$ICON_INFO" "$RESET"
  printf '%sChanges to %s apply to new shells only. Open a new terminal\n' "$DIM" "$_files"
  printf 'session (or start a new shell) for them to take effect.%s\n' "$RESET"
}

# Ask a yes/no question. Reads from the controlling terminal so it works even
# when the script itself arrives on stdin (curl … | sh). Honours
# SETUP_ASSUME_YES=1 for unattended runs; declines when no terminal is present.
confirm() {
  if [ "${SETUP_ASSUME_YES:-0}" = "1" ]; then
    return 0
  fi
  # Need an interactive terminal; bail out quietly if one cannot be opened
  # (e.g. headless CI, or a /dev/tty that exists but is not connected).
  if ! { true >/dev/tty; } 2>/dev/null; then
    return 1
  fi
  printf '%s   %s %s [y/N] %s' "$YELLOW" "$ICON_INFO" "$1" "$RESET" >/dev/tty
  if ! read -r _reply </dev/tty 2>/dev/null; then
    printf '\n' >/dev/tty 2>/dev/null
    return 1
  fi
  case "$_reply" in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# ----------------------------------------------------------------------------
# Environment probes.
# ----------------------------------------------------------------------------

is_wsl() {
  [ -n "${WSL_INTEROP:-}" ] && return 0
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

# Native Windows is unsupported: the API environment requires Ubuntu under WSL.
# A POSIX `sh` exists on Windows only via a Cygwin/MinGW/MSYS shell (Git Bash et
# al.), where `uname -s` reports CYGWIN*/MINGW*/MSYS* — whereas Ubuntu under WSL
# reports Linux (and is recognised by is_wsl). So when we see one of those shells
# we are on Windows but not in WSL: stop immediately, before any check/fix runs
# (we must never try to install Docker here), and explain how to get Ubuntu onto
# WSL. Exits the script non-zero on a match.
bail_if_windows_without_wsl() {
  case "$(uname -s)" in
    CYGWIN* | MINGW* | MSYS*) ;;   # a Windows shell; WSL would report Linux
    *) return 0 ;;
  esac

  printf '\n%s%s  Windows detected — Ubuntu under WSL is required%s\n\n' \
    "$BOLD" "$ICON_FAIL" "$RESET"
  printf '%sThe Lumivero API environment runs on Ubuntu under WSL (Windows\n' "$DIM"
  printf 'Subsystem for Linux), not directly on Windows. Set that up first,\n'
  printf 'then run this script again from inside the Ubuntu shell.%s\n\n' "$RESET"

  printf '%s%s  Install Ubuntu under WSL%s\n' "$BOLD" "$ICON_INFO" "$RESET"
  printf '  1. Open %sPowerShell%s or %sCommand Prompt%s as Administrator.\n' \
    "$BOLD" "$RESET" "$BOLD" "$RESET"
  printf '  2. Run %swsl --install -d Ubuntu%s\n' "$BOLD" "$RESET"
  printf '  3. Reboot if prompted, then launch %sUbuntu%s from the Start menu\n' \
    "$BOLD" "$RESET"
  printf '     and create your UNIX username and password.\n'
  printf '  4. From inside that Ubuntu shell, re-run this script:\n'
  printf '     %scurl -fsSL https://lumivero.github.io/scripts/lumivero-api_setup.sh | sh%s\n\n' \
    "$BOLD" "$RESET"
  printf '%sMore detail: https://learn.microsoft.com/windows/wsl/install%s\n\n' \
    "$DIM" "$RESET"

  exit 1
}

# ----------------------------------------------------------------------------
# Reusable primitives for the checks registered in main().
# ----------------------------------------------------------------------------

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Remember that a shell-startup file was actually changed this run, so the run
# can finish by telling the developer to open a new terminal for the change to
# take effect. Dedups by path, so a file touched by several fixes is named once.
record_profile_changed() {
  case " ${PROFILES_CHANGED} " in
    *" $1 "*) ;;                                                  # already recorded
    *) PROFILES_CHANGED="${PROFILES_CHANGED}${PROFILES_CHANGED:+ }$1" ;;
  esac
}

# Append a line to a file unless it is already present, creating the file if
# missing. Idempotent, so it is safe to call on every run (e.g. to put a tool's
# bin directory on PATH in a shell rc file). Records the file as changed only
# when a line is actually appended, so a no-op re-run triggers no reload notice.
ensure_line_in_file() {
  _file="$1"
  _line="$2"
  if grep -qF "$_line" "$_file" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$_line" >>"$_file"
  record_profile_changed "$_file"
}

# Where each kind of export belongs, by shell convention. The aim is that the
# lines reach *every* shell a developer opens. The trap to avoid: bash reads
# ~/.bash_profile only for a *login* shell, so a fresh WSL window picks up a
# change written there, but typing `bash` in the current session — an
# interactive non-login shell, which reads only ~/.bashrc — does not. We
# therefore cover both bash startup files.
#
#   * zsh reads ~/.zshenv for every shell (login or not), so it alone carries an
#     env var; a PATH edit additionally goes in the login file ~/.zprofile.
#   * bash has no always-sourced file, so env vars and PATH edits are written to
#     BOTH ~/.bash_profile (login) and ~/.bashrc (interactive non-login) — each
#     file carries the line independently, so neither needs to source the other.
#
# A regular env var (export VAR=value) is idempotent, so re-sourcing it in a
# nested shell is harmless. A PATH prepend is not — unguarded, it duplicates the
# entry every time ~/.bashrc is re-sourced — so persist_path_line is given the
# self-guarding line form (see DEVCONTAINER_PATH_LINE) that prepends only when
# the directory is absent.
#
# Both helpers append idempotently, so a fix run under either shell sets up the
# other too.

# Persist a regular environment-variable line so every shell sees it: zsh
# ~/.zshenv (always sourced) + bash ~/.bash_profile (login) and ~/.bashrc
# (interactive non-login).
persist_env_line() {
  ensure_line_in_file "${HOME}/.zshenv" "$1"
  ensure_line_in_file "${HOME}/.bash_profile" "$1"
  ensure_line_in_file "${HOME}/.bashrc" "$1"
}

# Persist a PATH line so every shell sees it: zsh ~/.zprofile (login) + bash
# ~/.bash_profile (login) and ~/.bashrc (interactive non-login). The line must be
# the self-guarding form (see DEVCONTAINER_PATH_LINE) so re-sourcing ~/.bashrc in
# a nested shell cannot prepend the directory twice.
persist_path_line() {
  ensure_line_in_file "${HOME}/.zprofile" "$1"
  ensure_line_in_file "${HOME}/.bash_profile" "$1"
  ensure_line_in_file "${HOME}/.bashrc" "$1"
}

# True when <line> (a PATH export persisted by persist_path_line) is already
# present in every startup file it writes — zsh ~/.zprofile and bash
# ~/.bash_profile + ~/.bashrc. This is the read counterpart of persist_path_line
# and the same file-as-source-of-truth test the env-var checks use
# (check_github_token et al. grep the dotfile rather than the live environment):
# once the line is persisted, a new shell puts the directory on PATH, so a check
# can treat a tool installed at its known location as satisfied even when the
# current `curl … | sh` process — which cannot see edits to the parent shell's
# startup files — does not yet have it on PATH. Requiring all three (not only the
# login files) means an install persisted before ~/.bashrc was added re-runs its
# fix once to backfill it, then stays satisfied. Without this, such a check would
# report "not on PATH" and re-run its fix on every invocation.
path_line_persisted() {
  for _rc in "${HOME}/.zprofile" "${HOME}/.bash_profile" "${HOME}/.bashrc"; do
    grep -qF "$1" "$_rc" 2>/dev/null || return 1
  done
  return 0
}

# Install a package by Homebrew formula (macOS) or apt package (Debian/Ubuntu).
# Usage: install_pkg <brew-formula> <apt-package>
# Sets CHECK_DETAIL and returns non-zero when it cannot install.
install_pkg() {
  _brew="$1"
  _apt="$2"
  case "$OS_FAMILY" in
    macos)
      if ! have_cmd brew; then
        CHECK_DETAIL="Homebrew required; install it from https://brew.sh"
        return 1
      fi
      brew install "$_brew"
      ;;
    debian)
      if have_cmd sudo; then
        sudo apt-get update && sudo apt-get install -y "$_apt"
      else
        apt-get update && apt-get install -y "$_apt"
      fi
      ;;
    *)
      CHECK_DETAIL="no automated installer for this environment"
      return 1
      ;;
  esac
}

# Run a command as root: via sudo when available, directly otherwise (e.g. when
# already root inside a container). Mirrors the sudo handling in install_pkg.
run_root() {
  if have_cmd sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

# ----------------------------------------------------------------------------
# Individual checks. Each returns 0 when satisfied and may set CHECK_DETAIL.
# ----------------------------------------------------------------------------

# Check #1: are we on a supported operating system? Also records OS_FAMILY so
# later fixes know which package manager to use. There is no fix for this one.
check_os() {
  _os="$(uname -s)"
  case "$_os" in
    Darwin)
      OS_FAMILY="macos"
      CHECK_DETAIL="macOS"
      return 0
      ;;
    CYGWIN* | MINGW* | MSYS*)
      CHECK_DETAIL="unsupported Windows shell ${_os}; use Ubuntu under WSL"
      return 1
      ;;
    Linux)
      if [ ! -r /etc/os-release ]; then
        CHECK_DETAIL="/etc/os-release missing; need Debian or Ubuntu"
        return 1
      fi

      # shellcheck disable=SC1091
      . /etc/os-release
      _distro="${ID:-unknown}"

      if is_wsl; then
        if [ "$_distro" != "ubuntu" ]; then
          CHECK_DETAIL="WSL distro '${_distro}'; only Ubuntu under WSL is supported"
          return 1
        fi
        OS_FAMILY="debian"
        CHECK_DETAIL="Ubuntu under Windows WSL"
        return 0
      fi

      case "$_distro" in
        debian)
          OS_FAMILY="debian"
          CHECK_DETAIL="Debian Linux"
          return 0
          ;;
        ubuntu)
          OS_FAMILY="debian"
          CHECK_DETAIL="Ubuntu Linux"
          return 0
          ;;
        pop)
          # Pop!_OS is Ubuntu-derived and apt-based, so it uses the debian family.
          OS_FAMILY="debian"
          CHECK_DETAIL="Pop!_OS Linux"
          return 0
          ;;
        *)
          CHECK_DETAIL="unsupported Linux distribution '${_distro}'"
          return 1
          ;;
      esac
      ;;
    *)
      CHECK_DETAIL="unsupported OS ${_os}"
      return 1
      ;;
  esac
}

# Docker must be both installed (the `docker` CLI on PATH) and available (its
# daemon reachable, i.e. actually running). On macOS we don't auto-install —
# the developer is pointed at OrbStack — so the detail strings differ per OS.
check_docker() {
  if ! have_cmd docker; then
    if [ "$OS_FAMILY" = "macos" ]; then
      CHECK_DETAIL="not installed; install OrbStack (https://orbstack.dev) and start it, then re-run"
    else
      CHECK_DETAIL="not installed"
    fi
    return 1
  fi

  if docker info >/dev/null 2>&1; then
    CHECK_DETAIL="installed and running"
    return 0
  fi

  if [ "$OS_FAMILY" = "macos" ]; then
    CHECK_DETAIL="installed but not running; start OrbStack and re-run"
  else
    CHECK_DETAIL="installed but daemon not reachable; start Docker (you may need to log out and back in for the docker group) and re-run"
  fi
  return 1
}

# Auto-install Docker only on Linux, via the official convenience script, then
# add the current user to the docker group. On macOS there is no automated fix:
# the developer is asked to install OrbStack and start it.
fix_docker() {
  if [ "$OS_FAMILY" != "debian" ]; then
    CHECK_DETAIL="install OrbStack (https://orbstack.dev), start it, then re-run"
    return 1
  fi

  curl -fsSL https://get.docker.com | sh || return 1

  _user="${USER:-$(id -un)}"
  if have_cmd sudo; then
    sudo usermod -aG docker "$_user" || return 1
  else
    usermod -aG docker "$_user" || return 1
  fi

  # The install succeeded, but the freshly added 'docker' group membership only
  # takes effect in a new login session — the daemon isn't usable in this one,
  # so re-checking now would fail no matter what. Raise RESTART_REQUIRED instead:
  # the driver stops the run here and asks the developer to restart and re-run.
  CHECK_DETAIL="installed — restart your session to use it"
  RESTART_REQUIRED="Docker is installed, but its 'docker' group only takes effect in a new login session. Log out and back in (or close and reopen your terminal), then re-run this script."
}

# Default location the official devcontainers/cli install script writes to: a
# self-contained build (bundling its own Node) under ~/.devcontainers/bin. The
# binary can therefore exist there before that directory is on PATH.
DEVCONTAINER_BIN_DIR="${HOME}/.devcontainers/bin"

# The PATH line the fix persists for the devcontainer CLI. A single constant so
# the check (path_line_persisted) and the fix (persist_path_line) test and write
# the exact same string — the same single-source-of-truth pattern as
# GITHUB_TOKEN_LINE. It is the self-guarding form: a one-line `case` that prepends
# the directory only when it is not already on PATH, so it is safe to source from
# ~/.bashrc on every interactive shell (including nested ones) without stacking
# duplicate entries. Literal $HOME/$PATH so the startup shell expands them later,
# not this script now (hence the SC2016 disable).
# shellcheck disable=SC2016
DEVCONTAINER_PATH_LINE='case ":$PATH:" in *":$HOME/.devcontainers/bin:"*) ;; *) export PATH="$HOME/.devcontainers/bin:$PATH" ;; esac'

# devcontainer CLI — installed and runnable. Satisfied when it is on the live
# PATH, or when it is installed at its default location and that directory's
# PATH line is already persisted to the startup files (a fresh login shell will
# then have it on PATH — see path_line_persisted). The latter is why a fixed
# install is not re-fixed on every run: this `curl … | sh` process cannot see
# PATH edits made to the parent shell's startup files, so have_cmd alone would
# keep reporting "not on PATH". A binary present but with no persisted PATH line
# is reported separately so the fix knows to repair PATH only.
check_devcontainer() {
  _new_term=""
  if have_cmd devcontainer; then
    _dc="devcontainer"
  elif [ -x "${DEVCONTAINER_BIN_DIR}/devcontainer" ] && path_line_persisted "$DEVCONTAINER_PATH_LINE"; then
    _dc="${DEVCONTAINER_BIN_DIR}/devcontainer"
    _new_term=" (open a new terminal to use it)"
  elif [ -x "${DEVCONTAINER_BIN_DIR}/devcontainer" ]; then
    CHECK_DETAIL="installed but ${DEVCONTAINER_BIN_DIR} is not on PATH"
    return 1
  else
    CHECK_DETAIL="not installed"
    return 1
  fi

  _ver="$("$_dc" --version 2>/dev/null)" || _ver=""
  CHECK_DETAIL="${_ver:-installed}${_new_term}"
  return 0
}

# Install the devcontainer CLI via the official script when missing, then put
# its bin directory on PATH: persisted for future bash and zsh sessions and
# exported into the current process so the immediate re-check sees the binary.
fix_devcontainer() {
  if [ ! -x "${DEVCONTAINER_BIN_DIR}/devcontainer" ] && ! have_cmd devcontainer; then
    if ! curl -fsSL https://raw.githubusercontent.com/devcontainers/cli/main/scripts/install.sh | sh; then
      CHECK_DETAIL="install script failed"
      return 1
    fi
  fi

  persist_path_line "$DEVCONTAINER_PATH_LINE"

  case ":${PATH}:" in
    *":${DEVCONTAINER_BIN_DIR}:"*) ;;
    *)
      PATH="${DEVCONTAINER_BIN_DIR}:${PATH}"
      export PATH
      ;;
  esac
}

# Azure CLI — installed and actually runnable (`az version` exits 0). A broken
# install (e.g. missing Python deps) is reported as such so the fix re-installs.
check_az() {
  if ! have_cmd az; then
    CHECK_DETAIL="not installed"
    return 1
  fi

  _ver="$(az version --query '"azure-cli"' -o tsv 2>/dev/null)" || _ver=""
  if az version >/dev/null 2>&1; then
    CHECK_DETAIL="${_ver:-installed}"
    return 0
  fi

  CHECK_DETAIL="installed but not working; re-install to repair"
  return 1
}

# Install the Azure CLI: Microsoft's Debian convenience script on Linux (adds
# their apt repo and installs the `azure-cli` package), Homebrew on macOS.
fix_az() {
  case "$OS_FAMILY" in
    debian)
      if have_cmd sudo; then
        curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash || return 1
      else
        curl -sL https://aka.ms/InstallAzureCLIDeb | bash || return 1
      fi
      ;;
    macos)
      install_pkg azure-cli azure-cli || return 1
      ;;
    *)
      CHECK_DETAIL="no automated installer for this environment"
      return 1
      ;;
  esac
}

# The plain command-line tools the workflow needs — each only has to be on PATH.
# They are checked and installed as one set, so when several are missing they are
# installed in a single package-manager command (one `brew install …` on macOS,
# one `apt-get install …` on Debian/Ubuntu) rather than one invocation per tool.
#
# Command name doubles as the Homebrew formula and the apt package for every tool
# here except sops, which has no usable apt package on Ubuntu/Debian (it ships
# only as a GitHub-release binary) — so on Linux sops is installed from that
# release instead (see install_sops_linux); on macOS `brew install sops` works.
CLI_TOOLS="git jq make sops"

# Satisfied when every tool in CLI_TOOLS is on PATH. CHECK_DETAIL summarises the
# set — the tools present, or which are missing — so this one line stands in for
# the per-tool lines it replaces.
check_cli_tools() {
  _present=""
  _missing=""
  # shellcheck disable=SC2086  # CLI_TOOLS is a deliberate space-separated list
  for _t in $CLI_TOOLS; do
    if have_cmd "$_t"; then
      _present="${_present}${_present:+, }${_t}"
    else
      _missing="${_missing}${_missing:+, }${_t}"
    fi
  done

  if [ -n "$_missing" ]; then
    CHECK_DETAIL="missing: ${_missing}"
    return 1
  fi
  CHECK_DETAIL="${_present}"
  return 0
}

# Install whatever tools in CLI_TOOLS are missing, in as few commands as
# possible: one `brew install` (macOS) or one `apt-get install` (Debian/Ubuntu)
# covering every missing tool at once. sops on Linux is the exception — it has no
# usable apt package, so it is fetched from its official release binary by
# install_sops_linux. Sets CHECK_DETAIL and returns non-zero when it cannot
# install; the driver re-runs check_cli_tools afterwards to confirm.
fix_cli_tools() {
  _missing=""
  # shellcheck disable=SC2086  # CLI_TOOLS is a deliberate space-separated list
  for _t in $CLI_TOOLS; do
    have_cmd "$_t" || _missing="${_missing}${_missing:+ }${_t}"
  done
  [ -n "$_missing" ] || return 0

  case "$OS_FAMILY" in
    macos)
      if ! have_cmd brew; then
        CHECK_DETAIL="Homebrew required; install it from https://brew.sh"
        return 1
      fi
      # Command name == Homebrew formula for every tool in the set.
      # shellcheck disable=SC2086  # install every missing formula in one command
      brew install $_missing || return 1
      ;;
    debian)
      # Split the miss into apt packages (command name == package name) and sops,
      # which has no apt package and is installed from its release binary instead.
      _apt=""
      _need_sops=""
      for _t in $_missing; do
        if [ "$_t" = "sops" ]; then
          _need_sops=1
        else
          _apt="${_apt}${_apt:+ }${_t}"
        fi
      done

      # One apt-get install covering every apt-installable tool that is missing.
      if [ -n "$_apt" ]; then
        if have_cmd sudo; then
          # shellcheck disable=SC2086  # install every missing package in one command
          sudo apt-get update && sudo apt-get install -y $_apt || return 1
        else
          # shellcheck disable=SC2086  # install every missing package in one command
          apt-get update && apt-get install -y $_apt || return 1
        fi
      fi

      if [ -n "$_need_sops" ]; then
        install_sops_linux || return 1
      fi
      ;;
    *)
      CHECK_DETAIL="no automated installer for this environment"
      return 1
      ;;
  esac
}

# Install sops on Debian/Ubuntu from its official GitHub release binary, because
# there is no usable sops apt package there. The latest version is read from the
# /releases/latest redirect (no API token and no JSON parsing — so this does not
# depend on jq, which may itself be installing in the same pass), the matching
# Linux binary for the machine architecture is downloaded, and it is placed on
# PATH at /usr/local/bin. Sets CHECK_DETAIL and returns non-zero on any failure.
install_sops_linux() {
  _arch="$(dpkg --print-architecture 2>/dev/null)" || _arch=""
  case "$_arch" in
    amd64 | arm64) ;;
    *)
      CHECK_DETAIL="no sops release binary for architecture '${_arch:-unknown}'"
      return 1
      ;;
  esac

  # /releases/latest redirects to /releases/tag/<version>; the version is the
  # last path segment of the resolved URL.
  _url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/getsops/sops/releases/latest 2>/dev/null)" || _url=""
  _ver="${_url##*/}"
  case "$_ver" in
    v[0-9]*) ;;
    *)
      CHECK_DETAIL="could not determine the latest sops release"
      return 1
      ;;
  esac

  _dl="https://github.com/getsops/sops/releases/download/${_ver}/sops-${_ver}.linux.${_arch}"
  _tmp="$(mktemp 2>/dev/null)" || {
    CHECK_DETAIL="could not create a temporary file for the sops download"
    return 1
  }

  if ! curl -fsSL "$_dl" -o "$_tmp"; then
    rm -f "$_tmp"
    CHECK_DETAIL="failed to download sops ${_ver} from ${_dl}"
    return 1
  fi

  if ! run_root install -m 0755 "$_tmp" /usr/local/bin/sops; then
    rm -f "$_tmp"
    CHECK_DETAIL="failed to install sops to /usr/local/bin (need write access)"
    return 1
  fi
  rm -f "$_tmp"
}

# Visual Studio Code — the editor the Dev Containers workflow runs from. It is
# auto-installed only on Linux (Debian/Ubuntu), from Microsoft's official apt
# repository; on macOS it is not installed for you (get it from
# https://code.visualstudio.com/ or `brew install --cask visual-studio-code`).
# Detected by the `code` CLI on PATH or, on macOS, the installed .app bundle —
# VS Code on macOS ships the `code` command only after you run "Shell Command:
# Install 'code' command in PATH", so the app can be present without it.
check_vscode() {
  if have_cmd code; then
    _ver="$(code --version 2>/dev/null | head -n1)" || _ver=""
    CHECK_DETAIL="${_ver:+v${_ver}, }installed"
    return 0
  fi

  if [ "$OS_FAMILY" = "macos" ]; then
    if [ -d "/Applications/Visual Studio Code.app" ] || [ -d "${HOME}/Applications/Visual Studio Code.app" ]; then
      CHECK_DETAIL="app installed (the 'code' CLI is not on PATH)"
      return 0
    fi
    CHECK_DETAIL="not installed — get it from https://code.visualstudio.com/ or 'brew install --cask visual-studio-code'"
    return 1
  fi

  CHECK_DETAIL="not installed"
  return 1
}

# Install VS Code on Debian/Ubuntu from Microsoft's official apt repository
# (https://code.visualstudio.com/docs/setup/linux) — the same keyring + sources
# list shape as the GitHub CLI fix above. On macOS there is no automated install:
# the developer is pointed at the download (or Homebrew cask).
fix_vscode() {
  if [ "$OS_FAMILY" != "debian" ]; then
    CHECK_DETAIL="install VS Code from https://code.visualstudio.com/ (or 'brew install --cask visual-studio-code')"
    return 1
  fi

  # gpg dearmors the signing key, wget fetches it — install either if missing.
  have_cmd gpg || run_root apt-get install -y gpg || {
    CHECK_DETAIL="could not install gpg (needed to dearmor the VS Code signing key)"
    return 1
  }
  have_cmd wget || run_root apt-get install -y wget || {
    CHECK_DETAIL="could not install wget (needed to fetch the VS Code signing key)"
    return 1
  }

  run_root mkdir -p -m 755 /etc/apt/keyrings || return 1
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | run_root tee /etc/apt/keyrings/packages.microsoft.gpg >/dev/null || return 1
  run_root chmod go+r /etc/apt/keyrings/packages.microsoft.gpg || return 1

  _arch="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main\n' "$_arch" \
    | run_root tee /etc/apt/sources.list.d/vscode.list >/dev/null || return 1

  run_root apt-get update || return 1
  run_root apt-get install -y code || return 1
}

# The Azure Container Registry every developer needs pull/push access to.
ACR_NAME="uluruscacr"

# Logged in to Azure *and* able to authenticate against the ACR. The probe is
# non-interactive: `az account show` confirms an active Azure session, then
# `az acr login` exchanges that session for a registry token (it docker-logs in,
# so this also relies on Docker — checked earlier). The interactive `az login`
# lives in the fix, never here, so a check never blocks waiting for a browser.
check_acr() {
  if ! have_cmd az; then
    CHECK_DETAIL="Azure CLI not installed"
    return 1
  fi

  if ! az account show >/dev/null 2>&1; then
    CHECK_DETAIL="not logged in to Azure — run 'az login && az acr login --name ${ACR_NAME}', or file an /ithelp ticket for access to ACR ${ACR_NAME}"
    return 1
  fi

  if az acr login --name "$ACR_NAME" >/dev/null 2>&1; then
    CHECK_DETAIL="logged in; ACR ${ACR_NAME} accessible"
    return 0
  fi

  CHECK_DETAIL="logged in to Azure but cannot access ACR ${ACR_NAME} — file an /ithelp ticket to request access"
  return 1
}

# Run the interactive login the developer was asked for: `az login` (opens a
# browser / device-code flow on the terminal) followed by `az acr login` against
# the registry. The driver re-runs check_acr afterwards to confirm it took.
fix_acr() {
  if az login && az acr login --name "$ACR_NAME"; then
    return 0
  fi
  CHECK_DETAIL="login failed — run 'az login && az acr login --name ${ACR_NAME}', or file an /ithelp ticket for access to ACR ${ACR_NAME}"
  return 1
}

# GitHub CLI — installed and authenticated. `gh auth status` exits 0 only when
# there is a usable credential, so it doubles as the login probe; the
# interactive `gh auth login` lives in the fix, never here, so a check never
# blocks waiting for a browser.
check_gh() {
  if ! have_cmd gh; then
    CHECK_DETAIL="not installed"
    return 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    CHECK_DETAIL="installed but not logged in — run 'gh auth login'"
    return 1
  fi

  _ver="$(gh --version 2>/dev/null | head -n1 | cut -d' ' -f3)" || _ver=""
  CHECK_DETAIL="${_ver:+v${_ver}, }logged in"
  return 0
}

# Install the GitHub CLI when missing — Homebrew on macOS, the official GitHub
# apt repository on Debian/Ubuntu (the distro package lags badly) — then run the
# interactive `gh auth login`. Login input is read from /dev/tty so the prompts
# work under `curl … | sh`, where the script itself occupies stdin.
fix_gh() {
  if ! have_cmd gh; then
    case "$OS_FAMILY" in
      macos)
        install_pkg gh gh || return 1
        ;;
      debian)
        have_cmd wget || run_root apt-get install -y wget || {
          CHECK_DETAIL="could not install wget (needed to fetch the GitHub CLI keyring)"
          return 1
        }
        run_root mkdir -p -m 755 /etc/apt/keyrings || return 1
        wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          | run_root tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null || return 1
        run_root chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg || return 1
        _arch="$(dpkg --print-architecture)"
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$_arch" \
          | run_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null || return 1
        run_root apt-get update || return 1
        run_root apt-get install -y gh || return 1
        ;;
      *)
        CHECK_DETAIL="no automated installer for this environment"
        return 1
        ;;
    esac
  fi

  # Authenticate if there is no usable credential yet. gh auth login is
  # interactive; read its prompts from the terminal, not the piped-in script.
  if ! gh auth status >/dev/null 2>&1; then
    if ! gh auth login </dev/tty; then
      CHECK_DETAIL="login failed — run 'gh auth login'"
      return 1
    fi
  fi
}

# GITHUB_ACCESS_TOKEN wired into the shell profile — a regular environment
# variable, so it lives in the shell startup files (zsh ~/.zshenv; bash
# ~/.bash_profile and ~/.bashrc). The Lumivero API tooling reads this env var. Rather than
# write the secret to disk, we persist a command that resolves it at shell
# startup from the GitHub CLI credential (established by the GitHub CLI check
# above) — so the token itself never lands in a dotfile, and a rotated `gh`
# login is picked up automatically by the next shell. Single quotes keep the
# `$(…)` literal so the startup shell evaluates it later, not this script now
# (hence the SC2016 disable).
# shellcheck disable=SC2016
GITHUB_TOKEN_LINE='export GITHUB_ACCESS_TOKEN="$(gh auth token 2>/dev/null)"'

# Satisfied when that exact line is present in every env-var file persist_env_line
# writes (~/.zshenv, ~/.bash_profile, ~/.bashrc). The same fixed-string test
# ensure_line_in_file uses to append, so the two agree.
check_github_token() {
  for _rc in "${HOME}/.zshenv" "${HOME}/.bash_profile" "${HOME}/.bashrc"; do
    if ! grep -qF "$GITHUB_TOKEN_LINE" "$_rc" 2>/dev/null; then
      CHECK_DETAIL="not set in ${_rc##*/}"
      return 1
    fi
  done

  CHECK_DETAIL="set via 'gh auth token' in your shell startup files"
  return 0
}

# Persist the resolver line into the env-var files (idempotent append). It is
# a fixed command, not a value, so there is nothing to update on a token change
# and the secret is never written. The line works once the GitHub CLI is logged
# in, which the required check above ensures runs first.
fix_github_token() {
  persist_env_line "$GITHUB_TOKEN_LINE"
}

# LUV_TOKEN_CHECKSUM_SECRET — a per-developer secret the Lumivero API tooling
# uses to checksum tokens. A regular environment variable, so it lives in the
# shell startup files (zsh ~/.zshenv; bash ~/.bash_profile and ~/.bashrc). Unlike
# GITHUB_ACCESS_TOKEN (a fixed resolver command), this is a generated random
# value persisted verbatim, so the check matches an `export
# LUV_TOKEN_CHECKSUM_SECRET=` line by pattern (the value differs per machine)
# rather than an exact line, and the fix generates the secret once and writes
# the *same* value to both files — a split value would make bash and zsh
# compute different checksums.
CHECKSUM_SECRET_VAR="LUV_TOKEN_CHECKSUM_SECRET"

# Print the value exported for <var> in <file> (last export wins, matching shell
# semantics), with one layer of surrounding quotes stripped. Empty output (and a
# non-zero return) when the variable is not exported there.
exported_value_in() {
  _file="$1"
  _var="$2"
  _ln="$(grep -E "^[[:space:]]*export[[:space:]]+${_var}=" "$_file" 2>/dev/null | tail -n1)" || _ln=""
  [ -n "$_ln" ] || return 1
  _val="${_ln#*=}"
  case "$_val" in
    \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;;
    \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;;
  esac
  printf '%s' "$_val"
}

# Value of CHECKSUM_SECRET_VAR exported in <file> — a thin wrapper over the
# generic helper above, kept for readability at its call sites.
checksum_secret_in() {
  exported_value_in "$1" "$CHECKSUM_SECRET_VAR"
}

# Satisfied when CHECKSUM_SECRET_VAR is exported (to a non-empty value) in every
# env-var file persist_env_line writes (~/.zshenv, ~/.bash_profile, ~/.bashrc).
check_checksum_secret() {
  for _rc in "${HOME}/.zshenv" "${HOME}/.bash_profile" "${HOME}/.bashrc"; do
    _cur="$(checksum_secret_in "$_rc")" || _cur=""
    if [ -z "$_cur" ]; then
      CHECK_DETAIL="not set in ${_rc##*/}"
      return 1
    fi
  done
  CHECK_DETAIL="set in your shell startup files"
  return 0
}

# Persist the secret into the env-var files (idempotent append). Reuse a value
# already present in either file so the two stay in sync; only generate a fresh
# secret with `openssl rand -base64 32` when neither has one. The base64
# alphabet (A-Za-z0-9+/=) carries no characters special inside double quotes.
fix_checksum_secret() {
  _val="$(checksum_secret_in "${HOME}/.zshenv")" || _val=""
  if [ -z "$_val" ]; then
    _val="$(checksum_secret_in "${HOME}/.bash_profile")" || _val=""
  fi
  if [ -z "$_val" ]; then
    _val="$(checksum_secret_in "${HOME}/.bashrc")" || _val=""
  fi
  if [ -z "$_val" ]; then
    if ! have_cmd openssl; then
      CHECK_DETAIL="openssl not available to generate the secret"
      return 1
    fi
    _val="$(openssl rand -base64 32)" || _val=""
    if [ -z "$_val" ]; then
      CHECK_DETAIL="failed to generate a secret with 'openssl rand -base64 32'"
      return 1
    fi
  fi

  _line="export ${CHECKSUM_SECRET_VAR}=\"${_val}\""
  persist_env_line "$_line"
}

# The official install.sh writes the native build to ~/.local/bin, so the
# binary can exist there before that directory is on PATH (same shape as the
# devcontainer CLI above).
CLAUDE_BIN_DIR="${HOME}/.local/bin"

# The PATH line the fix persists for Claude Code — the single source of truth
# shared by the check (path_line_persisted) and the fix (persist_path_line), as
# with DEVCONTAINER_PATH_LINE above, and likewise the self-guarding `case` form so
# it can be sourced from ~/.bashrc on every shell without duplicating the entry.
# Literal $HOME/$PATH for the startup shell (SC2016).
# shellcheck disable=SC2016
CLAUDE_PATH_LINE='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'

# Claude Code (the `claude` CLI) — installed, reachable, signed in, and current.
# It is "reachable" when on the live PATH, or installed at its default location
# with its PATH line already persisted (a fresh login shell will then find it —
# see path_line_persisted); that second case is what stops a fixed install from
# being re-fixed every run, since this `curl … | sh` process can't see PATH
# edits to the parent shell's startup files. The binary is resolved once (by its
# absolute path when only persisted, else by name) and the same checks run on
# it: login is probed non-interactively with `claude auth status --json`, which
# reports `"loggedIn": true` for a usable session — the interactive
# `claude auth login` lives in the fix, never here, so a check never blocks
# waiting for a browser. When signed in, the check also runs `claude update` to
# keep the install current — best-effort, so a failed or already-current update
# never flips a healthy check to failing ("up to date" is reported only when the
# update actually succeeds). A binary present with no persisted PATH line is
# reported separately so the fix knows to repair PATH only.
check_claude() {
  _new_term=""
  if have_cmd claude; then
    _claude="claude"
  elif [ -x "${CLAUDE_BIN_DIR}/claude" ] && path_line_persisted "$CLAUDE_PATH_LINE"; then
    _claude="${CLAUDE_BIN_DIR}/claude"
    _new_term=" (open a new terminal to use it)"
  elif [ -x "${CLAUDE_BIN_DIR}/claude" ]; then
    CHECK_DETAIL="installed but ${CLAUDE_BIN_DIR} is not on PATH"
    return 1
  else
    CHECK_DETAIL="not installed"
    return 1
  fi

  if "$_claude" auth status --json 2>/dev/null | grep -qE '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
    if "$_claude" update >/dev/null 2>&1; then
      _upd=", up to date"
    else
      _upd=""
    fi
    _ver="$("$_claude" --version 2>/dev/null | cut -d' ' -f1)" || _ver=""
    CHECK_DETAIL="${_ver:+v${_ver}, }logged in${_upd}${_new_term}"
    return 0
  fi
  CHECK_DETAIL="installed but not logged in — run 'claude auth login'"
  return 1
}

# Install the native build via the official script when missing, put
# ~/.local/bin on PATH (persisted for future bash and zsh sessions and exported
# into the current process so the immediate re-check finds the binary), then
# sign in if needed. Updating is left to the post-fix re-check (check_claude
# runs `claude update`), so the fix itself does not duplicate it.
fix_claude() {
  if [ ! -x "${CLAUDE_BIN_DIR}/claude" ] && ! have_cmd claude; then
    if ! curl -fsSL https://claude.ai/install.sh | bash; then
      CHECK_DETAIL="install script failed"
      return 1
    fi
  fi

  persist_path_line "$CLAUDE_PATH_LINE"

  case ":${PATH}:" in
    *":${CLAUDE_BIN_DIR}:"*) ;;
    *)
      PATH="${CLAUDE_BIN_DIR}:${PATH}"
      export PATH
      ;;
  esac

  # Sign in if there is no usable session yet. claude auth login is interactive;
  # read its prompts from the terminal, not the piped-in script.
  if ! claude auth status --json 2>/dev/null | grep -qE '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
    if ! claude auth login </dev/tty; then
      CHECK_DETAIL="login failed — run 'claude auth login'"
      return 1
    fi
  fi
}

# JFrog credentials the Lumivero API tooling reads as JFROG_CREDENTIALS_USR /
# JFROG_CREDENTIALS_PSW — the Jenkins-style binding of a single username/token
# credential (USR = JFrog username, PSW = a JFrog Identity Token). Both are
# regular environment variables, so they live in the shell startup files (zsh
# ~/.zshenv; bash ~/.bash_profile and ~/.bashrc), persisted verbatim like
# LUV_TOKEN_CHECKSUM_SECRET: the values are hand-entered secrets with no source
# to derive them from, so the resolver-line trick used for GITHUB_ACCESS_TOKEN
# does not apply. The developer creates the token in the JFrog UI and pastes it.
JFROG_USR_VAR="JFROG_CREDENTIALS_USR"
JFROG_PSW_VAR="JFROG_CREDENTIALS_PSW"
JFROG_URL="https://lumivero.jfrog.io/"

# Satisfied when both credential vars are exported (to non-empty values) in every
# env-var file persist_env_line writes (~/.zshenv, ~/.bash_profile, ~/.bashrc).
check_jfrog_creds() {
  for _rc in "${HOME}/.zshenv" "${HOME}/.bash_profile" "${HOME}/.bashrc"; do
    for _var in "$JFROG_USR_VAR" "$JFROG_PSW_VAR"; do
      _cur="$(exported_value_in "$_rc" "$_var")" || _cur=""
      if [ -z "$_cur" ]; then
        CHECK_DETAIL="${_var} not set in ${_rc##*/}"
        return 1
      fi
    done
  done
  CHECK_DETAIL="set in your shell startup files"
  return 0
}

# Prompt for the credentials and persist both verbatim to the env-var files.
# Reuse a value already present in either file so re-runs don't clobber it and
# the two files stay in sync; only prompt for what's missing. Prompts read from
# /dev/tty (the script itself occupies stdin under curl … | sh); the token is
# read with echo off so a pasted secret is not shown on screen.
fix_jfrog_creds() {
  _usr="$(exported_value_in "${HOME}/.zshenv" "$JFROG_USR_VAR")" || _usr=""
  [ -n "$_usr" ] || { _usr="$(exported_value_in "${HOME}/.bash_profile" "$JFROG_USR_VAR")" || _usr=""; }
  [ -n "$_usr" ] || { _usr="$(exported_value_in "${HOME}/.bashrc" "$JFROG_USR_VAR")" || _usr=""; }
  _psw="$(exported_value_in "${HOME}/.zshenv" "$JFROG_PSW_VAR")" || _psw=""
  [ -n "$_psw" ] || { _psw="$(exported_value_in "${HOME}/.bash_profile" "$JFROG_PSW_VAR")" || _psw=""; }
  [ -n "$_psw" ] || { _psw="$(exported_value_in "${HOME}/.bashrc" "$JFROG_PSW_VAR")" || _psw=""; }

  if [ -z "$_usr" ] || [ -z "$_psw" ]; then
    # Prompting needs a controlling terminal; bail cleanly when headless (CI).
    if ! { true >/dev/tty; } 2>/dev/null; then
      CHECK_DETAIL="no terminal to enter credentials; set ${JFROG_USR_VAR} and ${JFROG_PSW_VAR} manually"
      return 1
    fi
    printf '   %s  Create a JFrog Identity Token at %s (Edit Profile), then paste it below.\n' \
      "$ICON_INFO" "$JFROG_URL" >/dev/tty
  fi

  if [ -z "$_usr" ]; then
    printf '%s   %s JFrog username: %s' "$YELLOW" "$ICON_INFO" "$RESET" >/dev/tty
    read -r _usr </dev/tty 2>/dev/null || _usr=""
    if [ -z "$_usr" ]; then
      CHECK_DETAIL="no JFrog username entered"
      return 1
    fi
  fi

  if [ -z "$_psw" ]; then
    printf '%s   %s JFrog identity token: %s' "$YELLOW" "$ICON_INFO" "$RESET" >/dev/tty
    stty -echo </dev/tty 2>/dev/null || true
    read -r _psw </dev/tty 2>/dev/null || _psw=""
    stty echo </dev/tty 2>/dev/null || true
    printf '\n' >/dev/tty 2>/dev/null
    if [ -z "$_psw" ]; then
      CHECK_DETAIL="no JFrog identity token entered"
      return 1
    fi
  fi

  # Write the same value to both files so bash and zsh agree. The token alphabet
  # carries no characters special inside double quotes (same assumption as the
  # base64 checksum secret above).
  persist_env_line "export ${JFROG_USR_VAR}=\"${_usr}\""
  persist_env_line "export ${JFROG_PSW_VAR}=\"${_psw}\""
}

# The Lumivero API repository and where it lives on GitHub. The checkout is
# expected in the developer's current working directory (curl … | sh runs there).
REPO_NAME="lumivero-api"
REPO_URL="https://github.com/lumivero/lumivero-api"

# The lumivero-api checkout. Satisfied two ways: the current directory is already
# the repo (its basename is lumivero-api — the developer cd'd in earlier), or a
# lumivero-api subdirectory is present in the current directory. Cloning lives in
# the fix; this only reports presence. On a hit it records the repo directory in
# REPO_DIR so main() can offer branch selection against it afterwards (the same
# whether the repo was already present or just cloned by the fix); REPO_DIR is
# cleared up front so a miss leaves it empty.
check_repo() {
  REPO_DIR=""
  _cwd="$(pwd)"
  if [ "${_cwd##*/}" = "$REPO_NAME" ]; then
    REPO_DIR="."
    CHECK_DETAIL="already inside ${REPO_NAME}"
    return 0
  fi
  if [ -d "$REPO_NAME" ]; then
    REPO_DIR="$REPO_NAME"
    CHECK_DETAIL="present at ./${REPO_NAME}"
    return 0
  fi
  CHECK_DETAIL="not present in ${_cwd} — clone ${REPO_URL}"
  return 1
}

# Once the repo is in place — freshly cloned or already present — fetch every
# branch and let the developer pick one to check out. Best-effort and never
# fatal: when run unattended (SETUP_ASSUME_YES), headless (no /dev/tty), or if
# git/fetch fails, the current branch is kept — as is a blank or invalid
# selection. All paths return 0. The menu and prompt read from /dev/tty so they
# work under `curl … | sh`. Called from main() against REPO_DIR.
select_repo_branch() {
  _dir="$1"

  have_cmd git || return 0

  # The menu is interactive: skip it (keeping the default branch) when unattended
  # or when no controlling terminal can be opened.
  if [ "${SETUP_ASSUME_YES:-0}" = "1" ]; then
    return 0
  fi
  if ! { true >/dev/tty; } 2>/dev/null; then
    return 0
  fi

  git -C "$_dir" fetch --all --quiet 2>/dev/null || return 0

  # Remote branches, "refs/remotes/origin/" prefix stripped and the HEAD symref
  # dropped. We match on the full refname (not %(refname:short)) because the short
  # form of refs/remotes/origin/HEAD is the bare "origin", which would slip past a
  # name filter and show up as a phantom branch. A fresh clone has no other local
  # branch, so origin's refs are the full set.
  _branches="$(git -C "$_dir" for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null \
    | sed 's#^refs/remotes/origin/##' | grep -v '^HEAD$')" || _branches=""
  if [ -z "$_branches" ]; then
    return 0
  fi

  _current="$(git -C "$_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" || _current=""
  _count="$(printf '%s\n' "$_branches" | wc -l | tr -d ' ')"

  printf '\n   %s  Branches in %s%s%s — select one to check out:\n' \
    "$ICON_INFO" "$BOLD" "$REPO_NAME" "$RESET" >/dev/tty

  # Numbered list; the same order as the sed lookup below, so the index matches.
  _i=0
  printf '%s\n' "$_branches" | while IFS= read -r _b; do
    _i=$((_i + 1))
    printf '       %s%2d%s) %s\n' "$DIM" "$_i" "$RESET" "$_b" >/dev/tty
  done

  printf '%s   %s Branch number [1-%s, Enter keeps %s]: %s' \
    "$YELLOW" "$ICON_INFO" "$_count" "${_current:-the default branch}" "$RESET" >/dev/tty
  read -r _sel </dev/tty 2>/dev/null || _sel=""

  # A blank answer keeps the default branch.
  if [ -z "$_sel" ]; then
    return 0
  fi

  # Validate: a number within range. Anything else keeps the default branch.
  case "$_sel" in
    *[!0-9]*)
      printf '   %s  %sNot a number — keeping %s.%s\n' \
        "$ICON_INFO" "$DIM" "${_current:-the default branch}" "$RESET" >/dev/tty
      return 0
      ;;
  esac
  if [ "$_sel" -lt 1 ] || [ "$_sel" -gt "$_count" ]; then
    printf '   %s  %sOut of range — keeping %s.%s\n' \
      "$ICON_INFO" "$DIM" "${_current:-the default branch}" "$RESET" >/dev/tty
    return 0
  fi

  _chosen="$(printf '%s\n' "$_branches" | sed -n "${_sel}p")"
  [ -n "$_chosen" ] || return 0

  if git -C "$_dir" checkout "$_chosen" >/dev/null 2>&1; then
    printf '   %s  %sChecked out branch%s %s%s%s\n' \
      "$ICON_INFO" "$DIM" "$RESET" "$BOLD" "$_chosen" "$RESET" >/dev/tty
  else
    printf '   %s  %sCould not check out %s — keeping %s.%s\n' \
      "$ICON_WARN" "$DIM" "$_chosen" "${_current:-the default branch}" "$RESET" >/dev/tty
  fi
}

# Clone the repository into the current directory. Prefer the GitHub CLI when it
# is present (it carries the auth from check #8, so it works for the private org
# repo without a separate git credential helper) and fall back to git over HTTPS.
# curl … | sh cannot change the caller's shell directory, so we can't honour the
# `cd lumivero-api` step ourselves — we point the developer at it instead. Branch
# selection is not done here: main() runs it against REPO_DIR after the post-fix
# re-check confirms the clone, so it happens for an already-present repo too.
fix_repo() {
  if have_cmd gh; then
    gh repo clone "lumivero/${REPO_NAME}" || return 1
  elif have_cmd git; then
    git clone "$REPO_URL" || return 1
  else
    CHECK_DETAIL="neither gh nor git available to clone ${REPO_URL}"
    return 1
  fi

  printf '   %s  %sCloned into ./%s — run: cd %s%s\n' \
    "$ICON_INFO" "$DIM" "$REPO_NAME" "$REPO_NAME" "$RESET"
}

# ----------------------------------------------------------------------------
# Check driver.
# ----------------------------------------------------------------------------

# run_check <label> <check_fn> [fix_fn] [required|optional]
#
#   check_fn : returns 0 when satisfied; may set CHECK_DETAIL for context.
#   fix_fn   : optional; attempts to satisfy the requirement, returns 0 on success.
#   severity : "required" (default) counts a miss as a failure; "optional" warns.
#
# Always returns 0 so one failing check does not abort the run under `set -e`;
# the final exit status is derived from FAIL_COUNT in main().
run_check() {
  _label="$1"
  _check="$2"
  _fix="${3:-}"
  _severity="${4:-required}"

  CHECK_TOTAL=$((CHECK_TOTAL + 1))
  CHECK_DETAIL=""

  print_pending "$_label"

  if "$_check"; then
    print_result ok "$_label" "$CHECK_DETAIL"
    PASS_COUNT=$((PASS_COUNT + 1))
    return 0
  fi

  _detail="$CHECK_DETAIL"
  clear_line

  if [ -n "$_fix" ] && confirm "Attempt to fix \"$_label\" now?"; then
    print_fixing "$_label"
    if "$_fix"; then
      [ -n "$RESTART_REQUIRED" ] && finish_restart_required "$_label"
      CHECK_DETAIL=""
      if "$_check"; then
        print_result fixed "$_label" "$CHECK_DETAIL"
        FIXED_COUNT=$((FIXED_COUNT + 1))
        return 0
      fi
    fi
    _detail="${CHECK_DETAIL:-$_detail}"
  fi

  if [ "$_severity" = "optional" ]; then
    print_result warn "$_label" "$_detail"
    WARN_COUNT=$((WARN_COUNT + 1))
    return 0
  fi

  print_result fail "$_label" "$_detail"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  return 0
}

# Stop the run early because a fix installed something whose effect only reaches
# a fresh login session (Docker's 'docker' group is the case in point): the
# remaining checks can't pass in this session, so there's no point continuing.
# The install itself succeeded, so this records the check as fixed, shows it,
# prints the restart instruction RESTART_REQUIRED carries, and exits 0 — nothing
# failed; the developer just restarts and re-runs.
finish_restart_required() {
  _label="$1"
  _detail="${CHECK_DETAIL:-installed — restart your session}"
  FIXED_COUNT=$((FIXED_COUNT + 1))

  print_result fixed "$_label" "$_detail"

  print_reload_notice   # name any profile files changed (no-op when none were)

  printf '\n%s%s  Restart your session, then re-run this script%s\n' \
    "$BOLD" "$ICON_INFO" "$RESET"
  printf '%s%s%s\n\n' "$DIM" "$RESTART_REQUIRED" "$RESET"

  exit 0
}

# ----------------------------------------------------------------------------
# The checklist.
# ----------------------------------------------------------------------------

main() {
  # Windows without WSL has no supported path: bail with guidance before any
  # check runs, rather than trying to install Docker.
  bail_if_windows_without_wsl

  banner

  # 1. Operating system — the foundation every other check builds on.
  run_check "Supported operating system" check_os "" required

  # An unsupported OS is fatal: every later check installs via OS_FAMILY, which
  # check_os sets only on a supported system, so the rest of the run could do
  # nothing useful. check_os leaves OS_FAMILY empty on every failure path — bail
  # with the supported matrix rather than limping on through checks that can't pass.
  if [ -z "$OS_FAMILY" ]; then
    printf '\n%s%s Unsupported operating system — stopping.%s\n' "$RED" "$ICON_FAIL" "$RESET"
    printf '%s   Supported: macOS, Debian, Ubuntu, Pop!_OS, or Ubuntu under Windows WSL.%s\n\n' \
      "$DIM" "$RESET"
    exit 1
  fi

  # ---------------------------------------------------------------------------
  # Add further checks below. Each is one run_check line backed by a check
  # function (returns 0 when satisfied, sets CHECK_DETAIL for context) and,
  # optionally, a fix function that installs or repairs it. Template:
  #
  #   check_git() {
  #     have_cmd git && return 0
  #     CHECK_DETAIL="not installed"
  #     return 1
  #   }
  #   fix_git() { install_pkg git git; }
  #
  #   run_check "git is installed" check_git fix_git required
  #
  # Pass severity "optional" for nice-to-haves so they warn instead of fail.
  # ---------------------------------------------------------------------------

  # 2. Docker — installed and its daemon reachable.
  run_check "Docker is installed and available" check_docker fix_docker required

  # 3. devcontainer CLI — installed, on PATH, and executable.
  run_check "devcontainer CLI is installed and on PATH" check_devcontainer fix_devcontainer required

  # 4. Azure CLI — installed and runnable.
  run_check "Azure CLI is installed and working" check_az fix_az required

  # 5. Command-line tools — git, jq, make and sops, checked and installed as one
  #    set so a multi-tool miss is fixed in a single package-manager command.
  run_check "Command-line tools installed (git, jq, make, sops)" check_cli_tools fix_cli_tools required

  # 6. Visual Studio Code — the editor the Dev Containers workflow runs from.
  #    Auto-installed on Linux only; optional, so a macOS/WSL miss just warns.
  run_check "Visual Studio Code is installed" check_vscode fix_vscode optional

  # 7. Azure + ACR login — signed in and able to reach the uluruscacr registry.
  #    Depends on the Azure CLI (4) and Docker (2), so it comes last.
  run_check "Logged in to Azure and ACR uluruscacr accessible" check_acr fix_acr required

  # 8. GitHub CLI — installed and authenticated (gh auth login).
  run_check "GitHub CLI is installed and logged in" check_gh fix_gh required

  # 9. GITHUB_ACCESS_TOKEN — exported in ~/.zshenv, ~/.bash_profile and ~/.bashrc
  #    from the GitHub CLI credential (8), so it must come after it.
  run_check "GITHUB_ACCESS_TOKEN is exported in your shell profile" check_github_token fix_github_token required

  # 10. LUV_TOKEN_CHECKSUM_SECRET — a generated secret exported in ~/.zshenv,
  #     ~/.bash_profile and ~/.bashrc (created with `openssl rand -base64 32` when missing).
  run_check "LUV_TOKEN_CHECKSUM_SECRET is exported in your shell profile" check_checksum_secret fix_checksum_secret required

  # 11. Claude Code — installed, on PATH, up to date, and signed in.
  run_check "Claude Code is installed and logged in" check_claude fix_claude required

  # 12. JFrog credentials — JFROG_CREDENTIALS_USR/PSW exported in ~/.zshenv,
  #     ~/.bash_profile and ~/.bashrc. Entered by hand (paste a JFrog Identity Token).
  run_check "JFrog credentials are exported in your shell profile" check_jfrog_creds fix_jfrog_creds required

  # 13. lumivero-api repository — checked out in the current directory (or we are
  #     already inside it). Depends on the GitHub CLI (8) for the private clone.
  run_check "lumivero-api repository is checked out" check_repo fix_repo required

  # With the repo in place (already present or just cloned), offer a branch to
  # check out. REPO_DIR is set by check_repo on a hit (and stays set across the
  # post-fix re-check), empty on a miss — so this is skipped when the repo is
  # absent. select_repo_branch is non-fatal and self-skips when unattended/headless.
  if [ -n "$REPO_DIR" ]; then
    select_repo_branch "$REPO_DIR"
  fi

  print_summary
  print_reload_notice

  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '\n%s%s Setup incomplete — %d required check(s) need attention.%s\n\n' \
      "$RED" "$ICON_FAIL" "$FAIL_COUNT" "$RESET"
    exit 1
  fi

  printf '\n%s%s Environment ready.%s\n\n' "$GREEN" "$ICON_DONE" "$RESET"
}

main "$@"

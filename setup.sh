#!/usr/bin/env sh

#
# setup.sh — Lumivero environment checklist.
#
# Walks a list of requirements (tools + environment settings), reports the
# status of each with a clear pass/fail/warn marker and, where a fix is known,
# offers to install or repair it.
#
# Delivery model: this script is served from GitHub Pages and run with
#   curl -fsSL https://lumivero.github.io/scripts/setup.sh | sh
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

# ----------------------------------------------------------------------------
# Reusable primitives for the checks registered in main().
# ----------------------------------------------------------------------------

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Append a line to a file unless it is already present, creating the file if
# missing. Idempotent, so it is safe to call on every run (e.g. to put a tool's
# bin directory on PATH in a shell rc file).
ensure_line_in_file() {
  _file="$1"
  _line="$2"
  if grep -qF "$_line" "$_file" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$_line" >>"$_file"
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
}

# Default location the official devcontainers/cli install script writes to: a
# self-contained build (bundling its own Node) under ~/.devcontainers/bin. The
# binary can therefore exist there before that directory is on PATH.
DEVCONTAINER_BIN_DIR="${HOME}/.devcontainers/bin"

# devcontainer CLI — installed and runnable from PATH. We treat "on PATH and
# executes" as the bar; a binary that exists in the default install dir but is
# not yet on PATH is reported separately so the fix knows to repair PATH only.
check_devcontainer() {
  if have_cmd devcontainer; then
    _ver="$(devcontainer --version 2>/dev/null)" || _ver=""
    CHECK_DETAIL="${_ver:-installed}"
    return 0
  fi

  if [ -x "${DEVCONTAINER_BIN_DIR}/devcontainer" ]; then
    CHECK_DETAIL="installed but ${DEVCONTAINER_BIN_DIR} is not on PATH"
    return 1
  fi

  CHECK_DETAIL="not installed"
  return 1
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

  # Literal $HOME/$PATH so the interactive shell expands them at startup, not now.
  # shellcheck disable=SC2016
  _line='export PATH="$HOME/.devcontainers/bin:$PATH"'
  ensure_line_in_file "${HOME}/.bashrc" "$_line"
  ensure_line_in_file "${HOME}/.zshrc" "$_line"

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

# ----------------------------------------------------------------------------
# The checklist.
# ----------------------------------------------------------------------------

main() {
  banner

  # 1. Operating system — the foundation every other check builds on.
  run_check "Supported operating system" check_os "" required

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

  # 5. Azure + ACR login — signed in and able to reach the uluruscacr registry.
  #    Depends on the Azure CLI (4) and Docker (2), so it comes last.
  run_check "Logged in to Azure and ACR uluruscacr accessible" check_acr fix_acr required

  # 6. GitHub CLI — installed and authenticated (gh auth login).
  run_check "GitHub CLI is installed and logged in" check_gh fix_gh required

  print_summary

  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '\n%s%s Setup incomplete — %d required check(s) need attention.%s\n\n' \
      "$RED" "$ICON_FAIL" "$FAIL_COUNT" "$RESET"
    exit 1
  fi

  printf '\n%s%s Environment ready.%s\n\n' "$GREEN" "$ICON_DONE" "$RESET"
}

main "$@"

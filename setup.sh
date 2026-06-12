#!/usr/bin/env sh

set -eu

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

is_wsl() {
  [ -n "${WSL_INTEROP:-}" ] && return 0
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

is_wslg() {
  # WSLg typically exposes one of these markers.
  [ "${WSL2_GUI_APPS_ENABLED:-0}" = "1" ] && return 0
  [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
  [ -n "${DISPLAY:-}" ] && [ -d /mnt/wslg ] && return 0
  [ -S /mnt/wslg/runtime-dir/wayland-0 ] && return 0
  return 1
}

os_name="$(uname -s)"

case "$os_name" in
  Darwin)
    printf 'Supported environment detected: macOS\n'
    ;;
  CYGWIN*|MINGW*|MSYS*)
    fail "Unsupported Windows bash environment (${os_name}). Supported on Windows only as Ubuntu under WSLg."
    ;;
  Linux)
    if [ ! -r /etc/os-release ]; then
      fail "Linux detected, but /etc/os-release is missing. Supported: Debian Linux or Ubuntu."
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    distro="${ID:-unknown}"

    if is_wsl; then
      if [ "$distro" != "ubuntu" ]; then
        fail "WSL detected with distro '${distro}'. Supported on Windows only as Ubuntu under WSLg."
      fi

      printf 'Supported environment detected: Ubuntu under Windows WSLg\n'
      exit 0
    fi

    if [ "$distro" = "debian" ]; then
      printf 'Supported environment detected: Debian Linux\n'
      exit 0
    fi

    if [ "$distro" = "ubuntu" ]; then
      printf 'Supported environment detected: Ubuntu Linux\n'
      exit 0
    fi

    fail "Unsupported Linux distribution: ${distro}. Supported: Debian Linux, or Ubuntu under Windows WSLg."
    ;;
  *)
    fail "Unsupported OS: ${os_name}. Supported: macOS, Debian Linux, or Ubuntu under Windows WSLg."
    ;;
esac

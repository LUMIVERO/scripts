#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

is_wsl() {
  [[ -n "${WSL_INTEROP:-}" || -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

is_wslg() {
  # WSLg usually exposes these environment/runtime markers.
  [[ -n "${WAYLAND_DISPLAY:-}" ]] && return 0
  [[ -n "${DISPLAY:-}" && -d /mnt/wslg ]] && return 0
  [[ -S /mnt/wslg/runtime-dir/wayland-0 ]] && return 0
  return 1
}

os_name="$(uname -s)"

case "$os_name" in
  Darwin)
    printf 'Supported environment detected: macOS\n'
    ;;
  Linux)
    if [[ ! -r /etc/os-release ]]; then
      fail "Linux detected, but /etc/os-release is missing. Supported: Debian Linux, or Ubuntu under WSLg only."
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    distro="${ID:-unknown}"

    if [[ "$distro" == "debian" ]]; then
      printf 'Supported environment detected: Debian Linux\n'
      exit 0
    fi

    if [[ "$distro" == "ubuntu" ]]; then
      if ! is_wsl; then
        fail "Ubuntu detected, but not inside WSL. Only Ubuntu inside Windows WSLg is supported."
      fi

      if ! is_wslg; then
        fail "Ubuntu under WSL detected, but WSLg markers were not found. Start a WSLg-capable session and try again."
      fi

      printf 'Supported environment detected: Ubuntu under Windows WSLg\n'
      exit 0
    fi

    fail "Unsupported Linux distribution: ${distro}. Supported: Debian Linux, or Ubuntu under WSLg only."
    ;;
  *)
    fail "Unsupported OS: ${os_name}. Supported: macOS, Debian Linux, or Ubuntu under Windows WSLg only."
    ;;
esac

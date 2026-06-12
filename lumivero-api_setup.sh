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

CHECK_TOTAL=0
PASS_COUNT=0
FIXED_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
CHECK_INDEX=0       # 1-based position of the current check (picks each beast)

# ----------------------------------------------------------------------------
# Side-scroller animation state.
#
# A little side-scroller: the developer (🧑‍💻) holds a fixed spot on the left and
# flies up and down, while a landscape of trees and greenery scrolls past along
# the ground — so the stationary developer appears to be flying rightward. Each
# check arrives from the right as a beast; the developer lines up and blasts it,
# the beast turns into a fruit that scrolls back and is digested as the developer
# flies over it. A failing check sends the developer crashing into the ground.
# Active only on an interactive terminal (GAME_ON); otherwise the script falls
# back to plain line-by-line results, so `curl … | sh` in CI is unaffected.
# ----------------------------------------------------------------------------

# The game needs cursor control and redraws, so it runs only when stdout is an
# interactive terminal. SETUP_NO_GAME=1 opts out (e.g. for a quieter run).
GAME_ON=0
if [ -t 1 ] && [ "${SETUP_NO_GAME:-0}" != "1" ]; then
  GAME_ON=1
fi

# Playfield geometry, in cells (each cell is one 2-wide glyph). From the top:
# flight rows 0..TREE_ROW-1 are open sky where the developer, beasts and fruit
# fly; then a scrolling tree line, a green grass band, and a brown earth band at
# the bottom. The developer holds a fixed column (DEV_COL) and only changes row
# — it "flies" vertically — while beasts and fruit enter from the right. Each
# check plays one self-contained scene, so the animation needs no check count to
# pace it (it scales automatically).
FIELD_W=12             # playfield width in cells
FIELD_H=8              # playfield height in cells (flight rows + 3 ground bands)
TREE_ROW=5             # scrolling tree line (trees with sky gaps); also the row a
                       # crashing developer hits, and the count of flight rows
GRASS_ROW=6            # solid green grass band
EARTH_ROW=7            # solid brown earth band (bottom row)
DEV_COL=1              # the developer's fixed column
START_ROW=2            # the developer's resting flight height
DEV_ROW=2              # the developer's current row (mutated as it flies)
RESULTS=""             # accumulated result lines, redrawn beneath the field
GAME_ELINE="${ESC}[K"  # erase-to-end-of-line, appended per row for flicker-free redraws

# Per-scene actors, chosen by check number in run_check_game.
CUR_BEAST=""           # the beast glyph for the current check
CUR_FRUIT=""           # the fruit it turns into when blasted
BEAST_ROW=0            # the sky row the beast occupies (varies per check)

# A different dangerous beast — and the fruit it becomes — per check, cycled by
# index (wrapping if there are ever more checks than entries).
BEASTS="🐉 👹 👾 🦂 🐍 🦖 🐊 🐺 🦅 🦈 👻"
FRUITS="🍎 🍊 🍇 🍓 🍒 🍑 🍐 🍍 🍌 🥝 🍉"

# Scrolling tree line. SCROLL advances one cell per frame, shifting the tree row
# left so the stationary developer reads as flying rightward; beasts and fruit
# move left at this same one-cell-per-frame speed. GROUND_SCENERY is the
# repeating run of trees and sky gaps (split into SCEN_0… by scenery_init); a
# prime-ish length avoids the pattern lining up with the field width.
SCROLL=0
GROUND_SCENERY="🌲 🟦 🟦 🌳 🟦 🌲 🟦 🟦 🌳 🟦 🟦 🌲 🟦 🌳 🟦 🟦 🌲"
GROUND_LEN=0           # number of tree-line cells (set by scenery_init)

G_SKY="🟦"      # open sky (also the gaps between trees on the tree line)
G_GRASS="🟩"    # solid green grass band
G_EARTH="🟫"    # solid brown earth band (bottom row)
G_DEV="🧑‍💻"     # the developer (holds a fixed spot, flies up and down)
G_SHOT="✨"      # the blast travelling toward a beast
G_CRASH="💥"    # the developer crashing into the ground on a failed check

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
# Side-scroller rendering.
#
# Each frame is a full redraw: the playfield on top, the accumulated pass/fail
# lines (RESULTS) below. Used only when GAME_ON=1; run_check otherwise prints
# results live, line by line.
# ----------------------------------------------------------------------------

game_sleep() {
  sleep 0.06 2>/dev/null || true
}

# Split GROUND_SCENERY into positional cells SCEN_0 … SCEN_{GROUND_LEN-1} so the
# ground row can be indexed by arithmetic (no per-cell subshell) as it scrolls.
scenery_init() {
  GROUND_LEN=0
  # shellcheck disable=SC2086  # deliberate word-splitting over the scenery list
  for _s in $GROUND_SCENERY; do
    eval "SCEN_${GROUND_LEN}=\$_s"
    GROUND_LEN=$((GROUND_LEN + 1))
  done
}

# The Nth (1-based) whitespace-separated token of a list, wrapping around when
# the index exceeds the count. Used to pick a beast / fruit per check.
nth_token() {
  _idx="$1"
  _list="$2"
  _count=0
  # shellcheck disable=SC2086  # deliberate word-splitting over the token list
  for _t in $_list; do _count=$((_count + 1)); done
  [ "$_count" -gt 0 ] || return 0
  _want=$(( (_idx - 1) % _count + 1 ))
  _i=0
  # shellcheck disable=SC2086
  for _t in $_list; do
    _i=$((_i + 1))
    if [ "$_i" -eq "$_want" ]; then
      printf '%s' "$_t"
      return 0
    fi
  done
}

banner_game() {
  printf '%s%s  Lumivero Setup — flight of the developer%s   %sfly %s up & down · blast beasts · eat fruit%s%s\n%s\n' \
    "$BOLD" "$ICON_DONE" "$RESET" "$DIM" "$G_DEV" "$RESET" "$GAME_ELINE" "$GAME_ELINE"
}

# Draw one frame flicker-free: open a synchronized update (ignored by terminals
# that don't support it), home the cursor, and overwrite the previous frame in
# place — no clear *before* drawing, so the screen never blanks. Each row erases
# its own tail (GAME_ELINE); a single clear-below at the end trims any leftover
# lines underneath.
#
#   render_field <dev_row> <actor_kind> <actor_row> <actor_col> <shot_col> <crashed>
#
# actor_kind is beast | fruit | gone | none; shot_col is the blast column (-1
# when no blast is in flight); crashed=1 draws the developer wrecked (💥) on the
# tree line at its column. The bottom three rows are the scrolling tree line (sky
# showing through the gaps), a green grass band and a brown earth band; in the
# flight rows above, cell priority is developer, then actor, then blast, else sky.
render_field() {
  _drow="$1"
  _akind="$2"
  _arow="$3"
  _acol="$4"
  _shot="$5"
  _crash="$6"

  printf '%s[?2026h%s[H' "$ESC" "$ESC"
  banner_game

  _r=0
  while [ "$_r" -lt "$FIELD_H" ]; do
    _line="   "
    _c=0
    while [ "$_c" -lt "$FIELD_W" ]; do
      if [ "$_r" -eq "$EARTH_ROW" ]; then
        _cell="$G_EARTH"
      elif [ "$_r" -eq "$GRASS_ROW" ]; then
        _cell="$G_GRASS"
      elif [ "$_r" -eq "$TREE_ROW" ]; then
        if [ "$_crash" = "1" ] && [ "$_c" -eq "$DEV_COL" ]; then
          _cell="$G_CRASH"
        elif [ "$GROUND_LEN" -gt 0 ]; then
          _gi=$(( (_c + SCROLL) % GROUND_LEN ))
          eval "_cell=\$SCEN_${_gi}"
        else
          _cell="$G_SKY"
        fi
      elif [ "$_crash" != "1" ] && [ "$_c" -eq "$DEV_COL" ] && [ "$_r" -eq "$_drow" ]; then
        _cell="$G_DEV"
      elif [ "$_akind" != "none" ] && [ "$_akind" != "gone" ] && [ "$_c" -eq "$_acol" ] && [ "$_r" -eq "$_arow" ]; then
        if [ "$_akind" = "beast" ]; then
          _cell="$CUR_BEAST"
        else
          _cell="$CUR_FRUIT"
        fi
      elif [ "$_shot" -ge 0 ] && [ "$_c" -eq "$_shot" ] && [ "$_r" -eq "$_arow" ]; then
        _cell="$G_SHOT"
      else
        _cell="$G_SKY"
      fi
      _line="${_line}${_cell}"
      _c=$((_c + 1))
    done
    printf '%s%s\n' "$_line" "$GAME_ELINE"
    _r=$((_r + 1))
  done

  printf '%s\n%s' "$GAME_ELINE" "$RESULTS"
  printf '%s[J%s[?2026l' "$ESC" "$ESC"

  SCROLL=$((SCROLL + 1))   # advance the landscape one cell for the next frame
}

# Animate one check's scene. <state> is ok|fixed|warn|fail. The beast flies in
# from the right at world speed (one cell per frame, the same as the scrolling
# trees). On a non-failing state the developer lines up its row and blasts the
# beast into a fruit that scrolls back and is digested as it flies over; on a
# failure the beast reaches the developer, who plummets and crashes into the
# ground. DEV_ROW persists between scenes, so the climb or dive to meet each
# beast is the up-and-down "flying" motion.
play_scene() {
  _state="$1"
  _bcol=$((FIELD_W - 1))        # the beast enters at the right edge

  # Fly the developer one row toward the beast (helper kept inline for clarity).
  if [ "$_state" = "fail" ]; then
    # The beast flies all the way in and collides with the developer …
    while [ "$_bcol" -gt $((DEV_COL + 1)) ]; do
      if [ "$DEV_ROW" -lt "$BEAST_ROW" ]; then
        DEV_ROW=$((DEV_ROW + 1))
      elif [ "$DEV_ROW" -gt "$BEAST_ROW" ]; then
        DEV_ROW=$((DEV_ROW - 1))
      fi
      render_field "$DEV_ROW" beast "$BEAST_ROW" "$_bcol" -1 0
      game_sleep
      _bcol=$((_bcol - 1))
    done
    # … and the developer plummets and crashes into the ground (the tree line).
    _fall="$DEV_ROW"
    while [ "$_fall" -lt $((TREE_ROW - 1)) ]; do
      _fall=$((_fall + 1))
      render_field "$_fall" beast "$BEAST_ROW" "$_bcol" -1 0
      game_sleep
    done
    render_field "$TREE_ROW" beast "$BEAST_ROW" "$_bcol" -1 1
    game_sleep
    DEV_ROW="$START_ROW"   # respawn at resting height for the next check
    return 0
  fi

  # The developer flies up or down to line up its row; once aligned it fires a
  # blast that travels right to meet the left-moving beast.
  _shot=-1
  while :; do
    if [ "$DEV_ROW" -lt "$BEAST_ROW" ]; then
      DEV_ROW=$((DEV_ROW + 1))
    elif [ "$DEV_ROW" -gt "$BEAST_ROW" ]; then
      DEV_ROW=$((DEV_ROW - 1))
    elif [ "$_shot" -lt 0 ]; then
      _shot=$((DEV_COL + 1))                       # aligned — launch the blast
    fi

    [ "$_shot" -ge 0 ] && [ "$_shot" -ge "$_bcol" ] && break   # blast meets beast
    [ "$_bcol" -le $((DEV_COL + 1)) ] && break                 # safety stop

    render_field "$DEV_ROW" beast "$BEAST_ROW" "$_bcol" "$_shot" 0
    game_sleep
    _bcol=$((_bcol - 1))
    [ "$_shot" -ge 0 ] && _shot=$((_shot + 1))
  done

  # The beast turns into a fruit where it was hit …
  render_field "$DEV_ROW" fruit "$BEAST_ROW" "$_bcol" -1 0
  game_sleep

  # … and the fruit scrolls left at world speed until the developer flies over
  # and digests it.
  _fcol="$_bcol"
  while [ "$_fcol" -gt "$DEV_COL" ]; do
    _fcol=$((_fcol - 1))
    render_field "$DEV_ROW" fruit "$BEAST_ROW" "$_fcol" -1 0
    game_sleep
  done
  render_field "$DEV_ROW" gone "$BEAST_ROW" "$DEV_COL" -1 0
  game_sleep
}

# Format one result line (no trailing newline) for the RESULTS buffer. Mirrors
# print_result but returns the string instead of printing it live.
format_result() {
  _fstate="$1"
  _flabel="$2"
  _fdetail="${3:-}"

  case "$_fstate" in
    ok)    _ficon="$ICON_PASS"; _fcolor="$GREEN" ;;
    fixed) _ficon="$ICON_FIX";  _fcolor="$GREEN" ;;
    warn)  _ficon="$ICON_WARN"; _fcolor="$YELLOW" ;;
    fail)  _ficon="$ICON_FAIL"; _fcolor="$RED" ;;
    *)     _ficon="$ICON_INFO"; _fcolor="$BLUE" ;;
  esac

  if [ -n "$_fdetail" ]; then
    printf '   %s  %s%s%s %s(%s)%s' "$_ficon" "$_fcolor" "$_flabel" "$RESET" "$DIM" "$_fdetail" "$RESET"
  else
    printf '   %s  %s%s%s' "$_ficon" "$_fcolor" "$_flabel" "$RESET"
  fi
}

# Format the cheerful "the developer crashed" block for a failed check (no
# trailing newline). The detail already carries the fix hint.
format_crash() {
  _dlabel="$1"
  _ddetail="${2:-}"

  printf '   %s  %s%sThe beast won — you crashed into the ground!%s %s%s%s\n' \
    "$G_CRASH" "$BOLD" "$RED" "$RESET" "$RED" "$_dlabel" "$RESET"
  if [ -n "$_ddetail" ]; then
    printf '       %s %sRespawn quest:%s %s%s%s\n' "$ICON_FIX" "$BOLD" "$RESET" "$DIM" "$_ddetail" "$RESET"
  fi
  printf '       %sShake it off and take flight again — you'\''ve got this! 💪%s' \
    "$DIM" "$RESET"
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
# we are on Windows but not in WSL: stop immediately, before the game or any
# check/fix runs (we must never animate or try to install Docker here), and
# explain how to get Ubuntu onto WSL. Exits the script non-zero on a match.
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

# Where each kind of export belongs, by shell convention:
#
#   * A regular environment variable (export VAR=value) goes in an
#     always-sourced file — zsh's ~/.zshenv (read by every zsh, login or not)
#     and bash's ~/.bash_profile (login shell).
#   * A PATH edit (export PATH=…:$PATH) goes in a login file — zsh's ~/.zprofile
#     and bash's ~/.bash_profile — so a nested non-login shell doesn't re-source
#     it and prepend the same entry twice.
#
# Both helpers append idempotently to both shells' files, so a fix run under
# either shell sets up the other too.

# Persist a regular environment-variable line: zsh ~/.zshenv + bash ~/.bash_profile.
persist_env_line() {
  ensure_line_in_file "${HOME}/.zshenv" "$1"
  ensure_line_in_file "${HOME}/.bash_profile" "$1"
}

# Persist a PATH line: zsh ~/.zprofile + bash ~/.bash_profile.
persist_path_line() {
  ensure_line_in_file "${HOME}/.zprofile" "$1"
  ensure_line_in_file "${HOME}/.bash_profile" "$1"
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

  # Literal $HOME/$PATH so the startup shell expands them later, not now.
  # shellcheck disable=SC2016
  _line='export PATH="$HOME/.devcontainers/bin:$PATH"'
  persist_path_line "$_line"

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

# GITHUB_ACCESS_TOKEN wired into the shell profile — a regular environment
# variable, so it lives in the always-sourced files (zsh ~/.zshenv, bash
# ~/.bash_profile). The Lumivero API tooling reads this env var. Rather than
# write the secret to disk, we persist a command that resolves it at shell
# startup from the GitHub CLI credential (established by the GitHub CLI check
# above) — so the token itself never lands in a dotfile, and a rotated `gh`
# login is picked up automatically by the next shell. Single quotes keep the
# `$(…)` literal so the startup shell evaluates it later, not this script now
# (hence the SC2016 disable).
# shellcheck disable=SC2016
GITHUB_TOKEN_LINE='export GITHUB_ACCESS_TOKEN="$(gh auth token 2>/dev/null)"'

# Satisfied when that exact line is present in both env-var files (~/.zshenv and
# ~/.bash_profile). The same fixed-string test ensure_line_in_file uses to
# append, so the two agree.
check_github_token() {
  for _rc in "${HOME}/.zshenv" "${HOME}/.bash_profile"; do
    if ! grep -qF "$GITHUB_TOKEN_LINE" "$_rc" 2>/dev/null; then
      CHECK_DETAIL="not set in ${_rc##*/}"
      return 1
    fi
  done

  CHECK_DETAIL="set via 'gh auth token' in ~/.zshenv and ~/.bash_profile"
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
# always-sourced files (zsh ~/.zshenv, bash ~/.bash_profile). Unlike
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

# Satisfied when CHECKSUM_SECRET_VAR is exported (to a non-empty value) in both
# env-var files (~/.zshenv and ~/.bash_profile).
check_checksum_secret() {
  for _rc in "${HOME}/.zshenv" "${HOME}/.bash_profile"; do
    _cur="$(checksum_secret_in "$_rc")" || _cur=""
    if [ -z "$_cur" ]; then
      CHECK_DETAIL="not set in ${_rc##*/}"
      return 1
    fi
  done
  CHECK_DETAIL="set in ~/.zshenv and ~/.bash_profile"
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

# Claude Code (the `claude` CLI) — installed, on PATH, signed in, and current.
# Login is probed non-interactively with `claude auth status --json`, which
# reports `"loggedIn": true` for a usable session; the interactive
# `claude auth login` lives in the fix, never here, so a check never blocks
# waiting for a browser. When installed and signed in, the check also runs
# `claude update` to keep the install current on every run — best-effort, so a
# failed or already-current update never flips a healthy check to failing
# ("up to date" is reported only when the update actually succeeds). A binary
# present in the default install dir but not yet on PATH is reported separately
# so the fix knows to repair PATH only.
check_claude() {
  if have_cmd claude; then
    if claude auth status --json 2>/dev/null | grep -qE '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
      if claude update >/dev/null 2>&1; then
        _upd=", up to date"
      else
        _upd=""
      fi
      _ver="$(claude --version 2>/dev/null | cut -d' ' -f1)" || _ver=""
      CHECK_DETAIL="${_ver:+v${_ver}, }logged in${_upd}"
      return 0
    fi
    CHECK_DETAIL="installed but not logged in — run 'claude auth login'"
    return 1
  fi

  if [ -x "${CLAUDE_BIN_DIR}/claude" ]; then
    CHECK_DETAIL="installed but ${CLAUDE_BIN_DIR} is not on PATH"
    return 1
  fi

  CHECK_DETAIL="not installed"
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

  # Literal $HOME/$PATH so the startup shell expands them later, not now.
  # shellcheck disable=SC2016
  _line='export PATH="$HOME/.local/bin:$PATH"'
  persist_path_line "$_line"

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
# regular environment variables, so they live in the always-sourced files (zsh
# ~/.zshenv, bash ~/.bash_profile), persisted verbatim like
# LUV_TOKEN_CHECKSUM_SECRET: the values are hand-entered secrets with no source
# to derive them from, so the resolver-line trick used for GITHUB_ACCESS_TOKEN
# does not apply. The developer creates the token in the JFrog UI and pastes it.
JFROG_USR_VAR="JFROG_CREDENTIALS_USR"
JFROG_PSW_VAR="JFROG_CREDENTIALS_PSW"
JFROG_URL="https://lumivero.jfrog.io/"

# Satisfied when both credential vars are exported (to non-empty values) in both
# env-var files (~/.zshenv and ~/.bash_profile).
check_jfrog_creds() {
  for _rc in "${HOME}/.zshenv" "${HOME}/.bash_profile"; do
    for _var in "$JFROG_USR_VAR" "$JFROG_PSW_VAR"; do
      _cur="$(exported_value_in "$_rc" "$_var")" || _cur=""
      if [ -z "$_cur" ]; then
        CHECK_DETAIL="${_var} not set in ${_rc##*/}"
        return 1
      fi
    done
  done
  CHECK_DETAIL="set in ~/.zshenv and ~/.bash_profile"
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
  _psw="$(exported_value_in "${HOME}/.zshenv" "$JFROG_PSW_VAR")" || _psw=""
  [ -n "$_psw" ] || { _psw="$(exported_value_in "${HOME}/.bash_profile" "$JFROG_PSW_VAR")" || _psw=""; }

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
# the fix; this only reports presence.
check_repo() {
  _cwd="$(pwd)"
  if [ "${_cwd##*/}" = "$REPO_NAME" ]; then
    CHECK_DETAIL="already inside ${REPO_NAME}"
    return 0
  fi
  if [ -d "$REPO_NAME" ]; then
    CHECK_DETAIL="present at ./${REPO_NAME}"
    return 0
  fi
  CHECK_DETAIL="not present in ${_cwd} — clone ${REPO_URL}"
  return 1
}

# Clone the repository into the current directory. Prefer the GitHub CLI when it
# is present (it carries the auth from check #6, so it works for the private org
# repo without a separate git credential helper) and fall back to git over HTTPS.
# curl … | sh cannot change the caller's shell directory, so we can't honour the
# `cd lumivero-api` step ourselves — we point the developer at it instead.
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
  CHECK_INDEX=$((CHECK_INDEX + 1))
  CHECK_DETAIL=""

  if [ "$GAME_ON" = "1" ]; then
    run_check_game "$_label" "$_check" "$_fix" "$_severity"
    return 0
  fi

  # ---- plain line-by-line presentation (non-interactive / opted out) --------
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

# Game variant of run_check: resolves the check (running its fix if confirmed),
# appends a result line — or a crash block on an unresolved failure — to the
# RESULTS buffer, then animates this check's scene. The fix runs before the
# scene, so a successful fix plays a clean blast-and-eat rather than a crash.
# Counters are kept identical to the plain path so print_summary agrees.
run_check_game() {
  _label="$1"
  _check="$2"
  _fix="${3:-}"
  _severity="${4:-required}"

  # This check's beast and the fruit it becomes (cycled by check number); the
  # row it occupies varies so the developer has to fly up and down to meet it.
  CUR_BEAST="$(nth_token "$CHECK_INDEX" "$BEASTS")"
  CUR_FRUIT="$(nth_token "$CHECK_INDEX" "$FRUITS")"
  BEAST_ROW=$(( (CHECK_INDEX * 3 + 1) % TREE_ROW ))   # flight rows are 0..TREE_ROW-1

  _state=""
  if "$_check"; then
    _state="ok"
  else
    _detail="$CHECK_DETAIL"
    if [ -n "$_fix" ] && confirm "Attempt to fix \"$_label\" now?"; then
      print_fixing "$_label"
      if "$_fix"; then
        CHECK_DETAIL=""
        "$_check" && _state="fixed"
      fi
      [ -z "$_state" ] && _detail="${CHECK_DETAIL:-$_detail}"
    fi
    if [ -z "$_state" ]; then
      if [ "$_severity" = "optional" ]; then
        _state="warn"
      else
        _state="fail"
      fi
    fi
  fi

  case "$_state" in
    ok)
      _rline="$(format_result ok "$_label" "$CHECK_DETAIL")"
      PASS_COUNT=$((PASS_COUNT + 1)) ;;
    fixed)
      _rline="$(format_result fixed "$_label" "$CHECK_DETAIL")"
      FIXED_COUNT=$((FIXED_COUNT + 1)) ;;
    warn)
      _rline="$(format_result warn "$_label" "$_detail")"
      WARN_COUNT=$((WARN_COUNT + 1)) ;;
    *)
      _rline="$(format_crash "$_label" "$_detail")"
      FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
  esac

  RESULTS="${RESULTS}${_rline}
"

  play_scene "$_state"
}

# ----------------------------------------------------------------------------
# The checklist.
# ----------------------------------------------------------------------------

main() {
  # Windows without WSL has no supported path: bail with guidance before the
  # game or any check runs, rather than animating and trying to install Docker.
  bail_if_windows_without_wsl

  if [ "$GAME_ON" = "1" ]; then
    RESULTS=""
    SCROLL=0
    DEV_ROW="$START_ROW"
    scenery_init
    render_field "$DEV_ROW" none 0 0 -1 0
    game_sleep
  else
    banner
  fi

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

  # 7. GITHUB_ACCESS_TOKEN — exported in ~/.zshenv and ~/.bash_profile from the
  #    GitHub CLI credential (6), so it must come after it.
  run_check "GITHUB_ACCESS_TOKEN is exported in your shell profile" check_github_token fix_github_token required

  # 8. LUV_TOKEN_CHECKSUM_SECRET — a generated secret exported in ~/.zshenv and
  #    ~/.bash_profile (created with `openssl rand -base64 32` when missing).
  run_check "LUV_TOKEN_CHECKSUM_SECRET is exported in your shell profile" check_checksum_secret fix_checksum_secret required

  # 9. Claude Code — installed, on PATH, up to date, and signed in.
  run_check "Claude Code is installed and logged in" check_claude fix_claude required

  # 10. JFrog credentials — JFROG_CREDENTIALS_USR/PSW exported in ~/.zshenv and
  #     ~/.bash_profile. Entered by hand (paste a JFrog Identity Token).
  run_check "JFrog credentials are exported in your shell profile" check_jfrog_creds fix_jfrog_creds required

  # 11. lumivero-api repository — checked out in the current directory (or we are
  #     already inside it). Depends on the GitHub CLI (6) for the private clone.
  run_check "lumivero-api repository is checked out" check_repo fix_repo required

  print_summary

  if [ "$FAIL_COUNT" -gt 0 ]; then
    if [ "$GAME_ON" = "1" ]; then
      printf '\n%s%s %d crash(es) — clear the quest(s) above and take flight again.%s\n\n' \
        "$RED" "$G_CRASH" "$FAIL_COUNT" "$RESET"
    else
      printf '\n%s%s Setup incomplete — %d required check(s) need attention.%s\n\n' \
        "$RED" "$ICON_FAIL" "$FAIL_COUNT" "$RESET"
    fi
    exit 1
  fi

  if [ "$GAME_ON" = "1" ]; then
    printf '\n%s%s Every beast cleared — environment ready! 🏆🎉%s\n\n' \
      "$GREEN" "$BOLD" "$RESET"
  else
    printf '\n%s%s Environment ready.%s\n\n' "$GREEN" "$ICON_DONE" "$RESET"
  fi
}

main "$@"

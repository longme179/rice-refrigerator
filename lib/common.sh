# lib/common.sh - shared helpers for rice-backup / rice-restore (no secrets here)
# Sourced by bin/rice-backup.sh and bin/rice-restore.sh.

RICE_VERSION="0.4.0"
RICE_GIT_BASE_DEFAULT="https://github.com"
RICE_API_BASE_DEFAULT="https://api.github.com"

rice_info() { printf '[rice-backup] %s\n' "$*"; }
rice_warn() { printf '[rice-backup] WARNING: %s\n' "$*" >&2; }
rice_err()  { printf '[rice-backup] ERROR: %s\n' "$*" >&2; }
rice_die()  { rice_err "$*"; exit "${2:-1}"; }

rice_have() { command -v "$1" >/dev/null 2>&1; }

rice_is_tty() { [ -t 0 ]; }

# y/N confirmation (stdin)
rice_confirm() {
  local reply
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r reply || return 1
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# typed confirmation: the exact string $2 must be typed (public-repo guard; --yes never bypasses)
rice_confirm_typed() {
  local reply
  printf '%s (type exactly: %s) ' "$1" "$2" >&2
  IFS= read -r reply || return 1
  [ "$reply" = "$2" ]
}

# hidden secret input; refuses non-tty stdin so a piped token can never be logged
rice_read_secret() { # $1 varname  $2 prompt
  local __var=$1 __prompt=$2
  rice_is_tty || return 1
  printf '%s' "$__prompt" >&2
  IFS= read -rs "$__var" || return 1
  printf '\n' >&2
  return 0
}

# distro family: fedora | arch | ubuntu | unknown  (RICE_TEST_DISTRO overrides for tests)
rice_detect_distro() {
  if [ -n "${RICE_TEST_DISTRO:-}" ]; then printf '%s' "$RICE_TEST_DISTRO"; return; fi
  local id="" like=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id=${ID:-}
    like=${ID_LIKE:-}
  fi
  case "$id" in
    fedora|nobara|sericea|ublue*) printf 'fedora'; return ;;
    arch|artix|endeavouros|cachyos|manjaro) printf 'arch'; return ;;
    ubuntu|pop|linuxmint|debian|elementary|zorin|kali) printf 'ubuntu'; return ;;
  esac
  case "$like" in
    *fedora*) printf 'fedora' ;;
    *arch*) printf 'arch' ;;
    *debian*) printf 'ubuntu' ;;
    *) printf 'unknown' ;;
  esac
}

# distro version string for the manifest
rice_distro_version() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s %s' "${NAME:-unknown}" "${VERSION_ID:-}"
  else
    printf 'unknown'
  fi
}

# desktop environment (informational; collection never depends on it - see DECISIONS A3)
rice_detect_de() {
  local d="${XDG_CURRENT_DESKTOP:-} ${DESKTOP_SESSION:-}"
  case "$d" in
    *GNOME*|*gnome*) printf 'gnome'; return ;;
    *KDE*|*Plasma*|*plasma*) printf 'kde'; return ;;
  esac
  if rice_have plasmashell; then printf 'kde'; return; fi
  if rice_have gnome-shell; then printf 'gnome'; return; fi
  printf 'unknown'
}

# human-readable size
rice_hr_size() {
  local b=${1:-0}
  if [ "$b" -ge 1073741824 ]; then printf '%s GiB' "$((b / 1073741824))"
  elif [ "$b" -ge 1048576 ]; then printf '%s MiB' "$((b / 1048576))"
  elif [ "$b" -ge 1024 ]; then printf '%s KiB' "$((b / 1024))"
  else printf '%s B' "$b"; fi
}

rice_require_core() {
  local c missing=0
  for c in git tar find grep sha256sum stat readlink xargs sort; do
    rice_have "$c" || { rice_err "required command not found: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || exit 1
}

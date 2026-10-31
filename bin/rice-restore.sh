#!/usr/bin/env bash
# bin/rice-restore.sh - restore a rice-backup repository onto this machine.
#
# Usage:
#   rice-restore.sh --from URL [--dry-run|--apply] [--section NAME]...
#                   [--all-sections] [--list-sections] [--home DIR]
#                   [--skip-verify]
#
# Safety rules (R9):
#   - dry-run by default; --apply is required to change anything
#   - section-by-section opt-in (--section ... or --all-sections)
#   - any existing file is moved to ~/.rice-restore-backup-<timestamp>/ first
#   - the tool NEVER invokes sudo; system + package actions are written as
#     reviewable scripts that you run yourself
#   - package names without a known cross-distro mapping are LISTED in
#     UNMAPPED.txt, never guessed

set -u

RICE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# shellcheck source=../lib/common.sh
. "$RICE_ROOT/lib/common.sh"
# shellcheck source=../lib/gitops.sh
. "$RICE_ROOT/lib/gitops.sh"
# shellcheck source=../lib/restore.sh
. "$RICE_ROOT/lib/restore.sh"

FROM_URL=""
MODE="dry-run"
SECTIONS=()
ALL_SECTIONS=0
LIST_ONLY=0
TARGET_HOME="${HOME}"
SKIP_VERIFY=0
RELINK=0

usage() {
  cat <<'USAGE'
rice-restore - restore a rice-backup repository

usage: rice-restore.sh --from URL [options]
  --from URL          backup repository (https://github.com/OWNER/REPO.git or a
                      local file:// path)
  --dry-run           default mode: show the plan, change nothing
  --apply             actually restore (still never runs sudo)
  --section NAME      restore only this section (repeatable)
  --all-sections      restore every section present in the backup
  --list-sections     print the sections found in the backup and exit
  --home DIR          restore into DIR instead of $HOME
  --skip-verify       skip the manifest sha256 verification
  --relink            after restoring, recreate the symlink layout recorded
                      in the backup's symlinks.tsv: each followed link's
                      content moves to its recorded target location (inside
                      this home only) and the symlink is recreated. Links whose
                      target would land outside the home are LISTED, never
                      guessed. A dry-run only previews the relink plan
                      guessed. On dry-run the relink plan is only previewed

sections: dotfiles config systemd-user local-bin applications fonts
          icons-themes gnome-extensions kde gnome-dconf crontab packages system
USAGE
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ $# -ge 2 ] || usage 2; FROM_URL=$2; shift 2 ;;
    --dry-run) MODE="dry-run"; shift ;;
    --apply) MODE="apply"; shift ;;
    --section) [ $# -ge 2 ] || usage 2; SECTIONS+=("$2"); shift 2 ;;
    --all-sections) ALL_SECTIONS=1; shift ;;
    --list-sections) LIST_ONLY=1; shift ;;
    --home) [ $# -ge 2 ] || usage 2; TARGET_HOME=$2; shift 2 ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --relink) RELINK=1; shift ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage 2 ;;
  esac
done

rice_require_core
[ -n "$FROM_URL" ] || usage 2
[ -d "$TARGET_HOME" ] || rice_die "target home not found: $TARGET_HOME (create it first)" 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rice-restore.XXXXXX") || rice_die "mktemp failed" 1
trap 'rm -rf -- "$WORK" 2>/dev/null' EXIT

# authentication only for real github URLs (file:// test remotes need none)
case "$FROM_URL" in
  https://github.com/*)
    INTERACTIVE=0
    rice_is_tty && INTERACTIVE=1
    rice_auth_init "$INTERACTIVE" || rice_die "authentication failed" 4
    rice_auth_setup_git || rice_die "could not prepare git authentication" 4
    ;;
  file://*|/*) : ;;
  *) rice_die "unsupported --from URL (expected https://github.com/... or file://...): $FROM_URL" 2 ;;
esac

rice_info "cloning backup: $FROM_URL"
if ! rice_git clone -q "$FROM_URL" "$WORK/repo"; then
  rice_die "clone failed (check the URL and your access)" 3
fi
cd "$WORK/repo" || rice_die "clone directory missing" 1

# ---------------------------------------------------------------- integrity
if [ "$SKIP_VERIFY" -eq 0 ] && [ -f manifest.sha256 ]; then
  rice_info "verifying manifest checksums..."
  if sha256sum -c manifest.sha256 --quiet >/dev/null 2>&1; then
    rice_info "manifest verified: all checksums match"
  else
    rice_die "manifest verification FAILED (repository content changed or is corrupt); use --skip-verify to override" 1
  fi
elif [ "$SKIP_VERIFY" -eq 1 ]; then
  rice_warn "manifest verification skipped by request"
fi

BACKUP_FAMILY="unknown"
[ -f meta/distro-family.txt ] && BACKUP_FAMILY=$(head -1 meta/distro-family.txt)
TARGET_FAMILY=$(rice_detect_distro)
BACKUP_DISTRO_DESC=$(head -1 meta/distro.txt 2>/dev/null || echo unknown)

# original file modes from the manifest: git preserves only the executable
# bit, so exact modes (e.g. 0600) are re-applied from manifest.tsv on restore.
# Parsed with awk -F'\t' on purpose: manifest lines have an EMPTY target
# column for regular files, and an IFS=$'\t' read would collapse the
# consecutive tabs and shift every following field.
declare -A MODE_BY_REL=()
if [ -f manifest.tsv ]; then
  while IFS=$'\t' read -r _rel _mode; do
    MODE_BY_REL["${_rel#home/}"]=$_mode
  done < <(awk -F'\t' '$6 ~ /^home\// {print $6 "\t" $3}' manifest.tsv)
fi

# ------------------------------------------------------------- sections
# rice_section_files SECTION → prints repo-relative files for that section
rice_section_files() {
  local s=$1
  case "$s" in
    dotfiles)
      find home -maxdepth 1 -mindepth 1 \( -type f -o -type l \) -print0 2>/dev/null
      ;;
    config)
      find home/.config -type f -print0 2>/dev/null \
        | grep -zv '^home/\.config/systemd/user/' || true
      find home/.config -type l -print0 2>/dev/null \
        | grep -zv '^home/\.config/systemd/user/' || true
      ;;
    systemd-user)   find home/.config/systemd/user -print0 2>/dev/null || true ;;
    local-bin)      find home/.local/bin -print0 2>/dev/null || true ;;
    applications)   find home/.local/share/applications -print0 2>/dev/null || true ;;
    fonts)
      find home/.local/share/fonts home/.fonts -print0 2>/dev/null || true ;;
    icons-themes)
      find home/.local/share/icons home/.local/share/themes home/.icons home/.themes \
        -print0 2>/dev/null || true ;;
    gnome-extensions)
      find home/.local/share/gnome-shell/extensions -print0 2>/dev/null || true ;;
    kde)
      find home/.local/share/konsole home/.local/share/color-schemes \
        home/.local/share/plasma home/.local/share/wallpapers \
        home/.local/share/look-and-feel home/.local/share/aurorae \
        -print0 2>/dev/null || true ;;
    gnome-dconf)    [ -f desktop/gnome-dconf.dump ] && printf '%s\0' desktop/gnome-dconf.dump ;;
    crontab)        [ -f desktop/crontab.txt ] && printf '%s\0' desktop/crontab.txt ;;
    packages)      { [ -d packages ] && find packages -type f -print0; } 2>/dev/null || true ;;
    system)         { [ -d system/etc ] && find system/etc -type f -print0; } 2>/dev/null || true ;;
    *) return 0 ;;
  esac
}

ALL_KNOWN="dotfiles config systemd-user local-bin applications fonts icons-themes gnome-extensions kde gnome-dconf crontab packages system"

available_sections() {
  local s out=""
  for s in $ALL_KNOWN; do
    if [ -n "$(rice_section_files "$s" | head -c 1)" ]; then
      out="$out $s"
    fi
  done
  printf '%s' "${out# }"
}

if [ "$LIST_ONLY" -eq 1 ]; then
  printf 'sections available in this backup:%s\n' "$(available_sections | sed 's/ /\\n  /g')"
  printf 'backup distro: %s (%s); this machine: %s\n' "$BACKUP_DISTRO_DESC" "$BACKUP_FAMILY" "$TARGET_FAMILY"
  exit 0
fi

AVAIL=$(available_sections)
if [ "$ALL_SECTIONS" -eq 1 ]; then
  # shellcheck disable=SC2206
  SECTIONS=($AVAIL)
fi
if [ ${#SECTIONS[@]} -eq 0 ]; then
  # shellcheck disable=SC2206
  SECTIONS=($AVAIL)
  rice_info "no --section given; planning all available sections (dry-run default)"
fi

# validate requested sections
for s in "${SECTIONS[@]}"; do
  case " $ALL_KNOWN " in
    *" $s "*) ;;
    *) rice_die "unknown section: $s (known:$ALL_KNOWN)" 2 ;;
  esac
done

TS=$(date +'%Y%m%d-%H%M%S')
BACKUP_DIR="$TARGET_HOME/.rice-restore-backup-$TS"
GENERATED_DIR="$TARGET_HOME/.rice-restore-generated"

# --------------------------------------------------------------- planning
PLAN_TOTAL=0
plan_files() { # $1 section → count + preview
  local s=$1 f n=0 preview=""
  while IFS= read -r -d '' f; do
    n=$((n + 1))
    [ $n -le 5 ] && preview="$preview\n    $f"
  done < <(rice_section_files "$s")
  PLAN_TOTAL=$((PLAN_TOTAL + n))
  printf '  %-16s %s file(s)%b\n' "$s" "$n" "$preview"
}

printf '\n=== rice-restore %s plan ===\n' "$MODE"
printf 'backup repo : %s\n' "$FROM_URL"
printf 'backup from : %s (%s family)\n' "$BACKUP_DISTRO_DESC" "$BACKUP_FAMILY"
printf 'target home : %s\n' "$TARGET_HOME"
printf 'this machine: %s family\n' "$TARGET_FAMILY"
printf '\nplanned sections:\n'
for s in "${SECTIONS[@]}"; do
  plan_files "$s"
done
[ -f meta/systemd-user-enabled.txt ] \
  && printf '  systemd-user     enabled units list: meta/systemd-user-enabled.txt\n'

# relink preview (D37): what --relink would recreate from symlinks.tsv
if [ "$RELINK" -eq 1 ] && [ -f symlinks.tsv ]; then
  RELINK_N=$(grep -vc '^#' symlinks.tsv || true)
  printf '\nrelink: %s followed link(s) recorded in symlinks.tsv; with --apply\n' "$RELINK_N"
  printf 'their content moves to the recorded target locations and the links are\n'
  printf 'recreated (only targets inside this home; others are listed):\n'
  awk -F'\t' '$1 !~ /^#/ {print "  " $1 " -> " $2}' symlinks.tsv | head -15
  [ "${RELINK_N:-0}" -gt 15 ] && printf '  ... and %s more\n' "$((RELINK_N - 15))"
fi

# package reinstall preview (generated into the temp workdir, never the
# target home, so the dry run stays a pure no-op)
if [ "$MODE" = "dry-run" ]; then
  case " ${SECTIONS[*]} " in
    *" packages "*)
      rice_restore_packages "$WORK/preview-packages" >/dev/null 2>&1 || true
      if [ -f "$WORK/preview-packages/restore-packages.sh" ]; then
        printf '\npackage reinstall preview (%s -> %s):\n' "$BACKUP_FAMILY" "$TARGET_FAMILY"
        grep -v '^[[:space:]]*$' "$WORK/preview-packages/restore-packages.sh" | head -12
        printf '  (the full script is generated only on --apply; rice-restore never runs it)\n'
      fi
      if [ -f "$WORK/preview-packages/UNMAPPED.txt" ]; then
        UNMAPPED_N=$(grep -vE '^[[:space:]]*(#|\(none)' "$WORK/preview-packages/UNMAPPED.txt" | grep -c .)
        printf '  unmapped package names (LISTED, never guessed): %s\n' "$UNMAPPED_N"
      fi
      ;;
  esac
  printf '\ndry-run: nothing has been changed. Re-run with --apply (and optionally\n'
  printf 'a subset of --section ...) to perform the restore.\n'
  exit 0
fi

# ------------------------------------------------------------------ apply
rice_info "apply mode: existing files will be backed up to $BACKUP_DIR first"
mkdir -p "$BACKUP_DIR"

# move an existing target file out of the way (into the timestamped backup)
backup_existing() { # $1 target path (absolute)
  local t=$1
  if [ -e "$t" ] || [ -L "$t" ]; then
    local bt="$BACKUP_DIR/${t#"$TARGET_HOME"/}"
    mkdir -p -- "$(dirname -- "$bt")"
    cp -a -- "$t" "$bt" 2>/dev/null || return 0
    rm -rf -- "$t"
  fi
}

restore_file() { # $1 repo-relative path
  local f=$1 rel target
  rel=${f#home/}
  [ "$rel" = "$f" ] && return 0          # only home/ files go to TARGET_HOME
  target="$TARGET_HOME/$rel"
  backup_existing "$target"
  mkdir -p -- "$(dirname -- "$target")"
  cp -a -- "$f" "$target"
  # re-apply the exact recorded mode (cp -a alone cannot restore non-exec
  # modes because git tracks only the executable bit)
  if [ ! -L "$f" ] && [ -n "${MODE_BY_REL[$rel]:-}" ]; then
    chmod "${MODE_BY_REL[$rel]}" "$target" 2>/dev/null || true
  fi
}

for s in "${SECTIONS[@]}"; do
  rice_info "restoring section: $s"
  case "$s" in
    gnome-dconf)
      if [ "$TARGET_HOME" = "$HOME" ]; then
        if rice_have dconf; then
          dconf dump / > "$BACKUP_DIR/dconf-before.dump" 2>/dev/null || true
          dconf load / < desktop/gnome-dconf.dump \
            && rice_info "dconf settings loaded (previous state in the backup dir)"
        else
          rice_warn "dconf not installed; settings dump skipped (file: desktop/gnome-dconf.dump)"
        fi
      else
        rice_warn "gnome-dconf skipped in --home test mode (would affect the real user session)"
      fi
      ;;
    crontab)
      if [ "$TARGET_HOME" = "$HOME" ]; then
        if rice_have crontab; then
          crontab -l > "$BACKUP_DIR/crontab-before.txt" 2>/dev/null || true
          if grep -qv '^#' desktop/crontab.txt; then
            crontab desktop/crontab.txt && rice_info "crontab installed (previous one saved)"
          else
            rice_info "backup has no crontab entries; leaving the current crontab untouched"
          fi
        else
          rice_warn "crontab not available; skipped"
        fi
      else
        rice_warn "crontab skipped in --home test mode"
      fi
      ;;
    packages)
      rice_restore_packages
      ;;
    system)
      rice_restore_system
      ;;
    *)
      local_count=0
      while IFS= read -r -d '' f; do
        restore_file "$f"
        local_count=$((local_count + 1))
      done < <(rice_section_files "$s")
      printf '[rice-backup] section %s: %s file(s) restored\n' "$s" "$local_count"
      ;;
  esac
done

# suggest re-enabling systemd user units
if [ -f meta/systemd-user-enabled.txt ]; then
  printf '\nTo re-enable the systemd user units that were enabled on the backup machine:\n'
  printf '  systemctl --user daemon-reload\n'
  while IFS= read -r u; do
    case "$u" in
      '#'*) continue ;;
      '') continue ;;
      *) printf '  systemctl --user enable --now %q\n' "$u" ;;
    esac
  done < meta/systemd-user-enabled.txt | head -20
fi

printf '\nrestore complete.\n'
printf '  pre-existing files saved under: %s\n' "$BACKUP_DIR"
[ -d "$GENERATED_DIR" ] && printf '  generated review scripts in: %s\n' "$GENERATED_DIR"

# relink last (D37): only after the home content is in place
if [ "$RELINK" -eq 1 ]; then
  rice_restore_relink
fi
exit 0

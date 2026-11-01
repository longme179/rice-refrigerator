#!/usr/bin/env bash
# bin/rice-backup.sh - back up your rice (configs + package inventories) to a
# GitHub repository of your choice, without ever leaking credentials.
#
# Usage:
#   rice-backup.sh [--dry-run] [--yes] [--include-system] [--repo OWNER/NAME]
#                  [--home DIR] [--keep-stage] [--allow-oversize]
#                  [--exclude-from FILE] [--export FILE.tar.gz] [--list-files]
#                  [--explain [PATH...]] [--show-rules]
#   rice-backup.sh restore [rice-restore options...]   (passes through)
#   rice-backup.sh --help
#
# Flow (rule R1): authenticate -> resolve the target repo -> collect +
# content-scan a candidate set (read-only on the originals) -> show a dry-run
# summary with exclusions (names only) -> ask for confirmation -> stage into a
# 0700 temp dir -> manifest -> S4 secret scans (explicit + pre-push hook) ->
# push (plain https remote, never force).
#
# Security guarantees (details in README.md):
#   - the token lives in memory (env of this process) or a 0600 temp file that
#     the exit trap removes; never in the repo, remote URL, argv or logs
#   - hard deny list + content scan exclude credentials from the backup
#   - files over 50 MB and caches are skipped and listed in SKIPPED.md

set -u

RICE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# passthrough: single entrypoint can also restore (DECISIONS D2)
if [ "${1:-}" = "restore" ]; then
  shift
  exec bash "$RICE_ROOT/bin/rice-restore.sh" "$@"
fi

# shellcheck source=../lib/common.sh
. "$RICE_ROOT/lib/common.sh"
# shellcheck source=../lib/collect.sh
. "$RICE_ROOT/lib/collect.sh"
# shellcheck source=../lib/packages.sh
. "$RICE_ROOT/lib/packages.sh"
# shellcheck source=../lib/gitops.sh
. "$RICE_ROOT/lib/gitops.sh"

DRYRUN=0
ASSUME_YES=0
INCLUDE_SYSTEM=0
KEEP_STAGE=0
ALLOW_OVERSIZE=0
EXCLUDE_FROM=""
EXPORT_PATH=""
LIST_FILES=0
EXPLAIN=0                   # D42 R1: offline diagnostics for given paths
SHOW_RULES=0                # D42 R1: offline dump of the effective rule set
EXPLAIN_PATHS=()
RICE_RULES_ARG=""           # D38 R2: --rules FILE
RICE_NO_RULES=0             # D38 R2: --no-rules
RICE_FLAG_FILE_CAP=""       # D42 R2: --file-cap (parsed bytes)
RICE_FLAG_BUDGET=""         # D42 R2: --budget (parsed bytes)
RICE_FOLLOW=1                 # D37: follow symlinks (0 with --no-follow-symlinks)
RICE_FOLLOW_OUTSIDE=0         # D37: also follow targets outside home
RICE_HOME="${HOME}"
REPO_ARG="${RICE_REPO:-}"

usage() {
  printf 'rice-backup %s - back up your desktop rice to GitHub\n\n' "$RICE_VERSION"
  cat <<'USAGE'
usage: rice-backup.sh [options]
  --dry-run           show the summary and exclusions, change nothing (no push)
  --yes               skip the y/N confirmation (the public-repo typed check
                      is NEVER bypassed by this flag)
  --include-system    also collect a small, scanned /etc allowlist
  --repo OWNER/NAME   target repository (prompted otherwise; RICE_REPO env works)
  --home DIR          home directory to back up (default: $HOME)
  --keep-stage        keep the temporary staging dir for debugging
  --allow-oversize    permit a run whose total exceeds the 1 GiB budget
                      (RICE_TOTAL_MAX_BYTES overrides the budget value)
  --exclude-from FILE skip the paths listed in FILE (home-relative; a directory
                      entry skips its whole subtree; # comments allowed).
                      Purely subtractive: it can never override the deny list
                      or the content scan, only remove candidates.
  --export FILE.tar.gz  write an offline archive instead of pushing: no GitHub,
                      no PAT needed. The extracted directory is a git repo -
                      restore with rice-restore.sh --from file://<extracted-dir>
                      (export replaces the push; run twice for both)
  --list-files        print the post-exclusion candidate list (one
                      "path<TAB>bytes" line per file) and exit: offline,
                      read-only, no auth. Machine-readable view the GUI builds
                      its tick/skip checklist from
  --no-follow-symlinks  store symlinks as links only (pre-0.3.0 behavior);
                      by default links whose target is NOT already inside the
                      backup are followed: the target's content is fetched
                      into the repo and the original link is recorded in
                      symlinks.tsv (restore it later with rice-restore --relink)
  --follow-outside-home  also follow symlink targets that live outside $HOME
                      (default: those links are kept as links and reported)
  --explain [PATH...] offline diagnostics (D42): run the full read-only
                      collection, then print the verdict chain
                      (verdict/layer/rule) for each PATH - home-relative or
                      absolute under the home; with no PATH, dump every bucket
                      with reasons. No auth, no repo, nothing staged; exit 0
  --show-rules         offline (D42): print the effective rule set - include
                      roots (with per-entry source), deny dirs/globs, cache
                      patterns, size caps, symlink settings. No walk, no auth
  --rules FILE         load the customization rules from FILE instead of
                      ~/.config/rice-backup/rules.conf; --no-rules skips them
                      entirely. Sections: [include-file] [include-dir]
                      [skip-dir] [size] (see RULES-PLAN.md; [allow]/[ack-scan]
                      land in the next milestones)
  --include-file F    extra top-level home file to consider (repeatable)
  --include-dir D     extra home-relative root to walk (repeatable; a
                      deny-listed root is refused with its rule)
  --skip-dir D        drop a DEFAULT include root from the walk (repeatable)
  --allow PATH        re-include a SOFT-deny match (file or subtree; repeat-
                      able; rules.conf [allow] equivalent). The hard core
                      (ssh, browser profiles, messengers, wallets, key
                      material...) is NEVER overridable - attempts are refused
                      with the rule named
  --file-cap SIZE     per-file cap (default 50 MiB; hard max 100 MiB per
                      GitHub). SIZE: plain bytes or N/NK/NM/NG
  --budget SIZE       total budget (default 1 GiB). Precedence: env
                      RICE_TOTAL_MAX_BYTES > this flag > rules.conf > default
  restore ...         run the matching restore tool
  -h, --help          this help

environment:
  RICE_TOKEN          PAT for PAT-mode auth (otherwise a hidden prompt; gh is
                      preferred when installed)
  RICE_TEST_GIT_BASE  INTERNAL: file:// base used by the test suite only
USAGE
  printf 'version %s\n' "$RICE_VERSION"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRYRUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --include-system) INCLUDE_SYSTEM=1; shift ;;
    --repo) [ $# -ge 2 ] || usage 2; REPO_ARG=$2; shift 2 ;;
    --home) [ $# -ge 2 ] || usage 2; RICE_HOME=$2; shift 2 ;;
    --keep-stage) KEEP_STAGE=1; shift ;;
    --allow-oversize) ALLOW_OVERSIZE=1; shift ;;
    --exclude-from) [ $# -ge 2 ] || usage 2; EXCLUDE_FROM=$2; shift 2 ;;
    --export) [ $# -ge 2 ] || usage 2; EXPORT_PATH=$2; shift 2 ;;
    --list-files) LIST_FILES=1; shift ;;
    --no-follow-symlinks) RICE_FOLLOW=0; shift ;;
    --follow-outside-home) RICE_FOLLOW_OUTSIDE=1; shift ;;
    --explain) EXPLAIN=1; shift ;;
    --show-rules) SHOW_RULES=1; shift ;;
    --rules) [ $# -ge 2 ] || usage 2; RICE_RULES_ARG=$2; shift 2 ;;
    --no-rules) RICE_NO_RULES=1; shift ;;
    --include-file) [ $# -ge 2 ] || usage 2; rice_rules_add_file "$2"; shift 2 ;;
    --include-dir)  [ $# -ge 2 ] || usage 2; rice_rules_add_dir "$2"; shift 2 ;;
    --skip-dir)     [ $# -ge 2 ] || usage 2; rice_rules_add_skip "$2"; shift 2 ;;
    --allow)         [ $# -ge 2 ] || usage 2; rice_rules_add_allow "$2"; shift 2 ;;
    --file-cap) [ $# -ge 2 ] || usage 2
      RICE_FLAG_FILE_CAP=$(rice_rules_parse_size "$2") \
        || rice_die "--file-cap: invalid size: $2 (plain bytes or N/NK/NM/NG)" 2
      shift 2 ;;
    --budget) [ $# -ge 2 ] || usage 2
      RICE_FLAG_BUDGET=$(rice_rules_parse_size "$2") \
        || rice_die "--budget: invalid size: $2 (plain bytes or N/NK/NM/NG)" 2
      shift 2 ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    *)
      if [ "$EXPLAIN" -eq 1 ]; then
        EXPLAIN_PATHS+=("$1"); shift
      else
        printf 'unknown option: %s\n' "$1" >&2; usage 2
      fi
      ;;
  esac
done
# positional paths after `--` also feed --explain
if [ "$EXPLAIN" -eq 1 ] && [ $# -gt 0 ]; then
  EXPLAIN_PATHS+=("$@")
  shift $#
fi

rice_require_core
[ -d "$RICE_HOME" ] || rice_die "home directory not found: $RICE_HOME"

# ---- user rules (D38/D39/D42, R2): load + apply BEFORE --show-rules, the
# walk and --explain so every one of them reflects the merged rule set.
rice_rules_load "$RICE_RULES_ARG" "$RICE_NO_RULES"
rice_rules_apply "$RICE_HOME"

# --show-rules (D42): offline dump of the effective rule set. No walk, no auth,
# no repo; print and exit.
if [ "$SHOW_RULES" -eq 1 ]; then
  rice_show_rules
  exit 0
fi

# offline modes need no GitHub access: --export (D33), --list-files (D32 GUI),
# --explain / --show-rules (D42 diagnostics)
if [ -n "$EXPORT_PATH" ] || [ "$LIST_FILES" -eq 1 ] \
   || [ "$EXPLAIN" -eq 1 ] || [ "$SHOW_RULES" -eq 1 ]; then
  OFFLINE_MODE=1
else
  OFFLINE_MODE=0
fi

RICE_DISTRO=$(rice_detect_distro)
RICE_DE=$(rice_detect_de)
SCANNER="$RICE_ROOT/scripts/secret-scan.sh"
[ -x "$SCANNER" ] || rice_die "scanner not found: $SCANNER"

RICE_STAGE=""
cleanup() {
  rice_gitops_cleanup
  if [ -n "$RICE_STAGE" ] && [ "$KEEP_STAGE" -eq 0 ]; then
    rm -rf -- "$RICE_STAGE" 2>/dev/null
  elif [ -n "$RICE_STAGE" ]; then
    rice_info "staging dir kept: $RICE_STAGE"
  fi
  return 0
}
trap cleanup EXIT

# ------------------------------------------------------------------- auth
# Offline modes (D33/D32): no GitHub access, so no auth and no repo needed.
INTERACTIVE=0
rice_is_tty && INTERACTIVE=1
if [ "$OFFLINE_MODE" -eq 0 ]; then
  rice_auth_init "$INTERACTIVE" || rice_die "authentication failed (rule R3)" 4
  rice_auth_setup_git || rice_die "could not prepare git authentication" 4
  rice_info "auth mode: $RICE_AUTH_MODE (token never stored, never in any URL)"
fi

# ------------------------------------------------------------ target repo
REPO_OWNER=""
REPO_NAME=""
if [ "$OFFLINE_MODE" -eq 0 ]; then
  if [ -z "$REPO_ARG" ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
      printf 'Target GitHub repo (OWNER/NAME): ' >&2
      IFS= read -r REPO_ARG || REPO_ARG=""
    else
      rice_die "no --repo given and stdin is not a terminal (set RICE_REPO or pass --repo)" 1
    fi
  fi
  REPO_PARSED=$(rice_parse_repo "${REPO_ARG:-}") || rice_die "invalid repository name: ${REPO_ARG:-} (expected OWNER/NAME)"
  read -r REPO_OWNER REPO_NAME <<<"$REPO_PARSED"

  rice_repo_ensure "$REPO_OWNER" "$REPO_NAME" || rice_die "could not ensure a private target repo (see messages above)" 1

  if [ "$RICE_REPO_PRIVATE" = "no" ]; then
    rice_warn "repository $REPO_OWNER/$REPO_NAME exists and is PUBLIC."
    rice_warn "Everything backed up (file names, config contents) would be world-readable."
    rice_warn "This confirmation cannot be bypassed with --yes."
    rice_confirm_typed "To push anyway, confirm the repository" "$REPO_OWNER/$REPO_NAME" \
      || rice_die "aborted: public repository not confirmed" 1
  elif [ "$RICE_REPO_PRIVATE" = "unknown" ]; then
    rice_warn "could not determine whether $REPO_OWNER/$REPO_NAME is private."
    if [ "$DRYRUN" -eq 0 ]; then
      rice_confirm_typed "To push anyway, confirm the repository" "$REPO_OWNER/$REPO_NAME" \
        || rice_die "aborted: repository privacy could not be verified" 1
    fi
  fi
fi

# --------------------------------------------------------------- collection
rice_collect_init
rice_info "collecting candidates from $RICE_HOME (originals are read-only)..."
rice_collect_home "$RICE_HOME"
# ---- [allow] overrides (D40/R3): rescue soft-denied entries BEFORE the
# content scan so the scanner still guards every re-included file
rice_apply_allow_overrides "$RICE_HOME"
if [ "$INCLUDE_SYSTEM" -eq 1 ]; then
  rice_collect_etc
  rice_info "content-scanning ${#RICE_ETC_INCLUDE[@]} /etc allowlist file(s) with the S4 rules..."
  rice_scan_etc_candidates "$SCANNER"
  rice_info "system section: ${#RICE_ETC_INCLUDE[@]} /etc file(s) allowlisted"
fi
rice_info "content-scanning ${#RICE_INCLUDE[@]} candidate file(s) with the S4 rules..."
rice_scan_candidates "$RICE_HOME" "$SCANNER"

# ---- user selection (D32): purely SUBTRACTIVE, applied AFTER the deny list
# and the content scan so ticking something off can never bypass either layer
rice_apply_user_excludes "$RICE_HOME" "$EXCLUDE_FROM"

# ---- --explain (D42): offline verdict chain for the given paths (or a full
# bucket dump). Runs after collection, scan AND selection so every bucket is
# final; read-only, then exit.
if [ "$EXPLAIN" -eq 1 ]; then
  rice_explain "$RICE_HOME" ${EXPLAIN_PATHS[@]+"${EXPLAIN_PATHS[@]}"}
  rice_info "explain complete: read-only, nothing was staged or pushed."
  exit 0
fi

# ---- machine-readable candidate list for the GUI (D32 companion): one
# "rel<TAB>bytes" line per surviving candidate, offline and read-only. Info
# lines from rice_info also land on stdout; consumers skip non-matching lines.
if [ "$LIST_FILES" -eq 1 ]; then
  if [ ${#RICE_META_INC[@]} -gt 0 ]; then
    printf '%s\n' "${RICE_META_INC[@]}" | cut -f1,2
  fi
  exit 0
fi

# ----------------------------------------------------------- dry-run summary
SUMMARY_SECTIONS=0
section_count() { # $1 prefix pattern
  local n=0 p
  for p in "${RICE_INCLUDE[@]}"; do
    # shellcheck disable=SC2254
    case "$p" in
      $1*) n=$((n + 1)) ;;
    esac
  done
  printf '%s' "$n"
}

# top-level dotfiles: paths without a directory separator
topfile_count() {
  local n=0 p
  for p in "${RICE_INCLUDE[@]}"; do
    case "$p" in
      */*) ;;
      *) n=$((n + 1)) ;;
    esac
  done
  printf '%s' "$n"
}

# bytes of one section (field 2 of RICE_META_INC entries), pure parameter
# expansion so 3000+ candidates stay fast
section_bytes() { # $1 prefix pattern
  local t=0 p m b
  for m in "${RICE_META_INC[@]}"; do
    p=${m%%$'\t'*}
    # shellcheck disable=SC2254
    case "$p" in
      $1*) b=${m#*$'\t'}; b=${b%%$'\t'*}; t=$((t + ${b:-0})) ;;
    esac
  done
  printf '%s' "$t"
}

topfile_bytes() {
  local t=0 p m b
  for m in "${RICE_META_INC[@]}"; do
    p=${m%%$'\t'*}
    case "$p" in
      */*) ;;
      *) b=${m#*$'\t'}; b=${b%%$'\t'*}; t=$((t + ${b:-0})) ;;
    esac
  done
  printf '%s' "$t"
}

printf '\n=== rice-backup dry-run summary ===\n'
printf 'home       : %s\n' "$RICE_HOME"
printf 'distro     : %s (%s desktop) host=%s\n' "$(rice_distro_version)" "$RICE_DE" "$(hostname 2>/dev/null || echo unknown)"
if [ -n "$EXPORT_PATH" ]; then
  printf 'target     : offline archive %s (no GitHub access)\n' "$EXPORT_PATH"
  printf 'auth       : none (offline export)\n'
else
  printf 'target     : %s (private: %s) branch main\n' "$(rice_remote_url "$REPO_OWNER" "$REPO_NAME")" "${RICE_REPO_PRIVATE:-unknown}"
  printf 'auth       : %s\n' "${RICE_AUTH_MODE:-unknown}"
fi

printf '\nwould upload (read-only pass done, nothing staged yet):\n'
printf '  dotfiles              : %s file(s), %s\n' "$(topfile_count)" "$(rice_hr_size "$(topfile_bytes)")"
printf '  .config/**            : %s file(s), %s\n' "$(section_count '.config/*')" "$(rice_hr_size "$(section_bytes '.config/*')")"
printf '  .local/**             : %s file(s), %s\n' "$(section_count '.local/*')" "$(rice_hr_size "$(section_bytes '.local/*')")"
printf '  fonts/icons/themes    : %s file(s), %s\n' \
  "$(( $(section_count '.fonts/*') + $(section_count '.icons/*') + $(section_count '.themes/*') ))" \
  "$(rice_hr_size "$(( $(section_bytes '.fonts/*') + $(section_bytes '.icons/*') + $(section_bytes '.themes/*') ))")"
printf '  /etc allowlist        : %s file(s)%s\n' "${#RICE_ETC_INCLUDE[@]}" \
  "$([ "$INCLUDE_SYSTEM" -eq 1 ] || printf ' (not requested: use --include-system)')"
printf '  package inventories   : %s\n' "$(rice_packages_plan_summary)"
printf '  desktop settings      : dconf dump (%s), crontab (%s)\n' \
  "$(rice_have dconf && printf 'available' || printf 'unavailable')" \
  "$(rice_have crontab && printf 'available' || printf 'unavailable')"
printf '  TOTAL                 : %s file(s), %s\n' "${#RICE_INCLUDE[@]}" "$(rice_hr_size "$RICE_TOTAL_BYTES")"
if [ ${#RICE_LINKS[@]} -gt 0 ] || [ ${#RICE_LINK_STATUS[@]} -gt 0 ]; then
  LINK_N=0 LINK_FILES=0 LINK_BYTES=0
  for LREC in "${RICE_LINKS[@]}"; do
    LINK_N=$((LINK_N + 1))
    LB=$(printf '%s' "$LREC" | cut -f5); LINK_FILES=$((LINK_FILES + ${LB:-0}))
    LB=$(printf '%s' "$LREC" | cut -f6); LINK_BYTES=$((LINK_BYTES + ${LB:-0}))
  done
  printf '  symlinks followed    : %s link(s) -> %s file(s), %s fetched; %s kept as link(s)\n' \
    "$LINK_N" "$LINK_FILES" "$(rice_hr_size "$LINK_BYTES")" "${#RICE_LINK_STATUS[@]}"
fi
SHOWN=0
for p in "${RICE_INCLUDE[@]}"; do
  if [ "$SHOWN" -lt 40 ]; then printf '    %s\n' "$p"; fi
  SHOWN=$((SHOWN + 1))
done
[ "$SHOWN" -gt 40 ] && printf '    ... and %s more\n' "$((SHOWN - 40))"
if [ ${#RICE_META_INC[@]} -gt 0 ]; then
  printf '\nlargest candidates (top 15 by size):\n'
  printf '%s\n' "${RICE_META_INC[@]}" | sort -t$'\t' -k2,2 -rn | head -15 | cut -f1,2 \
    | while IFS=$'\t' read -r p b; do
        printf '    %9s  %s\n' "$(rice_hr_size "$b")" "$p"
      done
fi
if [ "$RICE_TOTAL_BYTES" -gt "$RICE_TOTAL_WARN_BYTES" ]; then
  printf '[rice-backup] WARNING: total exceeds %s; GitHub may throttle or reject large pushes\n' \
    "$(rice_hr_size "$RICE_TOTAL_WARN_BYTES")" >&2
fi

printf '\nexcluded (names only):\n'
printf '  hard deny list : %s item(s)\n' "${#RICE_DENIED[@]}"
for i in "${RICE_DENIED[@]}"; do printf '    - %s [%s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
printf '  scan hits       : %s item(s)\n' "${#RICE_SCANHITS[@]}"
for i in "${RICE_SCANHITS[@]}"; do printf '    - %s [%s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
printf '  user excluded   : %s item(s)\n' "${#RICE_USER_EXCL[@]}"
for i in "${RICE_USER_EXCL[@]}"; do printf '    - %s [%s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
if [ ${#RICE_ALLOWED[@]} -gt 0 ]; then
  printf '  deny overridden : %s item(s)\n' "${#RICE_ALLOWED[@]}"
  for i in "${RICE_ALLOWED[@]}"; do printf '    - %s [%s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
fi
printf '  oversized (>%s): %s item(s)\n' "$(rice_hr_size "$RICE_MAX_FILE_BYTES")" "${#RICE_SKIPPED_BIG[@]}"
for i in "${RICE_SKIPPED_BIG[@]}"; do printf '    - %s (%s)\n' "${i%%$'\t'*}" "$(rice_hr_size "${i#*$'\t'}")"; done
printf '  caches/junk     : %s item(s)\n' "${#RICE_SKIPPED_CACHE[@]}"
for i in "${RICE_SKIPPED_CACHE[@]}"; do printf '    - %s\n' "$i"; done
printf '\n'

# ---- size budget (default 1 GiB, RICE_TOTAL_MAX_BYTES overrides) ----
if [ "$RICE_TOTAL_BYTES" -gt "$RICE_TOTAL_MAX_BYTES" ]; then
  if [ "$DRYRUN" -eq 1 ]; then
    printf '[rice-backup] WARNING: total %s exceeds the %s budget; a real run needs --allow-oversize\n' \
      "$(rice_hr_size "$RICE_TOTAL_BYTES")" "$(rice_hr_size "$RICE_TOTAL_MAX_BYTES")" >&2
  elif [ "$ALLOW_OVERSIZE" -ne 1 ]; then
    rice_die "total $(rice_hr_size "$RICE_TOTAL_BYTES") exceeds the $(rice_hr_size "$RICE_TOTAL_MAX_BYTES") budget - refusing to push. Run --dry-run to see the largest candidates, trim bulk data, or re-run with --allow-oversize" 5
  else
    rice_warn "size budget exceeded but --allow-oversize was given (total $(rice_hr_size "$RICE_TOTAL_BYTES"))"
  fi
fi

if [ "$DRYRUN" -eq 1 ]; then
  rice_info "dry-run complete: nothing was staged, committed or pushed."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  if [ -n "$EXPORT_PATH" ]; then
    rice_confirm "Proceed with staging and exporting these ${#RICE_INCLUDE[@]} file(s) to $EXPORT_PATH?" \
      || rice_die "aborted by user" 1
  else
    rice_confirm "Proceed with staging and pushing these ${#RICE_INCLUDE[@]} file(s)?" \
      || rice_die "aborted by user" 1
  fi
fi

# ------------------------------------------------------------------ staging
RICE_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/rice-backup.XXXXXX") || rice_die "mktemp failed" 1
chmod 700 "$RICE_STAGE"
rice_info "staging into $RICE_STAGE (0700, removed on exit)"

DIFF_BASE=$(rice_stage_prepare "$RICE_STAGE" "$REPO_OWNER" "$REPO_NAME") \
  || rice_die "stage preparation failed (remote unreachable? see messages)" 3
[ -n "$DIFF_BASE" ] && rice_info "remote has an existing backup; new commit will descend from it"

rice_stage_copy "$RICE_HOME" "$RICE_STAGE"
if [ "$INCLUDE_SYSTEM" -eq 1 ]; then
  rice_stage_copy_etc "$RICE_STAGE"
fi

# package inventories
RICE_PKG_HOME=$RICE_HOME
rice_packages_collect "$RICE_STAGE/packages"

# desktop settings
mkdir -p "$RICE_STAGE/desktop"
if rice_have dconf; then
  dconf dump / > "$RICE_STAGE/desktop/gnome-dconf.dump" 2>/dev/null \
    || echo "# dconf dump failed" > "$RICE_STAGE/desktop/gnome-dconf.dump"
else
  echo "# dconf not available on this machine (settings dump skipped)" \
    > "$RICE_STAGE/desktop/gnome-dconf.dump"
fi
if rice_have crontab; then
  crontab -l > "$RICE_STAGE/desktop/crontab.txt" 2>/dev/null \
    || echo "# no crontab for this user" > "$RICE_STAGE/desktop/crontab.txt"
else
  echo "# crontab command not available" > "$RICE_STAGE/desktop/crontab.txt"
fi

# meta
mkdir -p "$RICE_STAGE/meta"
rice_distro_version > "$RICE_STAGE/meta/distro.txt"
printf '%s\n' "$RICE_DE" > "$RICE_STAGE/meta/desktop.txt"
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$RICE_STAGE/meta/date.txt"
hostname 2>/dev/null > "$RICE_STAGE/meta/host.txt" || echo unknown > "$RICE_STAGE/meta/host.txt"
printf 'rice-backup %s\n' "$RICE_VERSION" > "$RICE_STAGE/meta/version.txt"
printf '%s\n' "$RICE_DISTRO" > "$RICE_STAGE/meta/distro-family.txt"
rice_packages_toolmatrix > "$RICE_STAGE/meta/tools.txt"
if rice_have systemctl; then
  systemctl --user list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' \
    > "$RICE_STAGE/meta/systemd-user-enabled.txt" \
    || echo "# systemctl --user unavailable (no user session?)" > "$RICE_STAGE/meta/systemd-user-enabled.txt"
  grep -q . "$RICE_STAGE/meta/systemd-user-enabled.txt" 2>/dev/null \
    || echo "# no enabled user units recorded" >> "$RICE_STAGE/meta/systemd-user-enabled.txt"
else
  echo "# systemctl not available" > "$RICE_STAGE/meta/systemd-user-enabled.txt"
fi
{
  printf 'files=%s bytes=%s denied=%s scanhits=%s big=%s caches=%s links_followed=%s links_kept=%s\n' \
    "${#RICE_INCLUDE[@]}" "$RICE_TOTAL_BYTES" "${#RICE_DENIED[@]}" \
    "${#RICE_SCANHITS[@]}" "${#RICE_SKIPPED_BIG[@]}" "${#RICE_SKIPPED_CACHE[@]}" \
    "${#RICE_LINKS[@]}" "${#RICE_LINK_STATUS[@]}"
} > "$RICE_STAGE/meta/counts.txt"

# reports + manifest + symlink records + restore note
mkdir -p "$RICE_STAGE/reports"
rice_write_reports "$RICE_STAGE"
rice_write_symlinks "$RICE_STAGE"
rice_make_manifest "$RICE_STAGE"
if [ -n "$EXPORT_PATH" ]; then
  cat > "$RICE_STAGE/RESTORE.md" <<'EOF'
# Restoring this backup (offline archive)

This backup was exported as a tar.gz archive instead of being pushed to
GitHub. No GitHub account, repository or token is involved.

1. Extract the archive anywhere - the result is itself a git repository:

       tar -xzf <archive>.tar.gz

2. Restore from the extracted repository with the matching restore tool from
   your rice-backup checkout:

    bin/rice-restore.sh --from file://<path-to-extracted-dir>

Restore is dry-run by default and applies section by section; read README.md
first. Package lists are never executed automatically: review the generated
script before running anything with sudo.
EOF
else
  cat > "$RICE_STAGE/RESTORE.md" <<'EOF'
# Restoring this backup

Run the matching restore tool from your rice-backup checkout:

    bin/rice-restore.sh --from <this repository URL>

Restore is dry-run by default and applies section by section; read README.md
first. Package lists are never executed automatically: review the generated
script before running anything with sudo.
EOF
fi

# ------------------------------------------------ commit, scan, push/export
if [ -n "$EXPORT_PATH" ]; then
  rice_info "committing, scanning (S4), writing the archive (no push)..."
else
  rice_info "committing, scanning (S4) and pushing..."
fi
COMMIT=$(rice_stage_finish "$RICE_STAGE" "$DIFF_BASE" "$SCANNER" "$RICE_ROOT" ${EXPORT_PATH:+export})
FINISH_RC=$?
COMMIT=$(printf '%s\n' "$COMMIT" | tail -n 1)
[ "$FINISH_RC" -eq 0 ] || rice_die "backup did not complete (see messages above; exit codes: 2=secret hit, 3=push or export failure)" "$FINISH_RC"

if [ -n "$EXPORT_PATH" ]; then
  # resolve a relative --export path against the ORIGINAL cwd (this script
  # never cd's at top level; every cd lives inside a subshell)
  case "$EXPORT_PATH" in
    /*) EXPORT_ABS=$EXPORT_PATH ;;
    *)  EXPORT_ABS="$PWD/$EXPORT_PATH" ;;
  esac
  rice_info "writing archive $EXPORT_ABS (contains .git, offline restorable)..."
  tar -czf "$EXPORT_ABS" -C "$RICE_STAGE" . || rice_die "archive write failed: $EXPORT_ABS" 3
  printf '[rice-backup] archive exported: commit %s -> %s\n' "$COMMIT" "$EXPORT_ABS"
  rice_info "restore offline: tar -xzf the archive, then bin/rice-restore.sh --from file://<extracted-dir>"
else
  printf '[rice-backup] backup pushed: commit %s -> %s\n' "$COMMIT" "$(rice_remote_url "$REPO_OWNER" "$REPO_NAME")"
fi
rice_info "done. Re-run any time: each run creates a new commit."
exit 0

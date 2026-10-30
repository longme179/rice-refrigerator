#!/usr/bin/env bash
# scripts/secret-scan.sh - content secret scanner for rice-backup (security rule S4).
#
# Modes:
#   secret-scan.sh [--expect FILE] tree    <dir>
#   secret-scan.sh [--expect FILE] files   <file>...
#   secret-scan.sh [--expect FILE] git     <rev>        (run inside a git repository)
#   secret-scan.sh [--expect FILE] history [<rev-range>|--all]
#
# Options:
#   --expect FILE  newline-separated path prefixes whose hits are EXPECTED test
#                  canaries (this repository's own fixtures). Reported as
#                  EXPECTED and do not fail the scan. Exact-value hits are
#                  NEVER expected and always fail.
#   --quiet        suppress the summary line on stderr.
#
# Environment:
#   RICE_SCAN_EXACT / RICE_TOKEN (env) - when set, that VALUE is searched for
#   exactly (e.g. the current PAT). The needle is piped to grep as a pattern
#   over stdin: it is never printed, never appears on a command line, and is
#   never written to disk.
#
# Output (stdout): HIT<TAB>rule<TAB>path  /  EXPECTED<TAB>rule<TAB>path
# Exit codes: 0 clean (or expected-only), 1 unexpected hits, 2 usage/IO error.
#
# Engine note: GNU grep (POSIX ERE) on purpose - Ubuntu's default awk (mawk)
# has incomplete ERE support, while grep behaves identically on
# Fedora/Arch/Ubuntu (decision D3).
#
# This file intentionally contains no secrets. Rule strings below are written
# so that they do not match themselves.

set -u
export LC_ALL=C

PROG=${0##*/}

# ---- rule table: name~case-insensitive~regex (fields split on '~') ----
RICE_RULES=(
  'gh-classic~0~ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|ghs_[A-Za-z0-9]{36}|ghr_[A-Za-z0-9]{36}'
  'gh-fine-grained~0~github_pat_[A-Za-z0-9_]{40,100}'
  'private-key~0~-----BEGIN[ A-Za-z0-9]*PRIVATE KEY'
  'aws-access-key~0~AKIA[0-9A-Z]{16}'
  'aws-secret-label~0~aws_secret_access_key[[:space:]]*[=:][[:space:]]*[A-Za-z0-9/+=]{30,}'
  'google-api-key~0~AIza[0-9A-Za-z_-]{35}'
  'slack-token~0~xox[abprs]-[A-Za-z0-9-]{10,}'
  'stripe-live-key~0~[sr]k_live_[0-9a-zA-Z]{20,}'
  'jwt~0~eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
  'bearer-token~1~Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}'
  'cred-assign~1~(password|passwd|passphrase|secret|token|api_?key|apikey|client_?secret|access_?token|auth)[[:space:]]*[=:][[:space:]]*["'\'']?[A-Za-z0-9._~+/!$%^&*()=-]{6,}'
  'url-embedded-creds~0~[a-z][a-z0-9+.-]*://[^/@[:space:]"'\''>]+:[^/@[:space:]"'\''>]+@'
)

# cred-assign values that are almost certainly placeholders, not secrets
RICE_CRED_WHITELIST='changeme|placeholder|example|required|optional|enabled|disabled|redacted|removed|unknown'

UNEXPECTED=0
EXPECTED=0
SCANNED=0
EXPECT_FILE=""

usage() {
  cat <<'USAGE'
usage: secret-scan.sh [--expect FILE] [--quiet] MODE [ARGS]
  MODE tree    <dir>            scan every regular file under dir (skips .git)
  MODE files   <file>...        scan the listed files
  MODE git     <rev>            scan the tree of a git revision (git grep)
  MODE history [<range>|--all]  scan every commit (default: --all)
env:  RICE_SCAN_EXACT / RICE_TOKEN  exact needle to search for (never printed)
exit: 0 clean or expected-only, 1 unexpected hits, 2 usage error
USAGE
  exit 2
}

# ---------------------------------------------------------------- reporting
report_hit() { # $1 rule  $2 path
  local rule=$1 path=$2 pfx found=0
  if [ -n "$EXPECT_FILE" ] && [ -f "$EXPECT_FILE" ] && [ "$rule" != "exact" ]; then
    while IFS= read -r pfx; do
      [ -n "$pfx" ] || continue
      case "$path" in
        "$pfx"*) found=1; break ;;
      esac
    done < "$EXPECT_FILE"
  fi
  if [ "$found" = 1 ]; then
    printf 'EXPECTED\t%s\t%s\n' "$rule" "$path"
    EXPECTED=$((EXPECTED + 1))
  else
    printf 'HIT\t%s\t%s\n' "$rule" "$path"
    UNEXPECTED=$((UNEXPECTED + 1))
  fi
}

# ------------------------------------------------------- cred-assign filter
# stdin: matched assignment strings; returns 0 if at least one value is NOT a
# placeholder. Values themselves are never printed.
nonwhitelisted_seen() {
  local m val
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    val=${m#*[:=]}
    val=${val#"${val%%[![:space:]]*}"}   # ltrim
    val=${val%"${val##*[![:space:]]*}"}  # rtrim
    val=${val//\"/}
    val=${val//\'/}
    case "$val" in
      "") ;;
      '$'*|'('*|'{'*|'<'*'`'*) ;;
      changeme|placeholder|example|required|optional|enabled|disabled|redacted|removed|unknown) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# ------------------------------------------------------------------ scanning
# scan_batch FILES...  - attribute hits per rule for the given files.
scan_batch() {
  local files=("$@")
  [ ${#files[@]} -gt 0 ] || return 0
  SCANNED=$((SCANNED + ${#files[@]}))

  local cs_args=() ci_args=()
  local r rule ci re
  for r in "${RICE_RULES[@]}"; do
    IFS='~' read -r rule ci re <<<"$r"
    if [ "$ci" = "1" ]; then
      ci_args+=(-e "$re")
    else
      cs_args+=(-e "$re")
    fi
  done

  # phase 1: which files have any hit at all (fast, combined patterns)
  local -A suspect_map=()
  local f
  if [ ${#cs_args[@]} -gt 0 ]; then
    while IFS= read -r -d '' f; do suspect_map["$f"]=1; done < <(
      grep -aIZlE "${cs_args[@]}" -- "${files[@]}" 2>/dev/null || true)
  fi
  if [ ${#ci_args[@]} -gt 0 ]; then
    while IFS= read -r -d '' f; do suspect_map["$f"]=1; done < <(
      grep -aIZlEi "${ci_args[@]}" -- "${files[@]}" 2>/dev/null || true)
  fi
  [ ${#suspect_map[@]} -gt 0 ] || return 0

  # phase 2: attribute each suspect file to rules (no matched text is printed)
  for f in "${!suspect_map[@]}"; do
    for r in "${RICE_RULES[@]}"; do
      IFS='~' read -r rule ci re <<<"$r"
      if [ "$rule" = "cred-assign" ]; then
        if grep -aoEi -e "$re" -- "$f" 2>/dev/null | nonwhitelisted_seen; then
          report_hit "$rule" "$f"
        fi
      elif [ "$ci" = "1" ]; then
        if grep -aoqEi -e "$re" -- "$f" 2>/dev/null; then
          report_hit "$rule" "$f"
        fi
      else
        if grep -aoqE -e "$re" -- "$f" 2>/dev/null; then
          report_hit "$rule" "$f"
        fi
      fi
    done
  done
}

# exact needle pass over FILES...
exact_batch() {
  local files=("$@")
  local needle=${RICE_SCAN_EXACT:-${RICE_TOKEN:-}}
  [ -n "$needle" ] || return 0
  [ ${#needle} -ge 8 ] || { printf '%s: exact needle too short, ignoring\n' "$PROG" >&2; return 0; }
  [ ${#files[@]} -gt 0 ] || return 0
  local f
  while IFS= read -r -d '' f; do
    report_hit "exact" "$f"
  done < <(printf '%s\n' "$needle" | grep -aIZlF -f - -- "${files[@]}" 2>/dev/null || true)
}

# git mode: scan the tree of revision $1 with git grep
scan_git_rev() {
  local rev=$1
  local r rule ci re f
  SCANNED=$(git ls-tree -r --name-only "$rev" 2>/dev/null | wc -l)
  # git grep prefixes paths with "REV:"; strip exactly that prefix so paths
  # stay repo-relative (needed for --expect matching and history dedup)
  for r in "${RICE_RULES[@]}"; do
    IFS='~' read -r rule ci re <<<"$r"
    if [ "$rule" = "cred-assign" ]; then
      # per-file check: git grep -o lines carry a "rev:path:" prefix that would
      # corrupt value parsing, so stream the blob through GNU grep instead
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        f=${f#"$rev":}
        if git show "$rev:$f" 2>/dev/null | grep -aoEi -e "$re" | nonwhitelisted_seen; then
          report_hit "$rule" "$f"
        fi
      done < <(git grep -aIlEi -e "$re" "$rev" -- 2>/dev/null || true)
    elif [ "$ci" = "1" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        report_hit "$rule" "${f#"$rev":}"
      done < <(git grep -aIlEi -e "$re" "$rev" -- 2>/dev/null || true)
    else
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        report_hit "$rule" "${f#"$rev":}"
      done < <(git grep -aIlE -e "$re" "$rev" -- 2>/dev/null || true)
    fi
  done
  # exact needle over the revision (pattern arrives via stdin, never argv)
  local needle=${RICE_SCAN_EXACT:-${RICE_TOKEN:-}}
  if [ -n "$needle" ] && [ ${#needle} -ge 8 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      report_hit "exact" "${f#"$rev":}"
    done < <(printf '%s\n' "$needle" | git grep -aIlF -f - "$rev" -- 2>/dev/null || true)
  fi
}

# --------------------------------------------------------------------- main
while [ $# -gt 0 ]; do
  case "$1" in
    --expect) [ $# -ge 2 ] || usage; EXPECT_FILE=$2; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) printf '%s: unknown option %s\n' "$PROG" "$1" >&2; usage ;;
    *) break ;;
  esac
done

MODE=${1:-}
[ -n "$MODE" ] || usage
shift

case "$MODE" in
  tree)
    [ $# -ge 1 ] || usage
    DIR=$1
    [ -d "$DIR" ] || { printf '%s: not a directory: %s\n' "$PROG" "$DIR" >&2; exit 2; }
    mapfile -d '' ALL < <(
      find "$DIR" \( -type d -name .git -prune \) -o \( -type f -o -type l \) -print0 2>/dev/null || true)
    # normalize leading ./ for expect-list matching
    norm=()
    for p in "${ALL[@]}"; do
      p=${p#./}
      norm+=("$p")
    done
    i=0
    while [ $i -lt ${#norm[@]} ]; do
      chunk=("${norm[@]:i:1000}")
      scan_batch "${chunk[@]}"
      exact_batch "${chunk[@]}"
      i=$((i + 1000))
    done
    ;;
  files)
    [ $# -ge 1 ] || usage
    total=$#
    i=0
    while [ $i -lt $total ]; do
      chunk=("${@:i+1:1000}")
      scan_batch "${chunk[@]}"
      exact_batch "${chunk[@]}"
      i=$((i + 1000))
    done
    ;;
  git)
    [ $# -ge 1 ] || usage
    REV=$1
    git rev-parse -q --verify "$REV^{commit}" >/dev/null 2>&1 || {
      printf '%s: not a commit: %s\n' "$PROG" "$REV" >&2; exit 2; }
    scan_git_rev "$REV"
    ;;
  history)
    RANGE=${1:---all}
    mapfile -t REVS < <(git rev-list "$RANGE" 2>/dev/null || true)
    [ ${#REVS[@]} -gt 0 ] || { printf '%s: no revisions for range %s\n' "$PROG" "$RANGE" >&2; exit 2; }
    declare -A SEEN=()
    for rev in "${REVS[@]}"; do
      # emit only the first occurrence of each rule+path across history
      while IFS=$'\t' read -r kind rule path; do
        [ -n "$kind" ] || continue
        key="$rule|$path"
        if [ -z "${SEEN[$key]:-}" ]; then
          SEEN[$key]=1
          if [ "$kind" = "HIT" ]; then
            printf 'HIT\t%s\t%s\n' "$rule" "$path"
            UNEXPECTED=$((UNEXPECTED + 1))
          else
            printf 'EXPECTED\t%s\t%s\n' "$rule" "$path"
            EXPECTED=$((EXPECTED + 1))
          fi
        fi
      done < <("$0" ${EXPECT_FILE:+--expect "$EXPECT_FILE"} git "$rev")
    done
    SCANNED=${#REVS[@]}
    ;;
  *)
    usage
    ;;
esac

if [ "${QUIET:-0}" != "1" ]; then
  printf 'SCAN mode=%s items=%d unexpected=%d expected=%d exact=%s\n' \
    "$MODE" "$SCANNED" "$UNEXPECTED" "$EXPECTED" \
    "$([ -n "${RICE_SCAN_EXACT:-${RICE_TOKEN:-}}" ] && echo on || echo off)" >&2
fi

[ "$UNEXPECTED" -eq 0 ] || exit 1
exit 0

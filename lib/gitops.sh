# lib/gitops.sh - authentication, repo selection and the scan+push pipeline (S2/S4/S5)
# The token lives ONLY in the process environment (RICE_TOKEN) plus, when an API
# call is needed, a 0600 curl config file that the exit trap removes. It never
# appears in a remote URL, argv, a log line or a committed file.

RICE_AUTH_MODE=""      # "gh" | "pat"
RICE_REPO_PRIVATE=""   # yes | no | unknown
RICE_TMPFILES=()       # trap-removed (askpass dir, curl configs, api bodies)

rice_tmp_track() { RICE_TMPFILES+=("$1"); }

rice_gitops_cleanup() {
  local f
  for f in "${RICE_TMPFILES[@]:-}"; do
    [ -n "$f" ] && rm -rf -- "$f" 2>/dev/null
  done
  return 0
}

# ------------------------------------------------------------------- auth
rice_auth_init() { # $1 = 1 when interactive input is allowed
  local interactive=$1
  if rice_have gh; then
    if gh auth status >/dev/null 2>&1; then
      RICE_AUTH_MODE=gh
      rice_info "auth mode: gh (existing credentials)"
      return 0
    fi
    if [ "$interactive" = "1" ] && rice_is_tty; then
      rice_info "auth mode: starting gh login (web/device flow)"
      if gh auth login --hostname github.com --git-protocol https; then
        if gh auth status >/dev/null 2>&1; then
          RICE_AUTH_MODE=gh
          return 0
        fi
      fi
      rice_err "gh login did not complete"
      return 1
    fi
    rice_err "gh is present but not authenticated, and this run is non-interactive"
    return 1
  fi
  # PAT mode (both paths MUST set the mode: rice_auth_setup_git and the dry-run
  # summary key off it - a missing mode silently skips GIT_ASKPASS installation)
  if [ -n "${RICE_TOKEN:-}" ]; then
    RICE_AUTH_MODE=pat
    rice_info "auth mode: RICE_TOKEN taken from the environment (memory only)"
    return 0
  fi
  if [ "$interactive" = "1" ] && rice_is_tty; then
    if rice_read_secret RICE_TOKEN "GitHub PAT (input hidden; lives only in memory): "; then
      if [ -n "$RICE_TOKEN" ]; then
        RICE_AUTH_MODE=pat
        rice_info "auth mode: PAT accepted (never echoed, never stored)"
        return 0
      fi
    fi
    rice_err "no token provided"
    return 1
  fi
  rice_err "gh not installed and stdin is not a terminal; export RICE_TOKEN and retry"
  return 1
}

# prepare git authentication (call after rice_auth_init)
rice_auth_setup_git() {
  if [ "$RICE_AUTH_MODE" = "pat" ]; then
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/rice-askpass.XXXXXX") || return 1
    chmod 700 "$dir"
    rice_tmp_track "$dir"
    cat > "$dir/askpass.sh" <<'EOF'
#!/bin/sh
# GIT_ASKPASS helper (rule S2): the token is read from the environment only.
case "$1" in
  *sername*) printf '%s\n' "${RICE_GIT_USER:-rice-backup}" ;;
  *) printf '%s\n' "${RICE_TOKEN:-}" ;;
esac
EOF
    chmod 700 "$dir/askpass.sh"
    export GIT_ASKPASS="$dir/askpass.sh"
    export GIT_TERMINAL_PROMPT=0
  fi
  return 0
}

# git wrapper: gh mode routes credentials through gh; pat mode uses GIT_ASKPASS
rice_git() {
  if [ "$RICE_AUTH_MODE" = "gh" ]; then
    git -c credential.helper='!gh auth git-credential' "$@"
  else
    git "$@"
  fi
}

# ------------------------------------------------------------------- API
# prints the response body; empty body + nonzero exit means transport failure
rice_api() { # $1 METHOD  $2 endpoint  $3 optional json file
  local method=$1 endpoint=$2 data=${3:-}
  if [ "$RICE_AUTH_MODE" = "gh" ]; then
    if [ "$method" = "GET" ]; then
      gh api "${RICE_API_BASE:-$RICE_API_BASE_DEFAULT}$endpoint" 2>/dev/null
    else
      if [ -n "$data" ]; then
        gh api -X "$method" --input "$data" "${RICE_API_BASE:-$RICE_API_BASE_DEFAULT}$endpoint" 2>/dev/null
      else
        gh api -X "$method" "${RICE_API_BASE:-$RICE_API_BASE_DEFAULT}$endpoint" 2>/dev/null
      fi
    fi
    return
  fi
  if rice_have curl; then
    local cfg body rc
    cfg=$(mktemp "${TMPDIR:-/tmp}/rice-curl.XXXXXX") || return 1
    chmod 600 "$cfg"
    rice_tmp_track "$cfg"
    body=""
    if [ -n "$data" ]; then
      body=$(mktemp "${TMPDIR:-/tmp}/rice-body.XXXXXX") || return 1
      chmod 600 "$body"
      rice_tmp_track "$body"
      cp -- "$data" "$body"
    fi
    {
      printf 'silent\nshow-error\n'
      printf 'request = "%s"\n' "$method"
      printf 'url = "%s%s"\n' "${RICE_API_BASE:-$RICE_API_BASE_DEFAULT}" "$endpoint"
      printf 'header = "Authorization: Bearer %s"\n' "$RICE_TOKEN"
      printf 'header = "Accept: application/vnd.github+json"\n'
      [ -n "$body" ] && printf 'data = @%s\n' "$body"
    } > "$cfg"
    curl --config "$cfg" 2>/dev/null
    return $?
  fi
  rice_warn "neither gh nor curl available: API calls are not possible"
  return 9
}

# ------------------------------------------------------------ repo selection
rice_remote_url() { # $1 owner $2 name
  printf '%s/%s/%s.git' "${RICE_TEST_GIT_BASE:-$RICE_GIT_BASE_DEFAULT}" "$1" "$2"
}

rice_parse_repo() { # $1 OWNER/NAME string → prints "owner name" or fails
  local s=${1:-}
  case "$s" in
    */*) ;;
    *) return 1 ;;
  esac
  local owner=${s%/*} name=${s#*/}
  case "$owner$name" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ -n "$owner" ] && [ -n "$name" ] || return 1
  printf '%s %s' "$owner" "$name"
}

# ensure the target repo exists and is private (R4)
rice_repo_ensure() { # $1 owner $2 name
  local owner=$1 name=$2 resp
  if [ -n "${RICE_TEST_GIT_BASE:-}" ]; then
    rice_info "repo: test mode (RICE_TEST_GIT_BASE) - assuming pre-created private repo"
    RICE_REPO_PRIVATE=yes
    return 0
  fi
  resp=$(rice_api GET "/repos/$owner/$name") || resp=""
  if [ -n "$resp" ] && grep -q '"message"[[:space:]]*:[[:space:]]*"Not Found"' <<<"$resp"; then
    resp=""
  fi
  if [ -n "$resp" ]; then
    if grep -q '"private"[[:space:]]*:[[:space:]]*true' <<<"$resp"; then
      RICE_REPO_PRIVATE=yes
    elif grep -q '"private"[[:space:]]*:[[:space:]]*false' <<<"$resp"; then
      RICE_REPO_PRIVATE=no
    else
      RICE_REPO_PRIVATE=unknown
    fi
    return 0
  fi
  # not found (or unreachable): try to create it PRIVATE
  rice_repo_create "$owner" "$name"
}

rice_repo_create() { # $1 owner $2 name
  local owner=$1 name=$2 resp payload
  rice_info "repo: $owner/$name not found - creating it PRIVATE"
  if [ "$RICE_AUTH_MODE" = "gh" ]; then
    if gh repo create "$owner/$name" --private >/dev/null 2>&1; then
      RICE_REPO_PRIVATE=yes
      rice_info "repo: created private $owner/$name via gh"
      return 0
    fi
    rice_warn "repo: gh repo create failed"
    return 1
  fi
  if rice_have curl; then
    payload=$(mktemp "${TMPDIR:-/tmp}/rice-payload.XXXXXX") || return 1
    chmod 600 "$payload"
    rice_tmp_track "$payload"
    printf '{"name":"%s","private":true}' "$name" > "$payload"
    resp=$(rice_api POST /user/repos "$payload") || resp=""
    if [ -n "$resp" ] && grep -q '"private"[[:space:]]*:[[:space:]]*true' <<<"$resp"; then
      RICE_REPO_PRIVATE=yes
      rice_info "repo: created private $owner/$name via the API"
      return 0
    fi
    if [ -n "$resp" ] && grep -q '"message"' <<<"$resp"; then
      local msg
      msg=$(grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$resp" | head -1 | sed 's/.*"//;s/"$//')
      rice_warn "repo: API create failed${msg:+: $msg}"
    fi
  fi
  rice_warn "repo: could not create $owner/$name automatically."
  rice_warn "create it manually (PRIVATE) at https://github.com/new then re-run rice-backup."
  return 1
}

# ----------------------------------------------------------- push pipeline
# S4: explicit scans + pre-push hook; S5: plain https remote, never force.
# Two phases: rice_stage_prepare runs BEFORE any file lands in the stage (it
# may populate the stage from the existing remote backup); rice_stage_finish
# runs AFTER staging (commit, scans, hook, push).

rice_stage_prepare() { # $1 stage dir  $2 owner  $3 name → prints "base" or "" (diff base)
  local stage=$1 owner=$2 name=$3
  local url

  # export mode (D33): offline archive - no remote, no fetch, no diff base
  if [ -z "$owner" ] && [ -z "$name" ]; then
    (
      cd "$stage" || exit 1
      git init -q -b main .
      git config user.name  >/dev/null 2>&1 || git config user.name  "rice-backup"
      git config user.email >/dev/null 2>&1 || git config user.email "rice-backup@localhost"
      printf ''
    )
    return 0
  fi

  url=$(rice_remote_url "$owner" "$name")

  # T2/S5: the remote URL must be a plain github URL (or the test base)
  case "$url" in
    https://github.com/*) : ;;
    *)
      if [ -z "${RICE_TEST_GIT_BASE:-}" ]; then
        rice_die "refusing to push to a non-github remote: $url" 3
      fi
      ;;
  esac

  ( cd "$stage" || exit 1
    git init -q -b main .
    # a fresh machine may have no git identity configured; fall back to a
    # repo-local identity so the backup commit can always be created
    # (global configuration is never touched)
    git config user.name  >/dev/null 2>&1 || git config user.name  "rice-backup"
    git config user.email >/dev/null 2>&1 || git config user.email "rice-backup@localhost"
    git remote remove origin >/dev/null 2>&1 || true
    git remote add origin "$url"
    if rice_git ls-remote --exit-code -h "$url" refs/heads/main >/dev/null 2>&1; then
      rice_git fetch -q origin main || rice_die "fetch of existing main failed" 3
      git reset -q --hard FETCH_HEAD
      printf 'origin/main'
    else
      printf ''
    fi
  )
}

rice_stage_finish() { # $1 stage  $2 diff-base ("" if none)  $3 scanner  $4 toolroot  [$5 = export] [$6 = ack expect file (repo-relative; "" = none)]
  local stage=$1 base=$2 scanner=$3 toolroot=$4
  local export_mode=${5:-}
  local expect=${6:-}

  ( cd "$stage" || exit 1
    git add -A
    local msg
    msg="rice-backup $(date +'%Y-%m-%d %H:%M') ${RICE_DISTRO:-unknown} host=$(hostname 2>/dev/null || echo unknown)"
    git commit -q --allow-empty -m "$msg"

    # install the pre-push hook (S4: hook AND explicit call). The [ack-scan]
    # expect list (D41/R4) rides along, so acknowledged scan hits do not
    # block the push while everything else still does.
    if [ -z "$export_mode" ]; then
      local hookargs=("$PWD")
      if [ -n "$expect" ] && [ -f "$expect" ]; then hookargs+=("$expect"); fi
      bash "$toolroot/scripts/install-hook.sh" ${hookargs[@]+"${hookargs[@]}"} >/dev/null 2>&1 \
        || rice_warn "could not install pre-push hook (continuing with explicit scans)"
    fi

    # ---- explicit scans (S4): full tree + changed files + the commit itself.
    # Scans run from the stage root with REPO-RELATIVE paths (tree .) so the
    # --expect prefixes (home/...) line up with git mode paths.
    local scans_failed=0 out eargs=()
    if [ -n "$expect" ] && [ -f "$expect" ]; then eargs=(--expect "$expect"); fi
    out=$("$scanner" ${eargs[@]+"${eargs[@]}"} tree .) || scans_failed=1
    printf '%s\n' "$out" | grep -v '^SCAN ' >&2 || true
    if [ -n "$base" ]; then
      local changed=()
      mapfile -d '' changed < <(git diff --name-only -z "$base" HEAD 2>/dev/null)
      if [ ${#changed[@]} -gt 0 ]; then
        out=$("$scanner" ${eargs[@]+"${eargs[@]}"} files "${changed[@]}") || scans_failed=1
        printf '%s\n' "$out" | grep -v '^SCAN ' >&2 || true
      fi
    fi
    out=$("$scanner" ${eargs[@]+"${eargs[@]}"} git HEAD) || scans_failed=1
    printf '%s\n' "$out" | grep -v '^SCAN ' >&2 || true

    if [ "$scans_failed" -ne 0 ]; then
      rice_err "SECRET HIT: refusing to continue (rule S4). The local staging commit is discarded;"
      rice_err "the remote was never contacted with this content."
      rice_err "If any listed file already existed in the REMOTE backup, rotate the involved"
      rice_err "credentials now and follow the history-rewrite runbook in README SECURITY."
      exit 2
    fi

    # export mode: stop here - the archive is written by the caller (no push)
    if [ -n "$export_mode" ]; then
      printf '%s\n' "$(git rev-parse --short HEAD)"
      exit 0
    fi

    # push (never --force; non-fast-forward aborts, never overwritten)
    if ! rice_git push origin main; then
      rice_err "push failed (never force-pushed). If it was rejected as non-fast-forward,"
      rice_err "inspect the remote repository manually before trying again."
      exit 3
    fi
    printf '%s\n' "$(git rev-parse --short HEAD)"
  )
}

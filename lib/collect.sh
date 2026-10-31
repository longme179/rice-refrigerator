# lib/collect.sh - selection, filtering and staging of rice files (rule R5/R6/R7)
# Exclusion layers, precedence L1 > L2 > L3 (see agent-state/PLAN.md section 5):
#   L1 hard deny (always wins) -> EXCLUDED.md
#   L2 content scan            -> EXCLUDED.md (rule name, never a value)
#   L3 hygiene: caches, >50MB  -> SKIPPED.md

RICE_MAX_FILE_BYTES=$((50 * 1024 * 1024))     # GitHub rejects >100MB; stay well below
RICE_TOTAL_WARN_BYTES=$((800 * 1024 * 1024))  # soft warning threshold
RICE_TOTAL_MAX_BYTES="${RICE_TOTAL_MAX_BYTES:-$((1024 * 1024 * 1024))}"  # hard budget (1 GiB; --allow-oversize overrides)

# ---- L1: hard deny - directories (paths relative to $HOME, case-insensitive) ----
RICE_DENY_DIRS=(
  .ssh
  .gnupg
  .gnome/keyrings
  .gnome2/keyrings
  .local/share/keyrings
  .password-store
  .config/gopass
  .local/share/gopass
  .aws
  .config/gcloud
  .azure
  .kube
  .config/kube
  .config/helm
  .docker
  .config/gh
  .mozilla
  .config/mozilla
  .local/share/mozilla
  .librewolf
  .waterfox
  .zen
  .floorp
  .config/google-chrome
  .config/google-chrome-beta
  .config/google-chrome-unstable
  .config/chromium
  .config/chromium-beta
  .config/BraveSoftware
  .config/vivaldi
  .config/Opera
  .config/opera
  .config/Microsoft-edge
  .config/librewolf
  .config/waterfox
  .config/ungoogled-chromium
  .var/app
  .thunderbird
  .config/evolution
  .local/share/evolution
  .local/share/TelegramDesktop
  .config/telegram-desktop
  .config/Signal
  .config/Element
  .config/discord
  .config/Keybase
  .config/Slack
  .config/zoomus
  .config/Zoom
  .local/share/kwalletd
  .pki
  .onepassword
  .config/1Password
  .config/Code/User/globalStorage
)

# ---- L1: hard deny - file globs (matched against the relative path, lowercase) ----
RICE_DENY_GLOBS=(
  .netrc
  .netrc.gpg
  .git-credentials
  .pypirc
  .k5login
  .kdbx
  *.kdbx
  *.kdb
  *.key
  *.pem
  *.p12
  *.pfx
  .env
  .env.*
  *.env
  *id_rsa*
  *id_dsa*
  *id_ecdsa*
  *id_ed25519*
  .bash_history
  .zsh_history
  .sh_history
  .python_history
  .node_repl_history
  .mysql_history
  .psql_history
  .sqlite_history
  *history*
  .lesshst
  .viminfo
  .viminfo.tmp
  .wget-hsts
  *.tfstate
  *.tfstate.*
)

# ---- include roots under $HOME ----
RICE_HOME_FILES=(
  .bashrc
  .bash_profile
  .bash_aliases
  .bash_logout
  .profile
  .zshrc
  .zshenv
  .zprofile
  .zlogout
  .inputrc
  .tmux.conf
  .screenrc
  .vimrc
  .gvimrc
  .gitconfig
  .gitignore
  .editorconfig
  .curlrc
  .wgetrc
)

RICE_HOME_DIRS=(
  .config
  .local/bin
  .local/share/applications
  .local/share/fonts
  .local/share/icons
  .local/share/themes
  .local/share/gnome-shell/extensions
  .local/share/konsole
  .local/share/color-schemes
  .local/share/plasma
  .local/share/wallpapers
  .local/share/look-and-feel
  .local/share/aurorae
  .fonts
  .icons
  .themes
)

# ---- /etc allowlist, only with --include-system ----
RICE_ETC_FILES=(
  /etc/hostname
  /etc/hosts
  /etc/fstab
  /etc/locale.conf
  /etc/vconsole.conf
  /etc/timezone
  /etc/machine-info
)

RICE_ETC_GLOBS=(
  '/etc/dnf/dnf.conf'
  '/etc/yum.repos.d/*.repo'
  '/etc/pacman.conf'
  '/etc/pacman.d/mirrorlist'
  '/etc/pacman.d/mirrorlist.*'
  '/etc/apt/sources.list'
  '/etc/apt/sources.list.d/*'
  '/etc/default/grub'
  '/etc/X11/xorg.conf.d/*'
  '/etc/systemd/system/*.service'
  '/etc/systemd/system/*.timer'
)

# ------------------------------------------------------------------ state
rice_collect_init() {
  RICE_INCLUDE=()        # rel paths that will be staged
  RICE_META_INC=()       # "rel<TAB>bytes<TAB>mode<TAB>type<TAB>target"
  RICE_DENIED=()         # "rel<TAB>rule"
  RICE_SCANHITS=()       # "rel<TAB>rule"
  RICE_USER_EXCL=()      # "rel<TAB>user-exclude" (from --exclude-from, D32)
  RICE_SKIPPED_BIG=()    # "rel<TAB>bytes"
  RICE_SKIPPED_CACHE=()  # rel paths (or dir summaries)
  RICE_TOTAL_BYTES=0
  RICE_ETC_INCLUDE=()    # abs /etc paths staged under system/
  RICE_ETC_DENIED=()
  # ---- symlink following (D37) ----
  RICE_FOLLOW="${RICE_FOLLOW:-1}"          # 0 = --no-follow-symlinks
  RICE_FOLLOW_OUTSIDE="${RICE_FOLLOW_OUTSIDE:-0}"  # 1 = --follow-outside-home
  declare -g -A RICE_SEEN=()      # virtual rel paths already considered
  declare -g -A RICE_SEEN_REAL=() # canonical targets already followed (dedup)
  RICE_COVERED_REL=()   # home-relative regions whose content is collected anyway
  RICE_LINKS_RAW=()     # "rel<TAB>raw<TAB>real" for every link met during the walk
  RICE_LINKS=()         # FOLLOWED links: "rel<TAB>raw<TAB>real<TAB>kind<TAB>files<TAB>bytes"
  RICE_LINK_STATUS=()   # links NOT followed: "rel<TAB>status<TAB>detail"
  RICE_DEREF=()         # followed FILE links (staged with tar -h)
}

# L1 matcher: prints rule name or nothing
rice_deny_rule_for() { # $1 rel path
  local rel_l=${1,,} p g
  for p in "${RICE_DENY_DIRS[@]}"; do
    if [ "$rel_l" = "$p" ] || [[ "$rel_l" == "$p"/* ]]; then
      printf 'deny-dir:%s' "$p"
      return
    fi
  done
  for g in "${RICE_DENY_GLOBS[@]}"; do
    # shellcheck disable=SC2254  (g is intentionally used as a case pattern)
    case "$rel_l" in
      $g) printf 'deny-file:%s' "$g"; return ;;
    esac
  done
  return 0
}

# L3: cache / junk path components
rice_is_cache_path() { # $1 lowercase rel path
  case "$1" in
    .cache|.cache/*|*/.cache|*/.cache/*) return 0 ;;
    */cache/*|*/Cache/*|*/caches/*|*/Caches/*) return 0 ;;
    */node_modules|*/node_modules/*) return 0 ;;
    */__pycache__|*/__pycache__/*) return 0 ;;
    */.npm|*/.npm/*) return 0 ;;
    */.git|*/.git/*) return 0 ;;
    */Trash|*/Trash/*) return 0 ;;
    .config/fcitx/dbus|.config/fcitx/dbus/*) return 0 ;;
    *.log) return 0 ;;
    *) return 1 ;;
  esac
}

# consider one relative path under $HOME for inclusion
# Symlinks are NOT decided here (D37): they are deferred to rice_resolve_links
# because whether their target is already covered by the backup can only be
# known after the full walk. Files found under a followed link's virtual path
# go through here as usual (deny/cache/size layers see the VIRTUAL path).
rice_consider() { # $1 home  $2 rel path
  local home=$1 rel=$2
  local rule
  rule=$(rice_deny_rule_for "$rel")
  if [ -n "$rule" ]; then
    RICE_DENIED+=("$rel"$'\t'"$rule")
    return
  fi
  if rice_is_cache_path "${rel,,}"; then
    if [ -d "$home/$rel" ]; then
      RICE_SKIPPED_CACHE+=("$rel/")
    else
      RICE_SKIPPED_CACHE+=("$rel")
    fi
    return
  fi
  local bytes mode type target
  if [ -L "$home/$rel" ]; then
    local raw real
    raw=$(readlink -- "$home/$rel" 2>/dev/null) || raw=""
    real=$(readlink -f -- "$home/$rel" 2>/dev/null) || true
    # readlink -f succeeds even for a dangling last component; empty real = dangling
    [ -n "$real" ] && [ ! -e "$real" ] && real=""
    RICE_LINKS_RAW+=("$rel"$'\t'"$raw"$'\t'"$real")
    return
  elif [ -f "$home/$rel" ]; then
    type=f
    target=""
    if ! bytes=$(stat -c %s -- "$home/$rel" 2>/dev/null); then
      RICE_SKIPPED_CACHE+=("$rel (stat failed)")
      return
    fi
    mode=$(stat -c %a -- "$home/$rel" 2>/dev/null || echo 644)
  else
    return # devices, sockets, fifos: not rice
  fi
  if [ "$bytes" -gt "$RICE_MAX_FILE_BYTES" ]; then
    RICE_SKIPPED_BIG+=("$rel"$'\t'"$bytes")
    return
  fi
  RICE_INCLUDE+=("$rel")
  RICE_META_INC+=("$rel"$'\t'"$bytes"$'\t'"$mode"$'\t'"$type"$'\t'"$target")
  RICE_TOTAL_BYTES=$((RICE_TOTAL_BYTES + bytes))
}

# walk include roots under $HOME
rice_collect_home() { # $1 home
  local home=$1 f rel d e
  # transparency pass: deny-listed / cache items OUTSIDE the include roots are
  # reported too (names + rules only). They were never candidates and their
  # contents are never read; this exists so EXCLUDED.md/SKIPPED.md reassure
  # the user that e.g. ~/.ssh was deliberately left alone.
  for e in "$home"/.* "$home"/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    rel=${e#"$home"/}
    case "$rel" in .|..) continue ;;
    esac
    if [ -n "$(rice_deny_rule_for "$rel")" ] || rice_is_cache_path "${rel,,}"; then
      rice_consider "$home" "$rel"
      RICE_SEEN["$rel"]=1
    fi
  done
  # a few deny rules sit deeper than one level; probe them explicitly
  for rel in .var/app .gnome/keyrings .gnome2/keyrings .local/share/keyrings \
             .local/share/gopass .local/share/evolution .local/share/TelegramDesktop \
             .local/share/kwalletd .local/share/mozilla; do
    [ -n "${RICE_SEEN[$rel]:-}" ] && continue
    if { [ -e "$home/$rel" ] || [ -L "$home/$rel" ]; } \
       && [ -n "$(rice_deny_rule_for "$rel")" ]; then
      rice_consider "$home" "$rel"
      RICE_SEEN["$rel"]=1
    fi
  done
  for f in "${RICE_HOME_FILES[@]}"; do
    if [ -e "$home/$f" ] || [ -L "$home/$f" ]; then
      rice_consider "$home" "$f"
    fi
  done
  for d in "${RICE_HOME_DIRS[@]}"; do
    [ -d "$home/$d" ] || continue
    while IFS= read -r -d '' f; do
      rel=${f#"$home"/}
      [ -n "${RICE_SEEN[$rel]:-}" ] && continue
      RICE_SEEN["$rel"]=1
      rice_consider "$home" "$rel"
    done < <(find "$home/$d" \( -type f -o -type l \) -print0 2>/dev/null | sort -z)
  done
  # phase 2 (D37): decide every symlink met above — follow, keep or exclude
  rice_resolve_links "$home"
}

# ---- symlink resolution (D37) ------------------------------------------------
# Is a home-relative link TARGET already collected by the backup itself?
# (a top-level file from RICE_HOME_FILES, anything under an include root, or
# inside a region already fetched via another followed link). If yes, the link
# itself round-trips perfectly and its content is in the repo anyway — so we
# KEEP it as a symlink instead of duplicating the content.
rice_link_target_covered() { # $1 home-relative target path
  local t=$1 f r c
  for f in "${RICE_HOME_FILES[@]}"; do
    [ "$t" = "$f" ] && return 0
  done
  for r in "${RICE_HOME_DIRS[@]}"; do
    if [ "$t" = "$r" ] || [[ "$t" == "$r"/* ]]; then return 0; fi
  done
  for c in "${RICE_COVERED_REL[@]}"; do
    if [ -n "$c" ] && { [ "$t" = "$c" ] || [[ "$t" == "$c"/* ]]; }; then return 0; fi
  done
  return 1
}

# Would following this target RE-WALK regions the backup already collects?
# (the target is an ANCESTOR of an include root or of an already-followed
# region: following it would duplicate that content under a second virtual
# prefix, so the link is kept instead and the overlap is reported)
rice_link_target_overlaps() { # $1 home-relative target path
  local t=$1 r c
  [ -n "$t" ] || return 1
  for r in "${RICE_HOME_DIRS[@]}"; do
    if [ "$r" = "$t" ] || [[ "$r" == "$t"/* ]]; then return 0; fi
  done
  for c in "${RICE_COVERED_REL[@]}"; do
    if [ -n "$c" ] && { [ "$c" = "$t" ] || [[ "$c" == "$t"/* ]]; }; then return 0; fi
  done
  return 1
}

# keep a link as a symlink candidate (today's pre-D37 behavior) + status note
rice_keep_link() { # $1 home  $2 rel  $3 raw  $4 status  $5 detail
  local home=$1 rel=$2 raw=$3 status=$4 detail=$5
  local bytes mode
  bytes=$(stat -c %s -- "$home/$rel" 2>/dev/null || echo 0)
  mode=$(stat -c %a -- "$home/$rel" 2>/dev/null || echo 777)
  RICE_INCLUDE+=("$rel")
  RICE_META_INC+=("$rel"$'\t'"$bytes"$'\t'"$mode"$'\t'l$'\t'"$raw")
  RICE_TOTAL_BYTES=$((RICE_TOTAL_BYTES + bytes))
  RICE_LINK_STATUS+=("$rel"$'\t'"$raw"$'\t'"$status"$'\t'"$detail")
}

rice_resolve_links() { # $1 home — phase 2 entry
  local home=$1 rec
  for rec in "${RICE_LINKS_RAW[@]}"; do
    local rel=${rec%%$'\t'*} rest=${rec#*$'\t'}
    local raw=${rest%%$'\t'*} real=${rest#*$'\t'}
    rice_resolve_one_link "$home" "$rel" "$raw" "$real"
  done
}

# Decide ONE symlink. real is the CANONICAL target ("" when dangling). Nested
# links discovered while walking a followed target recurse through here, so
# cycles terminate via RICE_SEEN_REAL (dedup) and rice_link_target_covered
# (anything inside an already-followed region is covered).
rice_resolve_one_link() { # $1 home  $2 rel  $3 raw  $4 real
  local home=$1 rel=$2 raw=$3 real=$4
  local rule realrel kind
  if [ -z "$real" ] || [ ! -e "$real" ]; then
    rice_keep_link "$home" "$rel" "$raw" dangling "target does not exist (link kept)"
    return 0
  fi
  if [ "$RICE_FOLLOW" -ne 1 ]; then
    rice_keep_link "$home" "$rel" "$raw" disabled "following off (--no-follow-symlinks)"
    return 0
  fi
  realrel=""
  if [ "$real" = "$home" ]; then
    rice_keep_link "$home" "$rel" "$raw" overlaps "target is the home itself (link kept)"
    return 0
  fi
  if [[ "$real" == "$home"/* ]]; then
    realrel=${real#"$home"/}
  fi
  if [ -z "$realrel" ]; then
    if [ "$RICE_FOLLOW_OUTSIDE" -ne 1 ]; then
      rice_keep_link "$home" "$rel" "$raw" outside "target outside home, not followed (use --follow-outside-home)"
      return 0
    fi
  else
    rule=$(rice_deny_rule_for "$realrel")
    if [ -n "$rule" ]; then
      # a symlink may never bypass L1: the link itself is excluded, rule named
      RICE_DENIED+=("$rel"$'\t'"deny-target:$rule")
      return 0
    fi
    if rice_is_cache_path "${realrel,,}"; then
      rice_keep_link "$home" "$rel" "$raw" cache "target is cache/junk (link kept, junk never fetched)"
      return 0
    fi
    if rice_link_target_covered "$realrel"; then
      rice_keep_link "$home" "$rel" "$raw" covered "target is already inside the backup (link kept)"
      return 0
    fi
    if rice_link_target_overlaps "$realrel"; then
      rice_keep_link "$home" "$rel" "$raw" overlaps "target would re-walk regions already in the backup (link kept)"
      return 0
    fi
  fi
  if [ -n "${RICE_SEEN_REAL[$real]:-}" ]; then
    rice_keep_link "$home" "$rel" "$raw" duplicate "target already fetched via another link (link kept)"
    return 0
  fi

  if [ -d "$real" ]; then
    kind=dir
  elif [ -f "$real" ]; then
    kind=file
  else
    rice_keep_link "$home" "$rel" "$raw" unsupported "target is not a file or directory (link kept)"
    return 0
  fi

  RICE_SEEN_REAL["$real"]=1
  RICE_COVERED_REL+=("$realrel")   # marks the region as fetched (also for nested links)

  if [ "$kind" = file ]; then
    local bytes mode
    if ! bytes=$(stat -c %s -- "$real" 2>/dev/null); then
      rice_keep_link "$home" "$rel" "$raw" unsupported "target stat failed (link kept)"
      return 0
    fi
    mode=$(stat -c %a -- "$real" 2>/dev/null || echo 644)
    if [ "$bytes" -gt "$RICE_MAX_FILE_BYTES" ]; then
      RICE_SKIPPED_BIG+=("$rel"$'\t'"$bytes")
      return 0
    fi
    # content of the TARGET is staged at the link path (tar -h in stage copy)
    RICE_INCLUDE+=("$rel")
    RICE_META_INC+=("$rel"$'\t'"$bytes"$'\t'"$mode"$'\t'f$'\t'"")
    RICE_TOTAL_BYTES=$((RICE_TOTAL_BYTES + bytes))
    RICE_DEREF+=("$rel")
    RICE_LINKS+=("$rel"$'\t'"$raw"$'\t'"$real"$'\t'"$kind"$'\t'1$'\t'"$bytes")
    return 0
  fi

  # kind=dir: fetch the target's content under the LINK path (virtual paths)
  local p sub virt nraw nreal
  while IFS= read -r -d '' p; do
    sub=${p#"$real"/}
    virt="$rel/$sub"
    [ -n "${RICE_SEEN[$virt]:-}" ] && continue
    RICE_SEEN["$virt"]=1
    if [ -L "$p" ]; then
      nraw=$(readlink -- "$p" 2>/dev/null) || nraw=""
      nreal=$(readlink -f -- "$p" 2>/dev/null) || true
      [ -n "$nreal" ] && [ ! -e "$nreal" ] && nreal=""
      rice_resolve_one_link "$home" "$virt" "$nraw" "$nreal"
    else
      rice_consider "$home" "$virt"
    fi
  done < <(find "$real" \( -type f -o -type l \) -print0 2>/dev/null | sort -z)
  local cnt=0 tot=0 m pv bv pt
  for m in "${RICE_META_INC[@]}"; do
    pv=${m%%$'\t'*}
    if [[ "$pv" == "$rel"/* ]]; then
      pt=$(printf '%s' "$m" | cut -f4)
      if [ "$pt" != "l" ]; then
        cnt=$((cnt + 1))
        bv=${m#*$'\t'}; bv=${bv%%$'\t'*}
        tot=$((tot + ${bv:-0}))
      fi
    fi
  done
  RICE_LINKS+=("$rel"$'\t'"$raw"$'\t'"$real"$'\t'"$kind"$'\t'"$cnt"$'\t'"$tot")
  return 0
}

# /etc collection (only called with --include-system); staged under system/etc
rice_collect_etc() {
  local f g
  for f in "${RICE_ETC_FILES[@]}"; do
    if [ -f "$f" ]; then
      RICE_ETC_INCLUDE+=("$f")
    fi
  done
  for g in "${RICE_ETC_GLOBS[@]}"; do
    # shellcheck disable=SC2254
    for f in $g; do
      [ -f "$f" ] && RICE_ETC_INCLUDE+=("$f")
    done
  done
}

# L2: content scan of all candidates; hits move RICE_INCLUDE -> RICE_SCANHITS
rice_scan_candidates() { # $1 home  $2 scanner script
  local home=$1 scanner=$2
  [ ${#RICE_INCLUDE[@]} -gt 0 ] || return 0
  local abs=() rel
  for rel in "${RICE_INCLUDE[@]}"; do
    abs+=("$home/$rel")
  done
  local out
  out=$("$scanner" files "${abs[@]}" 2>/dev/null) || true
  local -A bad=()
  local kind rule path
  while IFS=$'\t' read -r kind rule path; do
    [ -n "${kind:-}" ] || continue
    [ "$kind" = "HIT" ] || continue
    rel=${path#"$home"/}
    bad["$rel"]="$rule"
  done <<<"$out"
  local keep=()
  for rel in "${RICE_INCLUDE[@]}"; do
    if [ -n "${bad[$rel]:-}" ]; then
      RICE_SCANHITS+=("$rel"$'\t'"${bad[$rel]}")
    else
      keep+=("$rel")
    fi
  done
  RICE_INCLUDE=("${keep[@]}")
  # also drop their metadata and subtract their bytes from the reported total
  local metakeep=() m r2 b
  for m in "${RICE_META_INC[@]}"; do
    r2=${m%%$'\t'*}
    if [ -n "${bad[$r2]:-}" ]; then
      b=$(printf '%s' "$m" | cut -f2)
      RICE_TOTAL_BYTES=$((RICE_TOTAL_BYTES - ${b:-0}))
    else
      metakeep+=("$m")
    fi
  done
  RICE_META_INC=("${metakeep[@]}")
}

# L2 for the /etc allowlist (--include-system): same rules as $HOME candidates
rice_scan_etc_candidates() { # $1 scanner
  local scanner=$1
  [ ${#RICE_ETC_INCLUDE[@]} -gt 0 ] || return 0
  local out
  out=$("$scanner" files "${RICE_ETC_INCLUDE[@]}" 2>/dev/null) || true
  local -A bad=()
  local kind rule path
  while IFS=$'\t' read -r kind rule path; do
    [ -n "${kind:-}" ] || continue
    [ "$kind" = "HIT" ] || continue
    bad["$path"]="$rule"
  done <<<"$out"
  [ ${#bad[@]} -gt 0 ] || return 0
  local keep=() f
  for f in "${RICE_ETC_INCLUDE[@]}"; do
    if [ -n "${bad[$f]:-}" ]; then
      RICE_DENIED+=("etc:$f"$'\t'"${bad[$f]}")
    else
      keep+=("$f")
    fi
  done
  RICE_ETC_INCLUDE=("${keep[@]}")
}

# User selection (--exclude-from FILE, D32): purely SUBTRACTIVE. Applied AFTER
# the deny list (L1) and the content scan (L2), so a selection can never bypass
# either layer and never adds anything. Entries are home-relative paths; an
# entry names a file exactly or a directory subtree (prefix match on "dir/").
# Matching walks the ANCESTORS of each candidate (<= depth lookups per file into
# an associative array) so 3000+ candidates stay fast with any selection size.
rice_apply_user_excludes() { # $1 home  $2 selection file ("" = none)
  local home=$1 selfile=$2
  [ -n "$selfile" ] || return 0
  if [ ! -f "$selfile" ]; then
    rice_warn "selection file not found: $selfile (continuing without it)"
    return 0
  fi
  local -A pat=()
  local e
  while IFS= read -r e || [ -n "$e" ]; do
    e=${e%%#*}                                   # strip comments
    e=${e#"${e%%[![:space:]]*}"}                 # trim leading whitespace
    e=${e%"${e##*[![:space:]]}"}                 # trim trailing whitespace
    [ -n "$e" ] || continue
    case "$e" in
      /*|*..*)
        rice_warn "selection entry ignored (must be a path relative to the home): $e"
        continue
        ;;
    esac
    pat["$e"]=0
  done <"$selfile"
  [ ${#pat[@]} -gt 0 ] || return 0

  local keep=() rel hit anc rest m r2 b
  for rel in "${RICE_INCLUDE[@]}"; do
    hit=""
    rest=$rel
    while [ -n "$rest" ]; do            # rel, then each ancestor dir
      if [ -n "${pat[$rest]:-}" ]; then hit=$rest; break; fi
      case "$rest" in
        */*) rest=${rest%/*} ;;
        *)   rest="" ;;
      esac
    done
    if [ -n "$hit" ]; then
      pat["$hit"]=1
      RICE_USER_EXCL+=("$rel"$'\t'user-exclude)
    else
      keep+=("$rel")
    fi
  done
  RICE_INCLUDE=("${keep[@]}")

  local metakeep=()
  local -A excl=()
  for m in "${RICE_USER_EXCL[@]}"; do excl["${m%%$'\t'*}"]=1; done
  for m in "${RICE_META_INC[@]}"; do
    r2=${m%%$'\t'*}
    if [ -n "${excl[$r2]:-}" ]; then
      # bytes = field 2, pure parameter expansion (no fork per entry: 3000+
      # excluded files must stay fast, same pattern as section_bytes)
      b=${m#*$'\t'}; b=${b%%$'\t'*}
      RICE_TOTAL_BYTES=$((RICE_TOTAL_BYTES - ${b:-0}))
    else
      metakeep+=("$m")
    fi
  done
  RICE_META_INC=("${metakeep[@]}")

  for e in "${!pat[@]}"; do
    [ "${pat[$e]}" -eq 1 ] \
      || rice_warn "selection entry matched no candidate: $e"
  done
  rice_info "user selection applied: ${#RICE_USER_EXCL[@]} file(s) excluded"
}

# copy the include list into the staging tree with one tar pipe (R5:
# read-only on originals, permissions and symlinks preserved).
# D37: followed FILE links (RICE_DEREF) go through a SECOND pipe with tar -h
# so the staged entry carries the target's CONTENT at the link path; followed
# DIR content lands via normal path resolution. A pre-clean removes stale
# type mismatches from older backups (real dir <-> link/file flips, stale
# links on ancestor paths), so extraction can never write THROUGH a symlink
# out of the stage.
rice_stage_copy() { # $1 home  $2 stage
  local home=$1 stage=$2
  mkdir -p "$stage/home"
  # mirror semantics: remove files present in the old backup but no longer
  # collected (also when the current include list is empty)
  local -A want=() deref=() anc=()
  local -a plain=()
  local rel f a
  for rel in "${RICE_DEREF[@]}"; do deref["$rel"]=1; done
  for rel in "${RICE_INCLUDE[@]}"; do
    want["$rel"]=1
    [ -n "${deref[$rel]:-}" ] || plain+=("$rel")
  done
  # ancestors of every candidate must be REAL directories in the stage
  for rel in "${RICE_INCLUDE[@]}"; do
    a=$rel
    while [[ "$a" == */* ]]; do
      a=${a%/*}
      [ -n "${anc[$a]:-}" ] || anc["$a"]=1
    done
  done
  for a in "${!anc[@]}"; do
    f="$stage/home/$a"
    if { [ -e "$f" ] || [ -L "$f" ]; } && { [ ! -d "$f" ] || [ -L "$f" ]; }; then
      rm -f -- "$f"
    fi
  done
  # a candidate path that is a real DIRECTORY in the stage (old followed
  # content) but a file/link now must go before extraction
  for rel in "${RICE_INCLUDE[@]}"; do
    f="$stage/home/$rel"
    if [ -d "$f" ] && [ ! -L "$f" ]; then
      rm -rf -- "$f"
    fi
  done
  if [ ${#plain[@]} -gt 0 ]; then
    printf '%s\0' "${plain[@]}" \
      | tar -C "$home" --null -T - -cf - \
      | tar -C "$stage/home" -xpf -
  fi
  if [ ${#RICE_DEREF[@]} -gt 0 ]; then
    printf '%s\0' "${RICE_DEREF[@]}" \
      | tar -C "$home" --null -T - -h -cf - \
      | tar -C "$stage/home" -xpf -
  fi
  while IFS= read -r -d '' f; do
    rel=${f#"$stage/home"/}
    [ -n "${want[$rel]:-}" ] || rm -f -- "$f"
  done < <(find "$stage/home" \( -type f -o -type l \) -print0 2>/dev/null)
  find "$stage/home" -depth -type d -empty -exec rmdir -- {} \; 2>/dev/null || true
}

# copy /etc allowlist into staging (system section)
rice_stage_copy_etc() { # $1 stage
  local stage=$1 f
  [ ${#RICE_ETC_INCLUDE[@]} -gt 0 ] || return 0
  for f in "${RICE_ETC_INCLUDE[@]}"; do
    mkdir -p "$stage/system/etc/$(dirname -- "${f#/etc/}")"
    cp -a -- "$f" "$stage/system/etc/${f#/etc/}"
  done
}

# EXCLUDED.md / SKIPPED.md (names and rules only - never contents, never values)
rice_write_reports() { # $1 stage
  local stage=$1 i
  {
    printf '# Excluded by policy (names only - contents were never copied)\n\n'
    printf 'Generated: %s\n\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')\n"
    printf '## Hard deny list (L1)\n'
    if [ ${#RICE_DENIED[@]} -eq 0 ]; then printf '(none)\n'; fi
    for i in "${RICE_DENIED[@]}"; do printf -- '- %s [%s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
    printf '\n## Content scan hits (L2) - rule names only, values never stored\n'
    if [ ${#RICE_SCANHITS[@]} -eq 0 ]; then printf '(none)\n'; fi
    for i in "${RICE_SCANHITS[@]}"; do printf -- '- %s [%s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
    printf '\n## User excluded (--exclude-from selection)\n'
    if [ ${#RICE_USER_EXCL[@]} -eq 0 ]; then printf '(none)\n'; fi
    for i in "${RICE_USER_EXCL[@]}"; do printf -- '- %s [%s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
  } > "$stage/reports/EXCLUDED.md"
  {
    printf '# Skipped items\n\n'
    printf '## Files larger than %s\n' "$(rice_hr_size "$RICE_MAX_FILE_BYTES")"
    if [ ${#RICE_SKIPPED_BIG[@]} -eq 0 ]; then printf '(none)\n'; fi
    for i in "${RICE_SKIPPED_BIG[@]}"; do
      printf -- '- %s (%s)\n' "${i%%$'\t'*}" "$(rice_hr_size "${i#*$'\t'}")"
    done
    printf '\n## Caches and junk (L3)\n'
    if [ ${#RICE_SKIPPED_CACHE[@]} -eq 0 ]; then printf '(none)\n'; fi
    for i in "${RICE_SKIPPED_CACHE[@]}"; do printf -- '- %s\n' "$i"; done
  } > "$stage/reports/SKIPPED.md"
}

# symlinks.tsv (machine-readable, consumed by rice-restore.sh --relink) +
# reports/SYMLINKS.md (every link decision, names only). Followed links carry
# the raw target so the original layout can be recreated after a restore.
rice_write_symlinks() { # $1 stage
  local stage=$1 i
  {
    printf '# rel\traw_target\tcanonical_target\tkind\tfiles\tbytes\n'
    for i in "${RICE_LINKS[@]}"; do printf '%s\n' "$i"; done
  } > "$stage/symlinks.tsv"
  {
    printf '# Symlinks (followed, kept or excluded)\n\n'
    printf 'Generated: %s\n\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
    printf '## Followed - content fetched from the link target into the repo\n'
    if [ ${#RICE_LINKS[@]} -eq 0 ]; then printf '(none)\n'; fi
    local rel raw real kind n b
    for i in "${RICE_LINKS[@]}"; do
      IFS=$'\t' read -r rel raw real kind n b <<<"$i"
      printf -- '- %s -> %s (%s link, %s file(s), %s)\n' \
        "$rel" "$raw" "$kind" "$n" "$(rice_hr_size "${b:-0}")"
    done
    printf '\n## Kept as symlinks (target already inside the backup or not followable)\n'
    if [ ${#RICE_LINK_STATUS[@]} -eq 0 ]; then printf '(none)\n'; fi
    for i in "${RICE_LINK_STATUS[@]}"; do
      printf -- '- %s -> %s [%s: %s]\n' \
        "${i%%$'\t'*}" "$(printf '%s' "$i" | cut -f2)" \
        "$(printf '%s' "$i" | cut -f3)" "$(printf '%s' "$i" | cut -f4)"
    done
    printf '\nLinks whose target is deny-listed are listed in EXCLUDED.md with a\n'
    printf 'deny-target rule. rice-restore.sh --relink recreates followed links.\n'
  } > "$stage/reports/SYMLINKS.md"
}

# manifest.tsv (full metadata) + manifest.sha256 (sha256sum -c compatible)
# modes/sizes/targets come from the SOURCE side (RICE_META_INC) so they are
# true even if tar extraction is constrained by umask; hashes come from the
# staged copies (identical bytes). The walk runs INSIDE the stage directory:
# file operations below use ./-relative paths.
rice_make_manifest() { # $1 stage
  local stage=$1
  local -A meta=()
  local m rel
  for m in "${RICE_META_INC[@]}"; do
    rel=${m%%$'\t'*}
    meta["$rel"]=${m#*$'\t'}   # bytes<TAB>mode<TAB>type<TAB>target
  done
  : > "$stage/manifest.tsv"
  : > "$stage/manifest.sha256"
  (
    cd "$stage" || exit 1
    local f hrel bytes mode type target hash
    while IFS= read -r -d '' f; do
      rel=${f#./}                                   # repo-root relative
      hrel=${rel#home/}
      [ "$hrel" = "$rel" ] && hrel=""               # empty when not under home/
      if [ -L "$f" ]; then
        type=l; hash="-"
        if [ -n "$hrel" ] && [ -n "${meta[$hrel]:-}" ]; then
          IFS=$'\t' read -r bytes mode _t target <<<"${meta[$hrel]}"
        else
          bytes=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
          mode=$(stat -c %a -- "$f" 2>/dev/null || echo 777)
          target=$(readlink -- "$f")
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$hash" "$bytes" "$mode" "$type" "$target" "$rel" \
          >> "$stage/manifest.tsv"
      else
        type=f; target=""
        hash=$(sha256sum -- "$f" | cut -d' ' -f1)
        if [ -n "$hrel" ] && [ -n "${meta[$hrel]:-}" ]; then
          IFS=$'\t' read -r bytes mode _t _x _y <<<"${meta[$hrel]}"
        else
          bytes=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
          mode=$(stat -c %a -- "$f" 2>/dev/null || echo 644)
        fi
        printf '%s  %s\n' "$hash" "$rel" >> "$stage/manifest.sha256"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$hash" "$bytes" "$mode" "$type" "$target" "$rel" \
          >> "$stage/manifest.tsv"
      fi
    done < <(find . -path ./.git -prune -o \
        \( -type f -o -type l \) ! -name manifest.tsv ! -name manifest.sha256 \
        ! -name symlinks.tsv -print0 | sort -z)
  )
}

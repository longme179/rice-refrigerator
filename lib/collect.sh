# lib/collect.sh - selection, filtering and staging of rice files (rule R5/R6/R7)
# Exclusion layers, precedence L1 > L2 > L3 (see agent-state/PLAN.md section 5):
#   L1 hard deny (always wins) -> EXCLUDED.md
#   L2 content scan            -> EXCLUDED.md (rule name, never a value)
#   L3 hygiene: caches, >50MB  -> SKIPPED.md

RICE_MAX_FILE_BYTES=$((50 * 1024 * 1024))     # GitHub rejects >100MB; stay well below
RICE_TOTAL_WARN_BYTES=$((800 * 1024 * 1024))  # soft warning threshold

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
  RICE_SKIPPED_BIG=()    # "rel<TAB>bytes"
  RICE_SKIPPED_CACHE=()  # rel paths (or dir summaries)
  RICE_TOTAL_BYTES=0
  RICE_ETC_INCLUDE=()    # abs /etc paths staged under system/
  RICE_ETC_DENIED=()
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
    *.log) return 0 ;;
    *) return 1 ;;
  esac
}

# consider one relative path under $HOME for inclusion
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
    type=l
    target=$(readlink "$home/$rel") || target=""
    bytes=$(stat -c %s -- "$home/$rel" 2>/dev/null || echo 0)
    mode=$(stat -c %a -- "$home/$rel" 2>/dev/null || echo 777)
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
  local -A seen=()
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
      seen["$rel"]=1
    fi
  done
  # a few deny rules sit deeper than one level; probe them explicitly
  for rel in .var/app .gnome/keyrings .gnome2/keyrings .local/share/keyrings \
             .local/share/gopass .local/share/evolution .local/share/TelegramDesktop \
             .local/share/kwalletd; do
    [ -n "${seen[$rel]:-}" ] && continue
    if { [ -e "$home/$rel" ] || [ -L "$home/$rel" ]; } \
       && [ -n "$(rice_deny_rule_for "$rel")" ]; then
      rice_consider "$home" "$rel"
      seen["$rel"]=1
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
      [ -n "${seen[$rel]:-}" ] && continue
      seen["$rel"]=1
      rice_consider "$home" "$rel"
    done < <(find "$home/$d" \( -type f -o -type l \) -print0 2>/dev/null | sort -z)
  done
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

# copy the include list into the staging tree with one tar pipe (R5:
# read-only on originals, permissions and symlinks preserved)
rice_stage_copy() { # $1 home  $2 stage
  local home=$1 stage=$2
  mkdir -p "$stage/home"
  # mirror semantics: remove files present in the old backup but no longer
  # collected (also when the current include list is empty)
  local -A want=()
  local rel f
  for rel in "${RICE_INCLUDE[@]}"; do want["$rel"]=1; done
  if [ ${#RICE_INCLUDE[@]} -gt 0 ]; then
    printf '%s\0' "${RICE_INCLUDE[@]}" \
      | tar -C "$home" --null -T - -cf - \
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
        \( -type f -o -type l \) ! -name manifest.tsv ! -name manifest.sha256 -print0 | sort -z)
  )
}

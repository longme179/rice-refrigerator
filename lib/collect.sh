# lib/collect.sh - selection, filtering and staging of rice files (rule R5/R6/R7)
# Exclusion layers, precedence L1 > L2 > L3 (see agent-state/PLAN.md section 5):
#   L1 hard deny (always wins) -> EXCLUDED.md
#   L2 content scan            -> EXCLUDED.md (rule name, never a value)
#   L3 hygiene: caches, >50MB  -> SKIPPED.md

RICE_MAX_FILE_BYTES=$((50 * 1024 * 1024))     # default per-file cap (--file-cap / rules.conf [size] override)
RICE_TOTAL_WARN_BYTES=$((800 * 1024 * 1024))  # soft warning threshold
# hard budget: RESOLVED by rice_rules_apply (env RICE_TOTAL_MAX_BYTES > --budget
# > rules.conf [size] total_budget > default 1 GiB; --allow-oversize overrides)
RICE_TOTAL_MAX_BYTES="${RICE_TOTAL_MAX_BYTES:-}"

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

# ---- L1 hard core (D40, milestone R3): deny entries that can NEVER be re-included
# ---- via [allow]; everything else in L1 is soft (overridable with a warning).
# The stored deny REASONS keep their exact existing format ("deny-dir:.ssh"),
# so reports, the GUI adapter and the tests are untouched; hard/soft is derived
# on demand via rice_hard_rule_for.
RICE_DENY_HARD_DIRS=(
  .ssh .gnupg .gnome/keyrings .gnome2/keyrings .local/share/keyrings
  .local/share/kwalletd .password-store .config/gopass .local/share/gopass
  .pki .onepassword .config/1Password
  .aws .config/gcloud .azure .kube .config/kube .config/helm .docker .config/gh
  .mozilla .config/mozilla .local/share/mozilla .librewolf .waterfox .zen .floorp
  .config/google-chrome .config/google-chrome-beta .config/google-chrome-unstable
  .config/chromium .config/chromium-beta .config/BraveSoftware .config/vivaldi
  .config/Opera .config/opera .config/Microsoft-edge .config/librewolf
  .config/waterfox .config/ungoogled-chromium .var/app
  .thunderbird .config/evolution .local/share/evolution .local/share/TelegramDesktop
  .config/telegram-desktop .config/Signal .config/Element .config/discord
  .config/Keybase .config/Slack .config/zoomus .config/Zoom
)
RICE_DENY_HARD_GLOBS=(
  .netrc .netrc.gpg .git-credentials .pypirc .k5login
  .kdbx '*.kdbx' '*.kdb' '*.key' '*.pem' '*.p12' '*.pfx'
  '*id_rsa*' '*id_dsa*' '*id_ecdsa*' '*id_ed25519*'
)
declare -g -A RICE_DENY_HARD_DIR_SET=()
for _hd in "${RICE_DENY_HARD_DIRS[@]}"; do RICE_DENY_HARD_DIR_SET["$_hd"]=1; done
unset _hd
declare -g -A RICE_DENY_HARD_GLOB_SET=()
for _hg in "${RICE_DENY_HARD_GLOBS[@]}"; do RICE_DENY_HARD_GLOB_SET["$_hg"]=1; done
unset _hg

# prints the matching HARD rule (dir prefix or glob) for a rel path, or nothing
rice_hard_rule_for() { # $1 rel path
  local rel_l=${1,,} p g
  for p in "${RICE_DENY_HARD_DIRS[@]}"; do
    if [ "$rel_l" = "$p" ] || [[ "$rel_l" == "$p"/* ]]; then printf '%s' "$p"; return; fi
  done
  # shellcheck disable=SC2254  (g is intentionally used as a case pattern)
  for g in "${RICE_DENY_HARD_GLOBS[@]}"; do
    case "$rel_l" in
      $g) printf '%s' "$g"; return ;;
    esac
  done
  return 0
}

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

# ---- user rules (D38/D39/D42-size, milestone R2) ------------------------------
# Loaded from ~/.config/rice-backup/rules.conf (or --rules FILE / RICE_RULES
# env; --no-rules skips loading). Precedence everywhere: CLI flag > rules.conf
# > built-in default (one documented exception: env RICE_TOTAL_MAX_BYTES still
# wins for back-compat). [allow] and [ack-scan] land in milestones R3/R4.
RICE_EXTRA_FILES=()    # [include-file] + --include-file: extra top-level files
RICE_EXTRA_DIRS=()     # [include-dir]  + --include-dir : extra walked roots
RICE_SKIP_DIRS=()      # [skip-dir]     + --skip-dir    : default roots to drop
RICE_RULES_FILE=""     # resolved rules file ("" when none was loaded)
RICE_RULES_FILE_CAP="" # [size] file_cap
RICE_RULES_BUDGET=""   # [size] total_budget
declare -g -A RICE_ALLOW=()        # [allow] + --allow: path -> source
declare -g -A RICE_ALLOW_HIT=()   # allow entries that matched something
declare -g -A RICE_ROOT_SOURCE=()   # root/file -> default | rules.conf | flag

rice_rules_default_path() {
  printf '%s/.config/rice-backup/rules.conf' "${XDG_CONFIG_HOME:-${HOME:-.}/.config}"
}

# Validate one rules entry (also used by the repeatable flags): strips
# comments/whitespace, refuses absolute paths and `..`. Prints the cleaned
# entry and returns 0, or warns and returns 1.
rice_rules_clean_entry() { # $1 raw line
  local e=$1
  e=${e%%#*}
  e=${e#"${e%%[![:space:]]*}"}
  e=${e%"${e##*[![:space:]]}"}
  [ -n "$e" ] || return 1
  case "$e" in
    /*|*..*|.|'')
      rice_warn "rules entry ignored (must be a path relative to the home): $e"
      return 1
      ;;
  esac
  printf '%s' "$e"
}

# Parse a size value: plain bytes or N / NK / NM / NG (iB, base 1024), case
# insensitive. Prints the byte count and returns 0, or prints nothing.
rice_rules_parse_size() { # $1 raw value
  local v=${1//[[:space:]]/} n
  [ -n "$v" ] || return 1
  case "$v" in
    *[!0-9KkMmGgIiBb]*) return 1 ;;
  esac
  v=${v^^}
  case "$v" in
    *KIB) n=${v%KIB}; v=$((n * 1024)) ;;
    *MIB) n=${v%MIB}; v=$((n * 1048576)) ;;
    *GIB) n=${v%GIB}; v=$((n * 1073741824)) ;;
    *K)   n=${v%K};   v=$((n * 1024)) ;;
    *M)   n=${v%M};   v=$((n * 1048576)) ;;
    *G)   n=${v%G};   v=$((n * 1073741824)) ;;
  esac
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$v"
}

# Parse the rules file into the RICE_EXTRA_* / RICE_RULES_* globals. Unknown
# sections and the not-yet-available ones ([allow]/[ack-scan]) are warned and
# skipped - loading can never fail the run on its own.
rice_rules_load() { # $1 explicit file ("" = RICE_RULES env, then default path), $2 no_rules
  local file=$1 no=$2 line section="" e v key
  [ "$no" -eq 1 ] && return 0
  if [ -z "$file" ] && [ -n "${RICE_RULES:-}" ]; then file=$RICE_RULES; fi
  if [ -n "$file" ]; then
    if [ ! -f "$file" ]; then
      rice_warn "rules file not found: $file (continuing with defaults)"
      return 0
    fi
  else
    file=$(rice_rules_default_path)
    [ -f "$file" ] || return 0
  fi
  RICE_RULES_FILE=$file
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]*}"}
    [ -n "$line" ] || continue
    case "$line" in
      \[*)
        section=${line#[}; section=${section%]}; section=${section,,}
        ;;
      *=*)
        v=${line#*=}
        v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
        key=${line%%=*}
        key=${key#"${key%%[![:space:]]*}"}; key=${key%"${key##*[![:space:]]}"}
        if [ "$section" = "size" ]; then
          case "$key" in
            file_cap)
              if RICE_RULES_FILE_CAP=$(rice_rules_parse_size "$v"); then :; else
                rice_warn "invalid file_cap in rules (ignored): $v"
                RICE_RULES_FILE_CAP=""
              fi ;;
            total_budget)
              if RICE_RULES_BUDGET=$(rice_rules_parse_size "$v"); then :; else
                rice_warn "invalid total_budget in rules (ignored): $v"
                RICE_RULES_BUDGET=""
              fi ;;
            *) rice_warn "unknown [size] key ignored: $key" ;;
          esac
        else
          rice_warn "key=value line outside [size] ignored: $line"
        fi
        ;;
      *)
        e=$(rice_rules_clean_entry "$line") || continue
        case "$section" in
          include-file)
            RICE_EXTRA_FILES+=("$e")
            [ -n "${RICE_ROOT_SOURCE[$e]:-}" ] || RICE_ROOT_SOURCE["$e"]='rules.conf' ;;
          include-dir)
            RICE_EXTRA_DIRS+=("$e")
            [ -n "${RICE_ROOT_SOURCE[$e]:-}" ] || RICE_ROOT_SOURCE["$e"]='rules.conf' ;;
          skip-dir)
            RICE_SKIP_DIRS+=("$e") ;;
          allow)
            [ -n "${RICE_ALLOW[$e]:-}" ] || RICE_ALLOW["$e"]='rules.conf' ;;
          ack-scan)
            rice_warn "rules section [ack-scan] is not available yet (lands in milestone R4); entry ignored: $e" ;;
          *) rice_warn "unknown rules section ignored: [$section] (entry: $e)" ;;
        esac
        ;;
    esac
  done <"$file"
}

# Flag helpers (repeatable CLI options append with source=flag)
rice_rules_add_file() { local e; e=$(rice_rules_clean_entry "$1") || return 0
  RICE_EXTRA_FILES+=("$e"); RICE_ROOT_SOURCE["$e"]='flag'; }
rice_rules_add_dir() { local e; e=$(rice_rules_clean_entry "$1") || return 0
  RICE_EXTRA_DIRS+=("$e"); RICE_ROOT_SOURCE["$e"]='flag'; }
rice_rules_add_skip() { local e; e=$(rice_rules_clean_entry "$1") || return 0
  RICE_SKIP_DIRS+=("$e"); RICE_ROOT_SOURCE["$e"]='flag'; }
rice_rules_add_allow() { local e; e=$(rice_rules_clean_entry "$1") || return 0
  RICE_ALLOW["$e"]='flag'; }

# [allow] overrides (D40, milestone R3): re-include SOFT-denied entries as
# fresh candidates (cache/size/scan still apply to them); HARD-CORE matches
# are REFUSED with the rule named and stay denied. Runs right after the walk
# and BEFORE the content scan, so the scanner still guards every rescued file.
rice_apply_allow_overrides() { # $1 home
  [ ${#RICE_ALLOW[@]} -gt 0 ] || return 0
  local home=$1 keep=() rec rel rule a hit hard f raw real
  local TBTAB
  TBTAB=$(printf '\t')
  for rec in "${RICE_DENIED[@]}"; do
    rel=${rec%%"$TBTAB"*}; rule=${rec#*"$TBTAB"}
    hit=""
    for a in "${!RICE_ALLOW[@]}"; do
      if [ "$rel" = "$a" ] || [[ "$rel" == "$a"/* ]]; then hit=$a; break; fi
    done
    if [ -z "$hit" ]; then keep+=("$rec"); continue; fi
    RICE_ALLOW_HIT["$hit"]=1
    hard=$(rice_hard_rule_for "$rel")
    if [ -n "$hard" ]; then
      rice_warn "allow refused (hard core, never overridable): $rel [$rule]"
      keep+=("$rec")
      continue
    fi
    RICE_ALLOWED+=("$rel"$'\t'"$rule")
    rice_warn "deny overridden via [allow]: $rel [$rule]"
    if [ -L "$home/$rel" ]; then
      # rescued symlink: decide it through the normal D37 resolver
      raw=$(readlink -- "$home/$rel" 2>/dev/null) || raw=""
      real=$(readlink -f -- "$home/$rel" 2>/dev/null) || true
      [ -n "$real" ] && [ ! -e "$real" ] && real=""
      rice_resolve_one_link "$home" "$rel" "$raw" "$real"
    elif [ -d "$home/$rel" ]; then
      # rescued directory (e.g. a soft deny-dir): walk it fresh - children
      # still go through every layer, so only individually-allowed files pass
      while IFS= read -r -d '' f; do
        [ -n "${RICE_SEEN[${f#"$home"/}]:-}" ] && continue
        rice_consider "$home" "${f#"$home"/}"
      done < <(find "$home/$rel" \( -type f -o -type l \) -print0 2>/dev/null)
    else
      rice_consider "$home" "$rel" 1
    fi
  done
  RICE_DENIED=("${keep[@]}")
  local n=0
  for a in "${!RICE_ALLOW[@]}"; do
    [ -n "${RICE_ALLOW_HIT[$a]:-}" ] || { rice_warn "allow entry matched no denied item: $a"; n=$((n+1)); }
  done
  rice_info "deny overrides applied: ${#RICE_ALLOWED[@]} item(s) re-included"
}

# Apply the loaded rules + flags: resolve the caps, merge extra and skipped
# roots into the include arrays (with per-entry sources for --show-rules),
# refuse impossible values. MUST run before the walk, --show-rules and
# --explain. Refusals: cap above GitHub's 100 MiB; deny-listed include-roots
# (no root can ever bypass L1).
rice_rules_apply() { # $1 home
  local home=$1 r d f found rule dup keep
  # mark the built-in entries so --show-rules can attribute every line
  for d in "${RICE_HOME_DIRS[@]}"; do
    [ -n "${RICE_ROOT_SOURCE[$d]:-}" ] || RICE_ROOT_SOURCE["$d"]='default'
  done
  for f in "${RICE_HOME_FILES[@]}"; do
    [ -n "${RICE_ROOT_SOURCE[$f]:-}" ] || RICE_ROOT_SOURCE["$f"]='default'
  done
  # ---- caps (flag > rules.conf > default; env RICE_TOTAL_MAX_BYTES wins)
  if [ -n "${RICE_FLAG_FILE_CAP:-}" ]; then
    RICE_MAX_FILE_BYTES=$RICE_FLAG_FILE_CAP
  elif [ -n "$RICE_RULES_FILE_CAP" ]; then
    RICE_MAX_FILE_BYTES=$RICE_RULES_FILE_CAP
  fi
  if [ "$RICE_MAX_FILE_BYTES" -gt $((100 * 1024 * 1024)) ]; then
    rice_die "file cap $(rice_hr_size "$RICE_MAX_FILE_BYTES") exceeds GitHub's 100 MiB per-file limit - refusing (the push would fail)" 2
  fi
  if [ -n "${RICE_TOTAL_MAX_BYTES:-}" ]; then
    :                                     # env wins (back-compat, tests rely on it)
  elif [ -n "${RICE_FLAG_BUDGET:-}" ]; then
    RICE_TOTAL_MAX_BYTES=$RICE_FLAG_BUDGET
  elif [ -n "$RICE_RULES_BUDGET" ]; then
    RICE_TOTAL_MAX_BYTES=$RICE_RULES_BUDGET
  else
    RICE_TOTAL_MAX_BYTES=$((1024 * 1024 * 1024))
  fi
  # ---- [skip-dir]: remove matching default roots from the walk entirely
  for r in "${RICE_SKIP_DIRS[@]}"; do
    found=0; keep=()
    for d in "${RICE_HOME_DIRS[@]}"; do
      if [ "$d" = "$r" ]; then found=1; else keep+=("$d"); fi
    done
    if [ "$found" = 1 ]; then
      RICE_HOME_DIRS=("${keep[@]}")
      rice_info "include root skipped (rules): $r"
    else
      rice_warn "skip-dir entry is not a default include root: $r"
    fi
  done
  # ---- [include-dir]: extra walked roots (deny-listed roots refused)
  for r in "${RICE_EXTRA_DIRS[@]}"; do
    rule=$(rice_deny_rule_for "$r")
    if [ -n "$rule" ]; then
      rice_warn "include-dir entry refused (deny-listed): $r [$rule]"
      continue
    fi
    dup=0
    for d in "${RICE_HOME_DIRS[@]}"; do [ "$d" = "$r" ] && dup=1; done
    [ "$dup" = 1 ] && continue
    if [ ! -d "$home/$r" ] && [ ! -L "$home/$r" ]; then
      rice_warn "include-dir entry does not exist in the home: $r"
      continue
    fi
    RICE_HOME_DIRS+=("$r")
  done
  # ---- [include-file]: extra top-level files
  for r in "${RICE_EXTRA_FILES[@]}"; do
    dup=0
    for f in "${RICE_HOME_FILES[@]}"; do [ "$f" = "$r" ] && dup=1; done
    [ "$dup" = 1 ] && continue
    if [ ! -e "$home/$r" ] && [ ! -L "$home/$r" ]; then
      rice_warn "include-file entry does not exist in the home: $r"
      continue
    fi
    RICE_HOME_FILES+=("$r")
  done
}

# ------------------------------------------------------------------ state
rice_collect_init() {
  RICE_INCLUDE=()        # rel paths that will be staged
  RICE_META_INC=()       # "rel<TAB>bytes<TAB>mode<TAB>type<TAB>target"
  RICE_DENIED=()         # "rel<TAB>rule"
  RICE_ALLOWED=()        # "rel<TAB>rule" (rescued via [allow], D40/R3)
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
# $3 = 1 skips the L1 deny check (used ONLY by the [allow] rescue pass - the
# rescue itself already verified the rule is SOFT; every other layer still
# applies below).
rice_consider() { # $1 home  $2 rel path  $3 nodeny (1 = [allow] rescue)
  local home=$1 rel=$2
  local rule
  if [ "${3:-0}" != "1" ]; then
    rule=$(rice_deny_rule_for "$rel")
    if [ -n "$rule" ]; then
      RICE_DENIED+=("$rel"$'\t'"$rule")
      return
    fi
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

# EXCLUDED.md / SKIPPED.md / ALLOWED.md (names and rules only - never contents, never values)
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
    printf '# Deny overrides ([allow], names only)\n\n'
    printf 'Generated: %s\n\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')\n"
    printf 'These entries were re-included by an explicit [allow] rule after being\n'
    printf 'denied by a SOFT deny rule. Every other layer (content scan, cache skip,\n'
    printf 'per-file cap, budget) still applied to them. Hard-core entries can never\n'
    printf 'appear here.\n\n'
    if [ ${#RICE_ALLOWED[@]} -eq 0 ]; then printf '(none)\n'; fi
    for i in "${RICE_ALLOWED[@]}"; do printf -- '- %s [was: %s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
  } > "$stage/reports/ALLOWED.md"
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

# ---- diagnostics (D42, milestone R1): offline, read-only ---------------------

# Is a home-relative path inside the regions the walk considers at all?
# (a RICE_HOME_FILES entry, anything under a RICE_HOME_DIRS root, or inside a
# region fetched via a followed link). --explain uses this to distinguish
# "decided against" from "never was a candidate".
rice_path_walked() { # $1 rel path -> 0 when considered by the walk
  local rel=$1 p
  for p in "${RICE_HOME_FILES[@]}"; do
    [ "$rel" = "$p" ] && return 0
  done
  for p in "${RICE_HOME_DIRS[@]}"; do
    if [ "$rel" = "$p" ] || [[ "$rel" == "$p"/* ]]; then return 0; fi
  done
  for p in "${RICE_COVERED_REL[@]}"; do
    if [ -n "$p" ] && { [ "$rel" = "$p" ] || [[ "$rel" == "$p"/* ]]; }; then return 0; fi
  done
  return 1
}

# --show-rules: print the effective rule set. No walk, no auth, no repo. The
# output is section-stable so tests (and later the GUI) can parse it. Per-entry
# source marks (default / rules.conf / flag) and hard/soft deny marks are added
# by the milestones that introduce them (R2 / R3).
rice_show_rules() {
  local i
  printf '=== rice-backup effective rules ===\n'
  printf 'version     : %s\n' "$RICE_VERSION"
  if [ -n "$RICE_RULES_FILE" ]; then
    printf 'rules file  : %s (loaded)\n' "$RICE_RULES_FILE"
  else
    printf 'rules file  : (none - defaults only; create %s to customize)\n' "$(rice_rules_default_path)"
  fi
  printf 'file cap    : %s per file (GitHub rejects files >100 MiB)\n' \
    "$(rice_hr_size "$RICE_MAX_FILE_BYTES")"
  printf 'total budget: %s (a real run above it needs --allow-oversize)\n' \
    "$(rice_hr_size "$RICE_TOTAL_MAX_BYTES")"
  printf 'symlinks    : follow=%s outside-home=%s\n' \
    "${RICE_FOLLOW:-1}" "${RICE_FOLLOW_OUTSIDE:-0}"
  printf '\ninclude files (top-level, exact name under the home):\n'
  if [ ${#RICE_HOME_FILES[@]} -eq 0 ]; then printf '  (none)\n'; fi
  for i in "${RICE_HOME_FILES[@]}"; do
    printf '  %-30s (%s)\n' "$i" "${RICE_ROOT_SOURCE[$i]:-default}"
  done
  printf '\ninclude dirs (walked recursively):\n'
  if [ ${#RICE_HOME_DIRS[@]} -eq 0 ]; then printf '  (none)\n'; fi
  for i in "${RICE_HOME_DIRS[@]}"; do
    printf '  %-30s (%s)\n' "$i" "${RICE_ROOT_SOURCE[$i]:-default}"
  done
  if [ ${#RICE_SKIP_DIRS[@]} -gt 0 ]; then
    printf '\nskipped include roots ([skip-dir], not walked at all):\n'
    for i in "${RICE_SKIP_DIRS[@]}"; do
      printf '  %-30s (%s)\n' "$i" "${RICE_ROOT_SOURCE[$i]:-rules.conf}"
    done
  fi
  printf '\ndeny dirs (L1, path prefixes; hard = never overridable via [allow]):\n'
  for i in "${RICE_DENY_DIRS[@]}"; do
    if [ -n "${RICE_DENY_HARD_DIR_SET[${i,,}]:-}" ]; then
      printf '  %-30s (hard)\n' "$i"
    else
      printf '  %-30s (soft)\n' "$i"
    fi
  done
  printf '\ndeny file globs (L1, matched against the whole path):\n'
  for i in "${RICE_DENY_GLOBS[@]}"; do
    if [ -n "${RICE_DENY_HARD_GLOB_SET[${i,,}]:-}" ]; then
      printf '  %-30s (hard)\n' "$i"
    else
      printf '  %-30s (soft)\n' "$i"
    fi
  done
  if [ ${#RICE_ALLOW[@]} -gt 0 ]; then
    printf '\nallow overrides ([allow]/--allow, soft rules only):\n'
    for i in "${!RICE_ALLOW[@]}"; do
      printf '  %-30s (%s)\n' "$i" "${RICE_ALLOW[$i]}"
    done
  fi
  printf '\ncache/junk patterns (L3): .cache/**, */cache|Cache|caches/**,\n'
  printf '  node_modules, __pycache__, .npm, .git, Trash, .config/fcitx/dbus, *.log\n'
  printf '\n/etc allowlist (only with --include-system):\n'
  for i in "${RICE_ETC_FILES[@]}" "${RICE_ETC_GLOBS[@]}"; do printf '  %s\n' "$i"; done
  printf '\nnotes: deny rules are NAME-based. --explain PATH reports which layer\n'
  printf 'and rule claims any given path.\n'
}

# --explain: verdict chain for the given paths, or a full bucket dump when no
# path is given. Runs AFTER collection, content scan and user selection, so
# every bucket reflects exactly what a real run would decide. Read-only; the
# caller exits right after. Buckets are disjoint by construction, so the first
# match wins and the order of the lookups is only presentation.
rice_explain() { # $1 home; $2... paths ("" = dump every bucket)
  local home=$1; shift
  local p rel i verdict layer rule
  printf '=== rice-backup explain ===\n'
  printf 'home : %s\n' "$home"
  if [ "$#" -gt 0 ]; then
    for p in "$@"; do
      rel=$p
      case "$rel" in
        "$home"/*) rel=${rel#"$home"/} ;;
        /*)
          printf '%s\n      verdict  : not explainable\n' "$p"
          printf '      rule     : absolute path outside the home\n'
          continue
          ;;
      esac
      case "$rel" in
        *..*|.|'')
          printf '%s\n      verdict  : not explainable\n' "$p"
          printf '      rule     : path must be home-relative without ..\n'
          continue
          ;;
      esac
      verdict=""; layer=""; rule=""
      for i in "${RICE_ALLOWED[@]}"; do
        [ "${i%%$'\t'*}" = "$rel" ] || continue
        verdict=included; layer='candidate'
        rule="passes every layer; will be staged (rescued via [allow], was: ${i#*$'\t'}})"
        break
      done
      [ -n "$verdict" ] || for i in "${RICE_DENIED[@]}"; do
        [ "${i%%$'\t'*}" = "$rel" ] || continue
        verdict=excluded; layer='L1 deny'; rule=${i#*$'\t'}; break
      done
      [ -n "$verdict" ] || for i in "${RICE_SCANHITS[@]}"; do
        [ "${i%%$'\t'*}" = "$rel" ] || continue
        verdict=excluded; layer='L2 scan'; rule="scan:${i#*$'\t'}"; break
      done
      [ -n "$verdict" ] || for i in "${RICE_USER_EXCL[@]}"; do
        [ "${i%%$'\t'*}" = "$rel" ] || continue
        verdict=excluded; layer='selection'; rule='--exclude-from entry'; break
      done
      [ -n "$verdict" ] || for i in "${RICE_SKIPPED_BIG[@]}"; do
        [ "${i%%$'\t'*}" = "$rel" ] || continue
        verdict=skipped; layer='size cap'
        rule="larger than $(rice_hr_size "$RICE_MAX_FILE_BYTES") ($(rice_hr_size "${i#*$'\t'}"))"
        break
      done
      [ -n "$verdict" ] || for i in "${RICE_SKIPPED_CACHE[@]}"; do
        [ "$i" = "$rel" ] || [ "$i" = "$rel/" ] || [ "$i" = "$rel (stat failed)" ] || continue
        verdict=skipped; layer='L3 cache'; rule='cache/junk path pattern'; break
      done
      [ -n "$verdict" ] || for i in "${RICE_LINK_STATUS[@]}"; do
        [ "${i%%$'\t'*}" = "$rel" ] || continue
        verdict=included; layer='symlink'
        rule="kept as link: $(printf '%s' "$i" | cut -f3): $(printf '%s' "$i" | cut -f4)"
        break
      done
      [ -n "$verdict" ] || for i in "${RICE_LINKS[@]}"; do
        [ "${i%%$'\t'*}" = "$rel" ] || continue
        verdict=included; layer='symlink'; rule='followed: target content fetched'; break
      done
      [ -n "$verdict" ] || for i in "${RICE_INCLUDE[@]}"; do
        [ "$i" = "$rel" ] || continue
        verdict=included; layer='candidate'; rule='passes every layer; will be staged'; break
      done
      printf '%s\n' "$rel"
      if [ -n "$verdict" ]; then
        printf '      verdict  : %s\n' "$verdict"
        printf '      layer    : %s\n' "$layer"
        printf '      rule     : %s\n' "$rule"
        if [ "$layer" = 'L1 deny' ]; then
          if [ -n "$(rice_hard_rule_for "$rel")" ]; then
            printf '      override : HARD CORE - never overridable via [allow]\n'
          else
            printf '      override : soft rule - [allow] can re-include it\n'
          fi
        fi
      elif [ ! -e "$home/$rel" ] && [ ! -L "$home/$rel" ]; then
        printf '      verdict  : not found\n'
        printf '      layer    : -\n'
        printf '      rule     : no such file or symlink in the home\n'
      elif rice_path_walked "$rel"; then
        printf '      verdict  : not collected\n'
        printf '      layer    : walk\n'
        printf '      rule     : only files and symlinks are collected (directory or special?)\n'
      else
        printf '      verdict  : not considered\n'
        printf '      layer    : include roots\n'
        printf '      rule     : outside every include root (see --show-rules)\n'
      fi
    done
  else
    printf 'included candidates : %s file(s), %s\n' "${#RICE_INCLUDE[@]}" "$(rice_hr_size "$RICE_TOTAL_BYTES")"
    printf 'followed symlinks   : %s\n' "${#RICE_LINKS[@]}"
    printf 'kept symlinks       : %s\n' "${#RICE_LINK_STATUS[@]}"
    printf '\nexcluded:\n'
    printf '  L1 deny      : %s item(s)\n' "${#RICE_DENIED[@]}"
    for i in "${RICE_DENIED[@]}"; do printf '    %s [%s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
    printf '  L2 scan      : %s item(s)\n' "${#RICE_SCANHITS[@]}"
    for i in "${RICE_SCANHITS[@]}"; do printf '    %s [%s]\n' "${i%%$'\t'*}" "${i#*$'\t'}"; done
    printf '  selection    : %s item(s)\n' "${#RICE_USER_EXCL[@]}"
    for i in "${RICE_USER_EXCL[@]}"; do printf '    %s [--exclude-from]\n' "${i%%$'\t'*}"; done
    printf '\nskipped:\n'
    printf '  size cap     : %s item(s)\n' "${#RICE_SKIPPED_BIG[@]}"
    for i in "${RICE_SKIPPED_BIG[@]}"; do printf '    %s (%s)\n' "${i%%$'\t'*}" "$(rice_hr_size "${i#*$'\t'}")"; done
    printf '  L3 cache     : %s item(s)\n' "${#RICE_SKIPPED_CACHE[@]}"
    for i in "${RICE_SKIPPED_CACHE[@]}"; do printf '    %s\n' "$i"; done
  fi
}

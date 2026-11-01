#!/usr/bin/env bash
# tests/run-tests.sh - rice-backup acceptance suite (PLAN section 8, T01..T20).
#
# Self-contained: builds a temp workspace, a fixture $HOME (tests/fixtures/home,
# built by tests/fixtures/build.sh), PATH-mocked package managers and a local
# bare repository as the push target (RICE_TEST_GIT_BASE=file://...).
# No network access is needed or used; all canary "secrets" are FAKE
# (tests/canaries.txt).
#
# Usage: bash tests/run-tests.sh   (exit 0 = all assertions passed)
set -u
export LC_ALL=C

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures"
MOCKS="$FIXTURES/mocks"
MOCKS_MIN="$FIXTURES/mocks-min"
CANARIES="$ROOT/tests/canaries.txt"
SCANNER="$ROOT/scripts/secret-scan.sh"
ORIG_PATH="$PATH"

SUITE=$(mktemp -d /tmp/rice-suite.XXXXXX) || exit 2
RESULTS="$SUITE/results.tsv"
: > "$RESULTS"

# The canary fixture (tests/fixtures/home) and tests/canaries.txt are
# generated at runtime and never committed (GitHub push protection rejects
# token-shaped data even when it is fake). Build them if they are missing.
if [ ! -f "$CANARIES" ] || [ ! -e "$FIXTURES/home/.config/weird/github-pat" ] \
   || [ ! -e "$FIXTURES/home/.config/mozilla/firefox/xyz.default-release/cookies.sqlite" ]; then
  printf 'building runtime fixtures (tests/fixtures/build.sh)...\n'
  bash "$FIXTURES/build.sh" >/dev/null || { printf 'fixture build failed\n' >&2; exit 2; }
fi

ok()  { printf 'ok\t%s\n' "$1" >> "$RESULTS"; printf '  ok   %s\n' "$1"; }
bad() { printf 'FAIL\t%s\n' "$1" >> "$RESULTS"; printf '  FAIL %s\n' "$1"; }
info(){ printf '  ...  %s\n' "$1"; }

assert_eq()      { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got [$2] want [$3])"; }
assert_rc()      { [ "$2" -eq "$3" ] && ok "$1" || bad "$1 (rc=$2 want $3)"; }
assert_match()   { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || bad "$1 (missing: $3)"; }
assert_match_re(){ printf '%s' "$2" | grep -qE -- "$3" && ok "$1" || bad "$1 (regex: $3)"; }
assert_no_match(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected: $3)"; else ok "$1"; fi; }
assert_file()    { [ -e "$2" ] && ok "$1" || bad "$1 (missing: $2)"; }
assert_nofile()  { [ ! -e "$2" ] && ok "$1" || bad "$1 (unexpected: $2)"; }
assert_is_link() { [ -L "$2" ] && ok "$1" || bad "$1 (not a symlink: $2)"; }
assert_mode()    { [ "$(stat -c %a "$2" 2>/dev/null)" = "$3" ] && ok "$1" || bad "$1 ($(stat -c %a "$2" 2>/dev/null) want $3)"; }
assert_file_match() { assert_match "$1" "$(cat "$2" 2>/dev/null)" "$3"; }

# per-test environment ---------------------------------------------------------
setup_env() { # $1 distro family, $2 mocks dir (default $MOCKS)
  export RICE_TEST_DISTRO=$1
  export RICE_TEST_GIT_BASE="file://$TW/remote-base"
  export RICE_TOKEN="fake-test-token-abcdefghijklmnop"
  export RICE_SCAN_EXACT="RICECANARYEXACTSECRETVALUE42"
  export MOCK_STATE="$TW/state"
  mkdir -p "$MOCK_STATE"
  export PATH="${2:-$MOCKS}:$ORIG_PATH"
  umask 022
}
make_home() { # $1 dest - fixture + runtime 60 MiB sparse size-cap file
  cp -a "$FIXTURES/home/." "$1/"
  truncate -s 62914560 "$1/.config/bigapp/data.bin"
}
make_remote() { # $1 owner/name
  mkdir -p "$TW/remote-base/${1%/*}"
  git init -q --bare -b main "$TW/remote-base/$1.git"
}
backup() { bash "$ROOT/bin/rice-backup.sh" "$@" 2>&1; }
restore() { bash "$ROOT/bin/rice-restore.sh" "$@" 2>&1; }
revcount() { git -C "$1" rev-list --all --count; }
canaries_absent() { # $1 dir: no canary value may appear anywhere in it
  if grep -rIF --exclude-dir=.git -f "$CANARIES" "$1" >/dev/null 2>&1; then
    bad "no canary value leaked into $1"
  else
    ok "no canary value leaked into $1"
  fi
}

# --------------------------------------------------------------------- tests
t01() { # AC-11 scanner rules: every rule fires, values never printed
  TW=$SUITE/t01; mkdir -p "$TW/corpus" "$TW/clean"
  # corpus values come from the canonical canary list (built by
  # tests/fixtures/build.sh) so fixture, list and corpus can never drift
  mapfile -t CAN < "$CANARIES"
  printf '%s\n' "${CAN[0]}"  > "$TW/corpus/gh-classic"
  printf '%s\n' "${CAN[1]}"  > "$TW/corpus/gh-fine-grained"
  printf '%s\n' "${CAN[2]}"  > "$TW/corpus/gh-classic-2"
  printf '%s\n' "${CAN[3]}"  > "$TW/corpus/aws-access-key"
  printf 'aws_secret_access_key = %s\n' "${CAN[4]}" > "$TW/corpus/aws-secret"
  printf '%s\n' "${CAN[5]}"  > "$TW/corpus/google-api-key"
  printf '%s\n' "${CAN[6]}"  > "$TW/corpus/slack-token"
  printf '%s\n' "${CAN[7]}"  > "$TW/corpus/stripe-live-key"
  printf 'jwt %s\n' "${CAN[8]}" > "$TW/corpus/jwt"
  printf 'Authorization: Bearer %s\n' "${CAN[9]}" > "$TW/corpus/bearer-token"
  printf 'token = %s\n' "${CAN[10]}" > "$TW/corpus/cred-assign"
  printf 'see https://%s@example.com/endpoint\n' "${CAN[11]}" > "$TW/corpus/url-creds"
  printf 'value %s here\n' "${CAN[12]}" > "$TW/corpus/exact"
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nbody\n' > "$TW/corpus/private-key"
  out=$(RICE_SCAN_EXACT="${CAN[12]}" bash "$SCANNER" files "$TW"/corpus/* 2>/dev/null); rc=$?
  assert_rc "t01 scanner flags corpus (rc)" "$rc" 1
  local r
  for r in gh-classic gh-fine-grained private-key aws-access-key aws-secret-label \
           google-api-key slack-token stripe-live-key jwt bearer-token cred-assign \
           url-embedded-creds exact; do
    assert_match "t01 rule detected: $r" "$out" "$(printf 'HIT\t%s' "$r")"
  done
  local v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    assert_no_match "t01 value never printed" "$out" "$v"
  done < "$CANARIES"
  printf 'password=changeme\ntoken = $X\nsecret: placeholder\n' > "$TW/clean/ok"
  printf 'nothing interesting here\n' > "$TW/clean/plain"
  out=$(bash "$SCANNER" files "$TW"/clean/* 2>/dev/null); rc=$?
  assert_rc "t01 clean corpus passes" "$rc" 0
}

t02() { # AC-12 exact-needle mode
  TW=$SUITE/t02; mkdir -p "$TW"
  printf 'needle fakeexactneedle42 present\n' > "$TW/f1"
  printf 'clean\n' > "$TW/f2"
  out=$(RICE_SCAN_EXACT=fakeexactneedle42 bash "$SCANNER" files "$TW/f1" "$TW/f2" 2>/dev/null); rc=$?
  assert_rc "t02 exact hit rc" "$rc" 1
  assert_match "t02 exact rule reported" "$out" "$(printf 'HIT\texact\t%s' "$TW/f1")"
  assert_no_match "t02 needle value never printed" "$out" "fakeexactneedle42"
  out=$(bash "$SCANNER" files "$TW/f1" 2>/dev/null); rc=$?
  assert_rc "t02 without exact env -> clean" "$rc" 0
}

t03() { # AC-19 (partial) git + history modes, expect-list semantics
  TW=$SUITE/t03; mkdir -p "$TW/repo"
  git init -q -b main "$TW/repo"
  ( cd "$TW/repo" || exit 1
    mkdir -p canaries
    printf 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' > canaries/gh
    printf 'x\n' > plain.txt
    git add -A && git -c user.name=t -c user.email=t@t commit -q -m c1
    out=$(bash "$SCANNER" git HEAD 2>/dev/null); rc=$?
    assert_rc "t03 git mode flags canary" "$rc" 1
    printf 'canaries/\n' > "$TW/expect"
    out=$(bash "$SCANNER" --expect "$TW/expect" git HEAD 2>/dev/null); rc=$?
    assert_rc "t03 expect list -> expected-only rc" "$rc" 0
    assert_match "t03 EXPECTED reported, not HIT" "$out" "$(printf 'EXPECTED\tgh-classic\tcanaries/gh')"
    printf 'y\n' >> plain.txt
    git add -A && git -c user.name=t -c user.email=t@t commit -q -m c2
    out=$(bash "$SCANNER" --expect "$TW/expect" history 2>/dev/null); rc=$?
    assert_rc "t03 history expected-only rc" "$rc" 0
    out=$(bash "$SCANNER" history 2>/dev/null); rc=$?
    assert_rc "t03 history without expect rc" "$rc" 1
  )
}

t04() { # AC-01/04 dry-run summary, deny list by rule, names only, remote untouched
  TW=$SUITE/t04; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  out=$(backup --home "$TW/home" --repo test/backup --dry-run); rc=$?
  assert_rc "t04 dry-run rc" "$rc" 0
  assert_match "t04 dry-run states no changes" "$out" "dry-run complete"
  assert_match "t04 summary header" "$out" "rice-backup dry-run summary"
  assert_match "t04 upload lists .bashrc" "$out" "    .bashrc"
  assert_match "t04 placeholders file included" "$out" "    .config/dummy/placeholders"
  assert_match "t04 deny .ssh by rule" "$out" "- .ssh [deny-dir:.ssh]"
  assert_match "t04 deny kdbx by rule" "$out" "Notes.kdbx [deny-file:*.kdbx]"
  assert_match "t04 deny .var/app" "$out" "- .var/app [deny-dir:.var/app]"
  assert_match "t04 deny browser profile" "$out" "- .mozilla [deny-dir:.mozilla]"
  assert_match "t04 deny .env" "$out" "- .env [deny-file:.env]"
  assert_match "t04 deny history glob" "$out" "- .bash_history [deny-file:.bash_history]"
  assert_match "t04 scan hit cred-assign" "$out" "- .config/myapp/token.ini [cred-assign]"
  assert_match "t04 scan hit fine-grained pat" "$out" "- .config/weird/github-pat [gh-fine-grained]"
  assert_match "t04 scan hit exact needle" "$out" "- .config/misc/notes.txt [exact]"
  assert_match "t04 oversized listed with size" "$out" ".config/bigapp/data.bin (60 MiB)"
  assert_match "t04 cache dir listed" "$out" "- .cache/"
  # session 3: Firefox XDG profile (.config/mozilla) must be denied wholesale
  assert_match "t04 deny XDG firefox profile by rule" "$out" \
    "- .config/mozilla/firefox/xyz.default-release/cookies.sqlite [deny-dir:.config/mozilla]"
  assert_match "t04 deny zen profile" "$out" "- .zen [deny-dir:.zen]"
  assert_no_match "t04 XDG firefox files never in upload list" "$out" "    .config/mozilla/"
  assert_match "t04 fcitx dbus runtime junk skipped" "$out" "- .config/fcitx/dbus/9f61c0ffee0000-0"
  assert_match "t04 auth mode recorded" "$out" "auth       : gh"
  assert_match "t04 largest candidates section" "$out" "largest candidates (top 15 by size)"
  assert_match_re "t04 largest lists small.bin with size" "$out" '100 KiB +\.config/bigapp/small\.bin$'
  assert_match_re "t04 per-section bytes shown" "$out" '\.config/\*\* +: [0-9]+ file\(s\), [0-9]+ [KMG]iB'
  assert_eq "t04 remote untouched" "$(revcount "$TW/remote-base/test/backup.git")" "0"
  local v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    assert_no_match "t04 value not in output" "$out" "$v"
  done < "$CANARIES"
  out2=$(backup --home "$TW/home" --repo test/backup --dry-run --include-system); rc=$?
  assert_rc "t04 include-system dry-run rc" "$rc" 0
  assert_match_re "t04 /etc allowlist counted" "$out2" '/etc allowlist +: [1-9][0-9]* file'
}

t05() { # AC-01 dry-run leaves an EXISTING remote untouched
  TW=$SUITE/t05; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  out=$(backup --home "$TW/home" --repo test/backup --yes); rc=$?
  assert_rc "t05 first full backup rc" "$rc" 0
  assert_eq "t05 remote has 1 commit" "$(revcount "$TW/remote-base/test/backup.git")" "1"
  out=$(backup --home "$TW/home" --repo test/backup --dry-run); rc=$?
  assert_rc "t05 dry-run rc" "$rc" 0
  assert_eq "t05 remote still 1 commit" "$(revcount "$TW/remote-base/test/backup.git")" "1"
}

t06() { # AC-02/03/04/05/06/07 full backup: push, canaries absent, reports, manifest
  TW=$SUITE/t06; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  out=$(backup --home "$TW/home" --repo test/backup --yes); rc=$?
  assert_rc "t06 backup rc" "$rc" 0
  assert_match "t06 push happened" "$out" "backup pushed: commit"
  REMOTE="$TW/remote-base/test/backup.git"
  assert_eq "t06 exactly one new commit" "$(revcount "$REMOTE")" "1"
  git clone -q "$REMOTE" "$TW/clone"
  assert_file "t06 .bashrc in backup" "$TW/clone/home/.bashrc"
  assert_file "t06 placeholders included" "$TW/clone/home/.config/dummy/placeholders"
  assert_file "t06 100KiB file included" "$TW/clone/home/.config/bigapp/small.bin"
  assert_file "t06 space-named file included" "$TW/clone/home/.config/my dir/my file.conf"
  assert_is_link "t06 .vimrc symlink preserved" "$TW/clone/home/.vimrc"
  assert_mode "t06 myscript executable" "$TW/clone/home/.local/bin/myscript" 755
  assert_nofile "t06 .ssh absent" "$TW/clone/home/.ssh"
  assert_nofile "t06 .gnupg absent" "$TW/clone/home/.gnupg"
  assert_nofile "t06 .aws absent" "$TW/clone/home/.aws"
  assert_nofile "t06 .env absent" "$TW/clone/home/.env"
  assert_nofile "t06 .netrc absent" "$TW/clone/home/.netrc"
  assert_nofile "t06 gh config absent" "$TW/clone/home/.config/gh"
  assert_nofile "t06 docker config absent" "$TW/clone/home/.docker"
  assert_nofile "t06 kdbx absent" "$TW/clone/Notes.kdbx"
  assert_nofile "t06 browser profile absent" "$TW/clone/home/.mozilla"
  assert_nofile "t06 XDG firefox profile absent" "$TW/clone/home/.config/mozilla"
  assert_nofile "t06 zen profile absent" "$TW/clone/home/.zen"
  assert_file_match "t06 EXCLUDED lists XDG firefox cookies" "$TW/clone/reports/EXCLUDED.md" \
    "- .config/mozilla/firefox/xyz.default-release/cookies.sqlite [deny-dir:.config/mozilla]"
  assert_nofile "t06 flatpak app data absent" "$TW/clone/home/.var"
  assert_nofile "t06 pki absent" "$TW/clone/home/.pki"
  assert_nofile "t06 scan-hit file absent" "$TW/clone/home/.config/myapp/token.ini"
  assert_nofile "t06 oversize file absent" "$TW/clone/home/.config/bigapp/data.bin"
  canaries_absent "$TW/clone"
  assert_file_match "t06 EXCLUDED lists ssh rule" "$TW/clone/reports/EXCLUDED.md" "- .ssh [deny-dir:.ssh]"
  assert_file_match "t06 EXCLUDED lists kdbx rule" "$TW/clone/reports/EXCLUDED.md" "Notes.kdbx [deny-file:*.kdbx]"
  assert_file_match "t06 EXCLUDED lists cred-assign" "$TW/clone/reports/EXCLUDED.md" "- .config/myapp/token.ini [cred-assign]"
  assert_file_match "t06 EXCLUDED lists exact" "$TW/clone/reports/EXCLUDED.md" "- .config/misc/notes.txt [exact]"
  assert_file_match "t06 SKIPPED lists oversize" "$TW/clone/reports/SKIPPED.md" ".config/bigapp/data.bin (60 MiB)"
  assert_file_match "t06 SKIPPED lists cache dir" "$TW/clone/reports/SKIPPED.md" "- .cache/"
  ( cd "$TW/clone" && sha256sum -c --quiet manifest.sha256 >/dev/null 2>&1 ) \
    && ok "t06 manifest sha256 verifies in clone" \
    || bad "t06 manifest sha256 verifies in clone"
}

t07() { # AC-09 manifest hashes/modes/symlinks + meta
  TW=$SUITE/t07; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  backup --home "$TW/home" --repo test/backup --yes >/dev/null 2>&1
  git clone -q "$TW/remote-base/test/backup.git" "$TW/clone"
  M="$TW/clone/manifest.tsv"
  assert_eq "t07 distro family recorded" "$(head -1 "$TW/clone/meta/distro-family.txt")" "fedora"
  assert_match_re "t07 distro description recorded" "$(cat "$TW/clone/meta/distro.txt")" 'Debian|Fedora|Ubuntu|Arch'
  [ -s "$TW/clone/meta/date.txt" ]   && ok "t07 date recorded"   || bad "t07 date recorded"
  [ -s "$TW/clone/meta/host.txt" ]   && ok "t07 host recorded"   || bad "t07 host recorded"
  [ -s "$TW/clone/meta/version.txt" ] && ok "t07 tool version recorded" || bad "t07 tool version recorded"
  local want got
  want=$(sha256sum "$TW/clone/home/.bashrc" | cut -d' ' -f1)
  got=$(awk -F'\t' -v p='home/.bashrc' '$6==p{print $1}' "$M")
  assert_eq "t07 manifest hash matches sha256sum" "$got" "$want"
  got=$(awk -F'\t' -v p='home/.config/myapp/private.conf' '$6==p{print $3}' "$M")
  assert_eq "t07 mode 600 recorded" "$got" "600"
  got=$(awk -F'\t' -v p='home/.vimrc' '$6==p{print $4}' "$M")
  assert_eq "t07 symlink type recorded" "$got" "l"
  got=$(awk -F'\t' -v p='home/.vimrc' '$6==p{print $5}' "$M")
  assert_eq "t07 symlink target recorded" "$got" ".config/vim/vimrc"
  local n_manifest n_counts
  n_manifest=$(awk -F'\t' '$6 ~ /^home\//' "$M" | wc -l)
  n_counts=$(grep -o 'files=[0-9]*' "$TW/clone/meta/counts.txt" | head -1 | cut -d= -f2)
  assert_eq "t07 counts.txt agrees with manifest" "$n_counts" "$n_manifest"
}

t08() { # AC-10 package inventories via mocks, all three distro families
  local d rc P
  for d in fedora arch ubuntu; do
    TW=$SUITE/t08-$d; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
    setup_env "$d"
    backup --home "$TW/home" --repo test/backup --yes >/dev/null 2>&1
    rc=$?
    assert_rc "t08 $d backup rc" "$rc" 0
    git clone -q "$TW/remote-base/test/backup.git" "$TW/clone"
    P="$TW/clone/packages"
    case "$d" in
      fedora)
        assert_file_match "t08 fedora userinstalled" "$P/fedora-userinstalled.txt" "vim-enhanced"
        assert_file_match "t08 fedora unknown pkg listed" "$P/fedora-userinstalled.txt" "zzz-unknown-fakepkg"
        assert_file_match "t08 fedora repos" "$P/fedora-repos.txt" "fedora"
        assert_file_match "t08 fedora copr" "$P/fedora-copr.txt" "copr.fedorainfracloud.org" ;;
      arch)
        assert_file_match "t08 arch explicit" "$P/arch-explicit.txt" "zzz-aur-fakepkg"
        assert_file_match "t08 arch foreign" "$P/arch-foreign.txt" "zzz-aur-fakepkg" ;;
      ubuntu)
        assert_file_match "t08 ubuntu manual" "$P/ubuntu-manual.txt" "zzz-unknown-ubuntu-pkg"
        assert_file_match "t08 ubuntu sources" "$P/ubuntu-sources.txt" "### /etc/apt/sources.list" ;;
    esac
    assert_file_match "t08 $d flatpak inventory" "$P/flatpak.txt" "org.example.App"
    assert_file_match "t08 $d snap inventory" "$P/snap.txt" "firefox"
    assert_file_match "t08 $d npm inventory" "$P/npm-global.txt" "typescript@5.6.2"
    assert_file_match "t08 $d pip inventory" "$P/pip-user.txt" "requests==2.31.0"
    assert_file_match "t08 $d pipx inventory" "$P/pipx.txt" "tool-a"
    assert_file_match "t08 $d cargo inventory" "$P/cargo.txt" "ripgrep"
    assert_file_match "t08 $d gnome-extensions inventory" "$P/gnome-extensions.txt" "bar@example.com"
    assert_file_match "t08 $d gnome-extensions enabled inventory" "$P/gnome-extensions-enabled.txt" "foo@example.com"
  done
}

t09() { # AC-06/07 size cap and caches (explicit checks)
  TW=$SUITE/t09; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  out=$(backup --home "$TW/home" --repo test/backup --dry-run)
  assert_match "t09 >50MB skipped and listed" "$out" ".config/bigapp/data.bin (60 MiB)"
  assert_match "t09 cache dir skipped and listed" "$out" "- .cache/"
  assert_no_match "t09 big file not in upload list" "$out" "    .config/bigapp/data.bin"
  assert_match "t09 small file uploaded" "$out" "    .config/bigapp/small.bin"
}

t10() { # AC-08 re-run creates a new commit; history keeps removed files
  TW=$SUITE/t10; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  backup --home "$TW/home" --repo test/backup --yes >/dev/null 2>&1
  printf '# added later\n' >> "$TW/home/.bashrc"
  rm -f "$TW/home/.config/ricedata/theme.conf"
  printf 'new\n' > "$TW/home/.config/newfile.conf"
  out=$(backup --home "$TW/home" --repo test/backup --yes); rc=$?
  assert_rc "t10 second run rc" "$rc" 0
  assert_eq "t10 remote now 2 commits" "$(revcount "$TW/remote-base/test/backup.git")" "2"
  git clone -q "$TW/remote-base/test/backup.git" "$TW/clone"
  assert_file_match "t10 .bashrc updated in new commit" "$TW/clone/home/.bashrc" "# added later"
  assert_file "t10 new file present" "$TW/clone/home/.config/newfile.conf"
  assert_nofile "t10 removed file gone from HEAD" "$TW/clone/home/.config/ricedata/theme.conf"
  git -C "$TW/clone" show HEAD~1:home/.config/ricedata/theme.conf >/dev/null 2>&1 \
    && ok "t10 removed file still retrievable from history" \
    || bad "t10 removed file still retrievable from history"
}

t11() { # AC-13 hook blocks secrets anywhere in the pushed history; runbook works
  TW=$SUITE/t11; mkdir -p "$TW/repo"
  git init -q -b main "$TW/repo"
  bash "$ROOT/scripts/install-hook.sh" "$TW/repo" >/dev/null 2>&1
  assert_file "t11 hook installed" "$TW/repo/.git/hooks/pre-push"
  git init -q --bare -b main "$TW/bare.git"
  mapfile -t CAN < "$CANARIES"
  ( cd "$TW/repo" || exit 1
    printf 'leak: %s\n' "${CAN[0]}" > canary.txt
    git add -A && git -c user.name=t -c user.email=t@t commit -q -m bad
    git push "$TW/bare.git" main >/dev/null 2>&1
    assert_rc "t11 tip canary blocked" "$?" 1
    assert_eq "t11 remote unchanged after block" "$(git -C "$TW/bare.git" rev-list --all --count)" "0"
    # deleting the file is NOT enough: the blob stays reachable in history
    rm -f canary.txt
    printf 'clean\n' > clean.txt
    git add -A && git -c user.name=t -c user.email=t@t commit -q -m clean
    git push "$TW/bare.git" main >/dev/null 2>&1
    assert_rc "t11 push with secret in history still blocked" "$?" 1
    assert_eq "t11 remote still unchanged" "$(git -C "$TW/bare.git" rev-list --all --count)" "0"
    # documented runbook (README SECURITY): rebuild clean history, then push
    git checkout -q --orphan clean-main
    git add -A
    git -c user.name=t -c user.email=t@t commit -q -m clean-history
    git branch -q -M clean-main main
    git push "$TW/bare.git" main >/dev/null 2>&1
    assert_rc "t11 rebuilt clean history push allowed" "$?" 0
    assert_eq "t11 remote has the clean commit" "$(git -C "$TW/bare.git" rev-list --all --count)" "1"
    git -C "$TW/bare.git" cat-file -e "${CAN[0]}" 2>/dev/null \
      && bad "t11 canary blob absent from remote" \
      || ok "t11 canary blob absent from remote"
  )
}

t12() { # AC-15 public-repo guard: typed confirmation, not bypassed by --yes
  TW=$SUITE/t12; mkdir -p "$TW/home"; make_home "$TW/home"; mkdir -p "$TW/state"
  # NOTE: no RICE_TEST_GIT_BASE here -> the repo-ensure API path runs (gh mock)
  export RICE_TEST_DISTRO=fedora
  export RICE_TOKEN="fake-test-token-abcdefghijklmnop"
  export RICE_SCAN_EXACT="RICECANARYEXACTSECRETVALUE42"
  export MOCK_STATE="$TW/state"
  export PATH="$MOCKS:$ORIG_PATH"
  out=$(printf 'wrong-repo\n' | backup --home "$TW/home" --repo test/backup --dry-run --yes); rc=$?
  assert_rc "t12 wrong typed confirm aborts (even with --yes)" "$rc" 1
  assert_match "t12 public warning shown" "$out" "exists and is PUBLIC"
  assert_match "t12 abort reason" "$out" "public repository not confirmed"
  out=$(printf 'test/backup\n' | backup --home "$TW/home" --repo test/backup --dry-run); rc=$?
  assert_rc "t12 correct typed confirm proceeds (dry-run)" "$rc" 0
  assert_file "t12 gh api was called (mock log)" "$TW/state/gh.log"
  assert_file_match "t12 gh saw the repos API call" "$TW/state/gh.log" "gh api https://api.github.com/repos/test/backup"
}

t13() { # AC-16 repo creation: gh path, curl/PAT path, permission-failure path
  TW=$SUITE/t13; mkdir -p "$TW/home"; make_home "$TW/home"; mkdir -p "$TW/state"
  export RICE_TEST_DISTRO=fedora
  export RICE_TOKEN="fake-test-token-abcdefghijklmnop"
  export RICE_SCAN_EXACT="RICECANARYEXACTSECRETVALUE42"
  export MOCK_STATE="$TW/state"
  export PATH="$MOCKS:$ORIG_PATH"
  rm -f "$TW/state/gh.log" "$TW/state/curl.log"
  out=$(backup --home "$TW/home" --repo test/newrepo --dry-run); rc=$?
  assert_rc "t13 gh create + dry-run rc" "$rc" 0
  assert_match "t13 gh create message" "$out" "created private test/newrepo via gh"
  assert_file_match "t13 gh repo create called with --private" "$TW/state/gh.log" "gh repo create test/newrepo --private"
  # curl / PAT path (mocks-min has no gh)
  export PATH="$MOCKS_MIN:$ORIG_PATH"
  rm -f "$TW/state/curl.log"
  out=$(backup --home "$TW/home" --repo test/newrepo --dry-run); rc=$?
  assert_rc "t13 curl create + dry-run rc" "$rc" 0
  assert_match "t13 curl create message" "$out" "created private test/newrepo via the API"
  assert_file_match "t13 curl GET probe recorded" "$TW/state/curl.log" "curl GET https://api.github.com/repos/test/newrepo"
  assert_file_match "t13 curl POST create recorded" "$TW/state/curl.log" "curl POST https://api.github.com/user/repos"
  # permission failure -> manual instructions, abort before anything is pushed
  rm -f "$TW/state/curl.log"
  export MOCK_CURL_FAIL=1
  out=$(backup --home "$TW/home" --repo test/newrepo --dry-run); rc=$?
  assert_rc "t13 create failure aborts" "$rc" 1
  assert_match "t13 manual instructions printed" "$out" "create it manually"
  unset MOCK_CURL_FAIL
}

t14() { # AC-14 restore dry-run is a pure no-op + passthrough entrypoint
  TW=$SUITE/t14; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  backup --home "$TW/home" --repo test/backup --yes >/dev/null 2>&1
  NEW="$TW/newhome"; mkdir -p "$NEW/.config/myapp"
  printf 'OLD\n' > "$NEW/.bashrc"
  local before after
  before=$(cd "$NEW" && find . -printf '%P %y %m\n' | sort | sha256sum | cut -d' ' -f1)
  out=$(restore --from "$TW/remote-base/test/backup.git" --home "$NEW"); rc=$?
  assert_rc "t14 restore dry-run rc" "$rc" 0
  assert_match "t14 dry-run banner" "$out" "dry-run: nothing has been changed"
  assert_match "t14 section planning shown" "$out" "planned sections:"
  assert_match "t14 package preview present" "$out" "package reinstall preview"
  after=$(cd "$NEW" && find . -printf '%P %y %m\n' | sort | sha256sum | cut -d' ' -f1)
  assert_eq "t14 target home unchanged" "$after" "$before"
  out=$(bash "$ROOT/bin/rice-backup.sh" restore --help); rc=$?
  assert_rc "t14 restore passthrough --help rc" "$rc" 0
  assert_match "t14 passthrough shows restore usage" "$out" "rice-restore"
}

t15() { # AC-14 restore apply: files, modes, symlinks, timestamped conflict backups
  TW=$SUITE/t15; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  backup --home "$TW/home" --repo test/backup --yes >/dev/null 2>&1
  NEW="$TW/newhome"; mkdir -p "$NEW/.config/myapp"
  printf 'OLD-BASHRC\n' > "$NEW/.bashrc"
  printf 'OLD-SETTINGS\n' > "$NEW/.config/myapp/settings.ini"
  out=$(restore --from "$TW/remote-base/test/backup.git" --home "$NEW" --apply --all-sections); rc=$?
  assert_rc "t15 restore apply rc" "$rc" 0
  assert_file_match "t15 .bashrc restored" "$NEW/.bashrc" "fixture rice file"
  assert_file_match "t15 settings.ini restored" "$NEW/.config/myapp/settings.ini" "Catppuccin-Mocha"
  assert_is_link "t15 .vimrc restored as symlink" "$NEW/.vimrc"
  assert_eq "t15 .vimrc target" "$(readlink "$NEW/.vimrc")" ".config/vim/vimrc"
  assert_mode "t15 private.conf mode restored to 600" "$NEW/.config/myapp/private.conf" 600
  assert_mode "t15 myscript executable" "$NEW/.local/bin/myscript" 755
  assert_is_link "t15 systemd wants symlink restored" "$NEW/.config/systemd/user/timers.target.wants/backup.timer"
  assert_file "t15 space-named file restored" "$NEW/.config/my dir/my file.conf"
  local BK
  BK=$(ls -d "$NEW"/.rice-restore-backup-* 2>/dev/null | head -1)
  [ -n "$BK" ] && ok "t15 timestamped backup dir created" || bad "t15 timestamped backup dir created"
  assert_file "t15 old .bashrc saved" "$BK/.bashrc"
  assert_file_match "t15 old .bashrc content" "$BK/.bashrc" "OLD-BASHRC"
  assert_file "t15 old settings.ini saved" "$BK/.config/myapp/settings.ini"
  assert_file "t15 package script generated" "$NEW/.rice-restore-generated/restore-packages.sh"
  assert_match_re "t15 same-distro dnf install line" "$(cat "$NEW/.rice-restore-generated/restore-packages.sh")" 'sudo dnf install -y .*kitty.*vim-enhanced'
  assert_file_match "t15 unmapped empty for same distro" "$NEW/.rice-restore-generated/UNMAPPED.txt" "(none"
  assert_nofile "t15 no .ssh restored" "$NEW/.ssh"
  canaries_absent "$NEW"
}

t16() { # AC-14 cross-distro restore: mapped names used, unmapped LISTED
  TW=$SUITE/t16; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  backup --home "$TW/home" --repo test/backup --yes >/dev/null 2>&1
  NEW="$TW/newhome"; mkdir -p "$NEW"
  out=$(RICE_TEST_DISTRO=arch restore --from "$TW/remote-base/test/backup.git" \
          --home "$NEW" --apply --section packages); rc=$?
  assert_rc "t16 cross-distro packages rc" "$rc" 0
  G="$NEW/.rice-restore-generated"
  assert_match_re "t16 pacman line uses mapped names" "$(cat "$G/restore-packages.sh")" 'sudo pacman -S --needed .*google-chrome.*vim'
  assert_file_match "t16 flatpak line" "$G/restore-packages.sh" "flatpak install --user --noninteractive flathub org.example.App"
  assert_file_match "t16 snap line" "$G/restore-packages.sh" "sudo snap install firefox"
  assert_file_match "t16 pip line" "$G/restore-packages.sh" "python3 -m pip install --user requests==2.31.0"
  assert_file_match "t16 pipx line" "$G/restore-packages.sh" "pipx install tool-a"
  assert_file_match "t16 npm line" "$G/restore-packages.sh" "npm install -g typescript@5.6.2"
  assert_file_match "t16 cargo line" "$G/restore-packages.sh" "cargo install ripgrep"
  assert_file_match "t16 kitty LISTED as unmapped" "$G/UNMAPPED.txt" "kitty"
  assert_file_match "t16 hyprland LISTED as unmapped" "$G/UNMAPPED.txt" "hyprland"
  assert_file_match "t16 unknown pkg LISTED as unmapped" "$G/UNMAPPED.txt" "zzz-unknown-fakepkg"
  assert_no_match "t16 unmapped name never guessed into a command" \
    "$(cat "$G/restore-packages.sh")" "pacman -S --needed kitty"
}

t17() { # AC-17 syntax + custom lint (shellcheck when installed, else equivalents)
  local f fails=0 hits
  for f in "$ROOT"/bin/*.sh "$ROOT"/lib/*.sh "$ROOT"/scripts/*.sh \
           "$ROOT"/tests/run-tests.sh "$ROOT"/tests/containers.sh \
           "$ROOT"/tests/fixtures/build.sh \
           "$ROOT"/tests/fixtures/mocks/* "$ROOT"/tests/fixtures/mocks-min/*; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then bad "t17 syntax: $f"; fails=1; fi
  done
  [ "$fails" -eq 0 ] && ok "t17 bash -n on all shell files"
  hits=$(grep -rn 'set -x' "$ROOT/bin" "$ROOT/lib" "$ROOT/scripts" 2>/dev/null || true)
  [ -z "$hits" ] && ok "t17 no shell tracing anywhere" || bad "t17 no shell tracing anywhere"
  hits=$(grep -rnE '(^|[;&|] )sudo ' "$ROOT/bin" "$ROOT/lib" 2>/dev/null || true)
  [ -z "$hits" ] && ok "t17 tool itself never invokes sudo" || bad "t17 tool itself never invokes sudo"
  hits=$(grep -rnE 'push --force|push -f|push \+' "$ROOT/bin" "$ROOT/lib" "$ROOT/scripts" 2>/dev/null || true)
  [ -z "$hits" ] && ok "t17 never force-pushes" || bad "t17 never force-pushes"
  grep -q 'read -rs' "$ROOT/lib/common.sh" \
    && ok "t17 hidden secret prompt present" || bad "t17 hidden secret prompt present"
  if command -v shellcheck >/dev/null 2>&1; then
    info "t17 shellcheck available in this environment - running it"
    if shellcheck "$ROOT"/bin/*.sh "$ROOT"/lib/*.sh "$ROOT"/scripts/*.sh \
                  "$ROOT"/tests/fixtures/mocks/* 2>/dev/null; then
      ok "t17 shellcheck clean"
    else
      bad "t17 shellcheck reported issues"
    fi
  else
    info "t17 shellcheck NOT installed here - bash -n + custom lint rules ran instead (NOT RUN: shellcheck)"
    ok "t17 equivalent custom checks ran"
  fi
}

t18() { # AC-18 README coverage
  local R="$ROOT/README.md" kw
  assert_file "t18 README exists" "$R"
  for kw in --dry-run --yes --include-system rice-restore SKIPPED EXCLUDED UNMAPPED rotate private Limitations; do
    grep -q -- "$kw" "$R" && ok "t18 README covers: $kw" || bad "t18 README covers: $kw"
  done
}

t19() { # AC-20 graceful degradation when package managers are unavailable
  TW=$SUITE/t19; mkdir -p "$TW/home" "$TW/corebin"; make_home "$TW/home"; make_remote test/backup
  cp "$MOCKS/dnf" "$TW/corebin/"
  local c
  for c in bash git tar find grep sha256sum stat readlink xargs sort sed awk cut head tail \
           cat cp mv rm mkdir rmdir chmod touch tr wc date dirname basename hostname mktemp env; do
    ln -s "$(command -v "$c")" "$TW/corebin/$c"
  done
  export RICE_TEST_DISTRO=fedora
  export RICE_TEST_GIT_BASE="file://$TW/remote-base"
  export RICE_TOKEN="fake-test-token-abcdefghijklmnop"
  export RICE_SCAN_EXACT="RICECANARYEXACTSECRETVALUE42"
  export PATH="$TW/corebin"
  out=$(backup --home "$TW/home" --repo test/backup --yes); rc=$?
  assert_rc "t19 backup rc without flatpak/snap/npm/pip/python3" "$rc" 0
  git clone -q "$TW/remote-base/test/backup.git" "$TW/clone"
  local P="$TW/clone/packages"
  assert_file_match "t19 flatpak unavailable noted" "$P/flatpak.txt" "# flatpak not installed"
  assert_file_match "t19 snap unavailable noted" "$P/snap.txt" "# snap not installed"
  assert_file_match "t19 npm unavailable noted" "$P/npm-global.txt" "# npm not installed"
  assert_file_match "t19 pip unavailable noted" "$P/pip-user.txt" "# pip not available"
  assert_file_match "t19 gnome-extensions unavailable noted" "$P/gnome-extensions.txt" "# gnome-extensions not available"
}

t20() { # AC-19 workspace audit: tree clean, history clean except documented benign hits
  ( cd "$ROOT" || exit 1
    bash scripts/secret-scan.sh --expect tests/scan-expect.txt tree . >/dev/null 2>&1
    assert_rc "t20 workspace tree scan clean" "$?" 0
    local out badhits
    out=$(bash scripts/secret-scan.sh --expect tests/scan-expect.txt history 2>/dev/null)
    # the only tolerated hits: two documented benign phrases in the Phase-0
    # commit (agent-state/PLAN.md, see STATE.md) - anything else fails
    badhits=$(printf '%s\n' "$out" | awk -F'\t' '
      $1 == "HIT" &&
      !($2 == "cred-assign" && $3 == "agent-state/PLAN.md") &&
      !($2 == "url-embedded-creds" && $3 == "agent-state/PLAN.md")')
    [ -z "$badhits" ] && ok "t20 history: only the two documented benign hits" \
                        || bad "t20 history: only the two documented benign hits"
  )
}

t21() { # AC-21 session 3: PAT auth mode recorded + hard size budget with --allow-oversize
  TW=$SUITE/t21; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  # PAT path with no gh on PATH (mocks-min)
  export RICE_TEST_DISTRO=fedora
  export RICE_TEST_GIT_BASE="file://$TW/remote-base"
  export RICE_TOKEN="fake-test-token-abcdefghijklmnop"
  export RICE_SCAN_EXACT="RICECANARYEXACTSECRETVALUE42"
  export PATH="$MOCKS_MIN:$ORIG_PATH"
  out=$(backup --home "$TW/home" --repo test/backup --dry-run); rc=$?
  assert_rc "t21 PAT dry-run rc" "$rc" 0
  assert_match "t21 auth mode recorded as pat" "$out" "auth       : pat"
  # unit level: rice_auth_init must SET the mode (regression: it never did)
  (
    # shellcheck disable=SC1090,SC1091
    . "$ROOT/lib/common.sh" >/dev/null; . "$ROOT/lib/gitops.sh" >/dev/null
    RICE_AUTH_MODE=""
    rice_auth_init 0 >/dev/null 2>&1
    assert_eq "t21 RICE_AUTH_MODE=pat for env token" "$RICE_AUTH_MODE" "pat"
    RICE_AUTH_MODE=""; RICE_TOKEN=""
    rice_auth_init 0 >/dev/null 2>&1 && rc2=0 || rc2=1
    assert_rc "t21 no token + non-interactive fails" "$rc2" 1
  )
  # size budget: tiny budget -> real run refuses without the flag
  export RICE_TOTAL_MAX_BYTES=1024
  out=$(backup --home "$TW/home" --repo test/backup --yes); rc=$?
  assert_rc "t21 over-budget run refused (exit 5)" "$rc" 5
  assert_match "t21 budget refusal names the flag" "$out" "--allow-oversize"
  assert_eq "t21 refused run pushed nothing" "$(revcount "$TW/remote-base/test/backup.git")" "0"
  out=$(backup --home "$TW/home" --repo test/backup --dry-run); rc=$?
  assert_rc "t21 dry-run fine over budget" "$rc" 0
  assert_match "t21 budget warning in dry-run" "$out" "--allow-oversize"
  out=$(backup --home "$TW/home" --repo test/backup --yes --allow-oversize); rc=$?
  assert_rc "t21 over-budget allowed with flag" "$rc" 0
  assert_eq "t21 push happened with flag" "$(revcount "$TW/remote-base/test/backup.git")" "1"
  unset RICE_TOTAL_MAX_BYTES
}

t22() { # D32 --exclude-from: subtractive selection, subtrees, comments, budget
  TW=$SUITE/t22; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  # selection: comment + subtree + single file + unmatched entry
  printf '# my session selection\n\n.config/vim\n.bashrc\nzzz-not-a-candidate\n' > "$TW/sel.txt"
  out=$(backup --home "$TW/home" --repo test/backup --dry-run --exclude-from "$TW/sel.txt"); rc=$?
  assert_rc "t22 dry-run rc with selection" "$rc" 0
  assert_no_match "t22 subtree file removed from upload list" "$out" "    .config/vim/vimrc"
  assert_no_match "t22 selected file removed from upload list" "$out" "    .bashrc"
  assert_match "t22 user excluded counted in summary" "$out" "user excluded   : 2 item(s)"
  assert_match "t22 unmatched entry warned" "$out" "selection entry matched no candidate: zzz-not-a-candidate"
  assert_match "t22 selection applied info" "$out" "user selection applied: 2 file(s) excluded"
  # absolute paths are rejected (warned), the run continues without them
  printf '/etc/passwd\n' > "$TW/sel-abs.txt"
  out=$(backup --home "$TW/home" --repo test/backup --dry-run --exclude-from "$TW/sel-abs.txt"); rc=$?
  assert_rc "t22 absolute entry still runs" "$rc" 0
  assert_match "t22 absolute entry warned" "$out" "must be a path relative to the home"
  # the selection is purely SUBTRACTIVE: listing a hard-denied path neither
  # rescues it nor changes the deny list
  printf '.bash_history\n' > "$TW/sel-deny.txt"
  out=$(backup --home "$TW/home" --repo test/backup --dry-run --exclude-from "$TW/sel-deny.txt"); rc=$?
  assert_rc "t22 deny-listed entry in selection still runs" "$rc" 0
  assert_match "t22 deny list still applies" "$out" "hard deny list : "
  assert_no_match "t22 deny-listed file not in upload list" "$out" "    .bash_history"
  # real run: excluded files never reach the pushed repo; EXCLUDED.md reports them
  backup --home "$TW/home" --repo test/backup --yes --exclude-from "$TW/sel.txt" >/dev/null 2>&1
  git clone -q "$TW/remote-base/test/backup.git" "$TW/clone"
  assert_nofile "t22 excluded subtree not pushed" "$TW/clone/home/.config/vim/vimrc"
  assert_nofile "t22 excluded file not pushed" "$TW/clone/home/.bashrc"
  assert_file "t22 non-selected file pushed" "$TW/clone/home/.profile"
  assert_file_match "t22 EXCLUDED.md has user section" "$TW/clone/reports/EXCLUDED.md" "User excluded"
  assert_file_match "t22 EXCLUDED.md lists selected path" "$TW/clone/reports/EXCLUDED.md" ".config/vim/vimrc"
  # --list-files reflects the selection (GUI contract): post-exclusion rows
  out=$(backup --home "$TW/home" --list-files --exclude-from "$TW/sel.txt")
  assert_no_match "t22 list-files omits selected subtree" "$out" ".config/vim/vimrc"
  assert_no_match "t22 list-files omits selected file" "$out" $'\.bashrc\t'
  assert_match "t22 list-files includes kept file" "$out" ".profile"
  # budget interplay: excluding bulk data can bring a run back under budget
  mkdir -p "$TW/hb/home/.config/bulk"; make_home "$TW/hb/home"
  truncate -s 31457280 "$TW/hb/home/.config/bulk/big.bin"   # 30 MiB (< 50 MiB cap)
  printf '.config/bulk/big.bin\n' > "$TW/sel-budget.txt"
  export RICE_TOTAL_MAX_BYTES=$((20*1024*1024))
  out=$(backup --home "$TW/hb/home" --repo test/backup --yes); rc=$?
  assert_rc "t22 over budget without selection (exit 5)" "$rc" 5
  out=$(backup --home "$TW/hb/home" --repo test/backup --yes --exclude-from "$TW/sel-budget.txt"); rc=$?
  assert_rc "t22 under budget after excluding bulk" "$rc" 0
  unset RICE_TOTAL_MAX_BYTES
}

t23() { # D33 --export: offline archive, no auth/repo, restorable, nothing pushed
  TW=$SUITE/t23; mkdir -p "$TW/home"; make_home "$TW/home"
  # PAT removed and no gh on PATH (mocks-min): export must need NO auth at all
  export RICE_TEST_DISTRO=fedora
  export RICE_TEST_GIT_BASE="file://$TW/remote-base"
  export RICE_TOKEN=""
  export RICE_SCAN_EXACT="RICECANARYEXACTSECRETVALUE42"
  export PATH="$MOCKS_MIN:$ORIG_PATH"
  out=$(backup --home "$TW/home" --export "$TW/arch.tar.gz" --dry-run); rc=$?
  assert_rc "t23 export dry-run rc" "$rc" 0
  assert_match "t23 export target line" "$out" "target     : offline archive"
  assert_match "t23 export needs no auth" "$out" "auth       : none (offline export)"
  assert_nofile "t23 dry-run wrote no archive" "$TW/arch.tar.gz"
  out=$(backup --home "$TW/home" --export "$TW/arch.tar.gz" --yes); rc=$?
  assert_rc "t23 export rc" "$rc" 0
  assert_match "t23 export success line" "$out" "archive exported: commit"
  assert_file "t23 archive exists" "$TW/arch.tar.gz"
  assert_nofile "t23 no remote repo dir created" "$TW/remote-base"
  # the archive carries the scan gate: no canary anywhere in it
  mkdir -p "$TW/x"; tar -xzf "$TW/arch.tar.gz" -C "$TW/x"
  canaries_absent "t23 extracted archive"
  assert_file "t23 archive contains RESTORE.md" "$TW/x/RESTORE.md"
  assert_file_match "t23 RESTORE.md offline variant" "$TW/x/RESTORE.md" "offline archive"
  assert_file "t23 archive contains manifest" "$TW/x/manifest.tsv"
  # the extracted directory is a real git repository
  git -C "$TW/x" rev-parse --verify HEAD >/dev/null 2>&1 \
    && ok "t23 extracted dir is a git repo" || bad "t23 extracted dir is a git repo"
  assert_eq "t23 extracted repo has one commit" "$(revcount "$TW/x")" "1"
  # and the EXISTING restore tool restores from it via file://
  mkdir -p "$TW/rh"
  out=$(restore --from "file://$TW/x" --home "$TW/rh"); rc=$?
  assert_rc "t23 restore dry-run from extracted archive" "$rc" 0
  assert_match "t23 restore plan mentions sections" "$out" "sections"
  # relative --export paths resolve against the caller's cwd, not the stage
  ( cd "$TW" && backup --home "$TW/home" --export "rel.tar.gz" --yes ) >/dev/null 2>&1
  assert_file "t23 relative export path honored" "$TW/rel.tar.gz"
}

t24() { # D28+: GUI adapter/guiconf headless unit tests (no PyGObject needed)
  if ! command -v python3 >/dev/null 2>&1; then
    info "t24 skipped (no python3 on this machine)"
    return 0
  fi
  out=$(python3 -m unittest discover -s "$ROOT/gui/tests" 2>&1); rc=$?
  assert_rc "t24 adapter unittest rc" "$rc" 0
  assert_match "t24 adapter tests OK" "$out" "OK"
  assert_no_match "t24 no failures" "$out" "FAILED"
  # widget code compiles clean even where PyGObject cannot be imported (C5)
  out=$(python3 -m py_compile "$ROOT/gui/adapter.py" "$ROOT/gui/guiconf.py" \
                              "$ROOT/gui/gui_app.py" "$ROOT/gui/rice-gui" 2>&1); rc=$?
  assert_rc "t24 gui py_compile rc" "$rc" 0
  rm -rf "$ROOT/gui/__pycache__" "$ROOT/gui/tests/__pycache__" 2>/dev/null || true
}

t25() { # D37 symlink following: fetch target content, coverage, deny-target,
        # dedup/overlap links, --no-follow-symlinks and restore --relink
  TW=$SUITE/t25; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  # dry-run: followed links fetch content; summary line present
  out=$(backup --home "$TW/home" --repo test/backup --dry-run); rc=$?
  assert_rc "t25 dry-run rc" "$rc" 0
  assert_match "t25 summary has symlinks line" "$out" "symlinks followed    : 2 link(s) -> "
  assert_match "t25 fetched dir content listed" "$out" "    .config/quickshell/lme-shell/config.kdl"
  assert_match "t25 fetched file-link listed" "$out" "    .config/app.conf"
  assert_no_match "t25 target dir never listed directly" "$out" "    dev/lme-shell/config.kdl"
  assert_no_match "t25 deny-target link not in upload list" "$out" "    .config/mozilla-link"
  assert_match "t25 deny-target rule reported" "$out" "deny-target:deny-dir:.mozilla"
  # real run: repo carries CONTENT at the link path + symlinks.tsv + report
  backup --home "$TW/home" --repo test/backup --yes >/dev/null 2>&1
  git clone -q "$TW/remote-base/test/backup.git" "$TW/clone"
  assert_is_link "t25 covered link stays a link (.vimrc)" "$TW/clone/home/.vimrc"
  assert_file "t25 followed dir content in repo" "$TW/clone/home/.config/quickshell/lme-shell/config.kdl"
  [ -d "$TW/clone/home/.config/quickshell/lme-shell" ] \
    && [ ! -L "$TW/clone/home/.config/quickshell/lme-shell" ] \
    && ok "t25 followed link is a real dir in the repo" \
    || bad "t25 followed link is a real dir in the repo"
  assert_file "t25 file-link content in repo" "$TW/clone/home/.config/app.conf"
  assert_file_match "t25 file-link content matches target" "$TW/clone/home/.config/app.conf" "app settings fixture"
  assert_is_link "t25 dangling link preserved" "$TW/clone/home/.config/broken-link"
  assert_is_link "t25 duplicate-target link kept as link" "$TW/clone/home/.config/quickshell/lme-shell-2"
  assert_is_link "t25 ancestor-overlap link kept as link" "$TW/clone/home/.config/quickshell/lme-shell/inner/up"
  assert_nofile "t25 deny-target link absent from repo" "$TW/clone/home/.config/mozilla-link"
  assert_file "t25 symlinks.tsv in repo" "$TW/clone/symlinks.tsv"
  assert_file_match "t25 symlinks.tsv dir row" "$TW/clone/symlinks.tsv" "$(printf '.config/quickshell/lme-shell\t../../dev/lme-shell')"
  assert_file_match "t25 symlinks.tsv file row" "$TW/clone/symlinks.tsv" "$(printf '.config/app.conf\t../confs/app.conf')"
  assert_file_match "t25 SYMLINKS.md followed section" "$TW/clone/reports/SYMLINKS.md" "Followed"
  assert_file_match "t25 SYMLINKS.md kept section" "$TW/clone/reports/SYMLINKS.md" "Kept as symlinks"
  M=$(awk -F'\t' '$6=="home/.config/app.conf"{print $4}' "$TW/clone/manifest.tsv")
  assert_eq "t25 manifest type f for fetched file link" "$M" "f"
  # --list-files shows the fetched virtual rows (GUI tick/skip contract)
  out=$(backup --home "$TW/home" --list-files)
  assert_match "t25 list-files has virtual row" "$out" ".config/quickshell/lme-shell/config.kdl"
  # user selection can skip a whole fetched subtree (ancestor prefix match)
  printf '.config/quickshell/lme-shell\n' > "$TW/sel.txt"
  out=$(backup --home "$TW/home" --repo test/backup --dry-run --exclude-from "$TW/sel.txt")
  assert_no_match "t25 selection removes fetched subtree" "$out" "    .config/quickshell/lme-shell/config.kdl"
  # --no-follow-symlinks on the SAME repo: links replace fetched dirs (also
  # exercises the staging type-transition pre-clean)
  out=$(backup --home "$TW/home" --repo test/backup --yes --no-follow-symlinks); rc=$?
  assert_rc "t25 no-follow run rc" "$rc" 0
  rm -rf "$TW/clone2"
  git clone -q "$TW/remote-base/test/backup.git" "$TW/clone2"
  assert_is_link "t25 no-follow keeps link only" "$TW/clone2/home/.config/quickshell/lme-shell"
  assert_nofile "t25 no-follow child absent" "$TW/clone2/home/.config/quickshell/lme-shell/config.kdl"
  assert_is_link "t25 no-follow file link kept" "$TW/clone2/home/.config/app.conf"
  # restore --relink: preview on dry-run, layout recreated on apply
  make_remote test/backup2
  backup --home "$TW/home" --repo test/backup2 --yes >/dev/null 2>&1
  mkdir -p "$TW/rh"
  out=$(restore --from "file://$TW/remote-base/test/backup2.git" --home "$TW/rh" --dry-run --relink); rc=$?
  assert_rc "t25 relink dry-run rc" "$rc" 0
  assert_match "t25 relink preview line" "$out" "relink: 2 followed link(s)"
  assert_nofile "t25 relink dry-run changed nothing" "$TW/rh/dev"
  mkdir -p "$TW/rh2"
  out=$(restore --from "file://$TW/remote-base/test/backup2.git" --home "$TW/rh2" --apply --all-sections --relink); rc=$?
  assert_rc "t25 relink apply rc" "$rc" 0
  assert_match "t25 relink count line" "$out" "relink: 2 link(s) recreated"
  assert_is_link "t25 relinked dir link" "$TW/rh2/.config/quickshell/lme-shell"
  assert_eq "t25 relinked dir raw target" "$(readlink "$TW/rh2/.config/quickshell/lme-shell")" "../../dev/lme-shell"
  assert_file "t25 relinked dir target content" "$TW/rh2/dev/lme-shell/config.kdl"
  assert_is_link "t25 relinked file link" "$TW/rh2/.config/app.conf"
  assert_file "t25 relinked file target content" "$TW/rh2/confs/app.conf"
  canaries_absent "t25 restored home (content came through the follow)"
}

t26() { # D42 R1 --explain / --show-rules: offline diagnostics, no auth/repo
  TW=$SUITE/t26; mkdir -p "$TW/home"; make_home "$TW/home"
  setup_env fedora
  # extra fixture pieces for the remaining verdicts
  mkdir -p "$TW/home/.config/myapp/cache" "$TW/home/Documents"
  echo junk > "$TW/home/.config/myapp/cache/runtime.log"
  echo notes > "$TW/home/Documents/notes.txt"

  # --show-rules: offline, no repo/auth, section-stable output
  out=$(backup --home "$TW/home" --show-rules); rc=$?
  assert_rc "t26 show-rules rc (offline)" "$rc" 0
  assert_match "t26 show-rules header" "$out" "=== rice-backup effective rules ==="
  assert_match "t26 show-rules file cap" "$out" "file cap    : 50 MiB per file"
  assert_match "t26 show-rules budget" "$out" "total budget: 1 GiB"
  assert_match "t26 show-rules follow default" "$out" "symlinks    : follow=1 outside-home=0"
  assert_match "t26 show-rules include file listed" "$out" ".bashrc"
  assert_match "t26 show-rules include dir listed" "$out" ".config"
  assert_match "t26 show-rules deny dir listed" "$out" ".ssh"
  assert_match "t26 show-rules deny glob listed" "$out" "*history*"
  assert_match "t26 show-rules etc allowlist" "$out" "/etc/dnf/dnf.conf"
  assert_match "t26 show-rules no staging happened" "$out" "notes: deny rules are NAME-based"

  # --explain PATH...: verdict chain per path. No --repo given and rc 0 prove
  # the mode is offline (auth/repo blocks are skipped entirely).
  out=$(backup --home "$TW/home" --explain .bash_history .profile \
    .config/myapp/token.ini .config/bigapp/data.bin \
    .config/myapp/cache/runtime.log Documents/notes.txt no-such-file); rc=$?
  assert_rc "t26 explain rc (no auth, no repo)" "$rc" 0
  assert_match "t26 explain header" "$out" "=== rice-backup explain ==="
  assert_match "t26 explain home line" "$out" "home : $TW/home"
  assert_match "t26 explain L1 rule named" "$out" "rule     : deny-file:.bash_history"
  assert_match "t26 explain L1 layer" "$out" "layer    : L1 deny"
  assert_match "t26 explain L1 verdict" "$out" "verdict  : excluded"
  assert_match "t26 explain included candidate" "$out" "layer    : candidate"
  assert_match "t26 explain L2 layer" "$out" "layer    : L2 scan"
  assert_match "t26 explain L2 rule named" "$out" "rule     : scan:cred-assign"
  assert_match "t26 explain size cap layer" "$out" "layer    : size cap"
  assert_match "t26 explain size cap rule" "$out" "larger than 50 MiB"
  assert_match "t26 explain L3 cache layer" "$out" "layer    : L3 cache"
  assert_match "t26 explain outside roots" "$out" "outside every include root (see --show-rules)"
  assert_match "t26 explain not found" "$out" "no such file or symlink in the home"

  # path normalization: absolute-under-home accepted, other absolutes and ..
  # are rejected with a reason (the run itself still exits 0)
  out=$(backup --home "$TW/home" --explain "$TW/home/.bash_history"); rc=$?
  assert_rc "t26 explain absolute-under-home rc" "$rc" 0
  assert_match "t26 explain absolute-under-home normalized" "$out" "deny-file:.bash_history"
  out=$(backup --home "$TW/home" --explain /etc/passwd); rc=$?
  assert_rc "t26 explain outside-home absolute rc" "$rc" 0
  assert_match "t26 explain outside-home message" "$out" "absolute path outside the home"
  out=$(backup --home "$TW/home" --explain ../secret); rc=$?
  assert_rc "t26 explain dotdot rc" "$rc" 0
  assert_match "t26 explain dotdot rejected" "$out" "path must be home-relative without .."

  # dump mode (no paths): every bucket with reasons
  out=$(backup --home "$TW/home" --explain); rc=$?
  assert_rc "t26 explain dump rc" "$rc" 0
  assert_match "t26 dump included line" "$out" "included candidates : "
  assert_match "t26 dump L1 section" "$out" "L1 deny      : "
  assert_match "t26 dump L2 section" "$out" "L2 scan      : "
  assert_match "t26 dump size section" "$out" "size cap     : "
  assert_match "t26 dump cache section" "$out" "L3 cache     : "
  assert_match "t26 dump scanhit with rule" "$out" ".config/myapp/token.ini [cred-assign]"
  assert_match "t26 dump deny with rule" "$out" ".bash_history [deny-file:.bash_history]"

  # --explain respects --exclude-from (selection bucket is populated too)
  printf '.profile\n' > "$TW/sel.txt"
  out=$(backup --home "$TW/home" --exclude-from "$TW/sel.txt" --explain .profile); rc=$?
  assert_rc "t26 explain with selection rc" "$rc" 0
  assert_match "t26 explain selection layer" "$out" "layer    : selection"
  assert_match "t26 explain selection rule" "$out" "--exclude-from entry"

  # positional paths after -- also work
  out=$(backup --home "$TW/home" --explain -- .bash_history); rc=$?
  assert_rc "t26 explain after -- rc" "$rc" 0
  assert_match "t26 explain after -- parsed" "$out" "deny-file:.bash_history"

  # unknown options are still rejected when --explain is absent
  out=$(backup --home "$TW/home" --bogus-flag 2>&1); rc=$?
  assert_rc "t26 unknown option still usage error" "$rc" 2
  assert_match "t26 unknown option message" "$out" "unknown option: --bogus-flag"
}

t27() { # D38/D39/D42 R2 rules.conf + include roots + size flags (v0.4.0)
  TW=$SUITE/t27; mkdir -p "$TW/home"; make_home "$TW/home"; make_remote test/backup
  setup_env fedora
  # custom pieces: extra top-level file, extra root, a 2 MiB file for cap tests
  printf 'xr contents\n' > "$TW/home/.Xresources"
  mkdir -p "$TW/home/Dev/dotfiles"
  printf 'export A=1\n' > "$TW/home/Dev/dotfiles/vars.sh"
  mkdir -p "$TW/home/.config/capped"
  truncate -s 2097152 "$TW/home/.config/capped/two-m.bin"
  cat > "$TW/rules.conf" <<'EOF'
# t27 rules
[include-file]
.Xresources

[include-dir]
Dev/dotfiles

[skip-dir]
.local/share/applications

[allow]
.config/theme-assets/x

[size]
file_cap = 1MiB
total_budget = 12MiB
EOF
  out=$(backup --home "$TW/home" --rules "$TW/rules.conf" --repo test/backup --dry-run); rc=$?
  assert_rc "t27 rules dry-run rc" "$rc" 0
  assert_match "t27 extra top-level file included" "$out" "    .Xresources"
  assert_match "t27 extra root walked" "$out" "    Dev/dotfiles/vars.sh"
  assert_no_match "t27 skipped root not walked" "$out" ".local/share/applications/user.desktop"
  assert_match "t27 cap from rules applied" "$out" "oversized (>1 MiB): "
  assert_match "t27 capped file listed" "$out" ".config/capped/two-m.bin (2 MiB)"
  assert_match "t27 allow section not yet available" "$out" "not available yet"
  assert_match "t27 skip note" "$out" "include root skipped (rules): .local/share/applications"
  # --show-rules reflects the merged rule set with per-entry sources
  out=$(backup --home "$TW/home" --rules "$TW/rules.conf" --show-rules)
  assert_match "t27 show-rules rules file line" "$out" "rules file  : $TW/rules.conf (loaded)"
  assert_match "t27 show-rules default source" "$out" ".config"
  assert_match "t27 show-rules default mark" "$out" "(default)"
  assert_match "t27 show-rules rules mark" "$out" "(rules.conf)"
  assert_match "t27 show-rules skipped section" "$out" "skipped include roots"
  assert_match "t27 show-rules cap" "$out" "file cap    : 1 MiB per file"
  assert_match "t27 show-rules budget" "$out" "total budget: 12 MiB"
  # flag precedence over rules: --file-cap 5MiB beats [size] 1MiB
  out=$(backup --home "$TW/home" --rules "$TW/rules.conf" --file-cap 5MiB --repo test/backup --dry-run)
  assert_match "t27 flag cap label" "$out" "oversized (>5 MiB): "
  assert_match "t27 capped file passes at 5MiB" "$out" "two-m.bin"
  assert_no_match "t27 no 1MiB cap anymore" "$out" "oversized (>1 MiB):"
  # caps above GitHub's 100 MiB are refused
  out=$(backup --home "$TW/home" --file-cap 200MiB --repo test/backup --dry-run 2>&1); rc=$?
  assert_rc "t27 cap above GitHub limit refused (rc 2)" "$rc" 2
  assert_match "t27 cap refusal message" "$out" "exceeds GitHub's 100 MiB per-file limit"
  # invalid size flag values are usage errors
  out=$(backup --home "$TW/home" --file-cap abc --repo test/backup --dry-run 2>&1); rc=$?
  assert_rc "t27 invalid file-cap rc" "$rc" 2
  assert_match "t27 invalid file-cap message" "$out" "--file-cap: invalid size: abc"
  # --no-rules wins over --rules (documented debugging aid)
  out=$(backup --home "$TW/home" --rules "$TW/rules.conf" --no-rules --repo test/backup --dry-run)
  assert_no_match "t27 no-rules: extra file absent" "$out" "    .Xresources"
  assert_no_match "t27 no-rules: extra root absent" "$out" "    Dev/dotfiles/vars.sh"
  assert_match "t27 no-rules: default cap back" "$out" "oversized (>50 MiB): "
  # invalid entries / unknown sections are warned; the run still succeeds
  cat > "$TW/bad-rules.conf" <<'EOF'
[include-dir]
.ssh
/abs/path
[skip-dir]
Documents
[whatever]
foo
[size]
file_cap = abc
EOF
  out=$(backup --home "$TW/home" --rules "$TW/bad-rules.conf" --repo test/backup --dry-run); rc=$?
  assert_rc "t27 bad rules still run" "$rc" 0
  assert_match "t27 deny-listed root refused" "$out" "include-dir entry refused (deny-listed): .ssh [deny-dir:.ssh]"
  assert_match "t27 absolute entry ignored" "$out" "must be a path relative to the home"
  assert_match "t27 non-default skip warned" "$out" "not a default include root: Documents"
  assert_match "t27 unknown section warned" "$out" "unknown rules section ignored"
  assert_match "t27 invalid size warned" "$out" "invalid file_cap"
  # repeatable flags without any rules file
  out=$(backup --home "$TW/home" --no-rules --include-file .Xresources \
    --include-dir Dev/dotfiles --skip-dir .local/share/applications \
    --repo test/backup --dry-run)
  assert_match "t27 flag include-file" "$out" "    .Xresources"
  assert_match "t27 flag include-dir" "$out" "    Dev/dotfiles/vars.sh"
  assert_no_match "t27 flag skip-dir" "$out" ".local/share/applications/user.desktop"
  out=$(backup --home "$TW/home" --no-rules --include-dir Dev/dotfiles --show-rules)
  assert_match "t27 flag source mark" "$out" "(flag)"
  # budget flag: tiny budget trips the warning (dry-run) and exit 5 (real run)
  truncate -s 2097152 "$TW/home/.config/capped/two-m.bin"
  out=$(backup --home "$TW/home" --no-rules --file-cap 5MiB --budget 1MiB \
    --repo test/backup --dry-run); rc=$?
  assert_rc "t27 dry-run with tiny budget rc" "$rc" 0
  assert_match "t27 budget flag warning" "$out" "exceeds the 1 MiB budget"
  assert_match "t27 budget warning advises flag" "$out" "needs --allow-oversize"
  out=$(backup --home "$TW/home" --no-rules --file-cap 5MiB --budget 1MiB \
    --repo test/backup --yes 2>&1); rc=$?
  assert_rc "t27 real run over tiny budget exits 5" "$rc" 5
  # env RICE_TOTAL_MAX_BYTES still beats --budget (back-compat, t22 relies on it)
  RICE_TOTAL_MAX_BYTES=$((20*1024*1024)); export RICE_TOTAL_MAX_BYTES
  out=$(backup --home "$TW/home" --no-rules --file-cap 5MiB --budget 1MiB \
    --repo test/backup --dry-run)
  assert_no_match "t27 env beats budget flag" "$out" "exceeds the 1 MiB budget"
  unset RICE_TOTAL_MAX_BYTES
  # --explain reflects the merged roots
  out=$(backup --home "$TW/home" --rules "$TW/rules.conf" \
    --explain Dev/dotfiles/vars.sh .local/share/applications/user.desktop)
  assert_match "t27 explain extra-root file is candidate" "$out" "layer    : candidate"
  assert_match "t27 explain skipped-root file not considered" "$out" "outside every include root"
  # real run with rules: extra root pushed, skipped root dropped (mirror clean)
  backup --home "$TW/home" --rules "$TW/rules.conf" --file-cap 5MiB \
    --repo test/backup --yes >/dev/null 2>&1
  git clone -q "$TW/remote-base/test/backup.git" "$TW/clone"
  assert_file "t27 extra root pushed" "$TW/clone/home/Dev/dotfiles/vars.sh"
  assert_file "t27 extra top-level pushed" "$TW/clone/home/.Xresources"
  assert_nofile "t27 skipped root not pushed" "$TW/clone/home/.local/share/applications/user.desktop"
}

# --------------------------------------------------------------------- runner
printf 'rice-backup acceptance suite\n  root: %s\n  work: %s\n\n' "$ROOT" "$SUITE"
TESTS="t01 t02 t03 t04 t05 t06 t07 t08 t09 t10 t11 t12 t13 t14 t15 t16 t17 t18 t19 t20 t21 t22 t23 t24 t25 t26 t27"
for t in $TESTS; do
  printf '%s\n' "-- $t"
  ( "$t" ) || true
done

echo
P=$(grep -c '^ok' "$RESULTS" || true)
F=$(grep -c '^FAIL' "$RESULTS" || true)
printf 'passed: %s   failed: %s\n' "${P:-0}" "${F:-0}"
if [ "${F:-0}" -gt 0 ]; then
  printf '%s\n' 'failed assertions:'
  grep '^FAIL' "$RESULTS" | cut -f2-
  rm -rf "$SUITE"
  exit 1
fi
rm -rf "$SUITE"
exit 0

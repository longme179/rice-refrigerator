#!/usr/bin/env bash
# tests/fixtures/build.sh - (re)build the fixture $HOME, the package-manager
# mocks and the canonical canary list used by tests/run-tests.sh.
#
# Design: the repository commits ONLY the clean fixture (home-clean/) and this
# generator. The canary-bearing fixture (home/) and tests/canaries.txt are
# generated at RUNTIME and are git-ignored, because GitHub push protection
# rejects pushes containing token-shaped data - even obviously fake test
# values (this happened: a fake Stripe-key canary blocked a milestone push).
#
# ALL "secret" values are FAKE canaries. None of them is, or ever was, a real
# credential. They are generated PROGRAMMATICALLY with exact shapes so the
# scanner rules always fire on them: a hand-typed string that is one character
# too short silently passes the regex minimums (that also happened once - see
# agent-state/journal/). The 60 MiB size-cap file is likewise created by the
# test suite at runtime as a sparse file.
set -eu
umask 022   # deterministic fixture modes regardless of the builder's shell

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLEAN="$HERE/home-clean"     # committed, contains no canary data at all
H="$HERE/home"               # generated: CLEAN + injected FAKE canaries

# ----------------------------------------------------- FAKE canary generation
rep() { # $1 char(s)  $2 count -> the argument repeated count times
  local c=$1 n=$2 s=""
  while [ "$n" -gt 0 ]; do s="${s}${c}"; n=$((n - 1)); done
  printf '%s' "$s"
}
CAN_GHP="ghp_$(rep A 36)"                # gh-classic     rule needs exactly 36
CAN_FGPAT="github_pat_$(rep B 45)"       # gh-fine-grained rule needs >= 40
CAN_GHO="gho_$(rep C 36)"                # gh-classic     rule needs exactly 36
CAN_AKID="AKIA$(rep Q 16)"               # aws-access-key rule needs exactly 16
CAN_AWSSECRET="$(rep DEADBEEF 5)"        # aws-secret-label rule needs >= 30
CAN_GOOGLE="AIza$(rep C 35)"             # google-api-key rule needs exactly 35
CAN_SLACK="xoxb-$(rep Z 20)"             # slack-token    rule needs >= 10
CAN_STRIPE="sk_live_$(rep D 24)"         # stripe-live-key rule needs >= 20
CAN_JWT="eyJ$(rep A 12).$(rep B 12).$(rep C 12)"   # jwt rule: eyJ{10,}.{10,}.
CAN_BEARER="$(rep Ab 11)"                # bearer rule needs >= 20
CAN_CREDTOKEN="0123456789abcdefghij"     # cred-assign value (not a placeholder)
CAN_URLUSER="alice:hunterpass"           # url-embedded-creds userinfo
CAN_EXACT="RICECANARYEXACTSECRETVALUE42" # exact-needle canary (RICE_SCAN_EXACT)
# PEM headers are assembled from split pieces so that THIS file (which is
# committed) matches neither our own private-key rule nor GitHub push
# protection; the generated fixture files match the rule at runtime, as intended.
PEM_RSA_HDR="-----BEGIN RSA PRIV""ATE KEY-----"
PEM_RSA_FTR="-----END RSA PRIVATE ""KEY-----"
PEM_OSSH_HDR="-----BEGIN OPENSSH PRIV""ATE KEY-----"
PEM_OSSH_FTR="-----END OPENSSH PRIVATE ""KEY-----"

rm -rf "$H" "$HERE/mocks" "$HERE/mocks-min"
cp -a "$CLEAN" "$H"

# ----------------------------- inject content-scan canaries (L2, all FAKE)
mkdir -p "$H/.config/weird" "$H/.config/cloud" "$H/.config/chat" "$H/.config/pay" \
  "$H/.config/api" "$H/.config/creds" "$H/.config/net" "$H/.config/misc" "$H/.config/gh" \
  "$H/.aws"

printf 'token = %s\npassword = supersecretvalue99\n' "$CAN_CREDTOKEN" > "$H/.config/myapp/token.ini"
printf '%s\n' "$CAN_FGPAT" > "$H/.config/weird/github-pat"
printf '%s\n' "$CAN_GHP" > "$H/.config/weird/gh-token"
printf '%s\naws_secret_access_key = %s\n' "$CAN_AKID" "$CAN_AWSSECRET" > "$H/.config/cloud/aws-creds.txt"
printf '%s\n' "$CAN_GOOGLE" > "$H/.config/cloud/gcp-key.txt"
printf '%s\n' "$CAN_SLACK" > "$H/.config/chat/slack-token.txt"
printf '%s\n' "$CAN_STRIPE" > "$H/.config/pay/stripe.txt"
printf 'jwt: %s\n' "$CAN_JWT" > "$H/.config/api/jwt.txt"
printf 'Authorization: Bearer %s\n' "$CAN_BEARER" > "$H/.config/api/bearer.txt"
printf '%s\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAA==\n%s\n' \
  "$PEM_RSA_HDR" "$PEM_RSA_FTR" > "$H/.config/creds/privatekey.txt"
printf 'proxy = https://%s@example.com/endpoint\n' "$CAN_URLUSER" > "$H/.config/net/proxy.conf"
printf 'random notes\n%s\nmore notes\n' "$CAN_EXACT" > "$H/.config/misc/notes.txt"

# ----------------------------- inject deny-list canaries (L1, all FAKE)
printf 'machine api.example.com\nlogin alice\npassword netrcfakepassword\n' > "$H/.netrc"
printf 'API_TOKEN=envfake1234567890\n' > "$H/.env"
printf 'DATABASE_URL=postgres://user%s%s\n' ':envfakepass' '@db.example.com/mydb' >> "$H/.env"
printf 'github.com:\n    oauth_token: %s\n    user: rice-tester\n' "$CAN_GHO" > "$H/.config/gh/hosts.yml"
printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
  "$CAN_AKID" "$CAN_AWSSECRET" > "$H/.aws/credentials"
printf '%s\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcnNh\n%s\n' \
  "$PEM_OSSH_HDR" "$PEM_OSSH_FTR" > "$H/.ssh/id_rsa"

# ---------------------------------------------------------------------- mocks
M="$HERE/mocks"
mkdir -p "$M"

cat > "$M/dnf" <<'EOF'
#!/bin/sh
# mock dnf for the test suite (canned output, never a real package db)
case "$*" in
  *"repoquery --userinstalled"*)
    printf '%s\n' kitty vim-enhanced google-chrome-stable zzz-unknown-fakepkg hyprland ;;
  *"repolist --enabled"*)
    printf '%s\n' 'repo id  repo name' 'fedora   Fedora 41 - x86_64' 'updates  Fedora 41 - updates' ;;
  *"copr list"*)
    printf '%s\n' '  copr:copr.fedorainfracloud.org:owner:project' ;;
  *) exit 1 ;;
esac
exit 0
EOF

cat > "$M/pacman" <<'EOF'
#!/bin/sh
# mock pacman for the test suite
case "$*" in
  "-Qqe") printf '%s\n' kitty vim hyprland zzz-aur-fakepkg ;;
  "-Qqm") printf '%s\n' zzz-aur-fakepkg ;;
  *) exit 1 ;;
esac
exit 0
EOF

cat > "$M/apt-mark" <<'EOF'
#!/bin/sh
# mock apt-mark for the test suite
case "$*" in
  "showmanual") printf '%s\n' kitty vim zzz-unknown-ubuntu-pkg ;;
  *) exit 1 ;;
esac
exit 0
EOF

cat > "$M/flatpak" <<'EOF'
#!/bin/sh
# mock flatpak for the test suite
case "$*" in
  *"list --app"*)
    printf 'org.example.App\tflathub\n'
    printf 'org.gnome.Calculator\tflathub\n' ;;
  *) exit 1 ;;
esac
exit 0
EOF

cat > "$M/snap" <<'EOF'
#!/bin/sh
# mock snap for the test suite
case "$*" in
  "list")
    printf 'Name     Version  Rev   Tracking  Publisher  Notes\n'
    printf 'core22   0        1380  stable    canonical  base\n'
    printf 'firefox  1.0      4090  stable    mozilla    -\n' ;;
  *) exit 1 ;;
esac
exit 0
EOF

cat > "$M/npm" <<'EOF'
#!/bin/sh
# mock npm for the test suite (octal escapes: dash printf lacks \xNN)
case "$*" in
  *"ls -g --depth=0"*)
    printf '/usr/lib/node_modules\n'
    printf '\342\224\234\342\224\200\342\224\200 typescript@5.6.2\n'
    printf '\342\224\224\342\224\200\342\224\200 yaml@2.5.1\n' ;;
  *) exit 1 ;;
esac
exit 0
EOF

cat > "$M/pip3" <<'EOF'
#!/bin/sh
# mock pip3 for the test suite
case "$*" in
  *"list --user --format=freeze"*)
    printf 'requests==2.31.0\nrich==13.7.1\n' ;;
  *) exit 1 ;;
esac
exit 0
EOF

cat > "$M/gh" <<'EOF'
#!/bin/sh
# mock gh CLI for the test suite (answers auth status / api GET / repo create)
# every call is recorded to $MOCK_STATE/gh.log for assertions
if [ -n "${MOCK_STATE:-}" ] && [ -d "$MOCK_STATE" ]; then
  printf 'gh %s\n' "$*" >> "$MOCK_STATE/gh.log"
fi
case "$1" in
  auth)
    [ "$2" = "status" ] && exit 0
    exit 1 ;;
  api)
    case "$2" in
      */repos/test/backup)  printf '{"private":false,"full_name":"test/backup"}\n' ;;
      *)                    printf '{"message":"Not Found"}\n' ;;
    esac
    exit 0 ;;
  repo)
    # gh repo create OWNER/NAME --private  -> recorded in gh.log, exit 0
    exit 0 ;;
  *) exit 1 ;;
esac
EOF

cat > "$M/curl" <<'EOF'
#!/bin/sh
# mock curl for the test suite: rice-backup calls `curl --config FILE`, so the
# mock parses the url/request lines out of the config file and answers them.
# calls are recorded to $MOCK_STATE/curl.log; MOCK_CURL_FAIL=1 makes the
# repo-creation POST fail (for the no-permission failure path).
CFG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CFG=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$CFG" ] && [ -f "$CFG" ] || { printf 'mock-curl: no config file\n' >&2; exit 1; }
url=$(grep -o 'url = "[^"]*"' "$CFG" | head -1 | cut -d'"' -f2)
method=$(grep -o 'request = "[^"]*"' "$CFG" | head -1 | cut -d'"' -f2)
if [ -n "${MOCK_STATE:-}" ] && [ -d "$MOCK_STATE" ]; then
  printf 'curl %s %s\n' "${method:-GET}" "$url" >> "$MOCK_STATE/curl.log"
fi
case "$url" in
  */repos/test/backup)
    printf '{"private":false,"full_name":"test/backup"}\n'; exit 0 ;;
  */user/repos)
    if [ "${MOCK_CURL_FAIL:-0}" = "1" ]; then
      printf '{"message":"Resource not accessible by personal access tokens"}\n'
      exit 0
    fi
    printf '{"private":true,"full_name":"test/newrepo"}\n'; exit 0 ;;
  *)
    printf '{"message":"Not Found"}\n'; exit 0 ;;
esac
EOF

chmod 755 "$M"/*

# mocks-min: only curl + dnf (drives the PAT/curl API path; no gh present)
MM="$HERE/mocks-min"
mkdir -p "$MM"
cp "$M/curl" "$M/dnf" "$MM/"
chmod 755 "$MM"/*

# ---- canaries.txt: the canonical list of FAKE values (git-ignored, generated
# here). The line ORDER is stable and consumed by tests/run-tests.sh (t01 maps
# lines to rules); AC-03 greps every backup for every line and must find NONE.
{
  printf '%s\n' "$CAN_GHP"        # 1  gh-classic
  printf '%s\n' "$CAN_FGPAT"      # 2  gh-fine-grained
  printf '%s\n' "$CAN_GHO"        # 3  gh-classic (hosts.yml)
  printf '%s\n' "$CAN_AKID"       # 4  aws-access-key
  printf '%s\n' "$CAN_AWSSECRET"  # 5  aws-secret-label
  printf '%s\n' "$CAN_GOOGLE"     # 6  google-api-key
  printf '%s\n' "$CAN_SLACK"      # 7  slack-token
  printf '%s\n' "$CAN_STRIPE"     # 8  stripe-live-key
  printf '%s\n' "$CAN_JWT"        # 9  jwt
  printf '%s\n' "$CAN_BEARER"     # 10 bearer-token
  printf '%s\n' "$CAN_CREDTOKEN"  # 11 cred-assign
  printf '%s\n' "$CAN_URLUSER"    # 12 url-embedded-creds
  printf '%s\n' "$CAN_EXACT"      # 13 exact needle
  printf '%s\n' 'netrcfakepassword'
  printf '%s\n' 'supersecretvalue99'
  printf '%s\n' 'envfake1234567890'
  printf '%s\n' 'ZmFrZTpmb2tl'
  printf '%s\n' 'envfakepass'
} > "$HERE/../canaries.txt"

echo "fixtures built:"
echo "  home entries : $(find "$H" -mindepth 1 | wc -l) (from home-clean: $(find "$CLEAN" -mindepth 1 | wc -l))"
echo "  mocks        : $(ls "$M" | tr '\n' ' ')"
echo "  mocks-min    : $(ls "$MM" | tr '\n' ' ')"
echo "  canaries     : $(wc -l < "$HERE/../canaries.txt") values"

#!/usr/bin/env bash
# scripts/install-hook.sh - install the rice-backup secret-scan pre-push hook
# into a repository (security rule S4: hook AND explicit call before pushes).
#
# Usage: scripts/install-hook.sh <repo-path> [expect-file]
#   <repo-path>    repository whose .git/hooks receives the hook
#   [expect-file]  optional file of path prefixes with EXPECTED test canaries
#                  (used by this workspace repository for tests/fixtures/)
#
# The hook scans every commit being pushed with git grep based rules, and
# additionally performs an exact-needle check when RICE_TOKEN / RICE_SCAN_EXACT
# is present in the environment of the pushing process (the needle is piped to
# grep via stdin and never appears in argv or logs).

set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=${1:?usage: install-hook.sh <repo-path> [expect-file]}
EXPECT=${2:-}

HOOKDIR="$REPO/.git/hooks"
[ -d "$HOOKDIR" ] || { echo "install-hook: not a git repository: $REPO" >&2; exit 2; }

cp -- "$HERE/secret-scan.sh" "$HOOKDIR/rice-secret-scan.sh"
chmod 755 "$HOOKDIR/rice-secret-scan.sh"

if [ -n "$EXPECT" ]; then
  cp -- "$EXPECT" "$HOOKDIR/rice-scan-expect.txt"
else
  rm -f "$HOOKDIR/rice-scan-expect.txt"
fi

cat > "$HOOKDIR/pre-push" <<'EOF'
#!/bin/sh
# rice-backup pre-push secret gate (security rule S4).
# Installed by scripts/install-hook.sh - do not edit by hand; reinstall instead.
# Scans EVERY commit in the range being pushed (not only the tip): a secret
# that was committed and then deleted still blocks the push until the local
# history is rebuilt (runbook: README SECURITY).
scandir=$(dirname -- "$0")
EXP=""
if [ -f "$scandir/rice-scan-expect.txt" ]; then EXP="--expect $scandir/rice-scan-expect.txt"; fi
status=0
while read -r local_ref local_sha remote_ref remote_sha; do
    [ "$local_sha" = "0000000000000000000000000000000000000000" ] && continue
    if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
        range="$local_sha"    # new branch: scan every reachable commit
    else
        range="$remote_sha..$local_sha"
    fi
    for rev in $(git rev-list "$range" 2>/dev/null); do
        # shellcheck disable=SC2086  (EXP is intentionally word-split; no spaces in path)
        "$scandir/rice-secret-scan.sh" $EXP git "$rev" || status=1
    done
done
exit $status
EOF
chmod 755 "$HOOKDIR/pre-push"

echo "installed: $HOOKDIR/pre-push (+ rice-secret-scan.sh$( [ -n "$EXPECT" ] && printf ' + expect list' ))"

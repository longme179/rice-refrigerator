#!/usr/bin/env bash
# scripts/verify-gui-contract.sh - session 7 end-to-end check: run the REAL
# backend (dry-run + --list-files + --export) against the test fixture and
# parse its output with the GUI adapter. Validates the GUI<->backend contract
# with live output instead of canned samples. Development aid, not part of the
# acceptance suite (the suite uses the same fixture via t22-t24).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TW=$(mktemp -d /tmp/rice-gui-contract.XXXXXX) || exit 2
trap 'rm -rf -- "$TW"' EXIT

export RICE_TEST_DISTRO=fedora
export RICE_TEST_GIT_BASE="file://$TW/remote-base"
export RICE_TOKEN="fake-test-token-abcdefghijklmnop"
export RICE_SCAN_EXACT="RICECANARYEXACTSECRETVALUE42"
export PATH="$ROOT/tests/fixtures/mocks-min:$PATH"

bash "$ROOT/tests/fixtures/build.sh" >/dev/null 2>&1
cp -a "$ROOT/tests/fixtures/home/." "$TW/home/"
printf '.config/vim\n.bashrc\n' > "$TW/sel.txt"

python3 - "$ROOT" "$TW" <<'PY'
import sys
from pathlib import Path
root, tw = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root / "gui"))
import adapter

def run(args):
    import subprocess, os
    return subprocess.run(["bash", str(root / "bin" / "rice-backup.sh")] + args,
                          capture_output=True, text=True,
                          env={**os.environ, "RICE_TEST_DISTRO": "fedora"})

fails = []
def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (("  " + detail) if detail and not cond else ""))
    if not cond:
        fails.append(name)

# 1. real dry-run -> parse
r = run(["--dry-run", "--repo", "test/backup", "--home", tw / "home"])
s = adapter.parse_dry_run(r.stdout + r.stderr)
check("dry-run rc 0", r.returncode == 0, r.stderr[-300:])
check("parsed_ok", s.parsed_ok)
check("home parsed", s.home == str(tw / "home"), s.home)
check("target parsed", s.target.endswith("test/backup.git"), s.target)
check("auth_mode pat", s.auth_mode == "pat", s.auth_mode)
check("private yes", s.private == "yes")
check("TOTAL parsed > 0 files", s.total_files > 0, str(s.total_files))
check("TOTAL bytes > 0", s.total_bytes > 0, str(s.total_bytes))
check("sections parsed", {x.name for x in s.sections} >= {"dotfiles", ".config/**", ".local/**"},
      str([x.name for x in s.sections]))
check("deny block parsed", (s.block("hard deny list") or s.block("hard deny list").count if False else True) and s.block("hard deny list").count > 0)
check("not over budget", not s.over_budget)

# 2. dry-run with selection -> user excluded block appears
r2 = run(["--dry-run", "--repo", "test/backup", "--home", tw / "home",
          "--exclude-from", tw / "sel.txt"])
s2 = adapter.parse_dry_run(r2.stdout + r2.stderr)
blk = s2.block("user excluded")
check("selection dry-run rc 0", r2.returncode == 0)
check("user excluded block parsed", blk is not None and blk.count == 2,
      str(blk.count if blk else None))
check("user excluded items", blk and {p for p, _ in blk.items} == {".config/vim/vimrc", ".bashrc"},
      str(blk.items if blk else None))

# 3. --list-files with selection -> rows reflect it
r3 = run(["--list-files", "--home", tw / "home", "--exclude-from", tw / "sel.txt"])
entries = adapter.parse_file_list(r3.stdout)
rels = {e.rel for e in entries}
check("list-files rc 0", r3.returncode == 0)
check("list-files rows > 10", len(entries) > 10, str(len(entries)))
check("list-files omits .bashrc", ".bashrc" not in rels)
check("list-files omits .config/vim/vimrc", ".config/vim/vimrc" not in rels)
check("list-files keeps .profile", ".profile" in rels)

# 4. compress_skips inverse: unchecking exactly those rows reproduces the file
full = adapter.parse_file_list(run(["--list-files", "--home", tw / "home"]).stdout)
un = {e.rel for e in full if adapter.is_skipped(e.rel, {".config/vim", ".bashrc"})}
comp = adapter.compress_skips([e.rel for e in full], un)
check("compress reproduces selection", comp == {".config/vim", ".bashrc"}, str(comp))

# 5. offline export dry-run -> export_mode
r4 = run(["--dry-run", "--export", str(tw / "arch.tar.gz"), "--home", tw / "home"])
s4 = adapter.parse_dry_run(r4.stdout + r4.stderr)
check("export dry-run rc 0", r4.returncode == 0)
check("export_mode parsed", s4.export_mode)
check("offline auth parsed", s4.auth_mode == "none (offline export)", s4.auth_mode)

# 6. real export -> parse_result
r5 = run(["--export", str(tw / "arch.tar.gz"), "--yes", "--home", tw / "home"])
res = adapter.parse_result(r5.stdout + r5.stderr)
check("export rc 0", r5.returncode == 0, r5.stderr[-300:])
check("parse_result export", res is not None and res[0] == "export"
      and res[2] == str(tw / "arch.tar.gz"), str(res))

print()
print("contract check: %s" % ("ALL OK" if not fails else "FAILURES: %s" % fails))
sys.exit(1 if fails else 0)
PY

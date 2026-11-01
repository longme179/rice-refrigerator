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

# 7. R5: --show-rules -> parse_show_rules (defaults shape)
r6 = run(["--show-rules", "--home", tw / "home"])
sr = adapter.parse_show_rules(r6.stdout + r6.stderr)
check("show-rules rc 0", r6.returncode == 0, r6.stderr[-300:])
check("show-rules parsed_ok", sr.parsed_ok)
check("show-rules version 0.4.0", sr.version == "0.4.0", sr.version)
check("show-rules no rules file", sr.rules_file == "", sr.rules_file)
check("show-rules default dirs", ".config" in sr.default_dirs(), str(sr.default_dirs()[:4]))
check("show-rules hard deny .ssh", any(r.value == ".ssh" and r.note == "hard" for r in sr.deny_dirs))
check("show-rules soft deny *history*", any(r.value == "*history*" and r.note == "soft" for r in sr.deny_globs))
deny_dirs = [r.value for r in sr.deny_dirs]

# 8. R5: --explain -> parse_explain + explain_stanza rails
r7 = run(["--explain", ".config/myapp/token.ini", ".bash_history", ".ssh/id_rsa",
          "--home", tw / "home"])
ex = adapter.parse_explain(r7.stdout + r7.stderr)
check("explain rc 0", r7.returncode == 0, r7.stderr[-300:])
check("explain parsed_ok", ex.parsed_ok)
check("explain 3 rows", len(ex.rows) == 3, str([r.path for r in ex.rows]))
by = {r.path: r for r in ex.rows}
check("explain token.ini L2 cred-assign",
      by[".config/myapp/token.ini"].layer == "L2 scan"
      and by[".config/myapp/token.ini"].rule == "scan:cred-assign",
      str(by.get(".config/myapp/token.ini")))
st, _note = adapter.explain_stanza(by[".config/myapp/token.ini"], deny_dirs)
check("stanza offers ack for heuristic hit",
      st == "[ack-scan]\n.config/myapp/token.ini\n", st)
check("explain .bash_history soft L1",
      by[".bash_history"].layer == "L1 deny" and "soft rule" in by[".bash_history"].override)
st, _note = adapter.explain_stanza(by[".bash_history"], deny_dirs)
check("stanza offers allow for soft deny", st == "[allow]\n.bash_history\n", st)
st, note = adapter.explain_stanza(by[".ssh/id_rsa"], deny_dirs)
check("stanza refuses deny-dir child", st == "" and "deny dir .ssh" in note, note)

# 9. R5: adapter-written rules.conf drives the real backend (allow + ack)
rules = tw / "rules.conf"
adapter.write_rules(rules, adapter.parse_rules_text(
    "[allow]\n.bash_history\n\n[ack-scan]\n.config/myapp/token.ini\n\n"
    "[size]\nfile_cap = 50M\n"))
r8 = run(["--dry-run", "--repo", "test/backup", "--rules", str(rules),
          "--home", tw / "home"])
s8 = adapter.parse_dry_run(r8.stdout + r8.stderr)
check("rules dry-run rc 0", r8.returncode == 0, r8.stderr[-300:])
ov, ac = s8.block("deny overridden"), s8.block("scan acknowledged")
check("deny overridden block parsed", ov is not None and ov.count == 1
      and any(p == ".bash_history" for p, _n in ov.items), str(ov))
check("scan acknowledged block parsed", ac is not None and ac.count == 1
      and any(p == ".config/myapp/token.ini" for p, _n in ac.items), str(ac))

print()
print("contract check: %s" % ("ALL OK" if not fails else "FAILURES: %s" % fails))
sys.exit(1 if fails else 0)
PY

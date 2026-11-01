"""Headless unit tests for the rice-backup GUI adapter + guiconf layers.

These run with the stdlib unittest runner ONLY (no PyGObject, no display,
per GUI-PLAN section 9 / C5); the bash suite wires them in as t24.

The canned dry-run samples mirror the EXACT backend printf formats
(bin/rice-backup.sh), including one Fedora-shaped sample matching the
user's real-machine dry-run fields from session 6.
"""

import os
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GUI_DIR = HERE.parent
if str(GUI_DIR) not in sys.path:
    sys.path.insert(0, str(GUI_DIR))

import adapter  # noqa: E402
import guiconf  # noqa: E402


# ---------------------------------------------------------------------------
# canned backend outputs
# ---------------------------------------------------------------------------

DRYRUN_NORMAL = """\
[rice-backup] collecting candidates from /home/tester (originals are read-only)...
[rice-backup] content-scanning 24 candidate file(s) with the S4 rules...
[rice-backup] user selection applied: 2 file(s) excluded

=== rice-backup dry-run summary ===
home       : /home/tester
distro     : Fedora 44 (gnome desktop) host=fedbox
target     : https://github.com/test/backup.git (private: yes) branch main
auth       : pat

would upload (read-only pass done, nothing staged yet):
  dotfiles              : 6 file(s), 12 KiB
  .config/**            : 9 file(s), 2 MiB
  .local/**             : 5 file(s), 1 MiB
  fonts/icons/themes    : 1 file(s), 40 KiB
  /etc allowlist        : 0 file(s) (not requested: use --include-system)
  package inventories   : dnf (3), flatpak (2)
  desktop settings      : dconf dump (available), crontab (unavailable)
  TOTAL                 : 21 file(s), 3 MiB
    .bashrc
    .profile
    ... and 19 more

largest candidates (top 15 by size):
      2 MiB  .config/bigapp/small.bin
     40 KiB  .local/share/fonts/FakeFont.ttf

excluded (names only):
  hard deny list : 3 item(s)
    - .ssh [deny-dir]
    - .bash_history [deny-file:history]
    - Notes.kdbx [deny-file:kdbx]
  scan hits       : 1 item(s)
    - .config/myapp/token.ini [cred-assign]
  user excluded   : 2 item(s)
    - .config/vim/vimrc [user-exclude]
    - .bashrc [user-exclude]
  oversized (>50 MiB): 1 item(s)
    - .config/bigapp/data.bin (60 MiB)
  caches/junk     : 2 item(s)
    - .cache/
    - node_modules/

[rice-backup] dry-run complete: nothing was staged, committed or pushed.
"""

# Fedora-shaped sample: the user's real 0.1.1 dry-run fields (session 6),
# truncated item lists, no real secret data anywhere.
DRYRUN_REAL_FEDORA = """\
=== rice-backup dry-run summary ===
home       : /home/tester
distro     : Fedora 44 (gnome desktop) host=fedora44
target     : https://github.com/longme/horrible-graveyard-desktop.git (private: no) branch main
auth       : pat

would upload (read-only pass done, nothing staged yet):
  dotfiles              : 8 file(s), 20 KiB
  .config/**            : 911 file(s), 2 GiB
  .local/**             : 2273 file(s), 6 GiB
  fonts/icons/themes    : 0 file(s), 0 B
  /etc allowlist        : 0 file(s) (not requested: use --include-system)
  package inventories   : dnf (231), flatpak (2), snap (1), pip (18), pipx (2), npm (3), cargo (1), gnome-extensions (2)
  desktop settings      : dconf dump (available), crontab (available)
  TOTAL                 : 3192 file(s), 8 GiB
    .bashrc
    ... and 3184 more

largest candidates (top 15 by size):
     14 MiB  .local/share/fonts/IosevkaNerdFont-Regular.ttf
     14 MiB  .local/share/fonts/IosevkaNerdFont-Bold.ttf

excluded (names only):
  hard deny list : 449 item(s)
    - .bash_history [deny-file:history]
    - .config/mozilla [deny-dir:browser-profile]
  scan hits       : 1 item(s)
    - .config/mango/scripts/networks.py [aws-secret-label]
  user excluded   : 0 item(s)
  oversized (>50 MiB): 0 item(s)
  caches/junk     : 26 item(s)
    - .cache/
    - .var/app/org.mozilla.firefox/cache/

[rice-backup] WARNING: total 8 GiB exceeds the 1 GiB budget; a real run needs --allow-oversize
[rice-backup] dry-run complete: nothing was staged, committed or pushed.
"""

DRYRUN_EXPORT = """\
[rice-backup] collecting candidates from /home/tester (originals are read-only)...
[rice-backup] content-scanning 24 candidate file(s) with the S4 rules...

=== rice-backup dry-run summary ===
home       : /home/tester
distro     : Fedora 44 (gnome desktop) host=fedbox
target     : offline archive /tmp/rice-backup-export-preview.tar.gz (no GitHub access)
auth       : none (offline export)

would upload (read-only pass done, nothing staged yet):
  dotfiles              : 6 file(s), 12 KiB
  .config/**            : 9 file(s), 2 MiB
  TOTAL                 : 15 file(s), 2 MiB
    .bashrc

excluded (names only):
  hard deny list : 3 item(s)
    - .ssh [deny-dir]
  scan hits       : 0 item(s)
  user excluded   : 0 item(s)
  oversized (>50 MiB): 0 item(s)
  caches/junk     : 1 item(s)
    - .cache/

[rice-backup] dry-run complete: nothing was staged, committed or pushed.
"""

LIST_FILES_OUTPUT = """\
[rice-backup] collecting candidates from /home/tester (originals are read-only)...
[rice-backup] content-scanning 3 candidate file(s) with the S4 rules...
.bashrc\t209
.config/vim/vimrc\t1024
.local/share/fonts/A.ttf\t14680064
"""


# ---------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------

class TestParseDryRun(unittest.TestCase):

    def test_normal_summary(self):
        s = adapter.parse_dry_run(DRYRUN_NORMAL)
        self.assertTrue(s.parsed_ok)
        self.assertEqual(s.home, "/home/tester")
        self.assertIn("Fedora 44", s.distro)
        self.assertEqual(s.target, "https://github.com/test/backup.git")
        self.assertEqual(s.private, "yes")
        self.assertEqual(s.auth_mode, "pat")
        self.assertFalse(s.export_mode)
        self.assertFalse(s.over_budget)
        names = {sec.name: sec for sec in s.sections}
        self.assertEqual(names["dotfiles"].files, 6)
        self.assertEqual(names["dotfiles"].size_bytes, 12 * 1024)
        self.assertEqual(names[".config/**"].files, 9)
        self.assertEqual(names[".config/**"].size_bytes, 2 * 1024 * 1024)
        self.assertEqual(names[".local/**"].size_bytes, 1024 * 1024)
        self.assertEqual(names["fonts/icons/themes"].size_bytes, 40 * 1024)
        self.assertNotIn("TOTAL", names)             # parsed into total fields
        self.assertEqual(s.total_files, 21)
        self.assertEqual(s.total_bytes, 3 * 1024 * 1024)
        self.assertEqual(s.largest[0],
                         (".config/bigapp/small.bin", 2 * 1024 * 1024))
        self.assertEqual(s.largest[1],
                         (".local/share/fonts/FakeFont.ttf", 40 * 1024))
        deny = s.block("hard deny list")
        self.assertEqual(deny.count, 3)
        self.assertEqual(len(deny.items), 3)
        self.assertEqual(deny.items[0], (".ssh", "deny-dir"))
        self.assertFalse(deny.truncated)
        scan = s.block("scan hits")
        self.assertEqual(scan.items[0],
                         (".config/myapp/token.ini", "cred-assign"))
        user = s.block("user excluded")
        self.assertEqual(user.count, 2)
        self.assertIn((".bashrc", "user-exclude"), user.items)
        big = s.block("oversized")
        self.assertEqual(big.items[0][0], ".config/bigapp/data.bin")
        self.assertEqual(big.items[0][1], "60 MiB")
        cache = s.block("caches/junk")
        self.assertIn((".cache/", ""), cache.items)

    def test_symlinks_line_parsed(self):
        text = DRYRUN_NORMAL.replace(
            "  TOTAL                 : 21 file(s), 3 MiB\n",
            "  TOTAL                 : 21 file(s), 3 MiB\n"
            "  symlinks followed    : 2 link(s) -> 18 file(s), "
            "37.5 KiB fetched; 5 kept as link(s)\n")
        self.assertIn("symlinks followed", text)
        s = adapter.parse_dry_run(text)
        self.assertTrue(s.parsed_ok)
        self.assertEqual(s.links_followed, 2)
        self.assertEqual(s.files_from_links, 18)
        self.assertEqual(s.links_kept, 5)

    def test_oversized_block_accepts_custom_cap(self):
        # D42/R2: the dry-run label carries the ACTIVE per-file cap, so the
        # block key stays "oversized" whatever the cap text is.
        text = DRYRUN_NORMAL.replace(
            "  oversized (>50 MiB): 1 item(s)",
            "  oversized (>1 MiB): 2 item(s)")
        s = adapter.parse_dry_run(text)
        self.assertTrue(s.parsed_ok)
        big = s.block("oversized")
        self.assertEqual(big.count, 2)
        # the line must NOT be mistaken for a section
        names = {sec.name for sec in s.sections}
        self.assertNotIn("symlinks followed", names)

    def test_override_ack_lines_close_excluded_block(self):
        # R3/R4: "deny overridden" and "scan acknowledged" summary lines are
        # NOT excluded blocks; their item lines must never be attributed to
        # the preceding recognized block (e.g. "user excluded").
        text = DRYRUN_NORMAL.replace(
            "  oversized (>50 MiB): 1 item(s)",
            "  deny overridden : 1 item(s)\n"
            "    - .bash_history [deny-file:.bash_history]\n"
            "  scan acknowledged : 1 item(s)\n"
            "    - .config/myapp/token.ini [cred-assign]\n"
            "  oversized (>50 MiB): 1 item(s)")
        s = adapter.parse_dry_run(text)
        self.assertTrue(s.parsed_ok)
        user = s.block("user excluded")
        self.assertEqual(user.count, 2)
        self.assertEqual(len(user.items), 2)
        for item, _rule in user.items:
            self.assertNotIn(".bash_history", item)
            self.assertNotIn("token.ini", item)
        big = s.block("oversized")
        self.assertEqual(big.items[0][0], ".config/bigapp/data.bin")
        # the unrecognized lines must not become sections either
        names = {sec.name for sec in s.sections}
        self.assertNotIn("deny overridden", names)
        self.assertNotIn("scan acknowledged", names)

    def test_override_ack_blocks_parsed_as_blocks(self):
        # R5: "deny overridden" / "scan acknowledged" are FIRST-CLASS excluded
        # blocks now (their own notebook pages in the review window).
        text = DRYRUN_NORMAL.replace(
            "  oversized (>50 MiB): 1 item(s)",
            "  deny overridden : 1 item(s)\n"
            "    - .bash_history [deny-file:.bash_history]\n"
            "  scan acknowledged : 1 item(s)\n"
            "    - .config/myapp/token.ini [cred-assign]\n"
            "  oversized (>50 MiB): 1 item(s)")
        s = adapter.parse_dry_run(text)
        self.assertTrue(s.parsed_ok)
        ov = s.block("deny overridden")
        self.assertIsNotNone(ov)
        self.assertEqual(ov.count, 1)
        self.assertEqual(ov.items, [(".bash_history", "deny-file:.bash_history")])
        ac = s.block("scan acknowledged")
        self.assertIsNotNone(ac)
        self.assertEqual(ac.items, [(".config/myapp/token.ini", "cred-assign")])
        self.assertFalse(ac.truncated)

    def test_symlinks_line_absent_keeps_zeros(self):
        s = adapter.parse_dry_run(DRYRUN_NORMAL)
        self.assertEqual(s.links_followed, 0)
        self.assertEqual(s.files_from_links, 0)
        self.assertEqual(s.links_kept, 0)

    def test_real_fedora_shape(self):
        s = adapter.parse_dry_run(DRYRUN_REAL_FEDORA)
        self.assertTrue(s.parsed_ok)
        self.assertEqual(s.total_files, 3192)
        self.assertEqual(s.total_bytes, 8 * 1024 ** 3)
        self.assertTrue(s.over_budget)               # 'a real run needs' line
        self.assertEqual(s.private, "no")
        names = {sec.name: sec for sec in s.sections}
        self.assertEqual(names[".config/**"].files, 911)
        self.assertEqual(names[".local/**"].files, 2273)
        self.assertEqual(s.largest[0],
                         (".local/share/fonts/IosevkaNerdFont-Regular.ttf",
                          14 * 1024 * 1024))
        deny = s.block("hard deny list")
        self.assertEqual(deny.count, 449)
        self.assertTrue(deny.truncated)              # canned sample lists 2
        scan = s.block("scan hits")
        self.assertEqual(scan.items[0],
                         (".config/mango/scripts/networks.py", "aws-secret-label"))
        user = s.block("user excluded")
        self.assertEqual(user.count, 0)
        self.assertEqual(user.items, [])

    def test_export_mode(self):
        s = adapter.parse_dry_run(DRYRUN_EXPORT)
        self.assertTrue(s.parsed_ok)
        self.assertTrue(s.export_mode)
        self.assertEqual(s.auth_mode, "none (offline export)")
        self.assertEqual(s.target, "/tmp/rice-backup-export-preview.tar.gz")
        self.assertEqual(s.private, "unknown")

    def test_garbage_is_visible_not_fatal(self):
        s = adapter.parse_dry_run("some random program output\nno anchors here")
        self.assertFalse(s.parsed_ok)
        self.assertIn("random", s.raw)               # raw kept for fallback view
        s2 = adapter.parse_dry_run("")
        self.assertFalse(s2.parsed_ok)


class TestParseFileList(unittest.TestCase):

    def test_rows_and_noise(self):
        entries = adapter.parse_file_list(LIST_FILES_OUTPUT)
        self.assertEqual(len(entries), 3)
        self.assertEqual(entries[0], adapter.FileEntry(".bashrc", 209))
        self.assertEqual(entries[1].rel, ".config/vim/vimrc")
        self.assertEqual(entries[2].size, 14680064)

    def test_empty(self):
        self.assertEqual(adapter.parse_file_list(""), [])
        self.assertEqual(adapter.parse_file_list("\n\n[rice-backup] info\n"), [])


# ---------------------------------------------------------------------------
# selection logic
# ---------------------------------------------------------------------------

class TestSelection(unittest.TestCase):

    RELS = [".bashrc", ".profile",
            ".config/vim/vimrc", ".config/vim/other.rc",
            ".config/myapp/settings.ini",
            ".local/share/fonts/A.ttf", ".local/share/fonts/B.ttf",
            ".local/share/applications/user.desktop",
            ".local/bin/tool"]

    def test_is_skipped_ancestor_walk(self):
        self.assertTrue(adapter.is_skipped(".local/share/fonts/A.ttf",
                                           {".local/share/fonts"}))
        self.assertFalse(adapter.is_skipped(".local/bin/tool",
                                            {".local/share/fonts"}))
        self.assertTrue(adapter.is_skipped(".bashrc", {".bashrc"}))

    def test_compress_full_subtree_becomes_dir(self):
        skips = adapter.compress_skips(
            self.RELS, {".local/share/fonts/A.ttf", ".local/share/fonts/B.ttf"})
        self.assertEqual(skips, {".local/share/fonts"})

    def test_compress_whole_config(self):
        skips = adapter.compress_skips(
            self.RELS, {".config/vim/vimrc", ".config/vim/other.rc",
                        ".config/myapp/settings.ini"})
        self.assertEqual(skips, {".config"})

    def test_compress_mixed_uses_files(self):
        skips = adapter.compress_skips(self.RELS,
                                       {".config/vim/vimrc", ".bashrc"})
        self.assertEqual(skips, {".config/vim/vimrc", ".bashrc"})

    def test_compress_everything(self):
        skips = adapter.compress_skips(self.RELS, set(self.RELS))
        self.assertEqual(skips, {".bashrc", ".profile", ".config", ".local"})
    def test_compress_nothing(self):
        self.assertEqual(adapter.compress_skips(self.RELS, set()), set())

    def test_compress_scattered_large(self):
        rels = [".local/share/x/%d" % i for i in range(600)]
        unchecked = {r for r in rels if r.endswith("0")}   # every 10th
        skips = adapter.compress_skips(rels, unchecked)
        self.assertEqual(skips, unchecked)                 # nothing compressible


# ---------------------------------------------------------------------------
# commands, env, phases, prompts, redaction
# ---------------------------------------------------------------------------

class TestCommands(unittest.TestCase):

    def test_dry_run(self):
        cmd = adapter.build_command("/t/bin/rice-backup.sh", dry_run=True,
                                    repo="a/b", home="/h", include_system=True)
        self.assertEqual(cmd, ["bash", "/t/bin/rice-backup.sh", "--dry-run",
                               "--include-system", "--repo", "a/b", "--home", "/h"])

    def test_run_with_selection(self):
        cmd = adapter.build_command("/t/bin/rice-backup.sh", assume_yes=True,
                                    repo="a/b", exclude_from="/s/sel.txt",
                                    allow_oversize=True)
        self.assertEqual(cmd, ["bash", "/t/bin/rice-backup.sh", "--yes",
                               "--repo", "a/b", "--allow-oversize",
                               "--exclude-from", "/s/sel.txt"])

    def test_export_has_no_repo(self):
        cmd = adapter.build_command("/t/bin/rice-backup.sh", export_path="/a/x.tar.gz",
                                    assume_yes=True, exclude_from="/s/sel.txt")
        self.assertEqual(cmd, ["bash", "/t/bin/rice-backup.sh", "--yes",
                               "--exclude-from", "/s/sel.txt",
                               "--export", "/a/x.tar.gz"])
        self.assertNotIn("--repo", cmd)

    def test_list_files_is_offline(self):
        cmd = adapter.build_command("/t/bin/rice-backup.sh", list_files=True,
                                    home="/h", repo="a/b")
        self.assertEqual(cmd, ["bash", "/t/bin/rice-backup.sh", "--list-files",
                               "--home", "/h"])
        self.assertNotIn("--repo", cmd)

    def test_follow_symlinks_default_adds_no_flag(self):
        cmd = adapter.build_command("/t/bin/rice-backup.sh", dry_run=True)
        self.assertNotIn("--no-follow-symlinks", cmd)
        self.assertNotIn("--follow-outside-home", cmd)

    def test_no_follow_symlinks_flag(self):
        cmd = adapter.build_command("/t/bin/rice-backup.sh", dry_run=True,
                                    follow_symlinks=False)
        self.assertIn("--no-follow-symlinks", cmd)
        self.assertNotIn("--follow-outside-home", cmd)

    def test_follow_outside_home_flag(self):
        cmd = adapter.build_command("/t/bin/rice-backup.sh", dry_run=True,
                                    follow_outside=True)
        self.assertIn("--follow-outside-home", cmd)
        self.assertNotIn("--no-follow-symlinks", cmd)

    def test_valid_repo(self):
        self.assertTrue(adapter.valid_repo("longme/rice-refrigerator"))
        self.assertTrue(adapter.valid_repo("a.b-c/d_e.f"))
        self.assertFalse(adapter.valid_repo("nodivider"))
        self.assertFalse(adapter.valid_repo("owner/"))
        self.assertFalse(adapter.valid_repo("own er/name"))
        self.assertFalse(adapter.valid_repo(""))

    def test_child_env_token_only_in_env(self):
        base = {"PATH": "/usr/bin", "RICE_TOKEN": "stale"}
        env = adapter.child_env("SECRET-TOKEN-VALUE", base=base)
        self.assertEqual(env["RICE_TOKEN"], "SECRET-TOKEN-VALUE")
        env2 = adapter.child_env(None, base=base)
        self.assertNotIn("RICE_TOKEN", env2)

    def test_parse_result(self):
        self.assertEqual(
            adapter.parse_result("[rice-backup] backup pushed: commit abc1234 "
                                 "-> https://github.com/test/backup.git"),
            ("push", "abc1234", "https://github.com/test/backup.git"))
        self.assertEqual(
            adapter.parse_result("[rice-backup] archive exported: commit deadbee "
                                 "-> /tmp/x.tar.gz"),
            ("export", "deadbee", "/tmp/x.tar.gz"))
        self.assertIsNone(adapter.parse_result("[rice-backup] dry-run complete"))


class TestPhases(unittest.TestCase):

    def test_all_phases(self):
        cases = [
            ("[rice-backup] collecting candidates from /home/u (read-only)...", "collect"),
            ("[rice-backup] content-scanning 24 candidate file(s) with the S4 rules...", "scan"),
            ("[rice-backup] staging into /tmp/rice-backup.AbC (0700, removed on exit)", "stage"),
            ("[rice-backup] committing, scanning (S4) and pushing...", "commit"),
            ("[rice-backup] committing, scanning (S4), writing the archive (no push)...", "commit"),
            ("[rice-backup] backup pushed: commit abc -> https://github.com/a/b.git", "finish"),
            ("[rice-backup] archive exported: commit abc -> /tmp/x.tar.gz", "finish"),
        ]
        for line, want in cases:
            self.assertEqual(adapter.phase_from_line(line), want, line)
        self.assertIsNone(adapter.phase_from_line(
            "[rice-backup] dry-run complete: nothing was staged, committed or pushed."))

    def test_phase_order_matches_labels(self):
        self.assertEqual(tuple(adapter.PHASE_LABELS[k] for k in adapter.PHASE_ORDER),
                         ("Collect", "Scan", "Stage", "Commit", "Push / Export"))


class TestPromptDetection(unittest.TestCase):

    def test_public_repo_typed_prompt(self):
        p = adapter.detect_prompt(
            "To push anyway, confirm the repository (type exactly: test/backup) ")
        self.assertIsNotNone(p)
        self.assertEqual(p.kind, "public-repo")
        self.assertEqual(p.expected, "test/backup")

    def test_repo_prompt(self):
        p = adapter.detect_prompt("Target GitHub repo (OWNER/NAME): ")
        self.assertEqual(p.kind, "repo")

    def test_confirm_prompt(self):
        p = adapter.detect_prompt(
            "Proceed with staging and pushing these 21 file(s)? [y/N] ")
        self.assertEqual(p.kind, "confirm")

    def test_generic_prompt(self):
        self.assertEqual(adapter.detect_prompt("Enter value: ").kind, "generic")

    def test_non_prompts(self):
        self.assertIsNone(adapter.detect_prompt("[rice-backup] ERROR: push failed"))
        self.assertIsNone(adapter.detect_prompt(""))
        self.assertIsNone(adapter.detect_prompt(
            "[rice-backup] WARNING: total 8 GiB exceeds the 1 GiB budget"))


class TestRedact(unittest.TestCase):

    def test_redact_replaces_all_occurrences(self):
        out = adapter.redact("token abc123 here abc123", "abc123")
        self.assertEqual(out, "token %s here %s" % (adapter.REDACTED, adapter.REDACTED))

    def test_redact_no_secret_noop(self):
        self.assertEqual(adapter.redact("unchanged", None), "unchanged")
        self.assertEqual(adapter.redact("unchanged", ""), "unchanged")


class TestExitMeanings(unittest.TestCase):

    def test_known_codes(self):
        titles = {rc: adapter.exit_meaning(rc)[0] for rc in range(6)}
        self.assertEqual(titles[0], "Success")
        self.assertIn("Aborted", titles[1])
        self.assertIn("Secret", titles[2])
        self.assertIn("push", titles[3].lower())
        self.assertIn("Authentication", titles[4])
        self.assertIn("budget", titles[5].lower())

    def test_negative_signal(self):
        title, body = adapter.exit_meaning(-15)
        self.assertEqual(title, "Cancelled")
        self.assertIn("signal 15", body)


class TestLineAssembler(unittest.TestCase):

    def test_chunked_lines(self):
        a = adapter.LineAssembler()
        self.assertEqual(a.feed("abc"), [])
        self.assertEqual(a.feed("def\nxy"), ["abcdef"])
        self.assertEqual(a.partial(), "xy")
        self.assertEqual(a.feed("z\n"), ["xyz"])
        self.assertEqual(a.partial(), "")

    def test_prompt_partial(self):
        a = adapter.LineAssembler()
        a.feed("To push anyway, confirm the repo")
        a.feed(" (type exactly: a/b) ")
        self.assertIn("type exactly: a/b", a.partial())
        consumed = a.consume_partial()
        self.assertIn("type exactly", consumed)
        self.assertEqual(a.partial(), "")

    def test_flush(self):
        a = adapter.LineAssembler()
        a.feed("trailing partial")
        self.assertEqual(a.flush(), ["trailing partial"])
        self.assertEqual(a.flush(), [])


# ---------------------------------------------------------------------------
# Runner (real subprocesses, still headless)
# ---------------------------------------------------------------------------

class TestRunner(unittest.TestCase):

    def test_streams_and_rc(self):
        r = adapter.Runner(["bash", "-c",
                            "printf 'line1\\n'; printf 'line2\\n' >&2; exit 0"]).start()
        out, err = r.collect_text(timeout=5)
        self.assertEqual(out, "line1\n")
        self.assertEqual(err, "line2\n")
        self.assertEqual(r.rc, 0)

    def test_prompt_relay_roundtrip(self):
        script = ("printf 'To push anyway, confirm the repository "
                  "(type exactly: test/backup) ' >&2; "
                  "read -r x; printf 'got:%s\\n' \"$x\"")
        r = adapter.Runner(["bash", "-c", script]).start()
        asm = adapter.LineAssembler()
        prompt = None
        deadline = time.monotonic() + 5
        while prompt is None and time.monotonic() < deadline:
            for tag, chunk in r.poll_events(timeout=0.2):
                if tag == "err":
                    asm.feed(chunk)
                    prompt = adapter.detect_prompt(asm.partial())
        self.assertIsNotNone(prompt)
        self.assertEqual(prompt.expected, "test/backup")
        self.assertTrue(r.write_line("test/backup"))
        out, _err = r.collect_text(timeout=5)
        self.assertIn("got:test/backup", out)

    def test_terminate(self):
        r = adapter.Runner(["bash", "-c", "sleep 30"]).start()
        time.sleep(0.2)
        r.terminate()
        rc = r.wait(timeout=5)
        self.assertNotEqual(rc, 0)
        self.assertTrue(r.cancelled)

    def test_write_line_after_exit_fails(self):
        r = adapter.Runner(["bash", "-c", "exit 0"]).start()
        r.wait(timeout=5)
        self.assertFalse(r.write_line("x"))


# ---------------------------------------------------------------------------
# guiconf persistence (D34)
# ---------------------------------------------------------------------------

class TestGuiconf(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def test_conf_roundtrip_and_modes(self):
        conf = guiconf.GuiConf(base=self.base)
        self.assertEqual(conf.load()["repo"], "")    # defaults when absent
        conf.values["repo"] = "test/backup"
        conf.values["include_system"] = True
        conf.values["window_width"] = 1200
        conf.save()
        self.assertEqual(stat.S_IMODE(os.stat(conf.path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.base).st_mode), 0o700)
        loaded = guiconf.GuiConf(base=self.base).load()
        self.assertEqual(loaded["repo"], "test/backup")
        self.assertTrue(loaded["include_system"])
        self.assertEqual(loaded["window_width"], 1200)

    def test_conf_corrupt_falls_back_to_defaults(self):
        p = guiconf.app_dir(self.base) / guiconf.CONF_FILE_NAME
        p.write_text("[general\nbroken", encoding="utf-8")
        conf = guiconf.GuiConf(base=self.base)
        self.assertEqual(conf.load()["repo"], "")

    def test_selection_roundtrip_and_format(self):
        store = guiconf.SelectionStore(base=self.base)
        self.assertEqual(store.load(), set())
        store.save({".local/share/fonts", ".bashrc"})
        self.assertEqual(stat.S_IMODE(os.stat(store.path).st_mode), 0o600)
        text = store.path.read_text(encoding="utf-8")
        self.assertIn("--exclude-from", text)        # header documents the format
        again = guiconf.SelectionStore(base=self.base).load()
        self.assertEqual(again, {".local/share/fonts", ".bashrc"})

    def test_parse_selection_comments_and_blanks(self):
        self.assertEqual(guiconf.parse_selection(
            "# comment\n\n  .bashrc  \n.local/share/fonts\n"),
            {".bashrc", ".local/share/fonts"})
        self.assertEqual(guiconf.parse_selection(""), set())

    def test_serialize_selection_roundtrip(self):
        text = guiconf.serialize_selection({".config/vim", ".bashrc"})
        self.assertEqual(guiconf.parse_selection(text),
                         {".config/vim", ".bashrc"})

    def test_empty_selection_saves_header_only(self):
        store = guiconf.SelectionStore(base=self.base)
        store.save(set())
        self.assertEqual(store.load(), set())


# ---------------------------------------------------------------------------
# backend version contract
# ---------------------------------------------------------------------------

class TestBackendVersion(unittest.TestCase):

    def test_toolroot_version_is_new_enough(self):
        root = adapter.default_toolroot()
        v = adapter.backend_version(root)
        self.assertRegex(v, r"^0\.\d+\.\d+$")
        self.assertTrue(adapter.backend_new_enough(root))
        self.assertGreaterEqual(adapter.version_tuple(v), (0, 2, 0))


# ---------------------------------------------------------------------------
# rules.conf read/write (R5, mirrors lib/collect.sh rice_rules_*)
# ---------------------------------------------------------------------------

class TestRulesIO(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def test_default_path_xdg_and_base(self):
        old = os.environ.get("XDG_CONFIG_HOME")
        try:
            os.environ["XDG_CONFIG_HOME"] = os.path.join(self.base, "cfg")
            p = adapter.rules_default_path()
            self.assertEqual(p, Path(self.base) / "cfg" / "rice-backup" / "rules.conf")
            p2 = adapter.rules_default_path(base=os.path.join(self.base, "app"))
            self.assertEqual(p2, Path(self.base) / "app" / "rules.conf")
        finally:
            if old is None:
                os.environ.pop("XDG_CONFIG_HOME", None)
            else:
                os.environ["XDG_CONFIG_HOME"] = old

    def test_entry_problem_mirrors_backend(self):
        self.assertIsNone(adapter.rules_entry_problem(".bash_history"))
        self.assertIsNone(adapter.rules_entry_problem("  Dev/dotfiles # note "))
        self.assertIsNotNone(adapter.rules_entry_problem("/abs/path"))
        self.assertIsNotNone(adapter.rules_entry_problem("a/../b"))
        self.assertIsNotNone(adapter.rules_entry_problem("."))
        self.assertIsNotNone(adapter.rules_entry_problem(""))
        self.assertIsNotNone(adapter.rules_entry_problem("   # only comment"))

    def test_parse_size_text_mirrors_backend(self):
        self.assertEqual(adapter.parse_size_text("1024"), 1024)
        self.assertEqual(adapter.parse_size_text("50M"), 50 * 1024 ** 2)
        self.assertEqual(adapter.parse_size_text("2G"), 2 * 1024 ** 3)
        self.assertEqual(adapter.parse_size_text("10k"), 10 * 1024)
        self.assertEqual(adapter.parse_size_text("20MiB"), 20 * 1024 ** 2)
        self.assertEqual(adapter.parse_size_text("1 GiB"), 1024 ** 3)
        self.assertIsNone(adapter.parse_size_text("10X"))
        self.assertIsNone(adapter.parse_size_text("abc"))
        self.assertIsNone(adapter.parse_size_text(""))
        self.assertIsNone(adapter.parse_size_text("M"))

    def test_parse_rules_text_full_sections(self):
        rc = adapter.parse_rules_text(
            "# header comment\n"
            "[include-file]\n.Xresources\n\n"
            "[INCLUDE-DIR]\nDev/dotfiles\nDev/dotfiles\n\n"
            "[skip-dir]\n.local/share/wallpapers\n\n"
            "[allow]\n.bash_history\n\n"
            "[ack-scan]\n.config/myapp/token.ini\n\n"
            "[size]\nfile_cap = 50M\ntotal_budget = 2G\n")
        self.assertEqual(rc.include_files, [".Xresources"])   # section case-insensitive
        self.assertEqual(rc.include_dirs, ["Dev/dotfiles"])   # dedupe keeps first
        self.assertEqual(rc.skip_dirs, [".local/share/wallpapers"])
        self.assertEqual(rc.allow, [".bash_history"])
        self.assertEqual(rc.ack_scan, [".config/myapp/token.ini"])
        self.assertEqual(rc.file_cap, "50M")
        self.assertEqual(rc.total_budget, "2G")
        self.assertEqual(rc.warnings, [])

    def test_parse_rules_text_warnings(self):
        rc = adapter.parse_rules_text(
            "[bogus]\nnope\n"
            "free_entry\n"
            "key = value\n"
            "[size]\nfile_cap = banana\nunknown = 1\n"
            "[allow]\n/../escape\n")
        self.assertEqual(rc.allow, [])
        self.assertEqual(rc.file_cap, "")
        self.assertEqual(len(rc.warnings), 7)  # bogus section; two entries
        # outside a section; key=value outside [size]; bad size value;
        # unknown [size] key; the invalid /../escape entry
        joined = "; ".join(rc.warnings)
        self.assertIn("unknown section", joined)
        self.assertIn("outside a known section", joined)
        self.assertIn("outside [size]", joined)
        self.assertIn("invalid file_cap", joined)
        self.assertIn("unknown [size] key", joined)

    def test_render_parse_roundtrip(self):
        rc = adapter.RulesConf()
        rc.include_dirs = ["Dev/dotfiles", "Notes"]
        rc.skip_dirs = [".local/share/wallpapers"]
        rc.allow = [".bash_history"]
        rc.ack_scan = [".config/myapp/token.ini"]
        rc.file_cap = "50M"
        rc.total_budget = "2G"
        text = adapter.render_rules(rc)
        self.assertIn("[include-dir]", text)
        self.assertIn("file_cap = 50M", text)
        again = adapter.parse_rules_text(text)
        self.assertEqual(again, adapter.parse_rules_text(adapter.render_rules(again)))
        self.assertEqual(again.include_dirs, rc.include_dirs)
        self.assertEqual(again.skip_dirs, rc.skip_dirs)
        self.assertEqual(again.allow, rc.allow)
        self.assertEqual(again.ack_scan, rc.ack_scan)
        self.assertEqual(again.file_cap, "50M")
        self.assertEqual(again.total_budget, "2G")

    def test_read_missing_is_empty_never_raises(self):
        rc = adapter.read_rules(Path(self.base) / "nope" / "rules.conf")
        self.assertEqual(rc, adapter.RulesConf())

    def test_write_rules_private_modes(self):
        path = Path(self.base) / "rice-backup" / "rules.conf"
        rc = adapter.RulesConf()
        rc.allow = [".bash_history"]
        adapter.write_rules(path, rc)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(path.parent).st_mode), 0o700)
        back = adapter.read_rules(path)
        self.assertEqual(back.allow, [".bash_history"])


# ---------------------------------------------------------------------------
# --show-rules parsing (R5)
# ---------------------------------------------------------------------------

SHOW_RULES_LOADED = """\
=== rice-backup effective rules ===
version     : 0.4.0
rules file  : /home/tester/.config/rice-backup/rules.conf (loaded)
file cap    : 50 MiB per file (GitHub rejects files >100 MiB)
total budget: 1 GiB (a real run above it needs --allow-oversize)
symlinks    : follow=1 outside-home=0

include files (top-level, exact name under the home):
  .bashrc                         (default)
  .Xresources                     (rules.conf)

include dirs (walked recursively):
  .config                         (default)
  .local                          (default)
  Dev/dotfiles                    (rules.conf)

skipped include roots ([skip-dir], not walked at all):
  .local/share/wallpapers         (default)

deny dirs (L1, path prefixes; hard = never overridable via [allow]):
  .ssh                            (hard)
  .config/mozilla                 (hard)
  .config/discord                 (soft)

deny file globs (L1, matched against the whole path):
  *history*                       (soft)
  *.pem                           (hard)

allow overrides ([allow]/--allow, soft rules only):
  .bash_history                   (rules.conf)
  .zsh_history                    (flag)

scan acknowledgements ([ack-scan], exact file paths only):
  .config/myapp/token.ini         (rules.conf)
  ackable rules: cred-assign, bearer-token, url-embedded-creds,
  aws-secret-label - token-shaped rules are always refused

cache/junk patterns (L3): .cache/**, */cache|Cache|caches/**,
  node_modules, __pycache__, .npm, .git, Trash, .config/fcitx/dbus, *.log

/etc allowlist (only with --include-system):
  /etc/dconf/db/local
  /etc/systemd/system

notes: deny rules are NAME-based. --explain PATH reports which layer
and rule claims any given path.
"""


class TestShowRules(unittest.TestCase):

    def test_defaults_only_shape(self):
        text = SHOW_RULES_LOADED.replace(
            "rules file  : /home/tester/.config/rice-backup/rules.conf (loaded)",
            "rules file  : (none - defaults only; create "
            "/home/tester/.config/rice-backup/rules.conf to customize)")
        sr = adapter.parse_show_rules(text)
        self.assertTrue(sr.parsed_ok)
        self.assertEqual(sr.rules_file, "")
        self.assertEqual(sr.version, "0.4.0")

    def test_loaded_shape(self):
        sr = adapter.parse_show_rules(SHOW_RULES_LOADED)
        self.assertTrue(sr.parsed_ok)
        self.assertEqual(sr.rules_file,
                         "/home/tester/.config/rice-backup/rules.conf")
        self.assertEqual(sr.file_cap, "50 MiB")
        self.assertEqual(sr.total_budget, "1 GiB")
        self.assertTrue(sr.follow)
        self.assertFalse(sr.follow_outside)
        self.assertIn(adapter.RuleRow(".bashrc", "default"), sr.include_files)
        self.assertIn(adapter.RuleRow(".Xresources", "rules.conf"),
                      sr.include_files)
        self.assertIn(adapter.RuleRow("Dev/dotfiles", "rules.conf"),
                      sr.include_dirs)
        self.assertIn(adapter.RuleRow(".config", "default"), sr.include_dirs)
        self.assertEqual(sr.default_dirs(), [".config", ".local"])
        self.assertEqual(sr.default_files(), [".bashrc"])
        self.assertEqual([r.value for r in sr.skip_dirs],
                         [".local/share/wallpapers"])
        hard_dirs = [r.value for r in sr.deny_dirs if r.note == "hard"]
        soft_dirs = [r.value for r in sr.deny_dirs if r.note == "soft"]
        self.assertIn(".ssh", hard_dirs)
        self.assertIn(".config/mozilla", hard_dirs)
        self.assertEqual(soft_dirs, [".config/discord"])
        hard_globs = [r.value for r in sr.deny_globs if r.note == "hard"]
        self.assertEqual(hard_globs, ["*.pem"])
        self.assertIn(adapter.RuleRow(".bash_history", "rules.conf"), sr.allow)
        self.assertIn(adapter.RuleRow(".zsh_history", "flag"), sr.allow)
        self.assertEqual([r.value for r in sr.ack],
                         [".config/myapp/token.ini"])
        self.assertEqual(sr.etc_allow, ["/etc/dconf/db/local",
                                        "/etc/systemd/system"])

    def test_garbage_is_not_fatal(self):
        sr = adapter.parse_show_rules("total garbage\nno header\n")
        self.assertFalse(sr.parsed_ok)
        self.assertEqual(sr.include_dirs, [])

    def test_entry_with_spaces_and_parens(self):
        text = SHOW_RULES_LOADED.replace(
            "  Dev/dotfiles                    (rules.conf)",
            "  my dir (x)                      (rules.conf)")
        sr = adapter.parse_show_rules(text)
        self.assertIn(adapter.RuleRow("my dir (x)", "rules.conf"),
                      sr.include_dirs)


# ---------------------------------------------------------------------------
# --explain parsing (R5)
# ---------------------------------------------------------------------------

EXPLAIN_MULTI = """\
[rice-backup] collecting candidates from /home/tester (originals are read-only)...
[rice-backup] content-scanning 24 candidate file(s) with the S4 rules...
=== rice-backup explain ===
home : /home/tester
.bash_history
      verdict  : excluded
      layer    : L1 deny
      rule     : deny-file:.bash_history
      override : soft rule - [allow] can re-include it
.ssh/id_rsa
      verdict  : not considered
      layer    : include roots
      rule     : outside every include root (see --show-rules)
.config/myapp/token.ini
      verdict  : excluded
      layer    : L2 scan
      rule     : scan:cred-assign
      override : heuristic rule - [ack-scan] can acknowledge it
/dev/abs/path
      verdict  : not explainable
      rule     : absolute path outside the home
.config/acked.ini
      verdict  : included
      layer    : L2 scan
      rule     : scan:cred-assign - acknowledged via [ack-scan], kept after review
      override : acknowledged via [ack-scan] (heuristic rule, eyes-on decision)
[rice-backup] explain complete: read-only, nothing was staged or pushed.
"""


class TestExplain(unittest.TestCase):

    def test_multi_path_parse(self):
        out = adapter.parse_explain(EXPLAIN_MULTI)
        self.assertTrue(out.parsed_ok)
        self.assertEqual(out.home, "/home/tester")
        by = {r.path: r for r in out.rows}
        self.assertEqual(len(out.rows), 5)
        bh = by[".bash_history"]
        self.assertEqual(bh.verdict, "excluded")
        self.assertEqual(bh.layer, "L1 deny")
        self.assertEqual(bh.rule, "deny-file:.bash_history")
        self.assertIn("soft rule", bh.override)
        srk = by[".ssh/id_rsa"]
        self.assertEqual(srk.verdict, "not considered")
        self.assertEqual(srk.layer, "include roots")
        tk = by[".config/myapp/token.ini"]
        self.assertEqual(tk.layer, "L2 scan")
        self.assertEqual(tk.rule, "scan:cred-assign")
        self.assertIn("heuristic rule", tk.override)
        absrow = by["/dev/abs/path"]
        self.assertEqual(absrow.verdict, "not explainable")
        self.assertEqual(absrow.layer, "")            # layer line absent
        acked = by[".config/acked.ini"]
        self.assertEqual(acked.verdict, "included")
        self.assertIn("acknowledged", acked.override)
        self.assertEqual(out.first(), bh)

    def test_noise_lines_never_become_rows(self):
        out = adapter.parse_explain(EXPLAIN_MULTI)
        for r in out.rows:
            self.assertFalse(r.path.startswith("[rice-backup]"))
            self.assertNotIn("explain complete", r.path)

    def test_garbage_is_not_fatal(self):
        out = adapter.parse_explain("nothing here\n")
        self.assertFalse(out.parsed_ok)
        self.assertEqual(out.rows, [])
        self.assertIsNone(out.first())


# ---------------------------------------------------------------------------
# ack rails mirror + explain -> stanza (R5)
# ---------------------------------------------------------------------------

class TestAckRails(unittest.TestCase):

    def test_only_heuristic_rules_are_ackable(self):
        for rule in adapter.ACKABLE_SCAN_RULES:
            self.assertTrue(adapter.ack_is_allowed(rule), rule)
        for rule in ("gh-classic", "gh-fine-grained", "private-key",
                     "aws-access-key", "google-api-key", "slack-token",
                     "stripe-live-key", "jwt", "exact", ""):
            self.assertFalse(adapter.ack_is_allowed(rule), rule)

    def test_rules_stanza_sections(self):
        self.assertEqual(adapter.rules_stanza("allow", [".bash_history"]),
                         "[allow]\n.bash_history\n")
        self.assertEqual(adapter.rules_stanza("ack-scan", ["a", "b"]),
                         "[ack-scan]\na\nb\n")
        with self.assertRaises(ValueError):
            adapter.rules_stanza("bogus", ["x"])


class TestExplainStanza(unittest.TestCase):

    def _row(self, layer, rule="", override="", path=".bash_history",
             verdict="excluded"):
        return adapter.ExplainRow(path=path, verdict=verdict, layer=layer,
                                  rule=rule, override=override)

    def test_l1_soft_offers_allow(self):
        row = self._row("L1 deny", "deny-file:.bash_history",
                        "soft rule - [allow] can re-include it")
        stanza, note = adapter.explain_stanza(row)
        self.assertEqual(stanza, "[allow]\n.bash_history\n")
        self.assertIn("soft rule", note)

    def test_l1_hard_refused(self):
        row = self._row("L1 deny", "deny-glob:*.pem",
                        "override : HARD CORE - never overridable via [allow]"
                        .replace("override : ", ""))
        stanza, note = adapter.explain_stanza(row)
        self.assertEqual(stanza, "")
        self.assertIn("hard core", note)

    def test_l2_heuristic_offers_ack(self):
        row = self._row("L2 scan", "scan:cred-assign",
                        "heuristic rule - [ack-scan] can acknowledge it",
                        path=".config/myapp/token.ini")
        stanza, note = adapter.explain_stanza(row)
        self.assertEqual(stanza, "[ack-scan]\n.config/myapp/token.ini\n")
        self.assertIn("eyes-on review", note)

    def test_l2_token_shaped_refused(self):
        for override in ("NEVER acknowledgeable - token-shaped or key material",
                         "ack REFUSED - gh-fine-grained is token-shaped/key "
                         "material, never acknowledgeable"):
            row = self._row("L2 scan", "scan:gh-fine-grained", override)
            stanza, note = adapter.explain_stanza(row)
            self.assertEqual(stanza, "")
            self.assertIn("token-shaped", note)

    def test_l2_already_acknowledged_points_at_removal(self):
        row = self._row("L2 scan", "scan:cred-assign",
                        "acknowledged via [ack-scan] (heuristic rule, "
                        "eyes-on decision)", verdict="included")
        stanza, note = adapter.explain_stanza(row)
        self.assertEqual(stanza, "")
        self.assertIn("remove the [ack-scan] entry", note)

    def test_include_roots_dir(self):
        row = self._row("include roots", "outside every include root",
                        path="Dev/notes/todo.txt", verdict="not considered")
        stanza, note = adapter.explain_stanza(row)
        self.assertEqual(stanza, "[include-dir]\nDev/notes\n")
        stanza, note = adapter.explain_stanza(row, deny_dirs=[".ssh"])
        self.assertEqual(stanza, "[include-dir]\nDev/notes\n")

    def test_include_roots_under_deny_dir_refused(self):
        row = self._row("include roots", "outside every include root",
                        path=".ssh/id_rsa", verdict="not considered")
        stanza, note = adapter.explain_stanza(row, deny_dirs=[".ssh"])
        self.assertEqual(stanza, "")
        self.assertIn("deny dir .ssh", note)
        # case-insensitive prefix match (backend lowercases deny dirs)
        deep = self._row("include roots", "outside every include root",
                         path=".Config/Mozilla/prefs.js", verdict="not considered")
        stanza, note = adapter.explain_stanza(deep, deny_dirs=[".config/mozilla"])
        self.assertEqual(stanza, "")
        self.assertIn("deny dir .config/mozilla", note)

    def test_include_roots_toplevel_file(self):
        row = self._row("include roots", "outside every include root",
                        path=".Xresources", verdict="not considered")
        stanza, note = adapter.explain_stanza(row)
        self.assertEqual(stanza, "[include-file]\n.Xresources\n")

    def test_size_cap_and_unknown_offer_nothing(self):
        row = self._row("size cap", "larger than 50 MiB (60 MiB)",
                        verdict="skipped")
        stanza, note = adapter.explain_stanza(row)
        self.assertEqual(stanza, "")
        self.assertIn("file_cap", note)
        row = self._row("selection", "--exclude-from entry")
        self.assertEqual(adapter.explain_stanza(row), ("", ""))


# ---------------------------------------------------------------------------
# build_command: --show-rules / --explain (R5)
# ---------------------------------------------------------------------------

class TestBuildCommandRules(unittest.TestCase):

    def test_show_rules_offline_no_repo(self):
        argv = adapter.build_command("/opt/rice-backup.sh", show_rules=True,
                                     repo="test/backup", home="/home/t")
        self.assertEqual(argv, ["bash", "/opt/rice-backup.sh",
                                "--show-rules", "--home", "/home/t"])

    def test_explain_paths_come_last(self):
        argv = adapter.build_command("/opt/rice-backup.sh",
                                     explain=[".bash_history", ".ssh/id_rsa"],
                                     repo="test/backup", home="/home/t")
        self.assertEqual(argv, ["bash", "/opt/rice-backup.sh",
                                "--home", "/home/t",
                                "--explain", ".bash_history", ".ssh/id_rsa"])
        # every argument after --explain is a path: nothing may follow them
        self.assertEqual(argv[argv.index("--explain"):],
                         ["--explain", ".bash_history", ".ssh/id_rsa"])

    def test_dry_run_still_gets_repo(self):
        argv = adapter.build_command("/opt/rice-backup.sh", dry_run=True,
                                     repo="test/backup", home="/home/t")
        self.assertIn("--repo", argv)
        self.assertNotIn("--explain", argv)
        self.assertNotIn("--show-rules", argv)


if __name__ == "__main__":
    unittest.main()

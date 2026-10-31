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
  oversized (>50M): 1 item(s)
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
  oversized (>50M): 0 item(s)
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
  oversized (>50M): 0 item(s)
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
        big = s.block("oversized (>50M)")
        self.assertEqual(big.items[0][0], ".config/bigapp/data.bin")
        self.assertEqual(big.items[0][1], "60 MiB")
        cache = s.block("caches/junk")
        self.assertIn((".cache/", ""), cache.items)

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
        self.assertRegex(v, r"^0\.2\.\d+$")
        self.assertTrue(adapter.backend_new_enough(root))


if __name__ == "__main__":
    unittest.main()

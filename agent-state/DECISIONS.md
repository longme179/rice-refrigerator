# DECISIONS — logged assumptions and design decisions (never contains secrets)

Format: [DECISION] / [ASSUMPTION] with ID, date, reason.

- [DECISION] D1 2026-10-31 — Language is Bash (>=4.2). The constraint "only git and the default
  interpreter" is satisfied by bash on all three distros; python3 is not guaranteed on fresh Arch /
  minimal Ubuntu images. Coreutils+findutils+tar+git are the only runtime dependencies.
- [DECISION] D2 2026-10-31 — Two entrypoints (bin/rice-backup.sh, bin/rice-restore.sh) because the
  task explicitly asks for "a matching restore tool"; "one entrypoint" is interpreted as one command
  per flow with zero install steps. `rice-backup.sh restore` additionally passes through to the
  restore tool so a single command can do both.
- [DECISION] D3 2026-10-31 — The scanner engine is GNU grep (two-phase: combined -e list for speed,
  then per-rule attribution), not awk regex: Ubuntu's default awk is mawk with incomplete ERE
  (interval) support, while GNU grep behaves identically on Fedora/Arch/Ubuntu.
- [DECISION] D4 2026-10-31 — The Phase-0 commit (PLAN/STATE/DECISIONS/journal) is pushed BEFORE
  scripts/secret-scan.sh exists (Phase-0 ordering: plan first, then tool code). For that one push an
  ad-hoc equivalent scan runs: exact PAT via stdin-fed `grep -aIlF -f -` plus the core S4 regexes
  over `git ls-files`. Every later push uses the real scanner + pre-push hook.
- [ASSUMPTION] A1 2026-10-31 — The sandbox is Debian 13, not Ubuntu; apt-family tests here are
  labeled "debian-trixie as ubuntu-family proxy". Real Ubuntu is NOT directly tested from here.
- [ASSUMPTION] A2 2026-10-31 — For PAT-over-https git, any non-empty username works with the PAT as
  password. Validated RAN: the workspace clone succeeded through the askpass helper.
- [ASSUMPTION] A3 2026-10-31 — DE is unknown on the user's machine; detection uses
  XDG_CURRENT_DESKTOP/DESKTOP_SESSION then binary presence, and is informational only. The dconf
  dump is gated on `command -v dconf` (not on the DE guess) so it never depends on a wrong guess.
- [DECISION] D5 2026-10-31 — ~/.var/app (flatpak app data) is excluded by default: it commonly holds
  browser/KeePassXC flatpak data with credentials; the flatpak app list is still captured in the
  package inventory so the setup remains reproducible. Documented in README.
- [DECISION] D6 2026-10-31 — A re-run with zero changes still creates a commit (--allow-empty),
  because the requirement is "re-running creates a new commit".
- [DECISION] D7 2026-10-31 — History-rewrite runbook on a pre-push secret hit: create an orphan
  branch from the clean tree, commit, move the local branch pointer (this local rewrite is the one
  permitted use of history rewriting — nothing is ever force-pushed; the remote only ever receives a
  new, clean commit). If the secret may already be on the remote → tell the user to revoke the PAT
  immediately. Full runbook in README SECURITY.
- [DECISION] D8 2026-10-31 — Package "known mapping" for cross-distro restore is a small explicit
  alias table only (e.g. vim-enhanced/vim, google-chrome variants); everything else is listed in
  UNMAPPED.txt. No name guessing.
- [ASSUMPTION] A4 2026-10-31 — GitHub API base and git base are fixed to https://github.com /
  https://api.github.com; tests override only through RICE_TEST_GIT_BASE (file:// bare repos) and
  PATH-mocked gh/curl. The tool refuses to push to any non-github URL unless the test override env
  is present.

## Session 2 additions (testing + hardening)

- [DECISION] D9 2026-10-31 — Test canaries are FAKE values generated PROGRAMMATICALLY at RUNTIME
  by tests/fixtures/build.sh (exact regex shapes, e.g. 45 B's after github_pat_) into the
  git-ignored tests/fixtures/home/ and tests/canaries.txt; only the clean fixture
  (tests/fixtures/home-clean/) and the generator are committed. Two reasons: (a) a hand-typed
  canary one character short of a regex minimum (39 vs 40) passed BOTH scan layers and reached a
  test backup repo — caught only by the exact-value grep (AC-03); (b) GitHub PUSH PROTECTION
  rejected the milestone push while canaries were committed ("Push cannot contain secrets",
  Stripe-pattern locations in tests/canaries.txt and the stripe fixture) — even fake
  token-shaped data cannot live in git. The generator's own source avoids pattern shapes
  (rep()-construction, split PEM header strings, split URL-credentials literals).
- [DECISION] D10 2026-10-31 — The 60 MiB size-cap fixture is created at RUNTIME as a sparse file
  by the test suite (not committed) so the repository clone stays lightweight.
- [DECISION] D11 2026-10-31 — rice-restore re-applies exact file modes from manifest.tsv after
  copying, because git carries only the executable bit. The manifest is parsed with
  `awk -F'\t'`: an `IFS=$'\t' read` collapses the consecutive tabs of the empty target column
  and silently shifts every following field (that bug disabled mode restoration entirely).
- [DECISION] D12 2026-10-31 — The pre-push hook scans EVERY commit in the pushed range, not just
  the tip. T11 proved tip-only scanning lets a secret pass when the file is deleted in a
  follow-up commit. The README SECURITY runbook (orphan-branch rebuild) is exercised by T11.
- [DECISION] D13 2026-10-31 — /etc allowlist files (collected only with --include-system) are
  content-scanned at collection time with the same L2 rules as $HOME candidates, so a hit is
  excluded BEFORE staging instead of aborting the push later.
- [DECISION] D14 2026-10-31 — rice_collect_home runs a transparency probe over top-level
  entries plus a small deep-probe list: deny-listed or cache items OUTSIDE the include roots
  (e.g. ~/.ssh, ~/.mozilla, ~/.cache) are reported in EXCLUDED.md/SKIPPED.md with their rule.
  They were always excluded; now the user can SEE that they were.
- [DECISION] D15 2026-10-31 — The backup dry-run lists the first 40 upload paths (names only),
  and the restore dry-run previews the generated package script into its temp workdir, so both
  dry-runs stay pure no-ops while still showing what would happen.
- [ASSUMPTION] A5 2026-10-31 — bash >= 4.4 and git >= 2.28 are acceptable minimums (associative
  arrays, ${var,,}, mapfile -d '', git init -b). All three target distros' current releases
  ship newer versions; documented in README.
- [DECISION] D16 2026-10-31 — rice_info/rice_warn/rice_err concatenate arguments (no printf
  formatting); call sites that need formatting use printf directly. Reason: several call sites
  pass exit codes or user-controlled paths as extra args, which printf formatting would
  misinterpret, and a % character inside an interpolated path would break a format string.

## Session 3 additions (real-user dry-run feedback)

- [DECISION] D17 2026-10-31 — Firefox profile locations are denied in BOTH places: `.mozilla`
  AND `.config/mozilla` (plus `.local/share/mozilla`, `.librewolf`, `.waterfox`, `.zen`,
  `.floorp`). A real Fedora 44 dry-run proved current Firefox keeps its profile under
  `~/.config/mozilla/firefox/<id>.default-release/` — cookies.sqlite, key4.db, logins.json,
  places.sqlite and non-cache site storage were inside the include set, excluded only by the
  `*history*` glob and cache paths. Binary session stores carry no token shape, so the L2
  content scan can NEVER catch them; the deny list is the only effective layer (README
  Limitations now says so explicitly).
- [DECISION] D18 2026-10-31 — rice_auth_init sets RICE_AUTH_MODE=pat on BOTH PAT paths (env
  token and hidden prompt). Previously the mode stayed empty, which (a) printed a blank
  `auth:` line in the summary — the symptom the user actually noticed — and (b) made
  rice_auth_setup_git skip GIT_ASKPASS installation, so real PAT-mode pushes could not
  authenticate. The suite missed it because tests mock gh or push to file:// remotes.
  Regression test T21 asserts the mode at unit level and in the summary.
- [DECISION] D19 2026-10-31 — The dry-run summary shows per-section byte totals and the top 15
  largest candidates (sorted by bytes, human-readable), and a HARD total budget
  (RICE_TOTAL_MAX_BYTES, default 1 GiB) refuses the real run (exit 5) unless --allow-oversize
  is given; dry-run warns instead. Rationale: the user's real dry-run was 8 GiB with only a
  single warning line and no way to see what was big — a warning that cannot stop anything is
  not a control.
- [DECISION] D20 2026-10-31 — Package inventories gain gnome-extensions (list + list --enabled,
  best-effort with availability notes) and the plan summary gains pipx: and gnome-ext: keys
  (pipx was collected but invisible in the summary; gnome-extensions was not collected at all
  despite PLAN section 4 requiring it).
- [DECISION] D21 2026-10-31 — `.config/fcitx/dbus/*` runtime peer-registration files are L3
  junk (skipped + listed), not rice. Found in the user's include list; harmless but noise.
- [DECISION] D22 2026-10-31 — secret-scan.sh git mode streams blobs through GNU grep (phase 1:
  combined patterns case-insensitively to find suspects; phase 2: per-rule attribution with
  each rule's real case sensitivity) instead of per-rule `git grep`. Measured cause: git
  grep's ERE engine backtracks catastrophically on the url-embedded-creds rule — 16.9 s on a
  51-file fixture vs 0.042 s after the rewrite (a 400x speedup); a full test backup dropped
  from 34.5 s to 0.96 s. This also affects users directly: the pre-push hook runs git-mode
  scans on every push, and any backup containing URLs would have hit the same wall. The exact
  needle pass stays on `git grep -F` (literal search, no backtracking, pattern via stdin).
- [ASSUMPTION] A6 2026-10-31 — A 1 GiB default budget is the right trade-off for the layer of
  users this tool targets (configs, themes, fonts, wallpapers); heavy-media users have
  --allow-oversize and RICE_TOTAL_MAX_BYTES. Revisit if real-world dry-runs routinely exceed
  it with legitimate rice content.

## Session 4 additions (GUI frontend plan — all PROPOSED, no implementation yet)

- [PROPOSAL] D23 2026-10-31 — The GUI is an OPTIONAL layer. The original portability rule
  (fresh distro, git + default interpreter, no third-party pip/npm) is SCOPED to the CLI
  path, which stays fully portable and first-class. The GUI may require optional system
  packages but must self-check at startup and exit with exact per-distro install commands.
  Rationale: a GUI cannot honestly promise "runs anywhere with git" on all three distros;
  scoping the promise keeps it honest while the CLI guarantee is untouched.
- [PROPOSAL] D24 2026-10-31 — Stack: Python + PyGObject (GTK4, libadwaita when importable,
  plain GTK4 otherwise), files under gui/, launched standalone; no pip/npm/compile steps.
  Alternatives were scored (stdlib-web UI, zenity, Qt, Tauri/Electron) — see GUI-PLAN.md
  §3. The stdlib-web option is the strongest future alternative (SSH/headless use) and is
  kept cheap to adopt later because adapter.py is display-free. User may override G1.
- [PROPOSAL] D25 2026-10-31 — PAT handling in the GUI: hidden entry -> memory -> child
  process environment (RICE_TOKEN) only; wiped on close; on-screen redaction of the token
  value in every displayed log line; no disk logs; never argv/URL/title/config/clipboard.
  Mirrors S1/S2 with GUI-specific enforcement.
- [PROPOSAL] D26 2026-10-31 — Interactive prompts: the GUI passes --yes (it asked the
  confirmation itself) and relays the ONE surviving prompt — the public-repo typed
  confirmation — via a modal writing to child stdin. Unrecognized prompts get a generic
  relay dialog so a stdin-blocked child is always recoverable. Cancel is pre-push only
  (SIGTERM); stale 0700 staging dirs are detected and offered for cleanup at startup.
  The clean fix (backend trapping INT/TERM) is deferred until after the user's backend
  testing, listed in GUI-PLAN.md §5.4.
- [PROPOSAL] D27 2026-10-31 — gui.conf (~/.config/rice-backup/gui.conf, configparser,
  0600) stores ONLY repo owner/name, window geometry and UI preferences — nothing
  credential-shaped; explicitly safe for the backup itself to collect (L2 scans it anyway).

## Session 5 additions (user locks the GUI plan decisions)

- [DECISION] D28 2026-10-31 — G1 CONFIRMED by the user: Python + PyGObject (GTK4,
  libadwaita when importable) is the main GUI track. D23–D27 stand as proposed; the
  stack question in GUI-PLAN.md §11 is closed.
- [DECISION] D29 2026-10-31 — M3 (restore GUI) is DEFERRED until the user has a real
  backup to restore. Milestone order: M0 → M1 → M2 → M4 → (M3 when lifted). The CLI
  restore path remains the supported flow meanwhile.
- [DECISION] D30 2026-10-31 — Language policy: English only for GUI strings, README,
  deliverables and agent reports from now on. The Vietnamese reading copy of the GUI
  plan in download/ is replaced by an English copy; no gettext/i18n layer in M4.
- [DECISION] D31 2026-10-31 — PROCESS (sandbox rollback): between sessions 4 and 5 the
  sandbox was restored to an old snapshot, destroying the three UNPUSHED local commits
  (4cc4c1b tool fixes, a1a0fc8, 6de3588) together with their git objects and the
  session-3/4 journals. Recovery combined the release tarball (byte-exact archive of
  4cc4c1b, found in the sandbox staging area) with the session-4 documents held verbatim
  in the agent context. Lesson made a standing rule: PUSH AT EVERY GREEN MILESTONE —
  local-only commits are one recycle away from loss.

## Session 7 additions (user request: GUI with tick/skip, session saving, archive export)

- [DECISION] D32 2026-10-31 — `--exclude-from FILE` selection: purely subtractive
  (applied AFTER the hard deny list AND the content scan, so a selection can
  never bypass either layer); home-relative paths, one per line, `#` comments,
  a directory entry skips its whole subtree; unmatched entries warn (typo
  guard); absolute paths and `..` rejected; excluded items reported as
  `user excluded` in the dry-run summary and reports/EXCLUDED.md; byte totals
  and the 1 GiB budget recomputed. Companion flag `--list-files`: offline,
  read-only, one `rel<TAB>bytes` row per surviving candidate — the dry-run
  upload list truncates at 40 rows, so the GUI checklist needs this machine-
  readable full view; rice_info lines share the stream and are skipped by
  consumers. The earlier "backend frozen until user testing" scope (GUI-PLAN
  C4) is superseded BY THE USER'S OWN request for tick/skip.
- [DECISION] D33 2026-10-31 — `--export FILE.tar.gz` offline archives: skips auth
  AND repo resolution entirely (no GitHub, no PAT); collection, deny list,
  content scan, manifest, reports and the size budget all behave exactly as
  usual (S4 scans still gate the commit); then tars the staging repository
  INCLUDING .git, so the extracted directory is a real git repo restorable
  with the EXISTING `rice-restore.sh --from file://<dir>`; relative paths
  resolve against the caller's cwd (top level never cd's); export replaces
  the push for that run — running twice yields both (documented in README);
  RESTORE.md carries an offline variant.
- [DECISION] D34 2026-10-31 — GUI session persistence: `~/.config/rice-backup/
  gui.conf` (repo/home/preferences/geometry, configparser, 0600) +
  `selection.txt` (the SKIPPED paths in exactly the --exclude-from format,
  0600), both containing nothing credential-shaped (D27) and passed to the
  backend verbatim as the selection file.
- [DECISION] D35 2026-10-31 — IMPLEMENTATION DETAIL (S4): Python-side cred-assign
  false positives (type annotations / attribute assignments whose left side
  is a rule keyword) are fixed by RENAMING identifiers (auth -> auth_mode,
  token attribute -> pat), never by whitelisting gui/ in scan-expect.txt —
  the scan must stay strict on the files that carry the PAT.
- [DECISION] D36 2026-10-31 — GUI file checklist uses virtualized Gtk.TreeView
  (native CellRendererToggle) instead of the GUI-PLAN's Gtk.ListView: same
  virtualization guarantee for 3600 rows, far simpler per-row checkboxes now
  that tick/skip exists. GTK 4.6+ is the compatibility floor (Ubuntu 22.04 LTS
  OK); no 4.10-only APIs. Backend prompts are read from raw stderr chunks
  because they end WITHOUT a newline (LineAssembler + partial detection).
- [DECISION] D37 2026-11-01 — SYMLINK FOLLOWING (user report: repo contained only the
  link blob for home/.config/quickshell/lme-shell while the real target directory was
  never fetched). Root cause: `find` never descends into symlinked dirs (only the link
  entry is collected) and staging tar runs without -h (links stored as link blobs).
  New behavior, ON by default, `--no-follow-symlinks` restores the old one:
  1) links whose canonical target is ALREADY covered by the backup itself (target is
     one of RICE_HOME_FILES or lives under an include root, or lives inside an
     already-followed target) stay symlink blobs — the content is in the repo anyway
     and the link round-trips (existing t06/t07/t15 semantics are CORRECT for these);
  2) links whose target is under $HOME but NOT covered are followed: the target
     directory/file content is fetched under the LINK path (repo becomes
     self-contained), and the original link is recorded in symlinks.tsv +
     reports/SYMLINKS.md so `rice-restore.sh --relink` can recreate the layout;
  3) a link whose target (under $HOME) is deny-listed or cache-junk EXCLUDES the link
     (rule reported) — a symlink can never bypass L1/L3;
  4) targets OUTSIDE $HOME are not followed without `--follow-outside-home` (kept as
     link + note) so an accidental link to / or /usr cannot explode the walk;
  5) duplicate targets (two links, one canonical real) dedup: the second link stays
     a link; cycles are impossible by construction (canonical SEEN_REAL + coverage);
  6) every other layer applies unchanged to the VIRTUAL paths: deny globs, cache
     skip, 50 MiB per-file cap, L2 content scan (reads real content through the
     link), --exclude-from selection (an ancestor entry skips a whole fetched
     subtree), 1 GiB budget. Followed FILE links are staged via a second tar pipe
     with -h; followed DIR content lands through normal path resolution.
  7) staging pre-cleans type transitions (stale dir at a file/link path and vice
     versa, stale link at an ancestor path) so re-runs flip cleanly between layouts.
  rice-restore gains `--relink`: after an apply restore, each followed link's content
  is moved to its recorded (relative) target location under the target home and the
  symlink is recreated; targets that would land outside the target home are LISTED,
  never guessed (same philosophy as UNMAPPED.txt).

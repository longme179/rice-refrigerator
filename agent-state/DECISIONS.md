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

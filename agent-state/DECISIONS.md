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

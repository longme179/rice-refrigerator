# PLAN — rice-backup / rice-restore (workspace: rice-refrigerator)

- Status: COMPLETE (Phase 0), self-reviewed once against the task prompt on 2026-10-31.
- This is the fixed plan. Deviations → DECISIONS.md. Progress + evidence → STATE.md. Narrative → journal/.
- Owner of this repo: the agent workspace (memory + deliverable). The deliverable is the rice-backup tool.

## 1. Requirements restated (with testable acceptance criteria)

### 1.1 Fixed facts
- Workspace repo: https://github.com/longme179/rice-refrigerator.git (agent memory AND deliverable).
- PAT: fine-grained, scoped to this one repo (Contents: read/write). Provided out-of-band; during agent
  sessions it lives only at /tmp/rice-auth/.pat (0600) and in the shell env of the running session.
  It must never appear in any file, commit, git config, remote URL, argv, log, journal, error or reply.
- Target machine: user's Fedora; must also work on Arch and Ubuntu. DE unknown → detect, never assume.
- Every claim in this repo is labeled RAN (with command evidence) or NOT RUN. Nothing is claimed
  "works" without having been run.

### 1.2 Functional requirements
- R1 One-command backup: authenticate → prompt for target repo name → dry-run summary (what will be
  uploaded; what was excluded, names only) → confirmation → push.
- R2 Flags: --dry-run, --yes, --include-system.
- R3 Authentication: prefer `gh auth login` (web/device flow) when gh is available; otherwise prompt for a PAT
  with hidden input. Token lives only in memory or a 0600 temp file removed by a trap on exit; never in
  repo, URL, args or logs.
- R4 Target repo: create PRIVATE if missing. If it exists and is public → warn + typed confirmation.
- R5 Read-only on originals: copy into a 0700 temp staging dir; preserve permissions and symlinks;
  clean up on exit.
- R6 Hard deny list always wins: ~/.ssh, ~/.gnupg, keyrings, password stores, KeePass databases,
  browser profiles, ~/.config/gh, .netrc, aws/gcloud/azure/kube CLI credentials, docker config auth,
  .env files, cookies/tokens. Additionally content-scan every remaining file with the S4 patterns;
  on a hit exclude the file and list path + rule (never the value).
- R7 Skip caches and files over 50 MB → list in SKIPPED.md (GitHub rejects > 100 MB files).
- R8 Re-running creates a new commit. Manifest with file list, hashes, distro and version, date,
  package inventories.
- R9 Restore: dry-run by default; section-by-section opt-in; back up any existing file to a
  timestamped directory before overwriting; never invoke sudo implicitly; reinstall packages
  best-effort across distros; LIST packages with no known mapping instead of guessing names.
- R10 README: usage, what is excluded and why, how to restore, limitations, how to rotate the PAT.

### 1.3 Security rules (restated, non-negotiable)
- S1 PAT never in any file, commit, git config, remote URL, command-line argument, log, journal,
  error output, or reply.
- S2 Git auth via a GIT_ASKPASS helper that reads the token from an env var. Helper outside the repo,
  chmod 700, in /tmp or a private dir. Remote URL stays plain https://github.com/... Never `set -x`
  or echo around token-touching commands.
- S3 PAT pasted in chat → load into env/secret helper immediately; never repeat or save it. After a
  sandbox reset ask for it again and wait. Never search the filesystem for it.
- S4 Before EVERY push: secret scan over the staged diff AND the full tree (scanner lives in
  scripts/). Patterns: ghp_/gho_/ghs_/github_pat_, "BEGIN ... PRIVATE KEY", AWS keys, bearer tokens,
  password and token value assignments, plus exact match on the current PAT value. Install as git
  pre-push hook AND called explicitly. On a hit: do not push; rewrite local history if already
  committed; if it may have reached the remote tell the user to revoke immediately; record the
  incident without the secret value.
- S5 Push only to the workspace repo, never force-push, never touch other repos. (Tool runtime
  equivalent: push only to the user-confirmed https://github.com repo; never force.)

### 1.4 Acceptance criteria (evidence recorded in STATE.md; test IDs in §8)
- AC-01 `bin/rice-backup.sh --dry-run` on the fixture HOME with mocked package managers exits 0,
  prints upload summary + exclusions (names only), and leaves the remote bare repo unchanged
  (rev-list count identical).
- AC-02 Full run against a local bare remote: push succeeds, exactly one new commit per run.
- AC-03 Canary secrets (fixture §8.2 — all values FAKE) are absent from staging, pushed commit
  content, tool output and logs: grepping the cloned backup repo for each canary value yields nothing.
- AC-04 Deny-listed paths (~/.ssh, ~/.gnupg, ~/.aws, .netrc, .env, ~/.config/gh, .docker/config.json,
  *.kdbx, browser profiles, *history*, .pki, kwalletd, .var/app, Telegram/Signal/discord dirs, ...)
  are absent from the backup; EXCLUDED.md lists each with its rule name; secret values never appear.
- AC-05 Content-scan hits (fake token=, github_pat_, AKIA..., BEGIN PRIVATE KEY, Bearer, URL creds)
  are excluded and listed with rule name.
- AC-06 Files > 50 MB are skipped and listed in SKIPPED.md with size; files ≤ 50 MB are included.
- AC-07 Cache dirs are skipped; SKIPPED.md summarizes them.
- AC-08 Re-running creates a new commit (remote rev count +1); no force push anywhere (audit).
- AC-09 Manifest: sha256 of a known staged file matches `sha256sum`; manifest.tsv lists size, mode,
  type, symlink target; meta records distro, version, date, hostname, DE, tool availability.
- AC-10 Package inventories from mocks: fedora (dnf userinstalled/repos/coprs), arch (pacman -Qqe /
  -Qqm), ubuntu-family (apt-mark showmanual + sources); flatpak/snap/npm/pip lists; missing tools are
  recorded as unavailable, never invented.
- AC-11 Scanner: detects every rule on the canary corpus, exit 1, output lines "HIT <rule> <path>"
  (no values); clean corpus exits 0; whitelisted placeholders (password=changeme etc.) not flagged.
- AC-12 Scanner exact mode: RICE_SCAN_EXACT=fake-value flags a file containing it; the output does
  NOT contain the value itself.
- AC-13 Pre-push hook: canary injected into the staging repo → push aborts, remote unchanged, hook
  exit code non-zero.
- AC-14 Restore: default dry-run changes nothing (tree checksum of target HOME identical before/after);
  apply: files land with modes preserved, pre-existing conflicting files moved to a
  ~/.rice-restore-backup-<timestamp>/ tree; the tool never invokes sudo (code audit + trace);
  packages produce a reviewable script + UNMAPPED list; cross-distro restore lists unmapped names.
- AC-15 Public-repo guard: mocked API returns private:false → warning + typed repo-name confirmation;
  wrong input aborts.
- AC-16 Repo creation: mocked gh/curl produce a private-repo create call; PAT-without-scope failure
  path prints manual-creation instructions.
- AC-17 `bash -n` passes on every script; shellcheck clean when installed (else equivalent custom
  checks: no `set -x`, no echo of token vars, token never in argv).
- AC-18 README covers usage, exclusions+why, restore, limitations, PAT rotation.
- AC-19 Final audit: `scripts/secret-scan.sh tree .` and `scripts/secret-scan.sh history` are clean
  over the whole workspace repository including all pushed history.
- AC-20 No dependency beyond bash/git/coreutils: with flatpak/snap/npm/gh absent (mocked-unavailable),
  the tool degrades gracefully and records unavailability.

### 1.5 Non-goals
Backing up passwords, credentials or SSH material (never). Whole-home mirroring (rice-relevant paths
only). GUI restore wizard. Distros beyond Fedora/Arch/Ubuntu (Debian-family supported implicitly for
testing, see DECISIONS A1).

## 2. Threat model (every secret-leak vector → control)

| # | Vector | Control |
|---|--------|---------|
| T1 | Token in tool memory | Env var of the tool process only; never an argv value; not exported to any file; process env dies at exit. |
| T2 | Token in git remote URL | Remote is always the plain https://github.com/OWNER/REPO.git URL; auth via GIT_ASKPASS (helper reads env). Push pipeline asserts remote URL matches ^https://github\.com/ before pushing. |
| T3 | Token in a staged/committed file | Exact-value scan (RICE_SCAN_EXACT) over the full tree AND staged diff AND target commit before push (explicit + hook). |
| T4 | User secrets in backup content (ssh keys, .env, browser tokens, kdbx...) | Layer 1 hard deny list (always wins) + Layer 2 content scan (S4 patterns) → exclude file, report path + rule only. |
| T5 | Secrets already in git history (re-runs) | Scanner `history` mode over all commits pre-push; on hit: rebuild local history (orphan-branch procedure, README SECURITY) before pushing; if possibly pushed already → tell user to revoke PAT immediately; incident recorded without the value. |
| T6 | Token in agent logs/journal | Journal policy: no env dumps, no output of auth commands, no quoted chat; scanner greps agent-state/ too (it is part of the tree). |
| T7 | Token visible in `ps` (argv) | Patterns reach grep via stdin (`-f -`), curl auth via 0600 config file (`-K`), never `VAR=x cmd` with the literal, no `set -x` anywhere (custom lint rule). |
| T8 | Token in error output | git/curl never run with -v/--verbose; auth failures print a sanitized message only; stderr of auth commands is never echoed raw into logs. |
| T9 | Backup pushed to a public repo | Repo is created private by default; if it exists and is public → warning + typed exact-name confirmation; summary prints the visibility it checked. |
| T10 | Agent session (this workspace) leaking the PAT | PAT only at /tmp/rice-auth/.pat (0600) + session env; never inside /home/z/my-project; every workspace push passes the scanner + pre-push hook; workspace root itself is never staged (pre-existing .env there is untouched). |
| T11 | Supply chain | Zero third-party dependencies: bash + coreutils/findutils/tar + git only; no pip/npm/curl requirement at runtime (curl/gh optional paths degrade). |
| T12 | Restore destroying user files | Restore is dry-run by default; apply mode moves every overwritten file into a timestamped backup tree first; system/package actions are emitted as reviewable scripts, never auto-sudo. |
| T13 | Malicious backup repo content | Restore never executes scripts from the repo; package reinstall commands are generated locally into a file for review; document the trust assumption in README. |

## 3. Architecture and language

### 3.1 Language
Bash ≥ 4.2 (in practice 5.x on Fedora/Arch/Ubuntu). Justification: the only interpreter guaranteed
present on a fresh install of all three distros (python3 is absent from minimal Arch/base Ubuntu
images); the constraint "only git and the default interpreter" is satisfied by bash + coreutils +
findutils + tar, all in @core/base on the three targets. Scanner engine is GNU grep (NOT awk regex:
Ubuntu's default awk is mawk, whose ERE support is incomplete — DECISIONS D3).

### 3.2 Components (repo layout)
```
README.md                     user-facing docs (R10)
bin/rice-backup.sh            entrypoint: flags → auth → repo ensure → collect → dry-run → confirm → stage → manifest → scan → commit → scan+hook → push
bin/rice-restore.sh           entrypoint: fetch → verify → plan → dry-run | apply (per section)
lib/common.sh                 logging, distro/DE detection, tty-safe prompts, hidden read, utils
lib/collect.sh                include roots, deny list, cache skip, 50 MB cap, tar-based staging copy, reports
lib/packages.sh               per-distro package inventories + language managers (best-effort)
lib/gitops.sh                 auth state, askpass mgmt, repo exists/create (gh > curl > manual), scan+push pipeline
scripts/secret-scan.sh        standalone S4 scanner: modes tree|files|git|history; env RICE_SCAN_EXACT
scripts/install-hook.sh       installs pre-push hook + scanner copy into a repo's .git/hooks (tool + workspace)
tests/run-tests.sh            self-contained suite (assert framework inline)
tests/fixtures/home/          fake $HOME with FAKE canaries
tests/fixtures/mocks/         dnf, pacman, flatpak, snap, npm, gh, curl mocks answering exact commands
tests/containers.sh           optional fedora/archlinux/ubuntu container runs
agent-state/                  PLAN.md STATE.md DECISIONS.md journal/ (this memory)
```

### 3.3 Backup data flow
1. originals (READ-ONLY) → candidate file list (scoped include roots; deny list prunes first)
2. filters: deny → cache → size(>50 MB) → content scan (source files) → include list
3. copy include list into 0700 staging dir via one tar pipe (preserves mode/ownership/symlinks)
4. write packages/, desktop dumps, meta/, reports/ (EXCLUDED.md, SKIPPED.md, RESTORE.md) into staging
5. staging dir is a git repo: fetch remote main if it exists, overlay, `git add -A`, commit
   (--allow-empty so a re-run always makes a commit)
6. explicit scans: full tree + staged diff + target commit; install pre-push hook (scanner copy)
7. push origin main (never --force); on non-fast-forward → abort with explanation (never force)
8. trap removes staging + askpass + curl config; token was never on disk (except optional 0600
   curl config, trap-removed)

Exit codes: 0 ok; 1 usage/abort; 2 secret hit (push refused); 4 auth failure; 3 push failure.

## 4. Per-distro matrix

### 4.1 Package inventories (best-effort; every tool that is absent is recorded, never simulated)
| Layer | Fedora | Arch | Ubuntu(-family) |
|---|---|---|---|
| user-installed OS packages | `dnf -q repoquery --userinstalled` (fallback `dnf -q history userinstalled`) | `pacman -Qqe` (explicit) | `apt-mark showmanual` |
| foreign/AUR | n/a (note) | `pacman -Qqm` | n/a (note) |
| repos | `dnf -q repolist --enabled` | /etc/pacman.d/mirrorlist (+ repos from pacman.conf) | /etc/apt/sources.list + sources.list.d/* |
| COPR/PPA | COPR: `dnf -q copr list`, fallback listing /etc/yum.repos.d/_copr*.repo | n/a | PPA entries parsed from sources.list.d |
| flatpak | `flatpak list --app --columns=application,origin` | same | same |
| snap | `snap list` | same | same |
| pip --user | `pip3 list --user --format=freeze` (fallback `python3 -m pip ...`) | same | same |
| pipx | directory listing of ~/.local/pipx/venvs and ~/.local/share/pipx/venvs (no binary needed) | same | same |
| npm -g | `npm ls -g --depth=0` | same | same |
| cargo | parse ~/.cargo/.crates.toml (no cargo binary needed) | same | same |

### 4.2 Config surfaces (collected files)
| Surface | Paths (relative to $HOME unless stated) | Notes |
|---|---|---|
| shell rc | .bashrc .bash_profile .bash_aliases .profile .zshrc .zshenv .zprofile .inputrc .tmux.conf .screenrc .vimrc .gvimrc .gitconfig | glob-audited |
| XDG config | .config/** minus deny/cache/size | main rice surface |
| local bin | .local/bin/** | modes preserved |
| local share | .local/share/{applications,fonts,icons,themes,gnome-shell/extensions,konsole,color-schemes,plasma,wallpapers,look-and-feel,aurorae} | KDE dirs included when present |
| legacy dirs | .fonts .icons .themes | when present |
| systemd user | .config/systemd/user/** + `systemctl --user list-unit-files --state=enabled` | enablement list in meta |
| crontab | `crontab -l` | |
| GNOME | dconf dump `/` (if dconf present) + extensions dir + DE detection recorded | dump is content-scanned |
| KDE | covered by .config/** + .local/share dirs above | no dump needed |
| /etc (ONLY with --include-system) | hostname hosts fstab locale.conf vconsole.conf timezone dnf/dnf.conf yum.repos.d/*.repo pacman.conf pacman.d/mirrorlist* apt/sources.list apt/sources.list.d/* default/grub X11/xorg.conf.d/* systemd/system/*.service *.timer | every file content-scanned; crypttab/ssh/sshd/samba deliberately NOT in the allowlist |

### 4.3 Detection
- Distro: /etc/os-release ID (fedora|arch|ubuntu|debian→ubuntu-family) with ID_LIKE fallback.
- DE: XDG_CURRENT_DESKTOP / DESKTOP_SESSION → GNOME|KDE|other; fallback binary presence
  (gnome-shell/plasmashell); recorded as informational. dconf dump gated on `command -v dconf` only,
  so it works regardless of the DE guess (dumps whatever gsettings exist).

## 5. Exclusion policy

Three layers, precedence L1 > L2 > L3; every exclusion is reported by name (+ rule) only.

- L1 hard deny (always wins; EXCLUDED.md):
  dirs: .ssh .gnupg .gnome/keyrings .gnome2/keyrings .local/share/keyrings .password-store
  .config/gopass .local/share/gopass .aws .config/gcloud .azure .kube .config/kube .config/helm
  .docker .config/gh .mozilla .config/google-chrome* .config/chromium* .config/BraveSoftware
  .config/vivaldi* .config/Opera* .config/Microsoft-edge* .config/librewolf .config/waterfox
  .config/ungoogled-chromium .var/app .thunderbird .config/evolution .local/share/evolution
  .local/share/TelegramDesktop .config/telegram-desktop .config/Signal .config/Element
  .config/discord .config/Keybase .config/Slack .config/zoomus .local/share/kwalletd .pki
  .onepassword .config/1Password
  files/globs: .netrc .netrc.gpg .git-credentials .pypirc *.kdbx *.kdb *.key *.pem *.p12 *.pfx
  .env .env.* *.env *id_rsa* *id_ed25519* *id_ecdsa* *id_dsa* .bash_history .zsh_history
  .sh_history .python_history .node_repl_history .mysql_history .psql_history .sqlite_history
  .lesshst .viminfo .viminfo.tmp *.tfstate *.tfstate.*

  [SESSION-3 ADDENDUM] added after a real Fedora 44 dry-run showed the Firefox XDG profile
  at `.config/mozilla` sailing into the include set: `.config/mozilla`, `.local/share/mozilla`,
  `.librewolf`, `.waterfox`, `.zen`, `.floorp` (DECISIONS D17). Binary cookie/session stores
  carry no token shape, so L2 cannot catch them — the deny list is the only effective layer.
- L2 content scan (S4 patterns + extras; hit → exclude + rule name):
  rules: gh-classic (ghp_/gho_/ghs_/ghr_), gh-fine-pat (github_pat_...), private-key, aws-access-key
  (AKIA...), aws-secret-label, google-api-key (AIza...), slack-token (xox...-), stripe-key
  (sk_live_...), jwt (eyJ...), bearer, cred-assign (keyword assignments: password, token, secret,
  api key, auth and friends, followed by a non-placeholder VALUE), url-creds (URLs carrying embedded
  userinfo), exact (RICE_SCAN_EXACT, e.g. the current PAT).
  exact (RICE_SCAN_EXACT, e.g. the current PAT).
  placeholder whitelist for cred-assign values: a small fixed list of obvious placeholders plus
  values beginning with $ ( { < (shell/config indirection).
- L3 hygiene: cache components (.cache .npm __pycache__ node_modules cache Cache caches Trash
  .git), files > 50 MB → SKIPPED.md; total-size warning threshold 800 MiB (needs --yes to proceed).

Symlinks are copied as symlinks (tar semantics), never followed into targets; a symlink whose
target is a secret stores only the target path string, not content (documented limitation).
dconf dumps, package inventories and /etc files pass the same L2 scan.

## 6. Auth and repo-selection UX

1. gh present? → `gh auth status` OK → gh mode (git via `-c credential.helper='!gh auth
   git-credential'`, API via `gh api`). gh present but unauthenticated → run interactive
   `gh auth login --hostname github.com --git-protocol https` (web/device flow). Non-tty and
   unauthenticated → error with instructions.
2. else PAT mode: RICE_TOKEN env if set (advanced; documented ps caveat), else hidden `read -rs`
   prompt (tty required; piped stdin refused so the token can never arrive via a logged pipe).
   Token exists only in the process env + GIT_ASKPASS helper (0700, temp dir, trap-removed);
   optional curl config (0600, trap-removed) only if an API call is needed.
3. Target repo: --repo OWNER/NAME or RICE_REPO env or interactive prompt; charset-validated
   [A-Za-z0-9._-]+ (no URL injection).
4. Repo exists? gh api / curl GET /repos/OWNER/NAME → private? → create if missing (gh repo create
   --private, else curl POST /user/repos {"private":true}; failure from a repo-scoped PAT → printed
   manual instructions). Exists and public → loud warning + typed exact repo name required
   (not bypassed by --yes).
5. Remote URL is always plain https://github.com/OWNER/REPO.git; the push pipeline re-validates the
   URL regex before pushing. Test suite overrides the base only via RICE_TEST_GIT_BASE (file://)
   and PATH-mocked gh/curl, never in normal operation.

## 7. Restore design

- `bin/rice-restore.sh --from URL [--dry-run|--apply] [--section NAME ...|--all-sections]
  [--home DIR] [--distro fake-for-tests]`
- Default mode is dry-run even without a flag; --apply is required to change anything.
- Sections: dotfiles, config, local-bin, local-share, fonts, icons-themes, gnome-extensions,
  gnome-dconf, systemd-user, crontab, packages, system.
- Before any overwrite, existing files are moved to ~/.rice-restore-backup-<YYYYmmdd-HHMMSS>/
  mirroring their paths; the backup location is printed.
- Integrity first: `sha256sum -c manifest.sha256` over the cloned backup.
- gnome-dconf apply: `dconf load / < dump` (current state dumped to the backup dir first).
- crontab apply: `crontab < crontab.txt` (current crontab saved first).
- packages: same distro → generated restore-packages-<distro>.sh using that distro's installer;
  different distro → a small explicit alias map for well-known packages only, everything else listed
  in UNMAPPED.txt (never guessed). The script is written for review; the tool NEVER runs it and
  NEVER invokes sudo itself (flatpak/pip/npm/cargo commands included in the script for review).
- system section: writes root-actions.sh with cp commands for /etc targets — user reviews and runs
  with sudo themselves.
- --home DIR restores into a different directory (also used by tests).

## 8. Test strategy

### 8.1 Harness
tests/run-tests.sh: self-contained bash assert framework (pass/fail counters, exit non-zero on any
failure). Runs entirely inside a mktemp workspace with HOME overridden to the fixture, PATH
prepended with mocks, RICE_TEST_GIT_BASE=file://<tmp>/remote-base (local bare repos as push targets).

### 8.2 Fixture HOME (tests/fixtures/home) — ALL SECRETS ARE FAKE CANARIES
- clean rice files: .bashrc, .zshrc, .profile, .tmux.conf, .config/myapp/settings.ini,
  .config/ricedata/theme.conf, .local/bin/myscript (0755), .local/share/applications/user.desktop,
  .local/share/fonts/FakeFont.ttf, .local/share/gnome-shell/extensions/foo@example.com/extension.js,
  .config/systemd/user/backup.timer, a filename with a space.
- deny-list canaries: .ssh/id_rsa (fake openssh private-key block), .ssh/id_rsa.pub,
  .gnupg/private-keys-v1.d/k.key, .aws/credentials (AKIA…), .netrc (password=…), .env,
  .config/gh/hosts.yml (oauth_token …), .docker/config.json (auths), Notes.kdbx (binary),
  .mozilla/firefox/x.default/places.sqlite (empty), .bash_history, .var/app/org.example.App/data,
  .cache/junk/deep/file.
- content-scan canaries: .config/myapp/token.ini (token=…), .config/weird/github-pat
  (github_pat_…), .config/cloud/aws.key (AKIA…), .config/api/bearer.txt (Bearer …),
  .config/creds/private.pem (private-key block), .config/net/proxy.conf (URL with embedded
  user:pass credentials),
  .config/dummy/placeholders (password=changeme → must NOT be flagged).
- exact-match canary: .config/misc/notes.txt contains RICECANARYEXACTSECRETVALUE42; test sets
  RICE_SCAN_EXACT to that fake value.
- oversized: .config/bigapp/data.bin (60 MiB sparse file) → must be skipped + listed.
- canary values (all fake, grep targets): listed in tests/canaries.txt for AC-03 greps.

### 8.3 Mocks (tests/fixtures/mocks) — answer the EXACT commands in lib/packages.sh
dnf (repoquery --userinstalled / repolist / copr list), pacman (-Qqe / -Qqm), flatpak
(list --app), snap (list), npm (ls -g --depth=0), gh (auth status / repo create / api), curl
(repo exists JSON private:false for AC-15). Mock outputs are committed fixtures; the tool never
sees real network in tests.

### 8.4 Test IDs → ACs
T01 scanner files mode (AC-11) · T02 scanner exact mode (AC-12) · T03 scanner git/history modes
(AC-19 partial) · T04 deny list on dry-run (AC-04) · T05 dry-run leaves remote untouched (AC-01) ·
T06 full backup push + canaries absent in clone (AC-02/03) · T07 manifest hash + meta (AC-09) ·
T08 package inventories per distro via mocks (AC-10) · T09 oversized + caches (AC-06/07) ·
T10 re-run new commit (AC-08) · T11 pre-push hook blocks canary (AC-13) · T12 public-repo typed
confirm (AC-15) · T13 repo create mocked (AC-16) · T14 restore dry-run no-op (AC-14) ·
T15 restore apply + timestamped backups (AC-14) · T16 cross-distro unmapped list (AC-14) ·
T17 bash -n + lint rules (AC-17) · T18 README coverage greps (AC-18) · T19 unavailable tools
graceful (AC-20) · T20 final workspace audit tree+history (AC-19).

[SESSION-3 ADDENDUM] T21 (AC-21) PAT auth mode recorded + hard size budget refusal/
--allow-oversize; T04/T06/T08/T19 extended for the Firefox XDG profile deny
(`.config/mozilla`), Zen/Floorp homes, fcitx dbus junk, per-section bytes,
top-15 largest list, gnome-extensions inventory. Driven by a real user dry-run
on Fedora 44 (see journal 2026-10-31-03 and DECISIONS D17-D22).

### 8.5 Lint
shellcheck if installable in the sandbox (apt or a static binary in /tmp); otherwise equivalent:
bash -n everywhere + custom greps (no `set -x`, no `echo "$RICE_TOKEN"`, no literal-token
assignments, no token in argv-positions). Labeled RAN/NOT RUN accordingly.

### 8.6 Containers
tests/containers.sh: docker/podman are MISSING in this sandbox (verified RAN: command -v → absent).
If they remain unavailable, the three-distro container runs are marked NOT RUN with that evidence;
unit coverage relies on mocks (§8.3). No invented container output, ever.

## 9. Ordered work breakdown (done-criteria) and what cannot be verified

1. Secure session bootstrap (PAT → /tmp/rice-auth, askpass, clone) — DONE when ls-remote + clone
   succeed with evidence in STATE.md. [done 2026-10-31]
2. This PLAN + STATE/DECISIONS/journal committed and pushed — DONE when origin/main contains them
   and an ad-hoc scan (exact PAT via stdin-fed grep + core regexes; scanner not yet written, see
   DECISIONS D4) is clean.
3. scripts/secret-scan.sh + tests T01–T03 — DONE when scanner detects all canary rules with
   path+rule output, exact mode works, clean corpus passes, and it is installed as pre-push hook
   in the workspace clone via scripts/install-hook.sh.
4. lib/common.sh, lib/collect.sh — DONE when deny/cache/size filters pass T04/T09 assertions.
5. lib/packages.sh — DONE when T08 passes for the three distros with mocks (+ real apt on this
   Debian sandbox, labeled as such).
6. lib/gitops.sh + bin/rice-backup.sh — DONE when T05/T06/T07/T10/T11/T12/T13 pass.
7. bin/rice-restore.sh — DONE when T14/T15/T16 pass.
8. Lint pass (T17) + full suite green — DONE when tests/run-tests.sh exits 0 end-to-end.
9. Container matrix — DONE or explicitly NOT RUN with evidence.
10. README.md + tool-written RESTORE.md/EXCLUDED.md/SKIPPED.md reviewed — DONE when T18 passes.
11. Final audit: scanner tree + history over workspace repo clean; STATE.md carries all RAN
    evidence; final push.
12. Final report to the user (Vietnamese): RAN vs NOT RUN, known limitations, first-run checklist.

### 9.1 Cannot be verified from this sandbox (will be labeled NOT RUN)
- Real dnf/pacman/flatpak/snap/gh/pipx/npm behavior on real Fedora/Arch machines (mocks + apt-real
  on Debian only).
- Real GNOME/KDE session artifacts: dconf is absent in this sandbox → the `dconf dump` path is code-
  reviewed and mock-tested only.
- gh web/device flow end-to-end (gh absent).
- GitHub repo-creation API with the real PAT (the PAT is scoped to the one workspace repo, so
  POST /user/repos cannot be exercised for real; mocked).
- Real browser profiles / huge real homes (fixtures only; 60 MiB sparse file for the size cap).
- Container runs on fedora/archlinux/ubuntu images (docker/podman absent — evidence recorded).
- Anything on the user's real machine.

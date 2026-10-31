# rice-backup / rice-restore

Back up your Linux desktop "rice" — dotfiles, themes, fonts and package
inventories — to a **private GitHub repository of your choice**, and restore it
on a fresh machine. **Passwords, credentials and SSH material are never backed
up**: a hard deny list plus a content scanner keep them out by design.

- Runtime requirements: `bash >= 4.4`, `git >= 2.28`, GNU coreutils / findutils
  / grep / tar. Nothing else — no pip, no npm, no `gh` required.
- Supported on **Fedora**, **Arch** and **Ubuntu**-family systems (Debian is
  used as the ubuntu-family proxy during development testing).
- License: MIT (see LICENSE).

## Quick start

```sh
# on the machine you want to back up (first run a dry-run! see below):
./bin/rice-backup.sh

# it will: authenticate -> ask for the target repo (OWNER/NAME) -> show a
# dry-run summary (what will be uploaded, what was excluded, names only)
# -> ask for confirmation -> stage, scan and push a single commit.

# on the fresh machine:
./bin/rice-restore.sh --from https://github.com/OWNER/REPO.git
```

Every re-run of `rice-backup.sh` creates a **new commit** on top of the
previous backup, so the git history of the backup repo is a timeline of your
rice. `./bin/rice-backup.sh restore ...` passes through to the restore tool, so
one command covers both directions.

## What gets backed up

| Surface | Paths (relative to `$HOME`) |
|---|---|
| shell rc files | `.bashrc` `.bash_profile` `.bash_aliases` `.bash_logout` `.profile` `.zshrc` `.zshenv` `.zprofile` `.zlogout` `.inputrc` `.tmux.conf` `.screenrc` `.vimrc` `.gvimrc` `.gitconfig` `.gitignore` `.editorconfig` |
| XDG config | `.config/**` (minus exclusions below) |
| local scripts | `.local/bin/**` (executable bits preserved) |
| local share | `.local/share/{applications,fonts,icons,themes,gnome-shell/extensions,konsole,color-schemes,plasma,wallpapers,look-and-feel,aurorae}` |
| legacy dirs | `.fonts` `.icons` `.themes` (when present) |
| desktop settings | `dconf dump /` (when `dconf` exists), `crontab -l` |
| systemd user | `.config/systemd/user/**` + the enabled-unit list for re-enabling |
| package inventories | Fedora: dnf user-installed + repos + COPRs · Arch: `pacman -Qqe`/`-Qqm` + mirrorlist · Ubuntu: `apt-mark showmanual` + apt sources · all: flatpak, snap, pip `--user`, pipx, npm `-g`, cargo |
| `/etc` (opt-in) | a small allowlist (dnf/pacman/apt config, locale, vconsole, X11, user systemd units) — only with `--include-system` |

Every run also writes `manifest.tsv` + `manifest.sha256` (per-file sha256,
size, mode, symlink target), `meta/` (distro, date, host, tool availability),
`reports/EXCLUDED.md`, `reports/SKIPPED.md` and a short `RESTORE.md`.

## What is NEVER backed up (and why)

Layer 1 — **hard deny list** (always wins, no flag can override): `~/.ssh`,
`~/.gnupg`, keyrings, password stores, KeePass databases (`*.kdbx`, `*.kdb`),
private key material (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*id_rsa*`, …),
browser profiles — Firefox in **both** its locations (`~/.mozilla` and the
XDG `~/.config/mozilla`, where current Fedora Firefox actually keeps
cookies.sqlite, key4.db, logins.json and site storage), Chrome/Chromium/Brave/
Vivaldi/Opera/Edge/LibreWolf/Waterfox/Zen/Floorp, including their flatpak data
under `~/.var/app` — messaging apps that store session secrets (Discord,
Signal, Element, Telegram, Slack, Zoom, Keybase), credential CLIs (`~/.aws`,
`~/.azure`, `~/.kube`, `~/.config/gh`, `~/.docker`, gcloud), `.netrc`,
`.git-credentials`, `.pypirc`, `.env*` and every `*history*` /
shell-history file. These are listed in `EXCLUDED.md` with the rule that
matched — contents are never read, copied or printed.

Layer 2 — **content scan** of every remaining candidate with the same rule set
that gates this repository's own pushes (GitHub token shapes, private key
blocks, AWS/Google/Slack/Stripe keys, JWTs, Bearer headers,
`password`/`token`/`secret`-style assignments, URLs with embedded
user:pass credentials, plus an exact match for the token you are currently
authenticating with). A hit excludes the **whole file** — over-exclusion is
intentional and cheaper than a leaked credential. Hits are listed in
`EXCLUDED.md` by path + rule name, never by value.

Layer 3 — hygiene: caches (`~/.cache`, `node_modules`, `__pycache__`, `Trash`,
fcitx dbus runtime sockets, …) and files larger than **50 MiB** are skipped
and listed in `SKIPPED.md` (GitHub hard-rejects files over 100 MiB; we stay
well below). On top of that a **total size budget** (default **1 GiB**, tunable
via `RICE_TOTAL_MAX_BYTES`) refuses the real run — with a clear message — when
the backup would exceed it; `--allow-oversize` is the explicit opt-in. The
dry-run prints per-section byte totals and the **top 15 largest candidates**
so you always know what is eating the budget.

If a file you care about is excluded: open it yourself, move the secret out of
it (e.g. into a password manager or an unreferenced include), and re-run.

## Usage

```sh
./bin/rice-backup.sh [--dry-run] [--yes] [--include-system]
                     [--repo OWNER/NAME] [--home DIR] [--keep-stage]
                     [--allow-oversize]
```

| option | effect |
|---|---|
| `--dry-run` | show the full summary (per-section sizes, top-15 largest files) and exclusions, then stop. Nothing is staged or pushed. **Run this first.** |
| `--yes` | skip the y/N confirmation. The public-repo typed check is **never** bypassed by this flag. |
| `--include-system` | also collect the scanned `/etc` allowlist |
| `--repo OWNER/NAME` | target repository (otherwise you are prompted; `RICE_REPO` env works too) |
| `--home DIR` | back up a different home directory (default `$HOME`) |
| `--keep-stage` | keep the temp staging dir for debugging |
| `--allow-oversize` | allow a run whose total exceeds the 1 GiB budget (`RICE_TOTAL_MAX_BYTES` overrides the budget value; exit code 5 is the refusal) |

Authentication (in order of preference):

1. `gh` is installed and authenticated → used directly (web/device flow if
   it is installed but not logged in).
2. otherwise a PAT: taken from `RICE_TOKEN` if set, else a **hidden prompt**.
   The token lives only in the process memory and a `0700` GIT_ASKPASS helper
   in a temp dir that is removed on exit — never in the repo, the remote URL,
   a command line, or a log.

Target repo handling: if the repo does not exist it is created **private**; if
it exists and is **public** you get a loud warning and must type the exact
`OWNER/NAME` to proceed; if privacy cannot be determined you are asked to
confirm before anything is pushed.

## Restore

```sh
./bin/rice-restore.sh --from URL [--dry-run|--apply] [--section NAME]...
                      [--all-sections] [--list-sections] [--home DIR]
```

- **Dry-run is the default** — even without a flag nothing changes until you
  pass `--apply`.
- Sections (opt-in one by one or `--all-sections`): `dotfiles config
  systemd-user local-bin applications fonts icons-themes gnome-extensions kde
  gnome-dconf crontab packages system`.
- Before any file is overwritten, the existing one is copied to
  `~/.rice-restore-backup-<timestamp>/` mirroring its path — restore is
  reversible.
- The backup is verified first: `sha256sum -c manifest.sha256` must pass.
- File modes come from `manifest.tsv` (git only carries the executable bit, so
  e.g. a 0600 config is restored as 0600).
- **rice-restore never invokes sudo.** Package reinstallation is written as a
  reviewable script (`~/.rice-restore-generated/restore-packages.sh`) plus an
  `UNMAPPED.txt`; `/etc` restores become `root-actions.sh`. Read them, then run
  them yourself.
- Cross-distro restores use a small explicit alias table (e.g.
  `vim-enhanced` to `vim`); every package without a known mapping is **listed
  in UNMAPPED.txt, never guessed**.
- `dconf` settings are loaded with `dconf load` (current state saved first);
  the crontab is installed with `crontab` (previous one saved first); systemd
  user units are copied and the enable commands are printed.

## Rotating the PAT

1. Revoke the old token at GitHub → Settings → Developer settings →
   Personal access tokens (fine-grained) → select it → Delete.
2. Create a new fine-grained token scoped to your backup repository with
   **Contents: read and write** (add Administration: write only if you want
   rice-backup to be able to create the repository for you).
3. Re-run `./bin/rice-backup.sh` — it will prompt again, because tokens are
   never stored anywhere by this tool.

## Security model (short version)

- The backup repo is private by default; a public target requires typed
  confirmation that `--yes` cannot bypass.
- Before every push, the staged tree, the changed files and **every commit in
  the pushed range** are scanned (explicitly and via a pre-push hook that
  rice-backup installs into the backup repo). A hit aborts the push.
- The token you authenticate with is additionally searched for **by exact
  value** in everything that is about to leave your machine.

### SECURITY runbook — if a secret ever reaches the remote

1. **Rotate the credential immediately.** This is the only real remediation
   once data has left your machine.
2. If the push was **blocked** (the usual case — the hook fires first): the
   bad commit exists only locally. Rebuild clean history and push that:
   ```sh
   cd <backup-repo-clone>
   git checkout --orphan clean-main      # start history over from the current tree
   git add -A && git commit -m "clean history"
   git branch -M clean-main main
   git push origin main                  # never --force
   ```
3. If the secret may already be on the remote: rotate (step 1), then delete
   the backup repository on GitHub and let the next `rice-backup.sh` run create
   a fresh private one. rice-backup never force-pushes, so rewriting remote
   history is deliberately not offered.

## Limitations

- Cross-distro package equivalence is best-effort only: a small alias table
  plus an explicit UNMAPPED list, never a guess.
- `~/.var/app` (flatpak app data) is excluded by default — flatpak browsers
  and KeePassXC keep credentials there. The flatpak app list is still recorded
  so your setup stays reproducible.
- The content scanner matches known secret *shapes*; binary credential
  stores whose filenames carry no such shape (a `cookies.sqlite` copied to a
  random path, an exported session database) can pass it. That is exactly why
  browser/messenger profile DIRECTORIES are denied wholesale in layer 1 —
  keep them out of any include path. Always review the dry-run list — it
  prints every uploaded filename.
- dconf and crontab collection requires those commands (a note is recorded
  otherwise); restoring them applies to the running user session only.
- Development testing runs on Debian 13 with fully mocked package managers
  (see Development below). The three-distro container matrix is NOT RUN in the
  development sandbox (no podman/docker available); first runs on a real
  Fedora/Arch/Ubuntu machine should start with `--dry-run`.
- git cannot carry file modes other than the executable bit — rice-restore
  re-applies exact modes from `manifest.tsv`, which works for backups made by
  this tool, not for files added to the repo by hand.

## Development

```sh
bash tests/run-tests.sh          # full acceptance suite (T01-T21), no network needed
bash tests/containers.sh         # three-distro matrix (NOT RUN without podman/docker)
bash tests/fixtures/build.sh     # rebuild fixture $HOME + mocks + canary list
scripts/secret-scan.sh --help    # the S4 scanner (tree / files / git / history modes)
scripts/install-hook.sh <repo> [expect-file]   # install the pre-push gate
```

All test secrets are fake canaries generated at RUNTIME by
`tests/fixtures/build.sh`; the repository commits only the clean fixture
(`tests/fixtures/home-clean/`) and the generator itself. Reason: GitHub push
protection rejects pushes containing token-shaped data — even obviously fake
test values (a fake Stripe-key canary once blocked this repository's own
push). The agent workspace memory lives in `agent-state/` (PLAN / STATE /
DECISIONS / journal) and follows the same no-secrets rules it enforces.

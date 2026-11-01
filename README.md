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
                     [--allow-oversize] [--exclude-from FILE]
                     [--export FILE.tar.gz] [--list-files]
                     [--no-follow-symlinks] [--follow-outside-home]
                     [--rules FILE] [--no-rules] [--include-file F] [--include-dir D]
                     [--skip-dir D] [--file-cap SIZE] [--budget SIZE]
                     [--explain [PATH...]] [--show-rules]
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
| `--exclude-from FILE` | **selection** — skip the home-relative paths listed in `FILE` (one per line, `#` comments; a directory entry skips its whole subtree). See below. |
| `--export FILE.tar.gz` | **offline archive** — write a restorable tar.gz instead of pushing. No GitHub, no PAT. See below. |
| `--list-files` | print the post-exclusion candidate list (`path<TAB>bytes` per line) and exit — offline and read-only; what the GUI builds its checklist from |
| `--no-follow-symlinks` | store symlinks as link entries only (pre-0.3.0 behavior). By default symlinks whose target is **not already inside the backup** are followed — see below. |
| `--follow-outside-home` | also follow symlink targets that live outside `$HOME` (default: those links are kept as links and reported) |
| `--rules FILE` / `--no-rules` | load the customization rules from `FILE` instead of `~/.config/rice-backup/rules.conf`, or skip them entirely — see below |
| `--include-file F`, `--include-dir D`, `--skip-dir D` | one-shot equivalents of the rules-file sections (repeatable; a deny-listed root is refused with its rule) |
| `--file-cap SIZE`, `--budget SIZE` | per-file cap (default 50 MiB, hard max 100 MiB per GitHub) and total budget (default 1 GiB). `SIZE`: plain bytes or `N`/`NK`/`NM`/`NG`. Precedence: env `RICE_TOTAL_MAX_BYTES` > `--budget` > rules.conf > default |
| `--explain [PATH...]` | **offline diagnostics** — print the verdict chain (`verdict`/`layer`/`rule`) for each PATH, or dump every bucket with reasons. No auth, no repo, nothing staged |
| `--show-rules` | **offline** — print the effective rule set (include roots with per-entry source, deny dirs/globs, cache patterns, caps). No walk, no auth |

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

### Customizing what gets backed up (`rules.conf`, roots, caps)

`~/.config/rice-backup/rules.conf` (0600, plain text, `#` comments) customizes
the selection **persistently** — CLI flags override it, and the GUI reads and
writes the same file:

```ini
[include-file]     # extra TOP-LEVEL home files (e.g. .Xresources)
[include-dir]      # extra home-relative roots to walk (e.g. Dev/dotfiles)
[skip-dir]         # DEFAULT roots to drop from the walk (e.g. .local/share/wallpapers)
[size]             # file_cap = 50MiB / total_budget = 1GiB (bytes or NK/NM/NG)
```

Every other layer still applies inside new roots — the deny list, the content
scan, cache skipping, the per-file cap — so customization can never bypass a
security layer. A deny-listed `[include-dir]` entry is refused with its rule
named. `--show-rules` prints the merged rule set with the source of every
entry; `--explain PATH` tells you exactly which layer and rule claims a path
before you customize anything. `[allow]` and `[ack-scan]` (deny-list and
scan-hit overrides) land in the next milestones — see `RULES-PLAN.md`.

### Selecting what gets backed up (`--exclude-from`)

The selection file is a plain list of home-relative paths, one per line
(`#` starts a comment); an entry naming a directory skips its entire subtree:

```sh
# skip re-downloadable bulk data
.local/share/fonts
.local/bin/uv
.config/mango
```

The selection is **purely subtractive**: it is applied *after* the hard deny
list and the content scan, so ticking a path off can only *remove* candidates,
never override either safety layer. Excluded items appear as
`user excluded` in the dry-run summary and in `reports/EXCLUDED.md`; the size
budget is recomputed, so excluding bulk data can bring an over-budget run back
under the 1 GiB budget. Entries that match no current candidate produce a
warning (typo guard), absolute paths and `..` are rejected. The file is also
the persistence format of the GUI's tick/skip checklist
(`~/.config/rice-backup/selection.txt`).

### Offline archives (`--export`)

```sh
./bin/rice-backup.sh --export rice-$(hostname).tar.gz --yes
```

`--export` replaces the push for that run: everything else — collection, deny
list, content scan, manifest, reports, the 1 GiB budget — happens exactly as
usual, but the staging repository (including `.git`) is written into a tar.gz
instead of being pushed. **No GitHub access and no PAT are needed at all.**
Restoring needs no network either:

```sh
tar -xzf rice-<host>.tar.gz
./bin/rice-restore.sh --from file://$PWD/rice-<host>   # dry-run by default
```

The extracted directory is itself a git repository, so `rice-restore`'s normal
flow (manifest verification, section-by-section apply, conflict backups)
works unchanged. If you want both a GitHub backup *and* an archive, run the
tool twice (once without `--export`, once with it) — each run creates its own
commit.

### Symlinks (`--no-follow-symlinks`, `--follow-outside-home`)

Dotfiles are full of symlinks — a shell config that is a link into a dotfiles
repo, `.config/quickshell/lme-shell -> ~/dev/lme-shell`, systemd
`*.wants/` links. Up to 0.2.0 such links were stored **as link entries only**:
the repository referenced the target without containing its content, so a
restore onto a fresh machine left you with dangling links. Since 0.3.0 the
default is to **follow** them, with one rule deciding per link:

| the link points to... | what happens |
|---|---|
| content the backup already collects (e.g. `.vimrc -> .config/vim/vimrc`, or anything under an include root) | kept as a symlink — the content is in the repo anyway and the link round-trips exactly |
| a directory/file under `$HOME` that is **not** otherwise collected | **followed**: the target's content is fetched into the repo at the link's path, and the original link is recorded in `symlinks.tsv` + `reports/SYMLINKS.md` |
| a deny-listed or cache/junk target | the link itself is **excluded** (`deny-target:` rule in EXCLUDED.md) — a symlink can never bypass the deny list |
| outside `$HOME` | kept as a link and reported; follow only with `--follow-outside-home` |
| a dangling link, a duplicate of an already-followed target, or a target that would re-walk already-collected regions | kept as a link, reason in `reports/SYMLINKS.md` |

Every other layer applies to the fetched content unchanged: the deny globs,
cache skip, the 50 MiB per-file cap, the content scan (it reads the real
bytes through the link), the `--exclude-from` selection (unticking
`.config/quickshell/lme-shell` skips the whole fetched subtree) and the 1 GiB
budget. `--no-follow-symlinks` restores the old store-links-only behavior.

After a restore, `--relink` recreates the original layout from
`symlinks.tsv`:

```sh
./bin/rice-restore.sh --from URL --apply --all-sections --relink
```

For every followed link the restored content moves to its recorded target
location (only when that lands inside the target home) and the symlink is
recreated; anything that would land outside the home is listed in
`relink-manual.txt`, never guessed.

## Graphical interface (optional)

A point-and-click frontend lives in `gui/` (Python + PyGObject/GTK4): setup →
dry-run review with a **tick/skip checklist** (per file and per section, saved
between runs in `~/.config/rice-backup/`) → push **or offline archive export**
→ result. It is an optional layer: the CLI stays fully supported and portable,
and the GUI starts with a self-check that prints the exact per-distro install
command when PyGObject is missing. See `gui/README-GUI.md`.

## Restore

```sh
./bin/rice-restore.sh --from URL [--dry-run|--apply] [--section NAME]...
                      [--all-sections] [--list-sections] [--home DIR]
                      [--skip-verify] [--relink]
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
- `--relink` (after the home sections) recreates the symlink layout recorded
  in the backup's `symlinks.tsv` — see *Symlinks* above.

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

# GUI plan — rice-backup / rice-restore frontend

Status: **PLANNED — nothing implemented yet.** This document is the development plan for
a graphical frontend. The backend is the existing `bin/rice-backup.sh` and
`bin/rice-restore.sh`, which this plan does **not** modify (the user is testing the
backend separately). Written in session 4 (2026-10-31), amended in session 5 after the
user locked the open decisions: G1 stack confirmed (D28), M3 deferred (D29), and the
language is English only (D30). Proposals D23–D27 stand as written.

---

## 1. Goals and non-goals

Goals:

- A point-and-click flow for the whole backup story: setup → dry-run review → run →
  result, with the same safety posture as the CLI (dry-run first, exclusions visible,
  size budget, public-repo typed confirmation).
- Later (M3, **deferred**): a restore window — section picker, conflict-backup notice,
  generated package script preview, UNMAPPED list — without the GUI ever running anything
  with sudo. Deferred at the user's direction until a real backup exists to restore
  (D29); the CLI restore path is the supported flow until then.
- The GUI is an **optional layer**: the CLI stays first-class, fully portable, and the
  supported path on headless/fresh machines.

Non-goals (for now): changing the backend scripts; packaging (rpm/AUR/deb); system tray
or daemon; scheduled/automated backups; multi-machine remote management. These live in
§12 as future ideas.

## 2. Constraints

- **C1 — portability scope.** The original deployment rule ("fresh Fedora/Arch/Ubuntu,
  git + default interpreter, no third-party pip/npm deps, single entrypoint") applies to
  the CLI path and stays intact. The GUI may require *optional* system packages, but it
  must start (or exit) gracefully everywhere and print the exact per-distro install
  command when its dependencies are missing.
- **C2 — security inheritance.** Rules S1–S5 (token never in files/argv/URLs/logs;
  GIT_ASKPASS env flow; push-only-this-repo; scanner gate) apply unchanged. The GUI adds
  its own requirements (§7).
- **C3 — no toolchain.** The GUI itself must need no pip, no npm, no compilation step:
  plain source files launched by an interpreter.
- **C4 — single entrypoint.** `rice-backup.sh` remains the front door. An optional
  `gui` passthrough subcommand is a *future, optional* backend touch-up (§5.4), only
  after the user's backend testing; until then the GUI launches standalone.
- **C5 — honesty labels.** RAN / NOT RUN discipline continues. Anything needing a
  display is NOT RUN in the sandbox and covered by a manual checklist for the user.

## 3. Stack decision (G1, D24)

| option | Fedora WS | Arch (GNOME) | Ubuntu Desktop | extra deps | widgets for this job | effort | notes |
|---|---|---|---|---|---|---|---|
| **Python + PyGObject (GTK4, libadwaita)** | default | gnome group | default | none–one | full (virtualized ListView, PasswordEntry, TextView log) | med | native GNOME look on 2 of 3 default distros |
| Python stdlib web UI (http.server + browser) | yes | yes | yes | python3 only | HTML/JS (hand-rolled) | med-high | best for KDE/minimal/SSH use; adds a local web security surface |
| zenity / yad dialogs | often | no | often | zenity/yad | poor (no log streaming, no big lists) | low | quick-and-dirty; rejected as the main track |
| Qt / PySide | opt | opt | opt | large | full | med | heavier optional dep on GNOME boxes |
| Tauri / Electron | – | – | – | build toolchain + bundle | full | high | violates C3 outright |

**Decision G1 — CONFIRMED by the user (D28): Python + PyGObject, GTK4, with libadwaita
when the `gi` repository `Adw` imports, plain GTK4 otherwise. This is the main track.** Rationale: the user's machine is
Fedora 44 GNOME and both default distros are GNOME; real widgets matter for a 3600-row
reviewable file list and a live log; python3 also exists in the development sandbox so
the parsing layer is testable headless. The architecture (§4) isolates everything
backend-facing in a display-free adapter module, so switching to the stdlib-web option
later (the strongest alternative, useful over SSH for headless boxes) touches only the
window layer. A zenity-only "quick GUI" was considered and rejected: it cannot stream
the backup log or show the exclusion review, which are the two things the GUI exists
for.

## 4. Architecture

```
gui/
  rice-gui          executable launcher (python3 shebang, chmod 755)
  gui_app.py        Gtk.Application: windows, dialogs, prompt relay, threading glue
  adapter.py        backend invocations + output parsing -> dataclasses (NO gtk imports)
  guiconf.py        ~/.config/rice-backup/gui.conf (configparser, 0600, no secrets)
```

- **adapter.py is Gtk-free and display-free** on purpose: it is unit-testable headless
  in the sandbox against canned backend outputs, and it is the single swap point if the
  stack decision ever changes.
- **Threading model:** one worker thread per backend run. `subprocess.Popen` with
  `text=True`, one reader thread for stdout, one for stderr, both pushing lines into a
  `queue.Queue`; the GTK main loop drains the queue via `GLib.idle_add`. The UI never
  blocks on the child.
- **Spawning:** `Popen(["bash", str(script)] + args, cwd=toolroot,
  env={**os.environ, **token_env})` where `token_env` is either empty (gh mode) or
  carries the PAT in `RICE_TOKEN`. The token exists **only** in the child's
  environment — never in argv, never in a URL, never in a file. `/proc/PID/environ` is
  readable by the same uid (and root) only, which is the same exposure model the CLI
  has today.
- **Output streaming assumption:** the backend logs via the bash `printf` builtin, which
  performs one `write()` per call — lines arrive live through pipes. Verified in the M0
  spike; fallback is launching through `stdbuf -oL` if any stall is observed.
- **Phase tracking:** map known line prefixes (`collecting`, `content-scanning`,
  `staging`, `committing, scanning`, `backup pushed`, `[rice-backup] WARNING/ERROR`) to
  phase chips in the progress window; every unmatched line still lands in the log view.
- **GUI dependency self-check at startup:** try `import gi; gi.require_version("Gtk",
  "4.0")`. On failure show a dialog with the per-distro fix (`dnf install python3-gobject
  gtk4 libadwaita` / `pacman -S python-gobject gtk4 libadwaita` / `apt install
  python3-gobject gir1.2-gtk-4.0 gir1.2-libadwaita-1`) and exit 1. The CLI path is never
  affected.

## 5. GUI ↔ backend contract

### 5.1 Invocations

| GUI action | command (run via bash) | notes |
|---|---|---|
| dry-run | `bin/rice-backup.sh --dry-run --repo OWNER/NAME [--home DIR] [--include-system]` | `RICE_TOKEN` in env when PAT mode |
| run | `bin/rice-backup.sh --yes --repo OWNER/NAME [--include-system] [--home DIR] [--allow-oversize]` | `--yes` is safe: the GUI itself asked for confirmation; the public-repo typed check is NOT bypassed by it and is relayed (§5.3) |
| restore dry-run | `bin/rice-restore.sh --from URL --home DIR` | pure no-op on the backend's promise |
| restore apply | `bin/rice-restore.sh --from URL --home DIR --apply --section S…` | per selected section; never a blanket apply-all unless the user selected all |

`--keep-stage` is exposed only as a hidden debug preference. `--home` lives in an
"advanced" expander (default `$HOME`).

### 5.2 Exit codes to interpret

| code | meaning | GUI presentation |
|---|---|---|
| 0 | success (or clean dry-run) | result window / review window |
| 1 | user abort, invalid input, repo-not-creatable | dialog with the backend's message |
| 2 | secret hit (S4 gate) | serious dialog: points at README SECURITY runbook |
| 3 | stage preparation or push failure | dialog with last log lines + "check remote manually" |
| 4 | authentication failure | dialog prompting re-entry of PAT / gh login |
| 5 | over size budget without `--allow-oversize` | dialog offering the oversize switch |

### 5.3 Stdin prompt relay

With `--yes`, exactly one interactive prompt can still appear: the **public-repo typed
confirmation** (`To push anyway, confirm the repository (type exactly: OWNER/NAME)` on
stderr). The GUI watches stderr for that prompt pattern, pops a modal with an entry
field, and writes the typed line plus newline to the child's stdin. The PAT hidden
prompt is never needed (the GUI collects the PAT itself); the restore tool's own
confirmations are captured in M3 task 1. Fallback for an unrecognized prompt (backend
blocked on stdin, no dialog shown): a generic relay dialog displaying the last stderr
line with a free-text input, so a blocked child is always recoverable.

### 5.4 Parsed output anchors (dry-run)

The adapter anchors on these stable literal labels emitted by the backend:

- `=== rice-backup dry-run summary ===`, then `home :`, `distro :`, `target :
  … (private: yes|no|unknown)`, `auth : gh|pat`
- section lines `  .config/**            : 1334 file(s), 8 GiB` — regex
  `^  (\S.*?):\s+(\d+) file\(s\)(?:, ([0-9.]+ [KMG]iB))?$`
- `  TOTAL                 : N file(s), SIZE`
- `largest candidates (top 15 by size):` followed by `    SIZE  path` lines
- `excluded (names only):` blocks: `hard deny list`, `scan hits`,
  `oversized (>50M)`, `caches/junk` — items `- path [rule]` or `- path (SIZE)`
- warnings `[rice-backup] WARNING: total … a real run needs --allow-oversize`

Parsing failure is a *visible state*, never a crash and never silent: the review window
falls back to a raw-text view with a banner ("could not parse backend output — showing
raw"). Future `--json` on the backend (optional, later) removes the whole class.

**Optional backend touch-ups, explicitly deferred until after the user's backend
testing, none of them blocking M0–M2:** a `gui` passthrough subcommand (keeps the
single-entrypoint promise), `--json` dry-run output, and `trap cleanup INT TERM` so a
cancelled run cleans its staging dir. Until then the GUI compensates (§6 rules).

## 6. Windows and interaction rules

Setup window:

```
┌─ Rice Backup ──────────────────────────────────┐
│ Target repository (OWNER/NAME)                 │
│ [ longme179/rice-refrigerator              ]   │
│                                                 │
│ Authentication                                  │
│ (•) gh CLI — detected and logged in            │
│ ( ) Personal access token                       │
│     [ •••••••••••••••••••• ]  hidden           │
│     kept in memory only — never written down   │
│                                                 │
│ Advanced:  home [ $HOME ]  ☐ include /etc      │
│                                                 │
│ [ Run dry-run ]                       [ Quit ] │
└─────────────────────────────────────────────────┘
```

Dry-run review window (the core value):

```
┌─ Dry-run review ───────────────────────────────┐
│ 3607 files · 1.2 GiB total      ⬤ OVER BUDGET  │
│ ┌ sections ────────────┐ ┌ exclusions (tabs) ┐ │
│ │ dotfiles    3   4 KiB│ │ Deny 13 │ Scan 2 │ │
│ │ .config  1334  1.1GiB│ │ Big 0   │ Cache 26│ │
│ │ .local   2270   90MiB│ │ - .bash_history   │ │
│ │ fonts/themes 0       │ │   [deny-file:…]   │ │
│ └──────────────────────┘ └───────────────────┘ │
│ largest candidates (top 15) — collapsible      │
│ ┌ file list — searchable, virtualized ────────┐ │
│ │ 🔍 […………]                                  │ │
│ │ .bashrc                                     │ │
│ │ .config/btop/btop.conf                      │ │
│ │ … (3607 rows, smooth scroll)                │ │
│ └──────────────────────────────────────────────┘ │
│ ☐ Allow over-budget run (--allow-oversize)     │
│ [ Start backup ]  [ Refresh ]  [ Back ]        │
└─────────────────────────────────────────────────┘
```

Progress window:

```
┌─ Backup in progress ───────────────────────────┐
│ ▸ collect ✔  ▸ scan ✔  ▸ staging ◉  ▸ push ○   │
│ ┌ log (auto-scroll) ─────────────────────────┐  │
│ │ [rice-backup] staging into /tmp/rice-…     │  │
│ │ [rice-backup] committing, scanning (S4)…   │  │
│ └────────────────────────────────────────────┘  │
│ elapsed 00:42        [ Cancel ] (disabled       │
│                       during the push phase)    │
└─────────────────────────────────────────────────┘
```

Result window: `backup pushed: commit <sha> → https://github.com/OWNER/REPO`, file/byte
counts, pointers to `reports/EXCLUDED.md` and `reports/SKIPPED.md` in the repo, buttons
`Open repository` (xdg-open), `View log`, `Close`.

Restore window (M3 — deferred until a real backup exists, D29):

```
┌─ Restore ──────────────────────────────────────┐
│ From [ repo URL or local path ]      [Inspect]  │
│ backup meta: Fedora 44 · 2026-10-31 · 3607 files│
│ sections:                                       │
│ [x] dotfiles (3)        [x] .config (1334)     │
│ [ ] .local (2270)       [x] fonts/themes (0)   │
│ [x] packages — preview generated script        │
│ [ ] desktop (dconf dump / crontab)             │
│ conflicts are saved to ~/.rice-restore-backup-… │
│ UNMAPPED packages listed verbatim — never      │
│ guessed into a command, never auto-run         │
│ [ Dry-run plan ]      [ Apply selected ]       │
└─────────────────────────────────────────────────┘
```

Interaction rules (safety posture, mirroring the CLI):

1. The oversize switch defaults OFF every launch; enabling it re-confirms with a dialog
   that restates the total size.
2. The public-repo typed confirmation is relayed (§5.3) and cannot be bypassed.
3. Cancel is enabled only before the push phase (SIGTERM to the child). Because the
   backend does not yet trap signals, a cancelled run may leave a `rice-backup.*`
   staging dir in `/tmp` — it is 0700 and harmless; the GUI detects leftovers at
   startup and offers cleanup.
4. The GUI **never** runs package installs or anything with sudo: the packages section
   shows the generated script path with copy-to-clipboard and "run it in a terminal"
   guidance; UNMAPPED items are listed verbatim.
5. dconf/crontab restore commands are shown as copyable text, not executed.

## 7. Security requirements for the GUI (extends S1–S5)

- **PAT lifecycle (D25):** typed into a hidden entry → held in memory → injected into
   the child process environment only → dropped when the run finishes and the window
   closes. Never: argv, remote URLs, window title, config file, clipboard, disk logs.
- **On-screen redaction (belt and braces):** the display pipeline substitutes any
   occurrence of the in-memory token value in log lines with `▶REDACTED◀`. The backend
   never echoes the token, so this only guards against future regressions — but it is
   cheap and it protects the "copy log" action.
- **No disk logs:** the log view is memory-only. `Copy log` copies the already-redacted
   visible text.
- **gui.conf policy (D27):** stores only the repo owner/name, window geometry, and UI
   preferences; created with mode 0600; contains nothing credential-shaped. It is safe
   for the backup itself to pick it up (L2 scans it like any file).
- **Future web fallback** (if ever built) must bind 127.0.0.1 only, generate a random
   per-launch session token, and make no requests beyond the local page.
- No auto-update mechanism, no telemetry, no network access other than the child
   git/gh/curl processes the backend already makes.

## 8. Milestones

| id | scope | exit criteria (acceptance) | est. |
|---|---|---|---|
| M0 | spike: window + threaded dry-run + live log | window never freezes while dry-run streams; lines arrive live; child exit code surfaced; cancel works pre-push | 0.5 d |
| M1 | dry-run review + setup window | parsed sections/exclusions/largest render; 3600-row list scrolls smoothly and is searchable; budget banner + oversize switch; PAT entry hidden; adapter unit tests green headless (canned outputs, incl. the real Fedora-shaped dry-run captured from the user's machine fields) | 2 d |
| M2 | run flow | progress phases; public-repo prompt relay modal; result window; exit-code dialogs (1/2/3/4/5) with correct guidance; stale-staging cleanup offer | 1.5 d |
| M3 | restore GUI — **DEFERRED until a real backup exists (D29); not scheduled** | task 1 (when lifted): capture `rice-restore` dry-run contract from `lib/restore.sh` and lock anchors; inspect view with meta; section checkboxes; apply per-section; conflict-backup path shown; generated script preview read-only; UNMAPPED verbatim | 2 d |
| M4 | polish | English-only UI copy pass (D30 — no gettext layer); `.desktop` + icon (optional); `README-GUI.md` with per-distro dependency table; final GUI security checklist walk-through | 1 d |

Current scope is ≈ 5 focused days (M0 → M1 → M2 → M4); lifting the M3 deferral adds
~2 d later. Every milestone ends with: `python3 -m py_compile` on all GUI
files, adapter tests re-run, manual checklist for the user, S4 tree scan, commit.
GUI code lives in the same repository, so the secret scanner and pre-push gate cover it
automatically.

## 9. Test strategy

- **Headless (sandbox, RAN-able):** adapter unit tests (stdlib `unittest`, honoring the
  no-deps rule) feeding canned backend outputs — normal dry-run, over-budget dry-run,
  public-repo dry-run, auth-fail, and later restore dry-runs. Python 3.12 is present in
  the dev sandbox (verified), so these genuinely run there.
- **Offline full-flow rig:** `RICE_TEST_GIT_BASE=file://…` plus the `tests/fixtures/
  mocks` PATH rig — the same one the CLI suite uses — lets the *running GUI* perform
  complete backup flows against a local bare repo with a fake PAT and zero network.
- **Manual checklist per milestone (user, real Fedora 44):** window-drag freeze test
  during a run; 3600-row scroll; cancel pre-push; public-repo relay; wrong PAT → exit 4
  dialog; over-budget refusal → exit 5 dialog; oversize switch → success.
- **NOT RUN in the sandbox (documented per C5):** anything requiring a display; xvfb is
  not assumed available.

## 10. Risks and mitigations

| risk | likelihood | mitigation |
|---|---|---|
| PyGObject missing (minimal Arch, server installs) | medium | startup self-check + exact per-distro install command; CLI unaffected (C1) |
| backend output drift breaks parsing | medium | anchors are our own stable literals; regexes centralized in adapter; raw-text fallback view; future `--json` eliminates the class |
| 3600-row list jank | low | Gtk.ListView (virtualized model), never Gtk.ListBox |
| unrecognized stdin prompt blocks the child | medium | generic relay dialog (§5.3 fallback) triggered by "child alive, silent, stdin awaited" heuristic |
| SIGTERM leaves staging dir | certain (by design today) | 0700 `/tmp` dir; startup leftover cleanup; future backend trap fix listed in §5.4 |
| token exposure via child env | low | same-uid-only readability, identical to the CLI model; documented; redaction on display |
| libadwaita absent | low | guarded import; plain GTK4 widgets |
| GUI lulls users into skipping dry-run | medium | the review window IS the dry-run; "Start backup" without a fresh dry-run asks to re-run it first |

## 11. Decisions resolved (session 5, 2026-10-31)

- **G1 stack: RESOLVED — CONFIRMED.** PyGObject/GTK4 is the main track (D28). The plan
  still keeps the stdlib-web alternative cheap to adopt later (adapter.py stays
  display-free).
- **M3 timing: RESOLVED — DEFERRED.** The restore GUI waits until the user has real
  backup history to restore (D29). Milestone order is now M0 → M1 → M2 → M4 → (M3 when
  lifted).
- **i18n: RESOLVED — ENGLISH ONLY.** No translation layer in M4 (D30).

## 12. Out of scope / future ideas

Stdlib-web remote mode (SSH-forwardable for headless boxes), system-tray quick actions,
a `gui` passthrough subcommand in `rice-backup.sh`, `--json` backend output, systemd
timer generation for scheduled backups, distro packaging. Each of these has a note in
§5.4 or the DECISIONS log; none affects M0–M2.

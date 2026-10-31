# rice-backup GUI (optional frontend)

A point-and-click layer over the CLI: **setup → dry-run review with a
tick/skip checklist → push to GitHub, or export an offline archive → result.**
The GUI is strictly optional — the CLI tools stay fully supported, portable
and unchanged (single entrypoint, git + bash only). Milestones M0/M1/M2 of
GUI-PLAN.md are implemented here; M3 (restore GUI) is deferred until a real
backup exists (D29).

## Launch

```sh
gui/rice-gui            # or: python3 gui/rice-gui
```

At startup the launcher self-checks PyGObject/GTK4. When missing it prints the
exact per-distro install command and exits 1 — the CLI path is never affected:

| distro | install |
|---|---|
| Fedora | `sudo dnf install python3-gobject gtk4 libadwaita` |
| Arch | `sudo pacman -S python-gobject gtk4 libadwaita` |
| Ubuntu | `sudo apt install python3-gobject gir1.2-gtk-4.0 gir1.2-libadwaita-1` |

There is no pip/npm/compile step anywhere (plan constraint C3). GTK 4.6 or
newer is enough (Ubuntu 22.04 LTS through current Fedora); libadwaita is
optional and simply not used when absent.

## Files

| file | role |
|---|---|
| `gui/rice-gui` | launcher + dependency self-check (per-distro hints) |
| `gui/gui_app.py` | GTK4 windows: setup, review checklist, progress, result, dialogs |
| `gui/adapter.py` | display-free backend contract: parsing, command building, subprocess runner, prompt relay, redaction, selection compression |
| `gui/guiconf.py` | session persistence: `gui.conf` + `selection.txt` (both 0600) |
| `gui/tests/` | headless unittest suite (45 tests) — no PyGObject needed |

`adapter.py` and `guiconf.py` import no GTK and run headless: they are the
unit-tested core (wired into the bash suite as t24). `gui_app.py` needs a
display and is verified via the manual checklist below.

## What you can do with it

- **Tick / skip what gets backed up.** The review window lists every candidate
  file (from `--list-files`) with a checkbox, plus per-section checkboxes
  (dotfiles, `.config`, `.local`, …). Unticked rows are written to
  `~/.config/rice-backup/selection.txt` in exactly the backend's
  `--exclude-from` format, so what you see is what the next run skips.
  Whole unticked subtrees are stored as single directory entries.
- **Sessions persist.** Repository, home, include-/etc, window size and the
  tick state survive restarts (`gui.conf` + `selection.txt`, both mode 0600,
  nothing credential-shaped — rule D27/D34). The selection file is plain text
  and safe to edit by hand.
- **Export an offline archive.** "Export archive…" writes a restorable
  tar.gz (the staging repo including `.git`) with **no GitHub and no PAT**
  (`--export`, D33). Restore: `tar -xzf <archive>` then
  `bin/rice-restore.sh --from file://<extracted-dir>`. "Offline mode" in the
  setup window runs the whole flow without any GitHub configuration.
- Everything else from the CLI posture: exclusions visible by name only,
  1 GiB budget banner + over-budget switch (re-confirmed, defaults OFF),
  public-repo typed confirmation relayed (never bypassed), exit-code dialogs
  (1/2/3/4/5) with concrete guidance, leftover-staging cleanup offer at
  startup, cancel available until the push/export phase begins.

## Security (extends S1–S5)

- The PAT is typed into a hidden entry, held in memory, injected **only** into
  the child process environment (`RICE_TOKEN`), and wiped when the setup
  window closes or the app shuts down (D25). It never appears in argv, URLs,
  window titles, the config file or any log.
- Every displayed log line passes through a redaction filter that replaces the
  in-memory PAT value with `▶REDACTED◀` (belt and braces; protects "Copy log").
- No disk logs: the log view is memory-only.
- The GUI never runs anything with sudo; it never executes package installs.
- Files: `gui.conf` (repo, geometry, preferences) and `selection.txt` (skipped
  paths) are 0600 and contain nothing credential-shaped.

## Development status (honesty labels, C5)

RAN headless in the development sandbox (each push):
`python3 -m py_compile` on all GUI sources, the 45-test unittest suite
(adapter parsing, command building, prompt relay, redaction, selection
compression, guiconf persistence + file modes), and the full bash acceptance
suite (t24 runs both).

NOT RUN in the sandbox (no display / no PyGObject there) — manual checklist
for a real Fedora/Arch/Ubuntu machine:

1. `gui/rice-gui` starts; missing-dependency path prints the right install
   command for your distro and exits 1.
2. Setup → Run dry-run: the window never freezes while the log streams live;
   phase markers advance (Collect → Scan → …).
3. Review: 3000+ rows scroll smoothly and the path filter works; ticking and
   unticking updates the header counts, section rows and the Session tab.
4. Untick `.local/share/fonts` (or similar), quit, relaunch: the ticks persist;
   a real run then skips exactly those paths (see `user excluded` in the
   dry-run summary and `reports/EXCLUDED.md` in the repo).
5. Over-budget selection shows the red OVER BUDGET chip; enabling the switch
   asks for confirmation; a real run without it exits 5 and the dialog offers
   the switch.
6. Public-repo target: the typed confirmation appears as a modal relay;
   typing the exact OWNER/NAME proceeds, "Abort run" cancels.
7. Wrong PAT → exit 4 dialog; unreachable remote → exit 3 dialog with log tail.
8. Cancel during staging works and the leftover staging dir is offered for
   cleanup at the next startup.
9. Export archive… → choose a path → archive written; extract it and
   `bin/rice-restore.sh --from file://<dir>` dry-runs the plan.
10. Token wipe: after closing the setup window, no RICE_TOKEN in the GUI
    process environment (`cat /proc/<pid>/environ` — same-uid readable, as
    with the CLI).

Implementation notes: the file checklist uses a virtualized `Gtk.TreeView`
(native checkbox renderer) instead of the planned `Gtk.ListView` — same
virtualization guarantee, far simpler toggles; prompts are read from **raw
stderr chunks** because backend prompts end without a newline.

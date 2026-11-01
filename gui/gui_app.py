"""GTK4 application layer for the rice-backup GUI (GUI-PLAN.md sections 4-7).

HONESTY LABEL (C5): this module imports PyGObject and is NOT RUN in the
development sandbox (no display, no PyGObject installed there). It is
py_compile-checked; all backend-facing logic lives in adapter.py and IS
unit-tested headless (gui/tests). The manual checklist in gui/README-GUI.md
covers the widget-level behaviours on the user's real machine — including
the R5 additions: the Rules editor window, the explain dialog and the
interactive excluded-row pages.

Security posture implemented here (S1-S5 + GUI rules):
  - the PAT lives only in app memory and the child process environment
    (adapter.child_env); never in argv, URLs, titles, config or logs (D25)
  - every log line passes through adapter.redact() before display
  - no disk logs: the log view is memory-only
  - gui.conf / selection.txt hold nothing credential-shaped (D27/D34)
  - the public-repo typed confirmation is relayed, never bypassed (GUI-PLAN 5.3)
  - the GUI never runs anything with sudo (GUI-PLAN rule 4)

GTK 4.6+ compatible (Ubuntu 22.04 LTS through Fedora current): no
4.10+-only APIs are used.
"""

from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

import adapter  # noqa: E402  (display-free backend contract)
import guiconf  # noqa: E402

RICE_BUDGET_DEFAULT = 1024 ** 3          # matches the backend default (D19)
MONO_CSS = b"textview { font-family: monospace; font-size: 9pt; }"


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------

def esc(s: str) -> str:
    return GLib.markup_escape_text(s)


def ellipsize_end() -> Pango.EllipsizeMode:
    return Pango.EllipsizeMode.END


def info_dialog(parent: Optional[Gtk.Window], title: str, body: str,
                kind: Gtk.MessageType = Gtk.MessageType.INFO) -> None:
    dlg = Gtk.MessageDialog(
        transient_for=parent, modal=True,
        message_type=kind, buttons=Gtk.ButtonsType.OK,
        text=title, secondary_text=body)
    dlg.connect("response", lambda d, r: d.destroy())
    dlg.show()


def confirm_dialog(parent: Gtk.Window, title: str, body: str) -> bool:
    """Modal yes/no confirm driven by a nested GLib main loop."""
    dlg = Gtk.MessageDialog(
        transient_for=parent, modal=True,
        message_type=Gtk.MessageType.QUESTION, buttons=Gtk.ButtonsType.YES_NO,
        text=title, secondary_text=body)
    loop = GLib.MainLoop()
    result = {"rc": Gtk.ResponseType.NO}

    def _resp(d, r):
        result["rc"] = r
        d.destroy()
        loop.quit()

    dlg.connect("response", _resp)
    dlg.show()
    loop.run()
    return result["rc"] == Gtk.ResponseType.YES


def apply_mono_style() -> None:
    try:
        css = Gtk.CssProvider()
        css.load_from_data(MONO_CSS)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    except Exception:
        pass  # cosmetic only


def open_uri(parent: Gtk.Window, uri: str) -> None:
    if shutil.which("xdg-open"):
        try:
            subprocess.Popen(["xdg-open", uri], start_new_session=True)
            return
        except OSError:
            pass
    info_dialog(parent, "Open manually", uri)


def copy_to_clipboard(widget: Gtk.Widget, text: str) -> None:
    try:
        clip = widget.get_display().get_clipboard()
        clip.set_text(text)
    except Exception:
        pass


def find_stale_staging() -> List[str]:
    return [d for d in
            glob.glob(os.path.join(adapter.get_temp_dir(), "rice-backup.*"))
            if os.path.isdir(d)]


# --------------------------------------------------------------------------
# RunWindow: one backend invocation with live log, phases, prompt relay
# --------------------------------------------------------------------------

class RunWindow(Gtk.ApplicationWindow):
    """Runs ONE backend command at a time via adapter.Runner; streams the
    combined (redacted) log; relays stdin prompts; calls on_finished(rc, text).

    `allow_cancel` is set for the real run/export only (GUI-PLAN rule 3:
    cancel is pre-push; disabled once the finish phase begins).
    """

    def __init__(self, app: "RiceGuiApp", title: str, allow_cancel: bool,
                 on_finished: Callable[[int, str], None]):
        super().__init__(application=app, title=title)
        self.rice = app
        self.allow_cancel = allow_cancel
        self.on_finished = on_finished
        self.runner: Optional[adapter.Runner] = None
        self._skip_callback = False
        self._prompt_open = False
        self._start_ts = time.monotonic()
        self._timer_id = 0
        self._tick_id = 0
        self.phase_idx = -1
        self._out_asm = adapter.LineAssembler()
        self._err_asm = adapter.LineAssembler()
        self._combined: List[str] = []

        self.set_default_size(760, 520)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_top(10)
        box.set_margin_bottom(10)
        box.set_margin_start(12)
        box.set_margin_end(12)

        self.phase_label = Gtk.Label(label=self._phase_text())
        box.append(self.phase_label)

        self.elapsed_label = Gtk.Label(label="elapsed 00:00")
        box.append(self.elapsed_label)

        self.log_buffer = Gtk.TextBuffer()
        view = Gtk.TextView(buffer=self.log_buffer)
        view.set_editable(False)
        view.set_cursor_visible(False)
        view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self._log_scroll = Gtk.ScrolledWindow()
        self._log_scroll.set_vexpand(True)
        self._log_scroll.set_child(view)
        self._log_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.ALWAYS)
        frame = Gtk.Frame()
        frame.set_child(self._log_scroll)
        box.append(frame)

        self.cancel_btn = Gtk.Button(label="_Cancel run", use_underline=True)
        self.cancel_btn.set_visible(allow_cancel)
        self.cancel_btn.connect("clicked", self._on_cancel)
        box.append(self.cancel_btn)

        self.set_child(box)
        self.connect("close-request", self._on_close_request)

    # -- api ------------------------------------------------------------------

    def start(self, argv: Sequence[str], env: dict, title: str) -> None:
        self.set_title(title)
        self._start_ts = time.monotonic()
        self.phase_idx = -1
        self._prompt_open = False
        self._skip_callback = False
        self.cancel_btn.set_sensitive(True)
        self.log_buffer.set_text("")
        self._out_asm = adapter.LineAssembler()
        self._err_asm = adapter.LineAssembler()
        self._combined = []
        self.runner = adapter.Runner(list(argv), cwd=str(self.rice.toolroot), env=env)
        self.runner.start()
        self._timer_id = GLib.timeout_add(80, self._drain)
        self._tick_id = GLib.timeout_add_seconds(1, self._tick)
        self.present()

    # -- internals --------------------------------------------------------------

    def _phase_text(self) -> str:
        marks = []
        for i, ph in enumerate(adapter.PHASE_ORDER):
            if i < self.phase_idx:
                marks.append("%s \u2714" % adapter.PHASE_LABELS[ph])
            elif i == self.phase_idx:
                marks.append("%s \u25c9" % adapter.PHASE_LABELS[ph])
            else:
                marks.append("%s \u25cb" % adapter.PHASE_LABELS[ph])
        return "   ".join(marks)

    def _tick(self) -> bool:
        secs = int(time.monotonic() - self._start_ts)
        self.elapsed_label.set_text("elapsed %02d:%02d" % (secs // 60, secs % 60))
        return GLib.SOURCE_CONTINUE

    def _append_log(self, line: str) -> None:
        line = adapter.redact(line, self.rice.pat)
        self._combined.append(line)
        end = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end, line + "\n")
        try:
            adj = self._log_scroll.get_vadjustment()
            adj.set_value(adj.get_upper())
        except Exception:
            pass

    def _set_phase(self, line: str) -> None:
        ph = adapter.phase_from_line(line)
        if ph:
            idx = adapter.PHASE_ORDER.index(ph)
            if idx > self.phase_idx:
                self.phase_idx = idx
                self.phase_label.set_text(self._phase_text())
            if ph == "finish" and self.allow_cancel:
                self.cancel_btn.set_sensitive(False)   # pre-push only (rule 3)

    def _process_events(self, events) -> None:
        for tag, chunk in events:
            if tag == "out":
                for line in self._out_asm.feed(chunk):
                    self._set_phase(line)
                    self._append_log(line)
            else:
                for line in self._err_asm.feed(chunk):
                    self._on_err_line(line)
                self._maybe_prompt()

    def _drain(self) -> bool:
        try:
            self._process_events(self.runner.poll_events(timeout=0.0))
        except Exception:
            return GLib.SOURCE_REMOVE
        if self.runner.alive():
            return GLib.SOURCE_CONTINUE
        # process ended: let the reader threads flush their final chunks
        try:
            self._process_events(self.runner.poll_events(timeout=0.3))
        except Exception:
            pass
        rc = self.runner.wait()                     # joins reader threads
        try:
            self._process_events(self.runner.poll_events(timeout=0.1))
        except Exception:
            pass
        for line in self._out_asm.flush() + self._err_asm.flush():
            self._append_log(line)
        self._cleanup_timers()
        if not self._skip_callback:
            self.on_finished(rc if rc is not None else -1, "\n".join(self._combined))
        self.destroy()
        return GLib.SOURCE_REMOVE

    def _on_err_line(self, line: str) -> None:
        self._set_phase(line)
        self._append_log(line)
        p = adapter.detect_prompt(line)
        if p and not self._prompt_open:
            self._open_prompt_modal(p)

    def _maybe_prompt(self) -> None:
        """Backend prompts end WITHOUT newline: they live in the partial."""
        if self._prompt_open:
            return
        partial = self._err_asm.partial()
        if not partial:
            return
        p = adapter.detect_prompt(partial)
        if p:
            self._append_log(self._err_asm.consume_partial())
            self._open_prompt_modal(p)

    def _open_prompt_modal(self, prompt: adapter.Prompt) -> None:
        self._prompt_open = True
        dlg = Gtk.Dialog(title="Backend needs input", transient_for=self, modal=True)
        dlg.set_default_size(500, -1)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        body.set_margin_top(10)
        body.set_margin_bottom(10)
        body.set_margin_start(14)
        body.set_margin_end(14)
        head = prompt.message
        body.append(Gtk.Label(label=head, wrap=True))
        entry = Gtk.Entry()
        body.append(entry)
        hint = ""
        if prompt.expected:
            hint = "type exactly: %s" % prompt.expected
        elif prompt.kind == "confirm":
            hint = "answer y or n"
        if hint:
            body.append(Gtk.Label(label=hint))
        dlg.get_content_area().append(body)
        dlg.add_button("_Send", Gtk.ResponseType.OK)
        dlg.add_button("_Abort run", Gtk.ResponseType.CANCEL)
        entry.connect("activate", lambda e: dlg.response(Gtk.ResponseType.OK))

        def _resp(d: Gtk.Dialog, r: int) -> None:
            answer = entry.get_text() if r == Gtk.ResponseType.OK else None
            d.destroy()
            self._prompt_open = False
            if answer is None:
                self.runner.terminate()
            else:
                self._append_log("[gui] relayed: %s" % answer)
                self.runner.write_line(answer)

        dlg.connect("response", _resp)
        entry.grab_focus()
        dlg.show()

    def _on_cancel(self, _btn: Gtk.Button) -> None:
        if confirm_dialog(self, "Cancel the run?",
                          "SIGTERM is sent to the backend before the push phase. "
                          "A 0700 staging directory may remain in %s; the GUI "
                          "offers cleanup at next startup." % adapter.get_temp_dir()):
            self.runner.terminate()

    def _on_close_request(self, _win: Gtk.ApplicationWindow) -> bool:
        if self.runner is not None and self.runner.alive():
            self.runner.terminate()
        self._skip_callback = True
        self._cleanup_timers()
        return False                     # allow destroy

    def _cleanup_timers(self) -> None:
        for attr in ("_timer_id", "_tick_id"):
            tid = getattr(self, attr, 0)
            if tid:
                try:
                    GLib.source_remove(tid)
                except Exception:
                    pass
                setattr(self, attr, 0)


# --------------------------------------------------------------------------
# SetupWindow
# --------------------------------------------------------------------------

class SetupWindow(Gtk.ApplicationWindow):

    def __init__(self, app: "RiceGuiApp") -> None:
        super().__init__(application=app, title="Rice Backup — setup")
        self.rice = app
        conf = app.conf

        self.set_default_size(int(conf.get("window_width", 980)),
                              int(conf.get("window_height", 700)))
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_margin_top(14)
        outer.set_margin_bottom(14)
        outer.set_margin_start(16)
        outer.set_margin_end(16)

        if app.version_warning:
            warn = Gtk.Label(
                label="<span foreground=\"#c01c28\"><b>%s</b></span>"
                      % esc(app.version_warning), use_markup=True, wrap=True)
            outer.append(warn)

        # -- target repository ------------------------------------------------
        outer.append(Gtk.Label(label="<b>Target repository (OWNER/NAME)</b>",
                               use_markup=True, halign=Gtk.Align.START))
        self.repo_entry = Gtk.Entry()
        self.repo_entry.set_placeholder_text("OWNER/NAME")
        self.repo_entry.set_text(conf.get("repo", "") or "")
        outer.append(self.repo_entry)

        # -- authentication ----------------------------------------------------
        outer.append(Gtk.Label(label="<b>Authentication</b>", use_markup=True,
                               halign=Gtk.Align.START))
        gh_ok = shutil.which("gh") is not None
        self.radio_gh = Gtk.CheckButton(
            label="gh CLI — %s" % ("detected" if gh_ok else
                                   "not found on this machine"))
        self.radio_gh.set_sensitive(gh_ok)
        self.radio_pat = Gtk.CheckButton(label="Personal access token")
        self.radio_pat.set_group(self.radio_gh)
        pat_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.pat_entry = Gtk.PasswordEntry()
        self.pat_entry.set_show_peek_icon(True)
        self.pat_entry.set_tooltip_text(
            "Kept in memory only — never written to disk, argv, URLs or logs")
        pat_box.append(self.pat_entry)
        mode = conf.get("auth_mode", "auto")
        if mode == "gh" and gh_ok:
            self.radio_gh.set_active(True)
        else:
            self.radio_pat.set_active(True)
        outer.append(self.radio_gh)
        outer.append(self.radio_pat)
        outer.append(pat_box)
        outer.append(Gtk.Label(
            label="<small>token hidden; memory only — wiped when this window "
                  "closes</small>", use_markup=True))

        # -- offline export mode (D33) ------------------------------------------
        self.offline_check = Gtk.CheckButton(
            label="Offline mode — export an archive only (no GitHub, no PAT)")
        self.offline_check.set_active(bool(conf.get("offline_last", False)))
        self.offline_check.connect("toggled", self._on_offline_toggled)
        outer.append(self.offline_check)

        # -- advanced ------------------------------------------------------------
        adv = Gtk.Expander(label="<b>Advanced</b>", use_markup=True)
        grid = Gtk.Grid(column_spacing=10, row_spacing=8)
        grid.attach(Gtk.Label(label="Home directory:", halign=Gtk.Align.START),
                    0, 0, 1, 1)
        self.home_entry = Gtk.Entry()
        self.home_entry.set_text(conf.get("home", "") or os.path.expanduser("~"))
        grid.attach(self.home_entry, 1, 0, 1, 1)
        self.include_system = Gtk.CheckButton(
            label="also collect the scanned /etc allowlist")
        self.include_system.set_active(bool(conf.get("include_system", False)))
        grid.attach(self.include_system, 0, 1, 2, 1)
        self.follow_links = Gtk.CheckButton(
            label="follow symlinks — fetch the content their targets point to "
                  "(links whose target is already backed up stay links; "
                  "recorded in symlinks.tsv for restore --relink)")
        self.follow_links.set_active(bool(conf.get("follow_symlinks", True)))
        grid.attach(self.follow_links, 0, 2, 2, 1)
        adv.set_child(grid)
        outer.append(adv)

        # -- session note ---------------------------------------------------------
        skipped_n = len(app.selection_store.skipped)
        note = ("<small>%s</small>" % esc(
            "Session saved under ~/.config/rice-backup/ (%d path(s) currently "
            "ticked OFF; review them after the dry-run)." % skipped_n
            if skipped_n else
            "No saved selection yet — everything found will be ticked ON."))
        outer.append(Gtk.Label(label=note, use_markup=True, wrap=True))

        # -- buttons ----------------------------------------------------------------
        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        btns.set_halign(Gtk.Align.END)
        quit_btn = Gtk.Button(label="_Quit", use_underline=True)
        quit_btn.connect("clicked", lambda b: app.quit())
        run_btn = Gtk.Button(label="_Run dry-run", use_underline=True)
        run_btn.get_style_context().add_class("suggested-action")
        run_btn.connect("clicked", self._on_run_dryrun)
        btns.append(quit_btn)
        btns.append(run_btn)
        outer.append(btns)

        self.set_child(outer)
        self.connect("close-request", self._on_close)
        self._on_offline_toggled(self.offline_check)
        self.present()

    # -- handlers -----------------------------------------------------------

    def _on_offline_toggled(self, check: Gtk.CheckButton) -> None:
        offline = check.get_active()
        for w in (self.repo_entry, self.radio_gh, self.radio_pat, self.pat_entry):
            w.set_sensitive(not offline)

    def _collect(self) -> Tuple[bool, str, str, bool]:
        """(ok, repo, home, offline) after basic validation."""
        offline = self.offline_check.get_active()
        home = self.home_entry.get_text().strip() or os.path.expanduser("~")
        repo = self.repo_entry.get_text().strip()
        if not offline and not adapter.valid_repo(repo):
            info_dialog(self, "Repository needed",
                        "Enter the target repository as OWNER/NAME, or switch "
                        "to offline mode to export an archive without GitHub.",
                        Gtk.MessageType.WARNING)
            return False, repo, home, False
        if not os.path.isdir(home):
            info_dialog(self, "Home directory not found",
                        "No such directory: %s" % home, Gtk.MessageType.WARNING)
            return False, repo, home, offline
        return True, repo, home, offline

    def _on_run_dryrun(self, _btn: Gtk.Button) -> None:
        ok, repo, home, offline = self._collect()
        if not ok:
            return
        app = self.rice
        app.repo = repo
        app.home = home
        app.offline_mode = offline
        app.include_system = self.include_system.get_active()
        app.follow_symlinks = self.follow_links.get_active()
        app.conf["repo"] = repo
        app.conf["home"] = home
        app.conf["include_system"] = app.include_system
        app.conf["follow_symlinks"] = app.follow_symlinks
        app.conf["offline_last"] = offline
        app.conf["auth_mode"] = "gh" if self.radio_gh.get_active() else "pat"
        app.save_conf()
        if not offline and self.radio_pat.get_active():
            app.pat = self.pat_entry.get_text()   # PAT in memory only (D25)
        else:
            app.pat = None

        argv = adapter.build_command(
            app.backend_script(), dry_run=True,
            repo=None if offline else repo, home=home,
            include_system=app.include_system,
            follow_symlinks=app.follow_symlinks,
            export_path=(adapter.get_temp_dir() +
                         "/rice-backup-export-preview.tar.gz") if offline else None)
        env = adapter.child_env(app.pat if not offline else None)
        win = RunWindow(app, "Dry-run", allow_cancel=False,
                        on_finished=self._dryrun_done)
        app.register_window("run", win)
        win.start(argv, env, "Dry-run — collecting and scanning (read-only)")

    def _dryrun_done(self, rc: int, text: str) -> None:
        app = self.rice
        if rc != 0:
            title, body = adapter.exit_meaning(rc)
            info_dialog(self, "Dry-run failed (exit %d): %s" % (rc, title), body,
                        Gtk.MessageType.ERROR)
            return
        summary = adapter.parse_dry_run(text)
        app.summary = summary

        argv = adapter.build_command(
            app.backend_script(), list_files=True, home=app.home,
            include_system=app.include_system,
            follow_symlinks=app.follow_symlinks)
        env = adapter.child_env(None)               # offline, read-only
        win = RunWindow(app, "Candidate list", allow_cancel=False,
                        on_finished=lambda rc2, text2: self._list_done(rc2, text2))
        app.register_window("run", win)
        win.start(argv, env, "Candidate list — post-exclusion file set")

    def _list_done(self, rc: int, text: str) -> None:
        app = self.rice
        if rc != 0:
            title, body = adapter.exit_meaning(rc)
            info_dialog(self, "Could not list candidates (exit %d): %s" % (rc, title),
                        body, Gtk.MessageType.ERROR)
            return
        app.entries = adapter.parse_file_list(text)
        app.register_window("review", ReviewWindow(app))

    def _on_close(self, _win: Gtk.ApplicationWindow) -> bool:
        self.rice.pat = None
        self.pat_entry.set_text("")
        return False


# --------------------------------------------------------------------------
# ReviewWindow — the core value: tick/skip checklist + exclusions + budget
# --------------------------------------------------------------------------

class ReviewWindow(Gtk.ApplicationWindow):

    def __init__(self, app: "RiceGuiApp") -> None:
        super().__init__(application=app, title="Dry-run review")
        self.rice = app
        self._needle = ""
        self._in_update = False
        self._session_children: List[Gtk.Widget] = []
        self._current_skips: set = set()
        self.set_default_size(int(app.conf.get("window_width", 980)),
                              int(app.conf.get("window_height", 700)))
        summary = app.summary
        entries = app.entries or []
        skipped = set(app.selection_store.skipped)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        outer.set_margin_top(10)
        outer.set_margin_bottom(10)
        outer.set_margin_start(12)
        outer.set_margin_end(12)

        # ---- header -----------------------------------------------------------
        if summary is None or not summary.parsed_ok:
            banner = Gtk.Label(
                label="<span foreground=\"#c01c28\"><b>could not parse backend "
                      "output — showing raw</b></span>", use_markup=True)
            outer.append(banner)
            raw = Gtk.TextView()
            buf = Gtk.TextBuffer()
            raw_text = summary.raw if summary else "(no dry-run output)"
            buf.insert(buf.get_end_iter(),
                       adapter.redact(raw_text, app.pat))
            raw.set_buffer(buf)
            raw.set_editable(False)
            sc = Gtk.ScrolledWindow()
            sc.set_vexpand(True)
            sc.set_child(raw)
            outer.append(sc)
            back = Gtk.Button(label="_Back", use_underline=True)
            back.connect("clicked", self._on_back)
            outer.append(back)
            self.set_child(outer)
            self.present()
            return

        head = "%s · %s" % (summary.distro, summary.target)
        if summary.export_mode:
            head += " · OFFLINE EXPORT"
        else:
            head += " · private: %s · auth: %s" % (summary.private,
                                                    summary.auth_mode)
        outer.append(Gtk.Label(label="<small>%s</small>" % esc(head),
                               use_markup=True, halign=Gtk.Align.START))
        if summary.links_followed or summary.links_kept:
            outer.append(Gtk.Label(
                label="<small>%s</small>" % esc(
                    "Symlinks: %d followed (%d file(s) fetched from their "
                    "targets), %d kept as links — see reports/SYMLINKS.md"
                    % (summary.links_followed, summary.files_from_links,
                       summary.links_kept)),
                use_markup=True, halign=Gtk.Align.START))
        self.header_label = Gtk.Label(label="")
        outer.append(self.header_label)

        # ---- body: sections (left) / exclusions+largest (right) ----------------
        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

        sec_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        sec_box.append(Gtk.Label(
            label="<b>Sections</b> — untick to skip whole trees",
            use_markup=True, halign=Gtk.Align.START))
        self.group_checks = {}
        groups: dict = {}
        for e in entries:
            groups.setdefault(adapter.group_top(e.rel), []).append(e)
        order = sorted(groups, key=lambda g: (g != "dotfiles", g))
        for g in order:
            cb = Gtk.CheckButton()
            cb.connect("toggled", self._on_group_toggled, g)
            self.group_checks[g] = cb
            sec_box.append(cb)
        sec_scroll = Gtk.ScrolledWindow()
        sec_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        sec_scroll.set_min_content_width(330)
        sec_scroll.set_child(sec_box)
        body.append(sec_scroll)

        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        nb = Gtk.Notebook()
        # R5: the excluded pages are interactive (activate a row -> explain
        # view); "Overridden" / "Acked" only exist when the backend printed
        # them (non-empty [allow]/[ack-scan] effects).
        for key, title, live in (
                ("hard deny list", "Deny", True),
                ("scan hits", "Scan hits", True),
                ("deny overridden", "Overridden", True),
                ("scan acknowledged", "Acked", True),
                ("oversized", "Oversized", False),
                ("caches/junk", "Caches", False)):
            block = summary.block(key)
            if key in ("deny overridden", "scan acknowledged") and not block:
                continue
            nb.append_page(self._excl_page(block, live), Gtk.Label(
                label="%s (%d)" % (title, block.count if block else 0)))
        nb.append_page(self._rules_page(), Gtk.Label(label="Rules"))
        self.session_page_label = Gtk.Label(label="Session (0)")
        nb.append_page(self._session_page(), self.session_page_label)
        right.append(nb)

        if summary.largest:
            exp = Gtk.Expander(label="<b>Largest candidates (top 15)</b>",
                               use_markup=True)
            exp.set_child(self._list_page(
                ["%9s  %s" % (adapter.human_size(b), p) for p, b in summary.largest]))
            right.append(exp)
        body.append(right)
        body.set_vexpand(False)

        # ---- file checklist -----------------------------------------------------
        search_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        search_row.append(Gtk.Label(label="<b>Candidates</b> — tick = back up",
                                    use_markup=True))
        self.search = Gtk.Entry()
        self.search.set_placeholder_text("filter by path…")
        self.search.set_hexpand(True)
        self.search.connect("changed", self._on_search)
        search_row.append(self.search)
        outer.append(search_row)

        self.store = Gtk.ListStore(bool, str, str, int)   # active, size, rel, bytes
        for e in entries:
            self.store.append([not adapter.is_skipped(e.rel, skipped),
                               adapter.human_size(e.size), e.rel, e.size])
        self.filter = self.store.filter_new()
        self.filter.set_visible_func(self._visible)
        view = Gtk.TreeView(model=self.filter)
        view.set_headers_visible(True)
        view.set_enable_search(False)

        rend_t = Gtk.CellRendererToggle()
        rend_t.connect("toggled", self._on_row_toggled)
        view.append_column(Gtk.TreeViewColumn("Back up", rend_t, active=0))

        rend_s = Gtk.CellRendererText()
        view.append_column(Gtk.TreeViewColumn("Size", rend_s, text=1))

        rend_p = Gtk.CellRendererText()
        rend_p.set_property("ellipsize", ellipsize_end())
        col_p = Gtk.TreeViewColumn("Path", rend_p, text=2)
        col_p.set_expand(True)
        view.append_column(col_p)

        scroll = Gtk.ScrolledWindow()
        scroll.set_vexpand(True)
        scroll.set_child(view)
        outer.append(body)
        outer.append(scroll)

        # ---- oversize + actions ---------------------------------------------------
        self.oversize = Gtk.CheckButton(
            label="Allow over-budget run (--allow-oversize)")
        self.oversize.set_active(False)             # defaults OFF every launch
        self.oversize.connect("toggled", self._on_oversize)
        outer.append(self.oversize)

        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        btns.set_halign(Gtk.Align.END)
        back = Gtk.Button(label="_Back", use_underline=True)
        back.connect("clicked", self._on_back)
        rules_btn = Gtk.Button(label="_Rules…", use_underline=True)
        rules_btn.connect("clicked", self._on_open_rules)
        refresh = Gtk.Button(label="_Refresh", use_underline=True)
        refresh.connect("clicked", self._on_refresh)
        self.export_btn = Gtk.Button(label="E_xport archive…", use_underline=True)
        self.export_btn.connect("clicked", self._on_export)
        self.run_btn = Gtk.Button(label="_Start backup", use_underline=True)
        self.run_btn.get_style_context().add_class("suggested-action")
        self.run_btn.connect("clicked", self._on_start_backup)
        self.run_btn.set_visible(not app.offline_mode)
        for b in (back, rules_btn, refresh, self.export_btn, self.run_btn):
            btns.append(b)
        outer.append(btns)

        self.set_child(outer)
        self.connect("close-request", self._on_close)
        self._refresh_session_page()
        self._update_header()
        self.present()
        # warm the --show-rules cache so the first explain view can gate
        # include-root stanzas on the deny dirs (R5)
        app.load_show_rules()

    # -- checklist plumbing ----------------------------------------------------

    def _visible(self, model, it, data) -> bool:
        if not self._needle:
            return True
        return self._needle in (model.get_value(it, 2) or "").lower()

    def _on_search(self, entry: Gtk.Entry) -> None:
        self._needle = entry.get_text().lower()
        self.filter.refilter()

    def _on_row_toggled(self, rend: Gtk.CellRendererToggle, path: str) -> None:
        fp = Gtk.TreePath.new_from_string(path)
        cp = self.filter.convert_path_to_child_path(fp)
        if cp is None:
            return
        it = self.store.get_iter(cp)
        self.store.set_value(it, 0, not self.store.get_value(it, 0))
        self._after_tick()

    def _on_group_toggled(self, cb: Gtk.CheckButton, group: str) -> None:
        if self._in_update:
            return
        active = cb.get_active()
        for row in self.store:
            if adapter.group_top(row[2]) == group:
                self.store.set_value(row.iter, 0, active)
        self._after_tick()

    def _after_tick(self) -> None:
        self._refresh_session_page()
        self._update_header()

    def _selected_stats(self) -> Tuple[int, int]:
        n = b = 0
        for row in self.store:
            if row[0]:
                n += 1
                b += row[3]
        return n, b

    def _update_header(self) -> None:
        total_n = len(self.store)
        sel_n, sel_b = self._selected_stats()
        chip = ""
        if sel_b > RICE_BUDGET_DEFAULT and not self.oversize.get_active():
            chip = '   <span foreground="#c01c28"><b>\u25cf OVER BUDGET</b></span>'
        elif sel_b > RICE_BUDGET_DEFAULT:
            chip = ('   <span foreground="#e5a50a"><b>\u25cf over budget '
                    '(allowed)</b></span>')
        self.header_label.set_markup(
            "%d candidates · <b>%d selected</b> · %s%s" % (
                total_n, sel_n, adapter.human_size(sel_b), chip))
        self._in_update = True
        try:
            for g, cb in self.group_checks.items():
                rows = [r for r in self.store if adapter.group_top(r[2]) == g]
                n_on = sum(1 for r in rows if r[0])
                size = adapter.human_size(sum(r[3] for r in rows))
                cb.set_active(bool(rows) and n_on == len(rows))
                cb.set_property("label", "%s  %d/%d · %s%s" % (
                    g, n_on, len(rows), size,
                    "" if n_on in (0, len(rows)) else "  (mixed)"))
        finally:
            self._in_update = False

    def _refresh_session_page(self) -> None:
        all_rels = [r[2] for r in self.store]
        unchecked = {r[2] for r in self.store if not r[0]}
        skips = adapter.compress_skips(all_rels, unchecked)
        self._current_skips = skips
        self.session_page_label.set_label("Session (%d)" % len(skips))
        for child in self._session_children:
            try:
                self._session_box.remove(child)
            except Exception:
                pass
        self._session_children = []
        if not skips:
            lbl = Gtk.Label(label="(nothing skipped)")
            self._session_box.append(lbl)
            self._session_children.append(lbl)
        for p in sorted(skips)[:400]:
            lbl = Gtk.Label(label=esc(p), halign=Gtk.Align.START)
            lbl.set_property("ellipsize", ellipsize_end())
            self._session_box.append(lbl)
            self._session_children.append(lbl)
        if len(skips) > 400:
            lbl = Gtk.Label(label="… and %d more" % (len(skips) - 400))
            self._session_box.append(lbl)
            self._session_children.append(lbl)

    def _session_page(self) -> Gtk.Widget:
        self._session_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        sc = Gtk.ScrolledWindow()
        sc.set_min_content_height(180)
        sc.set_child(self._session_box)
        return sc

    def _excl_page(self, block, live: bool) -> Gtk.Widget:
        """One excluded block as a notebook page. `live` pages (deny / scan
        / overridden / acked) are ListBoxes whose rows open the explain view
        (RULES-PLAN section 8: context action on an excluded row)."""
        items = list(block.items) if block else []
        if not live:
            return self._list_page(
                ["%s  %s" % (p, ("[%s]" % n) if n else "") for p, n in items]
                or ["(none)"])
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        box.append(Gtk.Label(
            label="<small>double-click a row to explain its verdict chain</small>",
            use_markup=True, halign=Gtk.Align.START))
        lb = Gtk.ListBox()
        lb.set_selection_mode(Gtk.SelectionMode.NONE)
        if items:
            for p, n in items[:500]:
                row = Gtk.ListBoxRow()
                lbl = Gtk.Label(
                    label=esc("%s  %s" % (p, ("[%s]" % n) if n else "")),
                    halign=Gtk.Align.START)
                lbl.set_property("ellipsize", ellipsize_end())
                row.set_child(lbl)
                try:
                    row._path = p
                except Exception:
                    pass
                lb.append(row)
            if len(items) > 500:
                lb.append(Gtk.ListBoxRow(child=Gtk.Label(
                    label="… and %d more (see the dry-run log)"
                          % (len(items) - 500))))
        else:
            lb.append(Gtk.ListBoxRow(child=Gtk.Label(label="(none)")))
        lb.connect("row-activated", self._on_excl_row)
        sc = Gtk.ScrolledWindow()
        sc.set_min_content_height(160)
        sc.set_child(lb)
        box.append(sc)
        return box

    def _on_excl_row(self, lb: Gtk.ListBox, row: Gtk.ListBoxRow) -> None:
        path = getattr(row, "_path", None)
        if path:
            ExplainDialog(self.rice, self, path)

    def _rules_page(self) -> Gtk.Widget:
        """Summary of the ACTIVE rules.conf + the editor entry point (R5)."""
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        rc = adapter.read_rules(self.rice.rules_path)
        lines: List[str] = []
        sections = (
            ("[include-file]", rc.include_files),
            ("[include-dir]", rc.include_dirs),
            ("[skip-dir]", rc.skip_dirs),
            ("[allow]", rc.allow),
            ("[ack-scan]", rc.ack_scan),
        )
        active = any(entries for _n, entries in sections) or rc.file_cap or rc.total_budget
        if not active:
            lines.append("defaults only - no rules.conf entries yet")
        for name, entries in sections:
            if entries:
                lines.append("%s (%d):" % (name, len(entries)))
                lines.extend("  %s" % v for v in entries[:8])
                if len(entries) > 8:
                    lines.append("  … and %d more" % (len(entries) - 8))
        if rc.file_cap:
            lines.append("[size] file_cap = %s" % rc.file_cap)
        if rc.total_budget:
            lines.append("[size] total_budget = %s" % rc.total_budget)
        for text in lines[:60]:
            lbl = Gtk.Label(label=esc(text), halign=Gtk.Align.START)
            lbl.set_property("ellipsize", ellipsize_end())
            box.append(lbl)
        if len(lines) > 60:
            box.append(Gtk.Label(label="… and %d more" % (len(lines) - 60)))
        btn = Gtk.Button(label="_Open the rules editor…", use_underline=True)
        btn.connect("clicked", self._on_open_rules)
        box.append(btn)
        box.append(Gtk.Label(
            label="<small>changes take effect on the next dry-run / backup; "
                  "'Save & re-run dry-run' refreshes this view</small>",
            use_markup=True, halign=Gtk.Align.START))
        sc = Gtk.ScrolledWindow()
        sc.set_min_content_height(180)
        sc.set_child(box)
        return sc

    def _on_open_rules(self, _btn: Optional[Gtk.Button]) -> None:
        win = RulesWindow(self.rice, on_saved=self._on_rules_saved)
        self.rice.register_window("rules", win)

    def _on_rules_saved(self) -> None:
        """After 'Save & re-run dry-run' in the rules editor."""
        self._on_refresh(None)

    def _list_page(self, lines: Sequence[str]) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        for text in list(lines)[:500]:
            lbl = Gtk.Label(label=esc(text), halign=Gtk.Align.START)
            lbl.set_property("ellipsize", ellipsize_end())
            box.append(lbl)
        if len(lines) > 500:
            box.append(Gtk.Label(
                label="… and %d more (see the full dry-run log)"
                      % (len(lines) - 500)))
        sc = Gtk.ScrolledWindow()
        sc.set_min_content_height(160)
        sc.set_child(box)
        return sc

    # -- actions -----------------------------------------------------------------

    def _on_oversize(self, check: Gtk.CheckButton) -> None:
        if not check.get_active():
            return
        _, sel_b = self._selected_stats()
        if not confirm_dialog(
                self, "Allow an over-budget run?",
                "The current selection is %s, above the 1 GiB budget. GitHub may "
                "throttle or reject large pushes. Proceed anyway?"
                % adapter.human_size(sel_b)):
            check.set_active(False)

    def _apply_selection(self) -> None:
        """Write the tick state to selection.txt (D34) so the backend's
        --exclude-from sees exactly what the user sees."""
        all_rels = [r[2] for r in self.store]
        unchecked = {r[2] for r in self.store if not r[0]}
        self._current_skips = adapter.compress_skips(all_rels, unchecked)
        self.rice.selection_store.save(self._current_skips)

    def _common_argv(self, **kw) -> List[str]:
        app = self.rice
        excl = (self.rice.selection_store.path
                if self.rice.selection_store.skipped else None)
        return adapter.build_command(
            app.backend_script(), home=app.home,
            include_system=app.include_system,
            follow_symlinks=app.follow_symlinks,
            exclude_from=excl, **kw)

    def _on_start_backup(self, _btn: Gtk.Button) -> None:
        app = self.rice
        if app.offline_mode:
            return
        self._apply_selection()
        app.save_geometry()
        argv = self._common_argv(
            repo=app.repo, assume_yes=True,
            allow_oversize=self.oversize.get_active())
        env = adapter.child_env(app.pat)
        win = RunWindow(app, "Backup", allow_cancel=True,
                        on_finished=self._run_done)
        app.register_window("run", win)
        win.start(argv, env, "Backup in progress — staging, scanning (S4), pushing")

    def _on_export(self, _btn: Gtk.Button) -> None:
        app = self.rice
        self._apply_selection()
        app.save_geometry()
        dlg = Gtk.FileChooserNative.new(
            "Export backup archive", self, Gtk.FileChooserAction.SAVE,
            "_Export", "_Cancel")
        dlg.set_current_name("rice-backup-%s.tar.gz"
                             % datetime.now().strftime("%Y%m%d-%H%M%S"))
        export_dir = app.conf.get("export_dir", "") or os.path.expanduser("~")
        try:
            dlg.set_current_folder(Gio.File.new_for_path(export_dir))
        except Exception:
            pass

        def _resp(fc, res):
            if res != Gtk.ResponseType.ACCEPT:
                fc.destroy()
                return
            gfile = fc.get_file()
            path = gfile.get_path() if gfile else None
            fc.destroy()
            if not path:
                return
            app.conf["export_dir"] = os.path.dirname(path) or export_dir
            app.save_conf()
            argv = self._common_argv(export_path=path, assume_yes=True,
                                     allow_oversize=self.oversize.get_active())
            env = adapter.child_env(None)             # offline: no PAT (D33)
            win = RunWindow(app, "Export", allow_cancel=True,
                            on_finished=self._run_done)
            app.register_window("run", win)
            app._pending_export_path = path
            win.start(argv, env, "Export in progress — staging, scanning (S4), "
                                 "writing the archive (no push)")

        dlg.connect("response", _resp)
        dlg.show()

    def _run_done(self, rc: int, text: str) -> None:
        app = self.rice
        if rc != 0:
            title, body = adapter.exit_meaning(rc)
            info_dialog(self, "Backup failed (exit %d): %s" % (rc, title),
                        body, Gtk.MessageType.ERROR)
            return
        export_path = getattr(app, "_pending_export_path", None)
        app._pending_export_path = None
        kind = "export" if export_path else "push"
        app.register_window("result", ResultWindow(app, kind, text, export_path))

    def _on_refresh(self, _btn: Gtk.Button) -> None:
        """Re-run the dry-run + candidate list (filesystem may have changed)."""
        app = self.rice
        self._apply_selection()
        argv = adapter.build_command(
            app.backend_script(), dry_run=True,
            repo=None if app.offline_mode else app.repo, home=app.home,
            include_system=app.include_system,
            export_path=(adapter.get_temp_dir() +
                         "/rice-backup-export-preview.tar.gz")
            if app.offline_mode else None)
        env = adapter.child_env(app.pat if not app.offline_mode else None)
        win = RunWindow(app, "Dry-run (refresh)", allow_cancel=False,
                        on_finished=self._refresh_done)
        app.register_window("run", win)
        win.start(argv, env, "Dry-run refresh — collecting and scanning")

    def _refresh_done(self, rc: int, text: str) -> None:
        if rc != 0:
            title, body = adapter.exit_meaning(rc)
            info_dialog(self, "Refresh failed (exit %d): %s" % (rc, title), body,
                        Gtk.MessageType.ERROR)
            return
        app = self.rice
        app.summary = adapter.parse_dry_run(text)
        argv = adapter.build_command(
            app.backend_script(), list_files=True, home=app.home,
            include_system=app.include_system,
            follow_symlinks=app.follow_symlinks)
        env = adapter.child_env(None)
        win = RunWindow(app, "Candidate list (refresh)", allow_cancel=False,
                        on_finished=self._refresh_list_done)
        app.register_window("run", win)
        win.start(argv, env, "Candidate list refresh")

    def _refresh_list_done(self, rc: int, text: str) -> None:
        if rc != 0:
            return
        app = self.rice
        app.entries = adapter.parse_file_list(text)
        self.destroy()
        app.register_window("review", ReviewWindow(app))

    def _on_back(self, _btn: Gtk.Button) -> None:
        self.rice.save_geometry()
        self.rice.save_conf()
        self.destroy()
        setup = self.rice.windows.get("setup")
        if setup is not None:
            setup.present()

    def _on_close(self, _win) -> bool:
        self.rice.save_geometry()
        self.rice.save_conf()
        return False


# --------------------------------------------------------------------------
# offline backend helper (R5): --explain / --show-rules without blocking GTK
# --------------------------------------------------------------------------

_ASYNC_RUNNERS: List[object] = []


def clear_box(box: Gtk.Widget) -> None:
    """Remove every child of a Gtk.Box / Gtk.ListBox (GTK4 containers are
    not Python-iterable; walk the sibling chain instead)."""
    child = box.get_first_child()
    while child is not None:
        nxt = child.get_next_sibling()
        box.remove(child)
        child = nxt


def listbox_rows(lb: Gtk.ListBox) -> List[Gtk.ListBoxRow]:
    child = lb.get_first_child()
    rows: List[Gtk.ListBoxRow] = []
    while child is not None:
        rows.append(child)
        child = child.get_next_sibling()
    return rows


def run_backend_async(argv: Sequence[str],
                      on_done: Callable[[int, str], None]) -> None:
    """Spawn an OFFLINE backend command (--explain / --show-rules: no PAT
    ever enters the child environment) and deliver (rc, combined text) on
    the GTK main thread via GLib.timeout_add. The runner is kept alive in a
    module-level list so a closing dialog can never orphan it mid-read."""
    runner = adapter.Runner([str(a) for a in argv],
                            env=adapter.child_env(None)).start()
    _ASYNC_RUNNERS.append(runner)
    chunks: List[str] = []

    def _tick() -> bool:
        for _tag, chunk in runner.poll_events(timeout=0.0):
            chunks.append(chunk)
        if runner.alive():
            return True
        rc = runner.wait()
        for _tag, chunk in runner.poll_events(timeout=0.3):
            chunks.append(chunk)
        try:
            _ASYNC_RUNNERS.remove(runner)
        except ValueError:
            pass
        try:
            on_done(rc if rc is not None else 0, "".join(chunks))
        except Exception:
            pass                # the receiving widget may already be gone
        return False

    GLib.timeout_add(80, _tick)


def choose_from_list(parent: Gtk.Window, title: str,
                     items: Sequence[Tuple[str, str]],
                     hint: str = "") -> Optional[Tuple[str, str]]:
    """Modal chooser over (path, note) pairs; returns the picked pair or
    None. Single-click selects, double-click or Select accepts. Runs a
    nested GLib main loop like confirm_dialog (show() alone does not
    block)."""
    dlg = Gtk.Dialog(title=title, transient_for=parent, modal=True)
    dlg.set_default_size(560, 420)
    picked = {"item": None}
    loop = GLib.MainLoop()

    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_margin_top(8)
    box.set_margin_bottom(8)
    box.set_margin_start(10)
    box.set_margin_end(10)
    if hint:
        lbl = Gtk.Label(label="<small>%s</small>" % esc(hint), use_markup=True,
                        halign=Gtk.Align.START, wrap=True)
        box.append(lbl)
    lb = Gtk.ListBox()
    for path, note in items:
        row = Gtk.ListBoxRow()
        text = "%s  %s" % (path, ("[%s]" % note) if note else "")
        rl = Gtk.Label(label=esc(text), halign=Gtk.Align.START)
        rl.set_property("ellipsize", ellipsize_end())
        row.set_child(rl)
        lb.append(row)
    if not items:
        lb.append(Gtk.ListBoxRow(child=Gtk.Label(label="(nothing to list)")))
    sc = Gtk.ScrolledWindow()
    sc.set_vexpand(True)
    sc.set_child(lb)
    box.append(sc)
    dlg.get_content_area().append(box)

    def _activated(_lb, row):
        picked["item"] = getattr(row, "_item", None)
        dlg.response(Gtk.ResponseType.OK)

    # attach items to their rows (the '(nothing to list)' filler maps to None)
    for r, item in zip(listbox_rows(lb), list(items) if items else [None]):
        try:
            r._item = item
        except Exception:
            pass
    lb.connect("row-activated", _activated)
    dlg.add_button("_Cancel", Gtk.ResponseType.CANCEL)
    btn = dlg.add_button("_Select", Gtk.ResponseType.OK)
    btn.get_style_context().add_class("suggested-action")

    def _resp(d, r):
        if r == Gtk.ResponseType.OK and picked["item"] is None:
            sel = lb.get_selected_row()
            if sel is not None:
                picked["item"] = getattr(sel, "_item", None)
        d.destroy()
        loop.quit()

    dlg.connect("response", _resp)
    dlg.show()
    loop.run()
    return picked["item"]


# --------------------------------------------------------------------------
# ExplainDialog: verdict chain for one path (R5, RULES-PLAN section 8)
# --------------------------------------------------------------------------

class ExplainDialog(Gtk.Dialog):
    """Runs `--explain PATH` (offline, read-only) and renders the verdict
    chain. Offers the exact rules.conf stanza to copy when the backend rails
    allow an override; hard-core / token-shaped refusals are shown as such
    and never offered."""

    def __init__(self, app: "RiceGuiApp", parent: Gtk.Window, path: str) -> None:
        super().__init__(title="Explain: %s" % path, transient_for=parent,
                         modal=True)
        self.rice = app
        self.path = path
        self._stanza = ""
        self.set_default_size(600, 400)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_top(10)
        box.set_margin_bottom(10)
        box.set_margin_start(12)
        box.set_margin_end(12)

        self.body = Gtk.Label(
            label="<i>running --explain (offline, read-only)…</i>",
            use_markup=True, halign=Gtk.Align.START, wrap=True)
        box.append(self.body)

        self.raw_buffer = Gtk.TextBuffer()
        view = Gtk.TextView(buffer=self.raw_buffer)
        view.set_editable(False)
        view.set_cursor_visible(False)
        view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        sc = Gtk.ScrolledWindow()
        sc.set_vexpand(True)
        sc.set_child(view)
        box.append(sc)

        self.note_lbl = Gtk.Label(label="", halign=Gtk.Align.START, wrap=True)
        box.append(self.note_lbl)
        self.stanza_btn = Gtk.Button(label="Copy rules.conf _stanza",
                                     use_underline=True, sensitive=False)
        self.stanza_btn.connect("clicked", self._on_copy)
        self.stanza_btn.set_halign(Gtk.Align.END)
        box.append(self.stanza_btn)

        self.get_content_area().append(box)
        self.add_button("_Close", Gtk.ResponseType.CLOSE)
        self.connect("response", lambda d, r: d.destroy())
        self.present()

        argv = adapter.build_command(app.backend_script(), home=app.home,
                                     explain=[path])
        run_backend_async(argv, self._done)

    def _done(self, rc: int, text: str) -> None:
        text = adapter.redact(text, self.rice.pat)
        self.raw_buffer.insert(self.raw_buffer.get_end_iter(), text)
        out = adapter.parse_explain(text)
        row = out.first()
        if row is None:
            self.body.set_markup("<b>%s</b> - no verdict (exit %d); see the "
                                 "raw output below" % (esc(self.path), rc))
            return
        lines = ["<b>%s</b>" % esc(row.path),
                 "verdict : %s" % esc(row.verdict),
                 "layer   : %s" % esc(row.layer),
                 "rule    : %s" % esc(row.rule)]
        if row.override:
            lines.append("override: %s" % esc(row.override))
        self.body.set_markup("\n".join(lines))
        deny_dirs = ()
        if self.rice.show_rules is not None:
            deny_dirs = [r.value for r in self.rice.show_rules.deny_dirs]
        stanza, note = adapter.explain_stanza(row, deny_dirs)
        if stanza:
            self._stanza = stanza
            self.stanza_btn.set_sensitive(True)
            self.note_lbl.set_text(note)
        else:
            self.note_lbl.set_text(note or "nothing to override for this "
                                            "verdict")

    def _on_copy(self, w: Gtk.Button) -> None:
        copy_to_clipboard(w, self._stanza)


# --------------------------------------------------------------------------
# RulesWindow: the rules.conf editor (R5, RULES-PLAN section 8)
# --------------------------------------------------------------------------

class RulesWindow(Gtk.ApplicationWindow):
    """Edits ~/.config/rice-backup/rules.conf:

      - Roots page: default include roots with enable checkboxes (an
        unchecked root is written to [skip-dir]) plus the custom
        [include-file]/[include-dir] entries.
      - Allow page: [allow] entries, each annotated with the deny rule it
        overrides (from the current dry-run); adding runs --explain first so
        hard-core paths are refused exactly like the backend refuses them.
      - Ack page: [ack-scan] entries; adding is gated behind a confirmation
        that names the matched scan rule and the rail policy - token-shaped
        rules are refused outright (adapter.ack_is_allowed).
      - Sizes page: [size] file_cap / total_budget.

    Saving writes via adapter.write_rules (0600); the backend re-reads the
    file on the next run, and 'Save & re-run dry-run' triggers the refresh
    so the user sees the effect immediately."""

    def __init__(self, app: "RiceGuiApp",
                 on_saved: Optional[Callable[[], None]] = None) -> None:
        super().__init__(application=app, title="Backup rules (rules.conf)")
        self.rice = app
        self.on_saved = on_saved
        self._updating = False
        self.rules_path = app.rules_path
        self.rc = adapter.read_rules(self.rules_path)
        # [skip-dir] entries are preserved verbatim until the default roots
        # load (they are recomputed against them in _fill_default_roots), so
        # an early Save cannot drop them (race guard).
        self._extra_skip = list(self.rc.skip_dirs)

        self.set_default_size(720, 560)
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        outer.set_margin_top(10)
        outer.set_margin_bottom(10)
        outer.set_margin_start(12)
        outer.set_margin_end(12)

        path_lbl = Gtk.Label(
            label="<small>rules file: <b>%s</b> - read by every future run; "
                  "0600, safe to edit by hand</small>"
                  % esc(str(self.rules_path)),
            use_markup=True, halign=Gtk.Align.START)
        outer.append(path_lbl)
        self.status_lbl = Gtk.Label(label="", halign=Gtk.Align.START, wrap=True)
        outer.append(self.status_lbl)

        nb = Gtk.Notebook()
        nb.append_page(self._roots_page(), Gtk.Label(label="Roots"))
        nb.append_page(self._allow_page(), Gtk.Label(label="Allow"))
        nb.append_page(self._ack_page(), Gtk.Label(label="Ack scan"))
        nb.append_page(self._sizes_page(), Gtk.Label(label="Sizes"))
        outer.append(nb)

        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        btns.set_halign(Gtk.Align.END)
        reload_btn = Gtk.Button(label="_Reload", use_underline=True)
        reload_btn.connect("clicked", self._on_reload)
        save_btn = Gtk.Button(label="_Save", use_underline=True)
        save_btn.connect("clicked", self._on_save)
        rerun_btn = Gtk.Button(label="_Save & re-run dry-run", use_underline=True)
        rerun_btn.get_style_context().add_class("suggested-action")
        rerun_btn.connect("clicked", self._on_save_rerun)
        for b in (reload_btn, save_btn, rerun_btn):
            btns.append(b)
        outer.append(btns)

        self.set_child(outer)
        self.connect("close-request", self._on_close)
        self._refresh_lists()
        self._load_show_rules()
        self.present()

    # -- pages ---------------------------------------------------------------

    def _roots_page(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)

        f_def = Gtk.Frame(label="Default include roots (untick = [skip-dir])")
        self._default_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self._default_box.set_margin_top(6)
        self._default_box.set_margin_bottom(6)
        self._default_box.set_margin_start(10)
        self._default_box.set_margin_end(10)
        self._default_box.append(Gtk.Label(
            label="<i>loading the default roots from the backend…</i>",
            use_markup=True, halign=Gtk.Align.START))
        sc = Gtk.ScrolledWindow()
        sc.set_min_content_height(190)
        sc.set_child(self._default_box)
        f_def.set_child(sc)
        box.append(f_def)

        f_custom = Gtk.Frame(label="Custom roots ([include-file] / [include-dir])")
        cust = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        cust.set_margin_top(6)
        cust.set_margin_bottom(6)
        cust.set_margin_start(10)
        cust.set_margin_end(10)
        self._custom_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        cust.append(self._custom_box)
        add_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self._root_entry = Gtk.Entry()
        self._root_entry.set_placeholder_text("home-relative path, e.g. Dev/dotfiles")
        self._root_entry.set_hexpand(True)
        add_row.append(self._root_entry)
        self._root_kind = Gtk.ComboBoxText()
        self._root_kind.append_text("directory (walked)")
        self._root_kind.append_text("top-level file")
        self._root_kind.set_active(0)
        add_row.append(self._root_kind)
        add_btn = Gtk.Button(label="_Add root")
        add_btn.set_use_underline(True)
        add_btn.connect("clicked", self._on_add_root)
        add_row.append(add_btn)
        cust.append(add_row)
        hint = Gtk.Label(
            label="<small>paths must exist in the home; deny-listed roots are "
                  "refused by the backend (hard core)</small>",
            use_markup=True, halign=Gtk.Align.START)
        cust.append(hint)
        f_custom.set_child(cust)
        box.append(f_custom)
        return box

    def _allow_page(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        f = Gtk.Frame(label="Deny overrides ([allow]) - soft rules only")
        inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        inner.set_margin_top(6)
        inner.set_margin_bottom(6)
        inner.set_margin_start(10)
        inner.set_margin_end(10)
        self._allow_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        inner.append(self._allow_box)
        add_btn = Gtk.Button(label="_Add from current exclusions…")
        add_btn.set_use_underline(True)
        add_btn.connect("clicked", self._on_add_allow)
        inner.append(add_btn)
        hint = Gtk.Label(
            label="<small>each add is verified with --explain first: hard-core "
                  "paths are refused. The backend re-checks every entry on "
                  "every run.</small>",
            use_markup=True, halign=Gtk.Align.START, wrap=True)
        inner.append(hint)
        f.set_child(inner)
        box.append(f)
        return box

    def _ack_page(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        f = Gtk.Frame(label="Scan acknowledgements ([ack-scan]) - exact file paths")
        inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        inner.set_margin_top(6)
        inner.set_margin_bottom(6)
        inner.set_margin_start(10)
        inner.set_margin_end(10)
        self._ack_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        inner.append(self._ack_box)
        add_btn = Gtk.Button(label="_Add from current scan hits…")
        add_btn.set_use_underline(True)
        add_btn.connect("clicked", self._on_add_ack)
        inner.append(add_btn)
        hint = Gtk.Label(
            label="<small>ackable rules: %s. Token-shaped / key material "
                  "(gh-*, private-key, aws-*, google-*, slack-*, stripe-*, "
                  "jwt, exact PAT hits) can never be acknowledged.</small>"
                  % esc(", ".join(adapter.ACKABLE_SCAN_RULES)),
            use_markup=True, halign=Gtk.Align.START, wrap=True)
        inner.append(hint)
        f.set_child(inner)
        box.append(f)
        return box

    def _sizes_page(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_top(8)
        box.set_margin_start(8)
        grid = Gtk.Grid()
        grid.set_row_spacing(6)
        grid.set_column_spacing(10)
        lbl1 = Gtk.Label(label="Per-file cap ([size] file_cap):", halign=Gtk.Align.START)
        self._cap_entry = Gtk.Entry()
        self._cap_entry.set_placeholder_text("e.g. 50M (blank = default)")
        self._cap_entry.set_text(self.rc.file_cap)
        grid.attach(lbl1, 0, 0, 1, 1)
        grid.attach(self._cap_entry, 1, 0, 1, 1)
        lbl2 = Gtk.Label(label="Total budget ([size] total_budget):", halign=Gtk.Align.START)
        self._budget_entry = Gtk.Entry()
        self._budget_entry.set_placeholder_text("e.g. 1G (blank = default)")
        self._budget_entry.set_text(self.rc.total_budget)
        grid.attach(lbl2, 0, 1, 1, 1)
        grid.attach(self._budget_entry, 1, 1, 1, 1)
        box.append(grid)
        box.append(Gtk.Label(
            label="<small>plain bytes or N/NK/NM/NG; values above 100 MiB are "
                  "refused (GitHub's hard limit); blank keeps the defaults. "
                  "RICE_TOTAL_MAX_BYTES in the environment still wins for the "
                  "budget (back-compat).</small>",
            use_markup=True, halign=Gtk.Align.START, wrap=True))
        return box

    # -- data flows ------------------------------------------------------------

    def _load_show_rules(self) -> None:
        argv = adapter.build_command(self.rice.backend_script(),
                                     home=self.rice.home, show_rules=True)
        run_backend_async(argv, self._show_rules_done)

    def _show_rules_done(self, rc: int, text: str) -> None:
        sr = adapter.parse_show_rules(adapter.redact(text, self.rice.pat))
        if sr.parsed_ok:
            self.rice.show_rules = sr
        else:
            self.status_lbl.set_text(
                "could not read the default rules from the backend "
                "(--show-rules exit %d) - root checkboxes unavailable this "
                "time; the other sections still work" % rc)
        self._fill_default_roots(sr if sr.parsed_ok else None)

    def _fill_default_roots(self, sr: Optional[adapter.ShowRules]) -> None:
        clear_box(self._default_box)
        if sr is None or not sr.parsed_ok:
            self._default_box.append(Gtk.Label(
                label="(default roots unavailable)", halign=Gtk.Align.START))
            return
        self._default_checks: dict = {}
        skipped = {r.value for r in sr.skip_dirs}
        roots = ([(v, True) for v in sr.default_dirs()] +
                 [(v, False) for v in sr.default_files()])
        for value, is_dir in sorted(roots):
            cb = Gtk.CheckButton(label="%s%s" % (value, "  (dir)" if is_dir else ""))
            cb.set_active(value not in skipped)
            self._default_checks[value] = cb
            self._default_box.append(cb)
        if not roots:
            self._default_box.append(Gtk.Label(
                label="(no default roots reported)", halign=Gtk.Align.START))
        # [skip-dir] entries that match no default root are preserved verbatim
        self._extra_skip = [r.value for r in sr.skip_dirs
                            if r.value not in self._default_checks]
        self._refresh_lists()

    def _refresh_lists(self) -> None:
        """Re-render the custom-roots / allow / ack rows from self.rc."""
        rc = self.rc
        for box in (self._custom_box, self._allow_box, self._ack_box):
            clear_box(box)

        if not (rc.include_files or rc.include_dirs):
            self._custom_box.append(Gtk.Label(
                label="(no custom roots)", halign=Gtk.Align.START))
        for v in rc.include_dirs:
            self._custom_box.append(self._removable_row(
                "%s  [include-dir]" % v, ("include-dir", v)))
        for v in rc.include_files:
            self._custom_box.append(self._removable_row(
                "%s  [include-file]" % v, ("include-file", v)))

        over = self._summary_map("deny overridden")
        denied = self._summary_map("hard deny list")
        if not rc.allow:
            self._allow_box.append(Gtk.Label(
                label="(no deny overrides)", halign=Gtk.Align.START))
        for v in rc.allow:
            if v in over:
                note = "was: %s (rescued in this dry-run)" % over[v]
            elif v in denied:
                note = "was: %s (STILL excluded - see the explain view)" % denied[v]
            else:
                note = "not denied in this dry-run (entry inactive)"
            self._allow_box.append(self._removable_row(
                "%s  -  %s" % (v, note), ("allow", v)))

        acked = self._summary_map("scan acknowledged")
        hits = self._summary_map("scan hits")
        if not rc.ack_scan:
            self._ack_box.append(Gtk.Label(
                label="(no scan acknowledgements)", halign=Gtk.Align.START))
        for v in rc.ack_scan:
            if v in acked:
                note = "kept (scan rule: %s)" % acked[v]
            elif v in hits:
                note = "STILL excluded (scan rule: %s - ack refused?)" % hits[v]
            else:
                note = "no scan hit in this dry-run (entry inactive)"
            self._ack_box.append(self._removable_row(
                "%s  -  %s" % (v, note), ("ack-scan", v)))

        if rc.warnings:
            self.status_lbl.set_text("warnings from the last load: %s"
                                     % "; ".join(rc.warnings[:4]))

    def _summary_map(self, block_key: str) -> dict:
        summary = self.rice.summary
        if summary is None:
            return {}
        block = summary.block(block_key)
        return {p: n for p, n in block.items} if block else {}

    def _removable_row(self, text: str, item: Tuple[str, str]) -> Gtk.Widget:
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        lbl = Gtk.Label(label=esc(text), halign=Gtk.Align.START)
        lbl.set_property("ellipsize", ellipsize_end())
        lbl.set_hexpand(True)
        btn = Gtk.Button(label="_Remove")
        btn.set_use_underline(True)
        btn.connect("clicked", self._on_remove, item)
        row.append(lbl)
        row.append(btn)
        return row

    # -- actions ---------------------------------------------------------------

    def _on_remove(self, _btn: Gtk.Button, item: Tuple[str, str]) -> None:
        section, value = item
        target = {"include-file": self.rc.include_files,
                  "include-dir": self.rc.include_dirs,
                  "allow": self.rc.allow,
                  "ack-scan": self.rc.ack_scan}.get(section, [])
        if value in target:
            target.remove(value)
        self._refresh_lists()

    def _on_add_root(self, _btn: Gtk.Button) -> None:
        raw = self._root_entry.get_text().strip()
        kind = "include-dir" if self._root_kind.get_active() == 0 else "include-file"
        problem = adapter.rules_entry_problem(raw)
        if problem is not None or not raw:
            info_dialog(self, "Invalid path",
                        "The path cannot be used: %s." % (problem or "empty"),
                        Gtk.MessageType.WARNING)
            return
        target = (self.rc.include_dirs if kind == "include-dir"
                  else self.rc.include_files)
        if raw not in target:
            target.append(raw)
        self._root_entry.set_text("")
        self._refresh_lists()

    def _on_add_allow(self, _btn: Gtk.Button) -> None:
        summary = self.rice.summary
        block = summary.block("hard deny list") if summary else None
        items = list(block.items) if block else []
        if not items:
            info_dialog(self, "Nothing to allow",
                        "The current dry-run denied no files by name, so there "
                        "is nothing to re-include.")
            return
        picked = choose_from_list(
            self, "Pick the denied path to re-include", items,
            hint="each pick is verified with --explain before it is added")
        if picked is None:
            return
        path, rule = picked
        argv = adapter.build_command(self.rice.backend_script(),
                                     home=self.rice.home, explain=[path])
        self.status_lbl.set_text("verifying %s with --explain…" % path)

        def done(rc: int, text: str) -> None:
            out = adapter.parse_explain(adapter.redact(text, self.rice.pat))
            row = out.first()
            if row is None:
                self.status_lbl.set_text("explain failed (exit %d)" % rc)
                return
            stanza, note = adapter.explain_stanza(row)
            if row.layer == "L1 deny" and "soft rule" in row.override:
                if not confirm_dialog(
                        self, "Re-include %s?" % path,
                        "This path is denied by the SOFT rule %s. An [allow] "
                        "entry re-includes it in every future run (it is still "
                        "content-scanned). Add it to rules.conf?" % rule):
                    self.status_lbl.set_text("cancelled")
                    return
                if path not in self.rc.allow:
                    self.rc.allow.append(path)
                self.status_lbl.set_text("added [allow] %s (was: %s)" % (path, rule))
                self._refresh_lists()
            else:
                info_dialog(self, "Refused",
                            "The backend will not let [allow] cover this path: "
                            "%s. %s" % (row.override or row.rule, note),
                            Gtk.MessageType.WARNING)
                self.status_lbl.set_text("refused: %s" % (row.override or row.rule))

        run_backend_async(argv, done)

    def _on_add_ack(self, _btn: Gtk.Button) -> None:
        summary = self.rice.summary
        block = summary.block("scan hits") if summary else None
        items = list(block.items) if block else []
        if not items:
            info_dialog(self, "Nothing to acknowledge",
                        "The current dry-run reported no content-scan hits.")
            return
        picked = choose_from_list(
            self, "Pick the scan hit to acknowledge", items,
            hint="only heuristic rules can be acknowledged")
        if picked is None:
            return
        path, rule = picked
        if not adapter.ack_is_allowed(rule):
            info_dialog(
                self, "Cannot be acknowledged",
                "The scan rule %s is token-shaped / key material: it can "
                "NEVER be acknowledged, not via the GUI, not via rules.conf. "
                "Rotate or remove the secret instead." % rule,
                Gtk.MessageType.WARNING)
            return
        if not confirm_dialog(
                self, "Acknowledge the %s hit on %s?" % (rule, path),
                "Matched rule: %s (heuristic - it over-matches innocuous "
                "content). Acknowledging KEEPS this file in every future "
                "backup after your eyes-on review; it is still content-"
                "scanned, and token-shaped rules stay refused. Add it to "
                "rules.conf?" % rule):
            return
        if path not in self.rc.ack_scan:
            self.rc.ack_scan.append(path)
        self.status_lbl.set_text("added [ack-scan] %s (rule: %s)" % (path, rule))
        self._refresh_lists()

    # -- save / reload -----------------------------------------------------------

    def _collect(self) -> Optional[adapter.RulesConf]:
        rc = adapter.RulesConf()
        rc.include_files = list(self.rc.include_files)
        rc.include_dirs = list(self.rc.include_dirs)
        rc.allow = list(self.rc.allow)
        rc.ack_scan = list(self.rc.ack_scan)
        checks = getattr(self, "_default_checks", {})
        skipped = [v for v, cb in checks.items() if not cb.get_active()]
        for v in getattr(self, "_extra_skip", []):
            if v not in skipped:
                skipped.append(v)
        rc.skip_dirs = skipped
        cap = self._cap_entry.get_text().strip()
        budget = self._budget_entry.get_text().strip()
        if cap and adapter.parse_size_text(cap) is None:
            info_dialog(self, "Invalid file cap",
                        "'%s' is not a size. Use plain bytes or N/NK/NM/NG."
                        % cap, Gtk.MessageType.WARNING)
            return None
        if budget and adapter.parse_size_text(budget) is None:
            info_dialog(self, "Invalid total budget",
                        "'%s' is not a size. Use plain bytes or N/NK/NM/NG."
                        % budget, Gtk.MessageType.WARNING)
            return None
        rc.file_cap = cap
        rc.total_budget = budget
        return rc

    def _on_save(self, _btn: Gtk.Button) -> None:
        rc = self._collect()
        if rc is None:
            return
        try:
            adapter.write_rules(self.rules_path, rc)
        except OSError as e:
            info_dialog(self, "Could not save", str(e), Gtk.MessageType.ERROR)
            return
        self.rc = rc
        self.status_lbl.set_text("saved to %s - every future run reads it"
                                 % self.rules_path)
        self._refresh_lists()

    def _on_save_rerun(self, _btn: Gtk.Button) -> None:
        rc = self._collect()
        if rc is None:
            return
        try:
            adapter.write_rules(self.rules_path, rc)
        except OSError as e:
            info_dialog(self, "Could not save", str(e), Gtk.MessageType.ERROR)
            return
        self.rc = rc
        self.destroy()
        if self.on_saved is not None:
            try:
                self.on_saved()
            except Exception:
                pass

    def _on_reload(self, _btn: Gtk.Button) -> None:
        self.rc = adapter.read_rules(self.rules_path)
        self._cap_entry.set_text(self.rc.file_cap)
        self._budget_entry.set_text(self.rc.total_budget)
        self.status_lbl.set_text("reloaded from %s" % self.rules_path)
        self._refresh_lists()
        self._load_show_rules()

    def _on_close(self, _win) -> bool:
        return False


class ResultWindow(Gtk.ApplicationWindow):

    def __init__(self, app: "RiceGuiApp", kind: str, log_text: str,
                 export_path: Optional[str] = None):
        super().__init__(application=app,
                         title="Backup pushed" if kind == "push"
                         else "Archive exported")
        self.rice = app
        self.log_text = log_text
        parsed = adapter.parse_result(log_text)
        commit = parsed[1] if parsed else "?"
        target = parsed[2] if parsed else ""

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        outer.set_margin_top(16)
        outer.set_margin_bottom(16)
        outer.set_margin_start(18)
        outer.set_margin_end(18)

        head = ("<b><span size=\"14000\">%s</span></b>" %
                ("Backup pushed" if kind == "push" else "Offline archive exported"))
        outer.append(Gtk.Label(label=head, use_markup=True))

        sel_n, sel_b = app.last_selection_stats()
        if kind == "push":
            lines = [
                "commit: %s" % commit,
                "repository: %s" % target,
                "backup size: %d file(s), %s" % (sel_n, adapter.human_size(sel_b)),
                "",
                "Exclusion reports live in the repository under",
                "reports/EXCLUDED.md and reports/SKIPPED.md.",
            ]
        else:
            lines = [
                "commit: %s" % commit,
                "archive: %s" % (export_path or target),
                "backup size: %d file(s), %s" % (sel_n, adapter.human_size(sel_b)),
                "",
                "Restore offline:",
                "    tar -xzf <archive>",
                "    bin/rice-restore.sh --from file://<extracted-dir>",
                "(dry-run by default; section by section)",
            ]
        outer.append(Gtk.Label(label="\n".join(lines), halign=Gtk.Align.START,
                               wrap=True))

        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        btns.set_halign(Gtk.Align.END)
        log_btn = Gtk.Button(label="_View log", use_underline=True)
        log_btn.connect("clicked", self._on_view_log)
        copy_btn = Gtk.Button(label="Copy _log", use_underline=True)
        copy_btn.connect("clicked", lambda b: copy_to_clipboard(b, self.log_text))
        btns.append(log_btn)
        btns.append(copy_btn)
        if kind == "push" and target:
            open_btn = Gtk.Button(label="_Open repository", use_underline=True)
            open_btn.connect("clicked", lambda b: open_uri(self, target))
            btns.append(open_btn)
        elif kind == "export" and (export_path or target):
            p = export_path or target
            open_btn = Gtk.Button(label="_Open folder", use_underline=True)
            open_btn.connect("clicked", lambda b: open_uri(
                self, os.path.dirname(p) or "."))
            btns.append(open_btn)
        close = Gtk.Button(label="_Close", use_underline=True)
        close.get_style_context().add_class("suggested-action")
        close.connect("clicked", lambda b: self.destroy())
        btns.append(close)
        outer.append(btns)

        self.set_child(outer)
        self.present()

    def _on_view_log(self, _btn: Gtk.Button) -> None:
        dlg = Gtk.Dialog(title="Run log (redacted)", transient_for=self, modal=True)
        dlg.set_default_size(760, 520)
        view = Gtk.TextView()
        buf = Gtk.TextBuffer()
        buf.insert(buf.get_end_iter(), self.log_text)
        view.set_buffer(buf)
        view.set_editable(False)
        view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        sc = Gtk.ScrolledWindow()
        sc.set_child(view)
        sc.set_vexpand(True)
        dlg.get_content_area().append(sc)
        dlg.add_button("_Close", Gtk.ResponseType.CLOSE)
        dlg.connect("response", lambda d, r: d.destroy())
        dlg.show()


# --------------------------------------------------------------------------
# application
# --------------------------------------------------------------------------

class RiceGuiApp(Gtk.Application):

    def __init__(self, toolroot: Path, version_warning: str = "") -> None:
        super().__init__(application_id="org.ricebackup.gui")
        self.toolroot = Path(toolroot)
        self.version_warning = version_warning
        self.conf_dir = guiconf.app_dir()
        self.conf = guiconf.GuiConf(base=self.conf_dir).load()
        self.selection_store = guiconf.SelectionStore(base=self.conf_dir)
        self.selection_store.load()
        self.pat: Optional[str] = None    # PAT in memory only (D25)
        self.repo = self.conf.get("repo", "") or ""
        self.home = self.conf.get("home", "") or os.path.expanduser("~")
        self.offline_mode = bool(self.conf.get("offline_last", False))
        self.include_system = bool(self.conf.get("include_system", False))
        self.follow_symlinks = bool(self.conf.get("follow_symlinks", True))
        self.summary = None
        self.entries: list = []
        self.windows: dict = {}
        self.rules_path = adapter.rules_default_path()   # R5 rules.conf
        self.show_rules: Optional[adapter.ShowRules] = None  # --show-rules cache
        self._pending_export_path: Optional[str] = None
        self.connect("shutdown", self._on_shutdown)

    # -- window bookkeeping ---------------------------------------------------

    def register_window(self, key: str, win: Gtk.Window) -> None:
        self.windows[key] = win

    def backend_script(self) -> Path:
        return self.toolroot / "bin" / "rice-backup.sh"

    def load_show_rules(self) -> None:
        """Fire-and-forget --show-rules (offline): warms the cache the
        explain view uses to gate include-root stanzas on the deny dirs."""
        if self.show_rules is not None:
            return
        argv = adapter.build_command(self.backend_script(), home=self.home,
                                     show_rules=True)

        def _done(rc: int, text: str) -> None:
            sr = adapter.parse_show_rules(adapter.redact(text, self.pat))
            if sr.parsed_ok:
                self.show_rules = sr

        run_backend_async(argv, _done)

    def save_conf(self) -> None:
        try:
            self.conf.save()
        except Exception:
            pass

    def save_geometry(self) -> None:
        for key in ("review", "setup"):
            win = self.windows.get(key)
            if win is not None:
                try:
                    self.conf["window_width"] = win.get_width()
                    self.conf["window_height"] = win.get_height()
                    return
                except Exception:
                    pass

    def last_selection_stats(self) -> Tuple[int, int]:
        review = self.windows.get("review")
        if review is not None and hasattr(review, "_selected_stats"):
            try:
                return review._selected_stats()
            except Exception:
                pass
        entries = self.entries or []
        return len(entries), sum(e.size for e in entries)

    # -- lifecycle ---------------------------------------------------------------

    def do_activate(self) -> None:  # noqa: N802
        apply_mono_style()
        stale = find_stale_staging()
        if stale:
            self._offer_stale_cleanup(stale)
        setup = self.windows.get("setup")
        if setup is not None:
            setup.present()
            return
        self.register_window("setup", SetupWindow(self))

    def _offer_stale_cleanup(self, stale: List[str]) -> None:
        loop = GLib.MainLoop()
        dlg = Gtk.MessageDialog(
            modal=True, message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.YES_NO,
            text="Leftover staging directories found",
            secondary_text="%d staging directory(ies) from cancelled runs remain "
                           "in %s. They are 0700 and harmless, but can be cleaned "
                           "up now. Delete them?"
                           % (len(stale), adapter.get_temp_dir()))

        def _resp(d, r):
            if r == Gtk.ResponseType.YES:
                for p in stale:
                    try:
                        shutil.rmtree(p)
                    except OSError:
                        pass
            d.destroy()
            loop.quit()

        dlg.connect("response", _resp)
        dlg.show()
        loop.run()

    def _on_shutdown(self, *_a) -> None:
        self.pat = None                    # wipe the in-memory PAT (D25)
        self.save_conf()


def main(argv: Optional[Sequence[str]] = None,
         toolroot: Optional[Path | str] = None) -> int:
    root = Path(toolroot) if toolroot else adapter.default_toolroot()
    warning = ""
    if not adapter.backend_new_enough(root):
        warning = ("backend %s found, %s needed: selection (--exclude-from), "
                   "archive export (--export), the candidate list "
                   "(--list-files), the rules editor (--show-rules) and the "
                   "explain view (--explain) require rice-backup %s or newer"
                   % (adapter.backend_version(root) or "?",
                      adapter.MIN_BACKEND_VERSION, adapter.MIN_BACKEND_VERSION))
        print("[rice-gui] WARNING: %s" % warning, file=sys.stderr)
    app = RiceGuiApp(toolroot=root, version_warning=warning)
    return app.run(list(argv) if argv else [])

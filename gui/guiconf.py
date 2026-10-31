"""Session persistence for the rice-backup GUI (decision D34).

Two files under ~/.config/rice-backup/, both created with strict modes and
both safe for the backup itself to collect (they contain nothing
credential-shaped, rule D27):

  gui.conf       configparser: repo, home, include_system, window geometry,
                 export dir, UI preferences
  selection.txt  the tick/skip state: the SKIPPED (unchecked) paths in the
                 exact --exclude-from format, passed to the backend verbatim

A custom base directory can be injected for tests.
"""

from __future__ import annotations

import configparser
import os
from pathlib import Path
from typing import Iterable, Optional, Set

APP_DIR_NAME = "rice-backup"
CONF_FILE_NAME = "gui.conf"
SELECTION_FILE_NAME = "selection.txt"

SELECTION_HEADER = (
    "# rice-backup GUI selection - the SKIPPED (unticked) paths.\n"
    "# Format of --exclude-from: one home-relative path per line; a directory\n"
    "# entry skips its whole subtree; purely subtractive (never overrides the\n"
    "# deny list or the content scan). Edited by the GUI; safe to edit by hand.\n"
)


def app_dir(base: Optional[Path | str] = None) -> Path:
    if base is not None:
        return Path(base)
    xdg = os.environ.get("XDG_CONFIG_HOME")
    root = Path(xdg).expanduser() if xdg else Path.home() / ".config"
    return root / APP_DIR_NAME


def _ensure_dir(path: Path) -> None:
    os.makedirs(path, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def _write_private(path: Path, text: str) -> None:
    """Create/overwrite with mode 0600 (D27/D34), no world/group read."""
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    try:
        os.chmod(str(path), 0o600)
    except OSError:
        pass


# --------------------------------------------------------------------------
# gui.conf
# --------------------------------------------------------------------------

DEFAULTS = {
    "repo": "",
    "home": "",
    "include_system": False,
    "auth_mode": "auto",      # 'auto' | 'gh' | 'pat'
    "offline_last": False,    # last launch used offline export mode
    "window_width": 980,
    "window_height": 700,
    "export_dir": "",
}

_BOOL_KEYS = ("include_system",)
_INT_KEYS = ("window_width", "window_height")


class GuiConf:
    """~/.config/rice-backup/gui.conf loader/saver (configparser, 0600)."""

    def __init__(self, path: Optional[Path | str] = None,
                 base: Optional[Path | str] = None) -> None:
        self.path = Path(path) if path else app_dir(base) / CONF_FILE_NAME
        self.values: dict = dict(DEFAULTS)

    def load(self) -> dict:
        self.values = dict(DEFAULTS)
        if not self.path.exists():
            return self.values
        parser = configparser.ConfigParser()
        try:
            parser.read(self.path, encoding="utf-8")
        except (configparser.Error, OSError, UnicodeDecodeError):
            return self.values          # unreadable -> defaults, never crash
        if not parser.has_section("general"):
            return self.values
        for key in DEFAULTS:
            if not parser.has_option("general", key):
                continue
            raw = parser.get("general", key)
            if key in _BOOL_KEYS:
                self.values[key] = raw.lower() in ("1", "true", "yes", "on")
            elif key in _INT_KEYS:
                try:
                    self.values[key] = int(raw)
                except ValueError:
                    pass
            else:
                self.values[key] = raw
        return self.values

    def save(self) -> None:
        _ensure_dir(self.path.parent)
        parser = configparser.ConfigParser()
        parser.add_section("general")
        for key, val in self.values.items():
            if isinstance(val, bool):
                parser.set("general", key, "true" if val else "false")
            else:
                parser.set("general", key, str(val))
        _write_private(self.path, self._render(parser))

    @staticmethod
    def _render(parser: configparser.ConfigParser) -> str:
        import io
        buf = io.StringIO()
        parser.write(buf)
        text = buf.getvalue()
        return text if text.endswith("\n") else text + "\n"


# --------------------------------------------------------------------------
# selection.txt
# --------------------------------------------------------------------------

def parse_selection(text: str) -> Set[str]:
    """Mirror of the backend's --exclude-from reader: strip '#' comments,
    trim whitespace, drop empty lines."""
    out: Set[str] = set()
    for line in text.splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            out.add(entry)
    return out


def serialize_selection(paths: Iterable[str]) -> str:
    lines = [SELECTION_HEADER]
    for p in sorted(set(paths)):
        lines.append(p)
    return "\n".join(lines) + "\n"


class SelectionStore:
    """The tick/skip session state: the set of SKIPPED home-relative paths."""

    def __init__(self, path: Optional[Path | str] = None,
                 base: Optional[Path | str] = None) -> None:
        self.path = Path(path) if path else app_dir(base) / SELECTION_FILE_NAME
        self.skipped: Set[str] = set()

    def load(self) -> Set[str]:
        self.skipped = set()
        try:
            text = self.path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return self.skipped
        self.skipped = parse_selection(text)
        return self.skipped

    def save(self, paths: Optional[Iterable[str]] = None) -> None:
        if paths is not None:
            self.skipped = set(paths)
        _ensure_dir(self.path.parent)
        _write_private(self.path, serialize_selection(self.skipped))

    def is_empty_file(self) -> bool:
        try:
            return not self.skipped and parse_selection(
                self.path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError):
            return True

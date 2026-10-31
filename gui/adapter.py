"""Display-free adapter between the rice-backup GUI and the bash backend.

Everything the GUI knows about the backend lives here (GUI-PLAN.md section 5,
plus the session-7 additions D32/D33):

  parse_dry_run()   dry-run summary text  -> DryRunSummary
  parse_file_list() --list-files output   -> [FileEntry]
  build_command()   GUI state             -> backend argv
  Runner            Popen + reader threads -> queue of (tag, chunk) events
  LineAssembler     chunk -> complete lines (+ partials: backend prompts are
                    printed WITHOUT a trailing newline and must be caught
                    mid-line, see detect_prompt)
  compress_skips()  unchecked rows -> minimal --exclude-from entry set
  redact()          on-screen token redaction (rule D25)

NO gtk imports in this module: it stays importable and unit-testable headless
(C5/D24). gui_app.py owns all widgets.

Backend contract: rice-backup >= 0.2.0 (needs --exclude-from / --export /
--list-files). backend_version() parses the version for the startup check.
"""

from __future__ import annotations

import os
import queue
import re
import subprocess
import tempfile
import threading
from bisect import bisect_left, bisect_right
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Set, Tuple

# --------------------------------------------------------------------------
# version / toolroot helpers
# --------------------------------------------------------------------------

MIN_BACKEND_VERSION = "0.2.0"


def default_toolroot() -> Path:
    """Directory containing bin/ lib/ scripts/ (parent of this gui/ dir)."""
    return Path(__file__).resolve().parent.parent


def backend_version(toolroot: Path | str) -> str:
    """RICE_VERSION string from lib/common.sh ('' when unreadable)."""
    try:
        text = (Path(toolroot) / "lib" / "common.sh").read_text(encoding="utf-8")
    except OSError:
        return ""
    m = re.search(r'RICE_VERSION="([^"]+)"', text)
    return m.group(1) if m else ""


def version_tuple(v: str) -> Tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", v)[:3])


def backend_new_enough(toolroot: Path | str) -> bool:
    return version_tuple(backend_version(toolroot)) >= version_tuple(MIN_BACKEND_VERSION)


# --------------------------------------------------------------------------
# size parsing / formatting
# --------------------------------------------------------------------------

_UNITS = {"B": 1, "KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3}


def size_to_bytes(num: str, unit: str) -> int:
    return int(float(num) * _UNITS.get(unit, 1))


def human_size(n: int) -> str:
    for unit, mul in (("GiB", _UNITS["GiB"]), ("MiB", _UNITS["MiB"]), ("KiB", _UNITS["KiB"])):
        if n >= mul:
            return "%.1f %s" % (n / mul, unit)
    return "%d B" % n


# --------------------------------------------------------------------------
# dry-run summary parsing (anchors: GUI-PLAN 5.4 + 'user excluded' block)
# --------------------------------------------------------------------------

@dataclass
class Section:
    name: str
    files: int
    size_bytes: int = 0


@dataclass
class ExcludedBlock:
    label: str          # 'hard deny list' | 'scan hits' | 'user excluded' | ...
    count: int          # count as printed in the header line
    items: List[Tuple[str, str]] = field(default_factory=list)  # (path, note)

    @property
    def truncated(self) -> bool:
        return len(self.items) < self.count


@dataclass
class DryRunSummary:
    home: str = ""
    distro: str = ""
    target: str = ""
    private: str = "unknown"
    auth_mode: str = ""
    sections: List[Section] = field(default_factory=list)
    total_files: int = 0
    total_bytes: int = 0
    largest: List[Tuple[str, int]] = field(default_factory=list)  # (path, bytes)
    excluded: List[ExcludedBlock] = field(default_factory=list)
    over_budget: bool = False
    export_mode: bool = False
    parsed_ok: bool = False
    raw: str = ""

    def block(self, label: str) -> Optional[ExcludedBlock]:
        for b in self.excluded:
            if b.label == label:
                return b
        return None


SUMMARY_HEAD = "=== rice-backup dry-run summary ==="
HOME_RE = re.compile(r"^home\s*:\s*(.+)$")
DISTRO_RE = re.compile(r"^distro\s*:\s*(.+)$")
TARGET_RE = re.compile(r"^target\s*:\s*(.+?)\s*\(private:\s*(yes|no|unknown)\)")
TARGET_EXPORT_RE = re.compile(r"^target\s*:\s*offline archive\s+(.+?)\s*\(no GitHub access\)")
AUTH_RE = re.compile(r"^auth\s*:\s*(.+)$")
SECTION_RE = re.compile(
    r"^  (\S.*?)\s*:\s+(\d+) file\(s\)(?:,\s*([0-9.]+)\s*(B|KiB|MiB|GiB))?\s*$"
)
LARGEST_HEAD = "largest candidates (top 15 by size):"
LARGEST_RE = re.compile(r"^\s+([0-9.]+)\s*(B|KiB|MiB|GiB)\s{2}(.+)$")
EXCLUDED_HEAD = "excluded (names only):"
EXCL_BLOCK_RE = re.compile(
    r"^  (hard deny list|scan hits|user excluded|oversized \(>50M\)|caches/junk)\s*:\s*(\d+) item\(s\)\s*$"
)
EXCL_ITEM_RULE_RE = re.compile(r"^ {4}- (.+?) \[([^\]]+)\]$")
EXCL_ITEM_SIZE_RE = re.compile(r"^ {4}- (.+?) \(([0-9.]+\s*(?:B|KiB|MiB|GiB))\)$")
EXCL_ITEM_PLAIN_RE = re.compile(r"^ {4}- (.+)$")
OVER_BUDGET_MARK = "a real run needs --allow-oversize"


def parse_dry_run(text: str) -> DryRunSummary:
    """Parse a (combined stdout+stderr) dry-run log. Never raises; a parse
    failure is the visible state parsed_ok=False with raw kept for the
    fallback view (GUI-PLAN 5.4)."""
    s = DryRunSummary(raw=text)
    if SUMMARY_HEAD not in text:
        return s
    s.parsed_ok = True
    s.over_budget = OVER_BUDGET_MARK in text

    in_largest = False
    current_block: Optional[ExcludedBlock] = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == LARGEST_HEAD:
            in_largest, current_block = True, None
            continue
        if stripped == EXCLUDED_HEAD:
            in_largest, current_block = False, None
            continue
        if in_largest:
            m = LARGEST_RE.match(line)
            if m:
                s.largest.append((m.group(3), size_to_bytes(m.group(1), m.group(2))))
                continue
            if not stripped:
                in_largest = False
                continue
        m = EXCL_BLOCK_RE.match(line)
        if m:
            current_block = ExcludedBlock(label=m.group(1), count=int(m.group(2)))
            s.excluded.append(current_block)
            continue
        if current_block is not None:
            m = EXCL_ITEM_RULE_RE.match(line)
            if m:
                current_block.items.append((m.group(1), m.group(2)))
                continue
            m = EXCL_ITEM_SIZE_RE.match(line)
            if m:
                current_block.items.append((m.group(1), m.group(2)))
                continue
            m = EXCL_ITEM_PLAIN_RE.match(line)
            if m:
                current_block.items.append((m.group(1), ""))
                continue
        m = TARGET_EXPORT_RE.match(line)
        if m:
            s.export_mode = True
            s.target = m.group(1)
            continue
        m = TARGET_RE.match(line)
        if m:
            s.target, s.private = m.group(1), m.group(2)
            continue
        m = AUTH_RE.match(line)
        if m:
            s.auth_mode = m.group(1).strip()
            if s.auth_mode.startswith("none (offline export)"):
                s.export_mode = True
            continue
        m = HOME_RE.match(line)
        if m:
            s.home = m.group(1).strip()
            continue
        m = DISTRO_RE.match(line)
        if m:
            s.distro = m.group(1).strip()
            continue
        m = SECTION_RE.match(line)
        if m:
            name, files, num, unit = m.group(1), int(m.group(2)), m.group(3), m.group(4)
            size = size_to_bytes(num, unit) if num else 0
            if name == "TOTAL":
                s.total_files, s.total_bytes = files, size
            else:
                s.sections.append(Section(name=name, files=files, size_bytes=size))
            continue
    return s


# --------------------------------------------------------------------------
# --list-files parsing (D32 companion)
# --------------------------------------------------------------------------

@dataclass
class FileEntry:
    rel: str
    size: int


FILE_LINE_RE = re.compile(r"^([^\t\n]+)\t([0-9]+)$")


def parse_file_list(text: str) -> List[FileEntry]:
    """One 'rel<TAB>bytes' row per candidate; rice_info lines on the same
    stream simply do not match and are skipped."""
    out: List[FileEntry] = []
    for line in text.splitlines():
        m = FILE_LINE_RE.match(line)
        if m:
            out.append(FileEntry(rel=m.group(1), size=int(m.group(2))))
    return out


def group_top(rel: str) -> str:
    """Top-level group used by the section checklist: the first path
    component, or 'dotfiles' for bare files."""
    if "/" not in rel:
        return "dotfiles"
    return rel.split("/", 1)[0]


# --------------------------------------------------------------------------
# selection compression (what gets written to --exclude-from)
# --------------------------------------------------------------------------

def is_skipped(rel: str, skipped: Iterable[str]) -> bool:
    """True when rel itself or any ancestor directory is in `skipped`
    (mirrors rice_apply_user_excludes' ancestor walk)."""
    sk = set(skipped)
    p = rel
    while p:
        if p in sk:
            return True
        p = p.rsplit("/", 1)[0] if "/" in p else ""
    return False


def compress_skips(all_rels: Sequence[str], unchecked: Set[str]) -> Set[str]:
    """Turn a set of unchecked file rows into the minimal --exclude-from
    entry set: maximal fully-unchecked subtrees become single directory
    entries; the rest are individual file paths. Purely subtractive (D32)."""
    total = sorted(set(all_rels))
    if not unchecked:
        return set()
    total_set = set(total)
    unchecked = {r for r in unchecked if r in total_set}
    cand_dirs: Set[str] = set()
    for r in unchecked:
        parts = r.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            cand_dirs.add("/".join(parts[:i]))

    def members(d: str) -> List[str]:
        lo = bisect_left(total, d + "/")
        hi = bisect_right(total, d + "/\uffff")
        return total[lo:hi]

    full: Set[str] = set()
    for d in cand_dirs:
        mem = members(d)
        if mem and all(r in unchecked for r in mem):
            full.add(d)
    chosen = {d for d in full if not any(d != f and d.startswith(f + "/") for f in full)}
    covered: Set[str] = set()
    for d in chosen:
        covered.update(members(d))
    return set(chosen) | {r for r in unchecked if r not in covered}


# --------------------------------------------------------------------------
# command building (GUI-PLAN 5.1 + D32/D33 rows)
# --------------------------------------------------------------------------

REPO_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")


def valid_repo(s: str) -> bool:
    return bool(s) and bool(REPO_RE.match(s))


RESULT_PUSH_RE = re.compile(r"backup pushed: commit ([0-9a-fA-F]+) -> (\S+)")
RESULT_EXPORT_RE = re.compile(r"archive exported: commit ([0-9a-fA-F]+) -> (\S+)")


def parse_result(text: str) -> Optional[Tuple[str, str, str]]:
    """('push'|'export', commit, target) from the final success line, if any."""
    m = RESULT_EXPORT_RE.search(text)
    if m:
        return ("export", m.group(1), m.group(2))
    m = RESULT_PUSH_RE.search(text)
    if m:
        return ("push", m.group(1), m.group(2))
    return None


def build_command(
    script: Path | str,
    *,
    dry_run: bool = False,
    repo: Optional[str] = None,
    home: Optional[str] = None,
    include_system: bool = False,
    allow_oversize: bool = False,
    assume_yes: bool = False,
    exclude_from: Optional[Path | str] = None,
    export_path: Optional[Path | str] = None,
    list_files: bool = False,
) -> List[str]:
    args: List[str] = ["bash", str(script)]
    if list_files:
        args.append("--list-files")            # exits before auth/repo (offline)
    if dry_run:
        args.append("--dry-run")
    if assume_yes:
        args.append("--yes")
    if include_system:
        args.append("--include-system")
    if repo and not export_path and not list_files:
        args += ["--repo", repo]
    if home:
        args += ["--home", str(home)]
    if allow_oversize:
        args.append("--allow-oversize")
    if exclude_from:
        args += ["--exclude-from", str(exclude_from)]
    if export_path:
        args += ["--export", str(export_path)]
    return args


def child_env(pat: Optional[str], base: Optional[dict] = None) -> dict:
    """Environment for the backend child. The PAT exists ONLY here (D25):
    never in argv, never in a file, never in a URL."""
    env = dict(base if base is not None else os.environ)
    if pat:
        env["RICE_TOKEN"] = pat
    else:
        env.pop("RICE_TOKEN", None)
    return env


# --------------------------------------------------------------------------
# phase tracking (GUI-PLAN section 4)
# --------------------------------------------------------------------------

PHASE_ORDER = ("collect", "scan", "stage", "commit", "finish")
PHASE_LABELS = {
    "collect": "Collect",
    "scan": "Scan",
    "stage": "Stage",
    "commit": "Commit",
    "finish": "Push / Export",
}

_PHASE_RULES: Tuple[Tuple[str, Tuple[str, ...]], ...] = (
    ("collect", ("collecting candidates",)),
    ("scan", ("content-scanning",)),
    ("stage", ("staging into",)),
    ("commit", ("committing, scanning",)),
    ("finish", ("backup pushed", "archive exported")),
)


def phase_from_line(line: str) -> Optional[str]:
    for phase, needles in _PHASE_RULES:
        if any(n in line for n in needles):
            return phase
    return None


# --------------------------------------------------------------------------
# exit codes (GUI-PLAN 5.2)
# --------------------------------------------------------------------------

EXIT_MEANINGS = {
    0: ("Success", "Backup pushed (or dry-run complete)."),
    1: ("Aborted or invalid input", "The backend refused to continue. Check the log "
        "for the exact message (user abort, invalid repo name, repo could not be created)."),
    2: ("Secret detected (S4 gate)", "The content scanner found credential-shaped data "
        "and refused to continue. Nothing was pushed. Follow the SECURITY runbook in "
        "README.md, then rotate the involved credentials."),
    3: ("Stage / push failure", "Staging, the push or the archive export failed. Check "
        "the log tail; for a rejected push inspect the remote repository manually "
        "before retrying (rice-backup never force-pushes)."),
    4: ("Authentication failure", "The PAT was rejected or gh is not logged in. "
        "Re-enter the token and retry."),
    5: ("Over size budget", "The total exceeds the 1 GiB budget. Review the largest "
        "candidates, tick off bulk data, or enable the over-budget switch."),
}


def get_temp_dir() -> str:
    return tempfile.gettempdir()


def exit_meaning(rc: int) -> Tuple[str, str]:
    if rc < 0:
        return ("Cancelled", "The backend process was terminated by signal %d. A 0700 "
                "staging directory may remain in %s; the GUI offers cleanup at next "
                "startup." % (-rc, get_temp_dir()))
    return EXIT_MEANINGS.get(rc, ("Unknown exit code", "Exit code %d." % rc))


# --------------------------------------------------------------------------
# prompt relay (GUI-PLAN 5.3)
# --------------------------------------------------------------------------

@dataclass
class Prompt:
    kind: str          # 'public-repo' | 'repo' | 'confirm' | 'generic'
    message: str
    expected: str = "" # what must be typed exactly (public-repo guard)
    secret: bool = False


_PUBLIC_REPO_RE = re.compile(r"confirm the repository.*type exactly:\s*([A-Za-z0-9._/-]+)")
_REPO_PROMPT_RE = re.compile(r"Target GitHub repo \(OWNER/NAME\):\s*$")
_CONFIRM_RE = re.compile(r"\[y/N\]\s*$")


def detect_prompt(text: str) -> Optional[Prompt]:
    """A prompt is a stderr fragment that ends WITHOUT a newline. Checked
    against complete lines AND growing partials."""
    t = text.strip()
    if not t:
        return None
    m = _PUBLIC_REPO_RE.search(t)
    if m:
        return Prompt("public-repo", t, expected=m.group(1))
    if _REPO_PROMPT_RE.search(t):
        return Prompt("repo", t)
    if _CONFIRM_RE.search(t):
        return Prompt("confirm", t)
    if t.endswith(":") or t.endswith(": "):
        return Prompt("generic", t)
    return None


REDACTED = "\u25b6REDACTED\u25c0"


def redact(text: str, secret: str | None = None) -> str:
    """Replace every occurrence of the in-memory PAT value (D25)."""
    if secret:
        return text.replace(secret, REDACTED)
    return text


# --------------------------------------------------------------------------
# line assembly (prompt-safe)
# --------------------------------------------------------------------------

class LineAssembler:
    """Reassembles a decoded stream from raw chunks into complete lines,
    keeping the trailing partial available: backend prompts ('... (type
    exactly: OWNER/NAME) ') have NO trailing newline."""

    def __init__(self) -> None:
        self._buf = ""

    def feed(self, chunk: str) -> List[str]:
        self._buf += chunk
        if "\n" not in self._buf:
            return []
        *lines, self._buf = self._buf.split("\n")
        return [l for l in lines if l != ""]

    def partial(self) -> str:
        return self._buf

    def consume_partial(self) -> str:
        out, self._buf = self._buf, ""
        return out

    def flush(self) -> List[str]:
        out = self._buf.strip("\n")
        self._buf = ""
        return [out] if out else []


# --------------------------------------------------------------------------
# runner: Popen + reader threads, never blocks the UI thread
# --------------------------------------------------------------------------

class Runner:
    """One backend invocation. Reader threads push (tag, chunk) events into
    a queue; the UI drains it from its main loop. `tag` is 'out' or 'err'.

    Both streams are delivered as RAW CHUNKS (not lines): stderr prompts
    must be detectable mid-line, and the consumer uses one LineAssembler
    per stream anyway.
    """

    def __init__(self, argv: Sequence[str], cwd: Optional[str] = None,
                 env: Optional[dict] = None) -> None:
        self.argv = [str(a) for a in argv]
        self.cwd = cwd
        self.env = env
        self.events: "queue.Queue[Tuple[str, str]]" = queue.Queue()
        self.proc: Optional[subprocess.Popen] = None
        self.rc: Optional[int] = None
        self.cancelled = False
        self._threads: List[threading.Thread] = []

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> "Runner":
        self.proc = subprocess.Popen(
            self.argv,
            cwd=self.cwd,
            env=self.env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False,
        )
        for tag, stream in (("out", self.proc.stdout), ("err", self.proc.stderr)):
            t = threading.Thread(target=self._pump, args=(tag, stream), daemon=True)
            t.start()
            self._threads.append(t)
        return self

    def _pump(self, tag: str, stream) -> None:
        fd = stream.fileno()
        while True:
            try:
                chunk = os.read(fd, 4096)
            except (OSError, ValueError):
                break
            if not chunk:
                break
            self.events.put((tag, chunk.decode("utf-8", errors="replace")))
        try:
            os.close(fd)
        except OSError:
            pass

    # -- interaction -------------------------------------------------------

    def poll_events(self, timeout: float = 0.0) -> List[Tuple[str, str]]:
        out: List[Tuple[str, str]] = []
        try:
            out.append(self.events.get(timeout=timeout))
        except queue.Empty:
            return out
        while True:
            try:
                out.append(self.events.get_nowait())
            except queue.Empty:
                return out

    def write_line(self, text: str) -> bool:
        """Answer a relayed prompt. Returns False when stdin is gone."""
        if self.proc is None or self.proc.stdin is None:
            return False
        try:
            self.proc.stdin.write((text + "\n").encode("utf-8"))
            self.proc.stdin.flush()
            return True
        except (OSError, ValueError):
            return False

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def wait(self, timeout: Optional[float] = None) -> Optional[int]:
        if self.proc is None:
            return None
        self.rc = self.proc.wait(timeout=timeout)
        for t in self._threads:
            t.join(timeout=2.0)
        return self.rc

    def terminate(self) -> bool:
        """SIGTERM (cancel, pre-push only per GUI-PLAN rule 3)."""
        self.cancelled = True
        if self.alive():
            try:
                self.proc.terminate()
            except OSError:
                pass
        return True

    # -- test convenience --------------------------------------------------

    def collect_text(self, timeout: Optional[float] = None) -> Tuple[str, str]:
        """Blocking helper (tests / headless flows): (stdout, stderr) text."""
        rc = self.wait(timeout=timeout)
        outs: List[str] = []
        errs: List[str] = []
        deadline = 5.0
        while True:
            got = self.poll_events(timeout=0.2)
            for tag, chunk in got:
                (outs if tag == "out" else errs).append(chunk)
            if not got and not self.alive():
                # drain whatever the threads still have in flight
                got = self.poll_events(timeout=0.3)
                for tag, chunk in got:
                    (outs if tag == "out" else errs).append(chunk)
                if not self.alive():
                    break
            deadline -= 0.2
            if deadline <= 0:
                break
        return "".join(outs), "".join(errs)

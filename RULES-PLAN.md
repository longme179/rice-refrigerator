# RULES-PLAN — deep customization of what gets backed up (D38–D42)

Status: DECIDED 2026-11-01 (design round with the user; all six recommended
options chosen). This file is the canonical plan. Implementation milestones
R1–R5 land in that order, each with a green suite, an S4 gate, and an immediate
commit+push (D31 discipline).

## 1. Problem (user report)

The backup selection is policy-hard with no user control beyond REMOVING
candidates (`--exclude-from`, D32):

- L1 deny matching is NAME-based (`*.key`, `*history*`, `.env`, `*id_rsa*`, 55
  deny dirs) — over-broad by design, so innocent files get blocked, and there
  is no way to say "I checked this one, include it".
- L2 content-scan hits hard-block a file (`networks.py` on the user's machine)
  with no acknowledge path.
- Include roots are fixed: 18 top-level dotfiles + 17 walked directories. You
  cannot add `.Xresources`, `Dev/dotfiles`, or a custom dir, and you cannot
  drop a bulky default root (`.local/share/wallpapers`) from the walk.
- Size caps are hardcoded (50 MiB per file, 1 GiB total via env only).

## 2. Design principles

- P1 — the HARD CORE is enforced in code, never in documentation: no flag,
  file, or GUI action can make rice-backup stage it (list in §5).
- P2 — every decision stays attributed: each bucket entry carries its rule
  (`deny-dir:.ssh`, `scan:cred-assign`, `allow:<original rule>`); reports and
  `--explain` always name the layer AND the rule.
- P3 — one source of truth: `~/.config/rice-backup/rules.conf`, plain INI-ish
  text, 0600, portable, shared by CLI and GUI. CLI flags override the file;
  the file overrides built-ins. Nothing credential-shaped is ever stored in it
  (paths and numbers only, D27 spirit).
- P4 — layer order is unchanged and still total:
  hard core > soft deny (minus `[allow]`) > L2 scan (minus `[ack-scan]`,
  within its rails) > L3 cache > size caps > `--exclude-from` selection.
  Overrides can only RE-INCLUDE soft-denied or acked items; they can never
  weaken the hard core or the scan rails.
- P5 — diagnose before override: `--explain` ships FIRST (R1) so the user can
  see exactly which layer and rule claims a path, before any override exists.

## 3. D38 — rules.conf

Location `~/.config/rice-backup/rules.conf`; `--rules FILE` (and `RICE_RULES`
env) point elsewhere. Created with mode 0600 by whoever writes it first (tool
or GUI). Sections (unknown sections/keys are warned and ignored):

```ini
# rice-backup rules - applies to every run (see RULES-PLAN.md)
[include-file]      # extra TOP-LEVEL home files, considered like the defaults
.Xresources
.xinitrc

[include-dir]       # extra walked roots (home-relative)
Dev/dotfiles
.xmonad

[skip-dir]          # default roots to NOT walk anymore
.local/share/wallpapers

[allow]             # soft-deny overrides (home-relative; subtree allowed)
.config/theme-assets/legacy-history.txt

[ack-scan]          # content-scan acknowledgements (exact file paths only)
.config/mango/scripts/networks.py

[size]              # plain integers, bytes
file_cap = 52428800
total_budget = 1073741824
```

Rules of the file:

- entries are home-relative paths; `#` comments; blank lines ignored;
  absolute paths and `..` are REJECTED (warned, not fatal).
- unmatched `[allow]`/`[ack-scan]` entries warn (typo guard, same as
  `--exclude-from`); unmatched `[include-dir]`/`[include-file]` warn.
- precedence: CLI flag > rules.conf > built-in default. `--no-rules` skips the
  file entirely (debugging aid).
- GUI and CLI read/write the SAME file (GUI section §8).

## 4. D39 — include-root customization

- `[include-file]` (+ `--include-file F`, repeatable): extra top-level home
  files considered exactly like `RICE_HOME_FILES` (deny/scan/size still apply).
- `[include-dir]` (+ `--include-dir D`, repeatable): extra walked roots, joined
  into `RICE_HOME_DIRS` semantics — L1/L2/L3/size apply inside, and the D37
  symlink coverage/overlap logic sees them (they count as "covered" regions).
- `[skip-dir]` (+ `--skip-dir D`, repeatable): REMOVES a default root from the
  walk (the dir is not descended at all — unlike `--exclude-from`, which skips
  files after the walk). Skipping a non-default root warns.
- New roots must stay under `$HOME` (no absolute, no `..`); adding a
  hard-core dir as a root is refused with its rule name.
- `--show-rules` prints the merged root list with the source of each entry
  (`default` / `rules.conf` / `flag`).

## 5. D40 — allow-list (L1 override) and the hard core

Mechanics: after the walk produces `RICE_DENIED`, every entry is classified:

1. HARD CORE match → stays denied, reason `deny-hard:<rule>`; `[allow]` entries
   hitting it are REFUSED with a clear message naming the rule. Enforced in
   `rice_deny_rule_for` itself (hard rules checked first, always).
2. SOFT deny + `[allow]` match (self or subtree) → the item returns to the
   normal candidate path (L3 cache, size cap, L2 scan all still apply) and is
   recorded in `RICE_ALLOWED` → `reports/ALLOWED.md` + dry-run line
   `deny overridden : N item(s)`; each override warns during collection.
3. SOFT deny, no allow → today's behavior (`deny-dir:` / `deny-file:`).

Hard core (NEVER overridable) — credential/vault/account-shaped, BROAD per the
user's choice:

- key/secret stores: `.ssh .gnupg .gnome/keyrings .gnome2/keyrings
  .local/share/keyrings .local/share/kwalletd .password-store .config/gopass
  .local/share/gopass .pki .onepassword .config/1Password`
- cloud/infra CLIs: `.aws .config/gcloud .azure .kube .config/kube
  .config/helm .docker .config/gh`
- browser profiles (all engines): `.mozilla .config/mozilla
  .local/share/mozilla .librewolf .waterfox .zen .floorp .config/google-chrome
  .config/google-chrome-beta .config/google-chrome-unstable .config/chromium
  .config/chromium-beta .config/BraveSoftware .config/vivaldi .config/Opera
  .config/opera .config/Microsoft-edge .config/librewolf .config/waterfox
  .config/ungoogled-chromium .var/app`
- messengers/mail: `.thunderbird .config/evolution .local/share/evolution
  .local/share/TelegramDesktop .config/telegram-desktop .config/Signal
  .config/Element .config/discord .config/Keybase .config/Slack .config/zoomus
  .config/Zoom`
- key-material globs: `.netrc .netrc.gpg .git-credentials .pypirc .k5login
  .kdbx *.kdbx *.kdb *.key *.pem *.p12 *.pfx *id_rsa* *id_dsa* *id_ecdsa*
  *id_ed25519*`

Soft deny (overridable via `[allow]`) — privacy/hygiene/heuristic:

- histories: `.bash_history .zsh_history .sh_history .python_history
  .node_repl_history .mysql_history .psql_history .sqlite_history *history*
  .lesshst .viminfo .viminfo.tmp .wget-hsts`
- env/template files: `.env .env.* *.env` (L2 still scans their CONTENT)
- state: `*.tfstate *.tfstate.* .config/Code/User/globalStorage`

A symlink whose target is hard-core stays excluded (`deny-target:` path, D37);
a link to a soft-allowed target follows only if the target itself is allowed.

## 6. D41 — scan acknowledgement (L2 override with rails)

- `[ack-scan]` entries are EXACT home-relative file paths (no subtrees: an ack
  is a per-file, eyes-on decision).
- ACKABLE (heuristic rules that over-match innocuous content):
  `cred-assign`, `bearer-token`, `url-embedded-creds`, `aws-secret-label`.
- NEVER ACKABLE (token-shaped or key material — treated as real secrets,
  period): `gh-classic`, `gh-fine-grained`, `private-key`, `aws-access-key`,
  `google-api-key`, `slack-token`, `stripe-live-key`, `jwt`, and ALWAYS
  `exact` (the runtime PAT needle — the scanner already refuses to expect
  exact hits, so this rail holds end-to-end).
- Mechanics: `rice_scan_candidates` keeps acked soft-rule hits in
  `RICE_INCLUDE` and records them in `RICE_SCAN_ACKED` →
  `reports/ACKNOWLEDGED.md` (path + rule name, never values) + dry-run line
  `scan acknowledged : N item(s)`. Hard-rule hits on acked paths are refused
  with the rule named ("this really looks like a credential").
- Staging/push continuity: the run generates `meta/scan-acks.expect`
  (repo-relative `home/`-prefixed paths of acked files) and passes it to the
  S4 scan in `rice_stage_finish` via the scanner's existing `--expect`
  mechanism; the staging repo's pre-push hook is installed with the same
  expect file. Expect-listing NEVER applies to the `exact` rule (scanner
  guarantee), so the real-PAT needle can never be pushed via an ack.
- Acked files keep their scan rule recorded in EXCLUDED.md's acknowledged
  section too — the repo always documents what was acknowledged, by whom
  (host/user) and when.

## 7. D42 — size caps + diagnostics

- `--file-cap BYTES` and `[size] file_cap`: per-file cap, default 50 MiB;
  values above 100 MiB are REFUSED (GitHub hard limit — a push would fail).
- `--budget BYTES` and `[size] total_budget`: replaces the env-only knob;
  `RICE_TOTAL_MAX_BYTES` keeps working (env > flag > file > default, one
  documented exception to P3 precedence for back-compat).
- `--explain [PATH...]` — OFFLINE, read-only, exit 0, no auth/repo. Runs the
  normal collection + scan (with rules applied), then for each given path
  prints its verdict block; with no paths, dumps every bucket with reasons:

  ```
  .config/theme-assets/legacy-history.txt
      verdict  : excluded
      layer    : L1 deny
      rule     : deny-file:*history*
      override : soft rule - [allow] can re-include it
  ```

  Paths may be home-relative or absolute-under-home. A path found in no
  bucket reports WHY (outside the include roots → point at `--show-rules` /
  `[include-dir]`; nonexistent in home; directory/special). Output format is
  stable → the GUI (R5) and tests parse it.
- `--show-rules` — OFFLINE, no walk: prints the effective rule set — version,
  caps, follow settings, include files/dirs WITH source (default/rules/flag),
  skipped roots, deny dirs/globs each marked `hard`/`soft`, active allow/ack
  entries with source, /etc allowlist. The debugging answer to "why didn't my
  rules.conf apply".

## 8. GUI (milestone R5)

- New "Rules" tab reading/writing rules.conf: default-roots list with enable
  checkboxes (writes `[skip-dir]`), add-root/add-file entries, `[allow]`
  editor showing each entry's ORIGINAL deny rule, `[ack-scan]` editor gated
  behind a confirmation dialog that shows the matched rule and the rail
  policy (token-shaped rules show "cannot be acknowledged").
- Explain view: context action on any excluded row → runs `--explain PATH`,
  renders the verdict chain and offers the exact rules.conf stanza to copy.
- The dry-run summary's new lines (`deny overridden`, `scan acknowledged`)
  are formatted so the adapter's SECTION_RE cannot match them (same
  convention as the symlinks line, D37).
- Adapter gains `explain()` + rules-file helpers; headless unit tests extend
  the existing 50-case suite; widget work ships with a manual checklist
  addition in gui/README-GUI.md.

## 9. Milestones

| ID | Scope | Deliverables | Tests | Status |
|----|-------|--------------|-------|--------|
| R1 | diagnostics only, zero behavior change | `--explain`, `--show-rules`, reason strings verified | t26 | ✅ done (suite 402/0, pushed 6fd2d4f) |
| R2 | rules.conf + roots + sizes + `--rules/--no-rules`, flags, version 0.4.0 | D38+D39+D42 size part | t27 | ✅ done (suite 447/0, contract rig OK) |
| R3 | allow-list + hard core + ALLOWED.md | D40 | t28 | ✅ done (suite 475/0) |
| R4 | ack-scan + expect flow + hook + ACKNOWLEDGED.md | D41 | t29 | ✅ done (suite 516/0) |
| R5 | GUI Rules tab + explain view + docs + 0.4.0 tarball | §8 | adapter tests + checklist | pending |

Each milestone: suite green (old assertions unmodified where the feature
permits) → S4 tree+range scan → commit → push → journal updated.

## 10. Compatibility

- No rules.conf present → behavior byte-identical to 0.3.0 (all defaults,
  zero overrides). The 356 existing assertions are the regression proof.
- `--exclude-from` unchanged (still the LAST, purely subtractive layer).
- Dry-run anchor lines the GUI adapter depends on keep their format; new
  lines are additive only.
- Restore side: allowed/acked files are ordinary candidates; nothing changes
  for rice-restore (relink logic untouched).

## 11. New fixtures (tests/fixtures/home-clean additions)

- `.config/theme-assets/legacy-history.txt` — soft `*history*` deny hit
- `.config/innocent/api-notes.md` — content that trips `cred-assign`
- `.config/blocked/looks-like-a-token` — content that trips a HARD scan rule
- `tests/fixtures/rules/sample-rules.conf` — exercised by t27–t29
- t28 asserts the hard core REFUSALS (allow on `.ssh`, `*.pem`, browser dir);
  t29 asserts ack rails (token-shaped ack refused, exact needle never
  expected) and the expect-file flow through the hook simulation.

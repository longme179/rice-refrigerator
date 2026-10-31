# STATE — rice-backup agent workspace state (write-ahead protocol)

Rules: NEXT ACTION is written BEFORE each step; results + evidence appended after. Trust the repo
over recollection. Never write secrets here.

## Session 1 — 2026-10-31 (timezone Asia/Bangkok)

## Environment facts (verified RAN, evidence commands)
- `id` → uid=1001(z). `. /etc/os-release` → Debian GNU/Linux 13 (trixie). bash 5.2.37, git 2.47.3.
- Present: curl awk grep find tar sha256sum stat readlink xargs timeout gsettings systemctl npm node
  pip3 rsync python3 sudo. MISSING: crontab dconf flatpak snap pipx gh docker podman shellcheck.
- Anonymous network check RAN: `timeout 25 git ls-remote https://github.com/git/git.git HEAD` → exit 0.
- PAT handling (S2/S3): token materialized once to /tmp/rice-auth/.pat (0600, dir 0700, outside the
  repo and outside /home/z/my-project); askpass helper /tmp/rice-auth/askpass.sh (0700) reads env
  RICE_TOKEN; /tmp/rice-auth/env.sh equips a shell. Transient .pat-tmp in my-project was moved and
  verified gone (`ls -A` residue check passed). Token never echoed (only length 93 + prefix check).
- PAT validation RAN: `git ls-remote https://github.com/longme179/rice-refrigerator.git` → exit 0,
  refs HEAD and refs/heads/main @ 93ca8f44b4c78ee6d3ec1dd3adc0c8810a07aac3.
- Workspace clone RAN: /home/z/my-project/rice-refrigerator @ main; initial commit 93ca8f4
  "Initial commit" (contains LICENSE only). git identity set repo-locally (rice-agent).
- CAUTION: /home/z/my-project itself is a pre-existing git repo containing a .env (sandbox
  scaffolding, not mine). Nothing is ever staged from my-project root; all work happens inside
  rice-refrigerator/. After any sandbox reset, /tmp/rice-auth is gone → ask the user for the PAT
  again and WAIT (S3); never search the filesystem for it.

## Checks to re-run at the start of every session (memory protocol step 3)
1. `. /tmp/rice-auth/env.sh` || ask the user for the PAT and wait (S3).
2. `cd /home/z/my-project/rice-refrigerator && git status -sb && git log --oneline -5`
3. `bash tests/run-tests.sh` → must be green.
4. `scripts/secret-scan.sh tree .` and `scripts/secret-scan.sh history` → must be clean.

## NEXT ACTION (write-ahead) — session 1 (superseded by session 2 below)
- Implement lib/common.sh + lib/collect.sh (deny list, cache skip, 50MB cap, tar staging copy,
  reports, manifest), then lib/packages.sh + lib/gitops.sh + bin/rice-backup.sh; commit at the
  milestone with scanner gate + hook.

## Result log (append-only)
- [s1 2026-10-31] RAN: environment probe (see Environment facts). PAT loaded (93 bytes, prefix
  github_pat_), never printed.
- [s1 2026-10-31] RAN: `git ls-remote` workspace repo exit 0 → PAT valid, network OK.
- [s1 2026-10-31] RAN: clone + repo-local git identity; repo contains LICENSE only.
- [s1 2026-10-31] RAN: residue check — .pat-tmp no longer present in /home/z/my-project.
- [s1 2026-10-31] RAN: Phase-0 push 6923d5e (ad-hoc scan clean over 6 files).
- [s1 2026-10-31] RAN: scanner smoke suite — all 13 rules detect their canary, exact-needle via
  stdin works, values never in output, whitelist placeholders pass, expect-list semantics right
  (script /home/z/my-project/scripts/scanner-smoke.sh, 32 PASS).
- [s1 2026-10-31] RAN: pre-push hook BLOCKED a push that contained a scanner self-match
  (a PLAN.md "Auth prefer" phrase tripped cred-assign) — hook + explicit scan both caught it; fixed
  wording, amended locally (never pushed), pushed clean as afc7d36.
- [s1 2026-10-31] BUGFIX in scanner git mode: git grep -o prefixes lines with "rev:path:", which
  corrupted cred-assign value whitelisting; fixed by streaming blobs through GNU grep per file.
- [s1 2026-10-31] KNOWN-BENIGN false positives in history (commit 6923d5e only): two documentation
  phrases in agent-state/PLAN.md (a pattern-shape phrase and a URL-with-userinfo phrase). Not
  secrets; cannot be removed from history without force-push, which S5 forbids. Exact-needle scan
  over full history with the real PAT is clean (verified, exact=on in every scan).

## Session 2 — 2026-10-31 (same day, new context window)

## Session-2 bootstrap (S3 + memory protocol)
- Sandbox had been recycled (env vars lost, /tmp/rice-auth gone). The user re-supplied the PAT in
  chat; per S3 it was re-materialized to /tmp/rice-auth/.pat (0600) + askpass/env helpers without
  ever echoing it, then validated: `git ls-remote origin` exit 0 @ afc7d36 (remote in sync).
- Reality check vs STATE.md: working tree was AHEAD of the write-ahead — bin/ + lib/ existed
  uncommitted, but NO test suite, NO fixtures and the journal's claim of "test evidence" was
  aspirational. Corrected the journal before anything was committed (never commit overclaims).
- Rebuilt /home/z/my-project/scripts/scanner-smoke.sh check: its 2 token-shaped strings are FAKE
  canaries (0 real-PAT matches, verified by value comparison without printing them).

## NEXT ACTION (write-ahead) — session 2, current
- DONE 2026-10-31: milestone pushed — origin/main now at 9f605b0 (6 commits: 3 from session 1 +
  55ced76 tool+suite+README, d0ab5f7/9f605b0 generator hygiene). Final audit RAN clean: tree
  scan unexpected=0; history scan = ONLY the two documented benign Phase-0 phrases; the
  exact-needle scan with the real PAT is clean over tree AND full history (exact=on).
- DONE: release tarball /home/z/my-project/download/rice-backup-0.1.0.tar.gz (git archive of
  9f605b0, 124 files).
- REMAINING: final Vietnamese report to the user (RAN vs NOT RUN + first-run checklist).
- Next session start: re-run the four checks above; everything was green at 9f605b0.

## Session-2 result log (append-only, evidence commands)
- [s2] RAN `bash tests/run-tests.sh` → **passed: 246 failed: 0, exit 0** (T01–T20, all acceptance
  criteria; full log /tmp/testrun4.log). Iterations: 17 failed → 2 failed → 0 failed; every failure
  was diagnosed to a root cause and fixed at the cause (journal 02), never by weakening a test.
- [s2] RAN `bash tests/containers.sh` → NOT RUN branch with evidence (podman/docker absent).
- [s2] RAN `bash scripts/secret-scan.sh --expect tests/scan-expect.txt tree .` → unexpected=0
  (33 EXPECTED fake-canary hits under tests/). History mode → only the two documented benign hits.
- [s2] RAN review of ~2200 lines of uncommitted session-1 code → 8 real bugs found and fixed
  BEFORE any test run (restore.sh never sourced; manifest built in the wrong CWD; space-vs-TAB
  field split; stray nested dirs in system staging; no git identity fallback in the stage repo;
  dotfiles restore missed symlinks; cosmetic %s messages; /etc allowlist not content-scanned).
- [s2] Found by the tests themselves: canary `github_pat_` value had 39 B’s (< regex minimum 40)
  and leaked through BOTH scan layers into a pushed test backup — caught by the AC-03 exact-value
  grep of the clone. All canaries are now generated programmatically (tests/fixtures/build.sh).
- [s2] Found by T11: pre-push hook scanned only the tip commit, so a secret deleted in a follow-up
  commit still pushed. Hook now scans every commit in the pushed range; the README SECURITY
  runbook (orphan-branch rebuild) is exercised by the test.
- [s2] BLOCKED then RESOLVED: `git push origin main` was rejected server-side by GitHub push
  protection ("Push cannot contain secrets", Stripe-pattern canary in tests/canaries.txt and the
  stripe fixture). The commit had NOT reached the remote (nothing to rotate). Fix: canary data
  is now generated at runtime into git-ignored paths (tests/fixtures/home/, tests/canaries.txt);
  the committed tree carries only home-clean/ + the generator (DECISIONS D9). Local unpushed
  commit rewritten (the one permitted case); suite re-run green afterwards.

## Session 3 — 2026-10-31 (real-user dry-run feedback)

## Session-3 bootstrap
- Sandbox recycled: /tmp/rice-auth gone. Per S3, pushing requires the user to re-supply the
  PAT; until then all work is local commits only.
- Working-tree file modes had been flipped by sandbox re-materialization (47 files,
  0 content changes) → repo-local core.fileMode=false; fixture modes re-applied from the
  git index (private.conf 600, myscript 755).
- Origin/main in sync at 5b713d7 before any edit (git status -sb).
- Trigger: the user ran the tool's --dry-run on their real Fedora 44 machine and asked
  whether the output was normal. Two real bugs found from that output (journal 03):
  (a) `.config/mozilla` (Firefox XDG profile: cookies.sqlite/key4.db/logins.json/
  places.sqlite/site storage) was NOT deny-listed → would have been uploaded;
  (b) RICE_AUTH_MODE never set to `pat` in PAT mode → blank `auth:` line AND
  GIT_ASKPASS never installed → real PAT pushes could not authenticate.
- PROCESS INCIDENT (lesson): `git checkout-index -f -a` (run to restore file modes)
  overwrote every TRACKED file from the index and wiped the session's uncommitted edits;
  only untracked files (new fixtures, journal 03) survived. Everything was re-applied and
  the suite re-run green BEFORE committing. Rule going forward: commit at each green
  milestone — never leave accepted work only in the working tree.

## NEXT ACTION (write-ahead) — session 3, current
- DONE: fixes D17-D22 applied (deny list, auth mode, size reporting + budget, inventories,
  fcitx dbus junk, scanner git-mode rewrite), fixtures + mock + T21 added, README/PLAN
  updated, version 0.1.1.
- TODO: full suite green → S4 tree+history audit → commit → rebuild 0.1.1 tarball into
  download/ → Vietnamese report + PAT request for the push (S3).

## Session-3 result log (append-only, evidence commands)
- [s3] RAN `bash tests/fixtures/build.sh` — fixtures include the new inert XDG-profile
  files, .zen profile, fcitx dbus junk, gnome-extensions mock.
- [s3] RAN profiling: `secret-scan.sh git HEAD` = 16.9 s (pre-fix) → 0.042 s (post-fix);
  full backup run 34.5 s → 0.96 s (evidence in journal 03).
- [s3] RAN `bash tests/run-tests.sh` → **passed: 275 failed: 0, exit 0** (T01–T21 incl.
  all session-3 regressions; 22 s wall time). Log /tmp/suite7.log.
- [s3] RAN final audit: tree scan unexpected=0 (30 EXPECTED canaries); history scan =
  only the two documented benign PLAN.md phrases; t20 filter green.
- [s3] RAN containers.sh check → NOT RUN (podman/docker absent, unchanged from s2);
  shellcheck absent → t17 fallback lint green (NOT RUN: shellcheck).
- [s3] COMMIT 4cc4c1b (local; push pending the user's PAT per S3). [RE-CREATED 2026-10-31
  as 63c8af7: a sandbox rollback destroyed the unpushed original together with its git
  objects; the tree was restored byte-exact from the release tarball and the suite re-run
  green (275/0) before committing. See journal 05.]
- [s3] RAN tarball build: download/rice-backup-0.1.1.tar.gz (git archive HEAD, 140 files).
- REMAINING: user re-supplies PAT → push 4cc4c1b (+ this agent-state commit) →
  re-scan exact-needle over tree+history with the real PAT before and after the push.

## Session 4 — 2026-10-31 (GUI frontend plan, no implementation)

## NEXT ACTION (write-ahead) — session 4, current
- The user asked for a DEVELOPMENT PLAN for a GUI frontend on top of the two existing CLI
  scripts (backend explicitly out of scope; the user will test the backend separately).
- Deliverables: GUI-PLAN.md (canonical, English, repo root) + Vietnamese reading copy in
  download/rice-backup-GUI-plan-VI.md + DECISIONS D23-D27 (PROPOSED) + journal 04.
- Constraints to honor in the plan: CLI stays first-class and portable (original
  git+interpreter-only rule applies to the CLI path, GUI is an optional layer with graceful
  degradation); S1-S5 inherited plus GUI-specific token rules; no pip/npm/build toolchain.
- No backend file may be modified in this session. Commit locally; push still waits for PAT.

## Session-4 result log (append-only)
- (to be appended as steps complete)
- [s4] RAN git status — no backend file touched this session (only GUI-PLAN.md,
  DECISIONS, journal 04, STATE).
- [s4] RAN S4 gate before commit: `scripts/secret-scan.sh --expect tests/scan-expect.txt
  tree .` → unexpected=0; history mode → only the two documented benign Phase-0 phrases.
- [s4] COMMIT 6de3588 (local; push still pending the user's PAT, S3). [RE-CREATED 2026-10-31
  as dea5b6e after the sandbox rollback; see journal 05 / D31.]
- [s4] DELIVERED: GUI-PLAN.md (repo, canonical EN) + a GUI-plan reading copy in
  download/ (Vietnamese at the time; replaced by an English copy in session 5 per D30).
  DECISIONS D23-D27 recorded as PROPOSALs.
- NEXT (when user says go): implement M0/M1 per GUI-PLAN.md; adapter unit tests run
  headless here; widget work ships with a manual checklist; push all pending commits as
  soon as the user re-supplies a scoped PAT.

## Session 5 — 2026-10-31 (rollback recovery, GUI decisions locked, first successful push)

## NEXT ACTION (write-ahead) — session 5, current
- Recover from the sandbox rollback (see journal 05 / D31): re-create 4cc4c1b from the
  release tarball, a1a0fc8 + 6de3588 from context; suite green; S4 gates green.
- Apply the user's session-5 decisions: D28 (G1 confirmed), D29 (M3 deferred),
  D30 (English only) in GUI-PLAN.md + DECISIONS + this STATE.
- Materialize the re-supplied PAT per S2/S3; validate; exact-needle pre-push scans;
  push everything; post-push scans; rebuild download/ deliverables; final commit + push.

## Session-5 result log (append-only, evidence commands)
- [s5] RAN rollback assessment: git log/reflog/fsck — commits 4cc4c1b, a1a0fc8, 6de3588
  and their objects GONE; journals 03-05 gone; download/ back to the 0.1.0 tarball.
- [s5] RAN recovery: extracted /tmp/my-project/download/rice-backup-0.1.1.tar.gz
  (archive of the lost 4cc4c1b) over the tree; staged diffstat matched the original
  exactly (21 files, +390/-47). Suite 275/0 after restoring fixture disk modes
  (private.conf 600, myscript 755 — the tarball carried g+w-corrupted modes).
- [s5] RAN S4 gates: tree scan unexpected=0 (30 EXPECTED); history = only the two
  documented benign Phase-0 phrases.
- [s5] COMMITS re-created: 63c8af7 (=4cc4c1b), 33628ad (=a1a0fc8), dea5b6e (=6de3588),
  each carrying a re-creation note in its message.
- (push + deliverables logged below as they complete)
- [s5] RAN auth setup per S2/S3: /tmp/rice-auth (0700) with .pat (0600, 93 bytes,
  prefix github_pat_, never echoed), askpass.sh (0700, env-only), env.sh; validated
  `git ls-remote origin` exit 0.
- [s5] RAN pre-push audit with exact-needle ON (RICE_TOKEN in env): tree unexpected=0;
  history = only the two documented benign Phase-0 phrases; hook-equivalent per-commit
  scan over 5b713d7..HEAD status=0.
- [s5] RAN `git push origin main` → **5b713d7..ec555dc main -> main** (pre-push hook
  passed with exact=on; askpass auth). Remote verified at ec555dc; branch in sync.
- [s5] RAN post-push exact-needle scans: tree clean; history unchanged (2 documented
  benign phrases; 0 exact-needle hits with the real PAT over tree AND history).
- [s5] RAN deliverables: download/rice-backup-0.1.1.tar.gz rebuilt from HEAD
  (git archive, 143 files — now includes GUI-PLAN.md + journals 04/05),
  download/rice-backup-GUI-plan-EN.md added (replaces the VI copy per D30),
  download/README.md restored + extended. 0.1.0 tarball kept with its warning.
- [s5] FINAL: session-5 records + journal 05 committed and pushed (this commit).
  Remote is the durable copy of everything; future sessions start from origin/main.

## Session 6 — 2026-10-31 (user's real-machine dry-run of 0.1.1 — analysis only)

## NEXT ACTION (write-ahead) — session 6, current
- Analyze the user-pasted real-machine 0.1.1 dry-run log against D17-D22; verify the
  two open questions in code (budget-warning placement, fonts bucket attribution);
- record findings in journal 06 + STATE; S4 gate; commit; push. No backend changes.

## Session-6 result log (append-only)
- [s6] RAN (user's machine, log pasted in chat; paste truncated mid-deny-list):
  dry-run against the public target repo in PAT mode.
- [s6] VERIFIED from that log: D17 (mozilla fully denied, both profiles, 449 deny
  items incl. cookies/key4/logins/places/bitwarden+github site storage), D18
  (auth: pat), D19 (size report + top-15), D20 (gnome-ext:yes).
- [s6] RAN code check: the 1 GiB budget warning prints at the END of dry-run output
  (bin/rice-backup.sh:257-267, stderr) — below the paste's cut, not missing; real run
  would exit 5 without --allow-oversize (total 8 GiB). fonts/icons/themes bucket
  counts only legacy top-level dirs (XDG fonts are under .local/**) — cosmetic.
- [s6] GAP noted for D32 (not implemented, user mid-testing): no --exclude option;
  payload is dominated by re-downloadable fonts (Iosevka NerdFont × 14 MiB variants)
  and .local/bin/uv 36 MiB. User advised to trim before the first real run.
- [s6] RAN S4 gate + commit + push of this record (see journal 06).

## Session 7 — 2026-10-31 (GUI implementation: tick/skip + sessions + archive export)

## NEXT ACTION (write-ahead) — session 7, current
- Implement the GUI per GUI-PLAN.md with the user's three additions: tick/skip
  selection (needs backend --exclude-from = D32 + --list-files companion),
  session persistence (D34), offline archive export (D33). Backend first with
  tests (suite must stay green), then gui/ (adapter headless-tested, widgets
  py_compile + manual checklist), commit+push at each milestone (D31).

## Session-7 result log (append-only)
- [s7] RAN backend milestone A: --exclude-from / --export / --list-files
  implemented (D32/D33 + companion); t22 + t23 added; suite 313/0; S4 tree
  scan unexpected=0; COMMIT d6b2f05. Version 0.2.0. README gained the
  selection + offline-archive + GUI sections.
- [s7] RAN GUI milestone B: gui/{rice-gui, adapter.py, guiconf.py, gui_app.py,
  README-GUI.md, tests/}; 45/45 headless unittests + py_compile via new t24;
  suite 317/0; S4 clean after renaming cred-assign false-positive identifiers
  (D35) instead of whitelisting; COMMIT 1e512ed. Widgets NOT RUN (C5) —
  10-point manual checklist in gui/README-GUI.md.
- [s7] ENVIRONMENT: /tmp/rice-auth is MISSING after the sandbox recycle → the
  session-7 commits (d6b2f05, 1e512ed, + final docs commit) are LOCAL until a
  PAT is re-requested from the user (rule S3: never search the filesystem for
  tokens). Push happens as soon as the PAT lands in env.
- [s7] PENDING: final docs/deliverable commit (this one) + push + 0.2.0
  tarball into download/.
- [s7] AMENDED (final): five local commits await the push (d6b2f05 backend
  hooks, 1e512ed GUI M0-M2, 089759c records, 4e7ebdc contract rig, 42f7bc3
  launcher exec bit); suite 317/0, S4 tree scan unexpected=0, worktree clean,
  tarball rebuilt from HEAD 42f7bc3 (155 files, gui/rice-gui mode 755).

## Session 7 — push record (final)
- [s7] PUSHED: all session-7 work is on origin/main at d241b02 (backend 0.2.0
  hooks D32/D33, GUI M0-M2 with tick/skip + sessions + archive export,
  records, contract rig, launcher exec bit). Auth per S1-S3: PAT from the
  user's chat message went to the shell environment ONLY; GIT_ASKPASS helper
  under /tmp/rice-auth (out of repo, 0700); value never echoed, never written
  to any file/URL/commit/log. NOTE: the sandbox shell recycles BETWEEN tool
  calls (env does not persist across calls) - the export + push must live in
  ONE command.
- [s7] RAN pre-push S4 gate: tree scan unexpected=0 with exact-needle ON;
  history scan (with expect) = the two documented Phase-0 phrases only;
  pre-push hook simulated over the exact push range: 6/6 commits PASS; hook
  then enforced it live during the push (unexpected=0 per commit).
- [s7] RAN post-push verification: origin/main == local HEAD; exact-needle
  scans (real PAT value as needle) CLEAN over tree AND history.
- [s7] SESSION CLOSED: suite 317/0; deliverable
  download/rice-backup-0.2.0.tar.gz. NEXT (user, real machine): the 10-point
  manual GUI checklist in gui/README-GUI.md; consider making the real backup
  target repo private; M3 restore GUI stays deferred (D29).

## Session 8 — 2026-11-01 (symlink following, D37)

## NEXT ACTION (write-ahead) — session 8, current
- AWAITING THE USER'S PAT (S3): /tmp/rice-auth lost .pat/env.sh in the
  sandbox recycle. When it lands: materialize to /tmp/rice-auth/.pat (0600)
  per S2, exact-needle pre-push scan, push e2be006 + the records commit,
  post-push exact-needle scan, verify origin/main == HEAD. Everything else
  is DONE: D37 complete, suite 356/0 (in-tree AND from the tarball),
  download/rice-backup-0.3.0.tar.gz + README updated, records written.

## Session-8 result log (append-only)
- [s8] RAN bootstrap: origin/main == HEAD == 262b4b9, tree clean, /tmp/rice-auth
  present, suite 317/0 after fixture rebuild.
- [s8] RAN tarball self-verification: extracted 0.3.0 tarball → suite
  initially 353/3 (fixture mode quirk), fixed build.sh mode re-assertion,
  amended to e2be006, rebuilt tarball → **356/0 from the tarball itself**.
- [s8] DONE (D37 implemented, suite 356/0, contract rig ALL OK): collect.sh
  link deferral + phase-2 resolver (deny-target/cache/coverage/overlap/
  dedup/outside/dangling) + recursive follow walk; staging pre-clean for
  type transitions + second tar pipe with -h for followed FILE links;
  symlinks.tsv + reports/SYMLINKS.md + dry-run "symlinks followed" line;
  --no-follow-symlinks / --follow-outside-home; rice-restore --relink;
  fixtures (followed dir+file links, dup, dangling, deny-target, ancestor
  overlap) + t25; GUI follow checkbox (persisted), adapter kwargs + summary
  parse + 5 new tests; docs. See journal 08 for the found-and-fixed bugs
  (ancestor duplication, report field order, link count) and the ln -s
  sandbox block (git-blob mklink workaround, scripts outside the repo).

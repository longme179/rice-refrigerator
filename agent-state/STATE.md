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

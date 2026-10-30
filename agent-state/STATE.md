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

## NEXT ACTION (write-ahead)
- Commit agent-state (PLAN.md, STATE.md, DECISIONS.md, journal/2026-10-31-01.md) + .gitignore with
  message "agent-state: Phase 0 plan"; run the ad-hoc pre-push scan (DECISIONS D4: exact PAT via
  stdin-fed `grep -aIlF -f -` over `git ls-files` + core S4 regexes over the same list); if clean,
  push origin main.

## Result log (append-only)
- [s1 2026-10-31] RAN: environment probe (see Environment facts). PAT loaded (93 bytes, prefix
  github_pat_), never printed.
- [s1 2026-10-31] RAN: `git ls-remote` workspace repo exit 0 → PAT valid, network OK.
- [s1 2026-10-31] RAN: clone + repo-local git identity; repo contains LICENSE only.
- [s1 2026-10-31] RAN: residue check — .pat-tmp no longer present in /home/z/my-project.

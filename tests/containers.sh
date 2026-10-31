#!/usr/bin/env bash
# tests/containers.sh - three-distro container verification (PLAN section 8.6).
#
# Runs a real backup -> restore round trip inside fedora / archlinux / ubuntu
# containers when a container runtime is available. When none is available
# (the situation in the dev sandbox) it reports NOT RUN with evidence and
# exits 0: container output is never invented.
#
# Usage: bash tests/containers.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

RUN=""
if command -v podman >/dev/null 2>&1; then RUN=podman; fi
if [ -z "$RUN" ] && command -v docker >/dev/null 2>&1; then RUN=docker; fi

if [ -z "$RUN" ]; then
  echo "NOT RUN: container matrix - neither podman nor docker is available here."
  echo "  evidence: command -v podman -> not found; command -v docker -> not found"
  echo "  the same code paths are covered by mocks in: bash tests/run-tests.sh (T04-T16)"
  exit 0
fi

echo "runtime: $RUN"
echo "NOTE: this container path itself was NOT RUN in the dev sandbox; it only"
echo "executes where a runtime exists. Round trip per image: fixture backup ->"
echo "local bare repo -> restore into a fresh home."
echo

fail=0
for img in fedora:latest archlinux:latest ubuntu:latest; do
  echo "== $img =="
  if "$RUN" run --rm -v "$ROOT:/rice:ro" "$img" bash -c '
      set -e
      # git is the only real prerequisite; install it when the image lacks it
      if ! command -v git >/dev/null 2>&1; then
        . /etc/os-release
        case "$ID" in
          fedora) dnf -y --setopt=install_weak_deps=False install git ;;
          arch)   pacman -Sy --noconfirm git ;;
          *)      apt-get update >/dev/null && apt-get -y install git ;;
        esac
      fi
      mkdir -p /tmp/remote-base/test /tmp/h /tmp/new
      git init -q --bare -b main /tmp/remote-base/test/backup.git
      cp -a /rice/tests/fixtures/home/. /tmp/h/
      export RICE_TEST_GIT_BASE=file:///tmp/remote-base
      export RICE_TOKEN=fake-container-token-000000000000
      unset RICE_TEST_DISTRO || true          # real distro detection inside the image
      bash /rice/bin/rice-backup.sh --home /tmp/h --repo test/backup --yes
      bash /rice/bin/rice-restore.sh --from /tmp/remote-base/test/backup.git \
           --home /tmp/new --apply --all-sections
      test -f /tmp/new/.bashrc || { echo "RESTORE-INCOMPLETE"; exit 1; }
      . /etc/os-release
      echo "CONTAINER-OK family=$ID"
    '; then
    echo "== $img OK"
  else
    echo "== $img FAILED"
    fail=1
  fi
done

exit "$fail"

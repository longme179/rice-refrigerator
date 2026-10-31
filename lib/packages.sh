# lib/packages.sh - per-distro package inventories (rule R8, PLAN section 4)
# Every tool that is missing is recorded as unavailable - output is NEVER invented.

RICE_PKG_HOME="${RICE_HOME:-$HOME}"

rice_packages_collect() { # $1 = stage/packages dir
  local out=$1
  mkdir -p "$out"
  case "${RICE_DISTRO:-}" in
    fedora) rice_pkg_fedora "$out" ;;
    arch)   rice_pkg_arch "$out" ;;
    ubuntu) rice_pkg_ubuntu "$out" ;;
    *)      printf '# package inventory not supported for this distro family: %s\n' \
              "${RICE_DISTRO:-unknown}" > "$out/unsupported.txt" ;;
  esac
  rice_pkg_common "$out"
}

rice_pkg_fedora() { # $1 out
  local out=$1
  if rice_have dnf; then
    if ! dnf -q repoquery --userinstalled 2>/dev/null | sort -u > "$out/fedora-userinstalled.txt"; then
      dnf -q history userinstalled 2>/dev/null | sort -u > "$out/fedora-userinstalled.txt" \
        || echo '# dnf userinstalled query failed' > "$out/fedora-userinstalled.txt"
    fi
    dnf -q repolist --enabled 2>/dev/null > "$out/fedora-repos.txt" \
      || echo '# dnf repolist failed' > "$out/fedora-repos.txt"
    if ! dnf -q copr list 2>/dev/null > "$out/fedora-copr.txt"; then
      : > "$out/fedora-copr.txt"
      local f
      for f in /etc/yum.repos.d/_copr*.repo; do
        [ -e "$f" ] && printf '# repo file: %s\n' "$f" >> "$out/fedora-copr.txt"
      done
      grep -q . "$out/fedora-copr.txt" 2>/dev/null \
        || echo '# no COPR repos detected (dnf copr plugin may be missing)' >> "$out/fedora-copr.txt"
    fi
  else
    echo '# dnf not available' > "$out/fedora-userinstalled.txt"
    echo '# dnf not available' > "$out/fedora-repos.txt"
    echo '# dnf not available' > "$out/fedora-copr.txt"
  fi
}

rice_pkg_arch() { # $1 out
  local out=$1
  if rice_have pacman; then
    pacman -Qqe 2>/dev/null | sort -u > "$out/arch-explicit.txt" \
      || echo '# pacman -Qqe failed' > "$out/arch-explicit.txt"
    pacman -Qqm 2>/dev/null | sort -u > "$out/arch-foreign.txt" \
      || echo '# pacman -Qqm failed' > "$out/arch-foreign.txt"
    if [ -r /etc/pacman.d/mirrorlist ]; then
      cp -- /etc/pacman.d/mirrorlist "$out/arch-mirrorlist.txt" 2>/dev/null \
        || echo '# mirrorlist copy failed' > "$out/arch-mirrorlist.txt"
    else
      echo '# /etc/pacman.d/mirrorlist not present' > "$out/arch-mirrorlist.txt"
    fi
  else
    echo '# pacman not available' > "$out/arch-explicit.txt"
    echo '# pacman not available' > "$out/arch-foreign.txt"
    echo '# pacman not available' > "$out/arch-mirrorlist.txt"
  fi
}

rice_pkg_ubuntu() { # $1 out
  local out=$1
  if rice_have apt-mark; then
    apt-mark showmanual 2>/dev/null | sort -u > "$out/ubuntu-manual.txt" \
      || echo '# apt-mark showmanual failed' > "$out/ubuntu-manual.txt"
  else
    echo '# apt-mark not available' > "$out/ubuntu-manual.txt"
  fi
  {
    local f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
      [ -e "$f" ] || continue
      printf '### %s\n' "$f"
      grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -v '^[[:space:]]*$' || true
    done
  } > "$out/ubuntu-sources.txt" 2>/dev/null \
    || echo '# apt sources unavailable' > "$out/ubuntu-sources.txt"
}

rice_pkg_common() { # $1 out
  local out=$1

  # flatpak
  if rice_have flatpak; then
    flatpak list --app --columns=application,origin 2>/dev/null > "$out/flatpak.txt" \
      || echo '# flatpak list failed' > "$out/flatpak.txt"
  else
    echo '# flatpak not installed' > "$out/flatpak.txt"
  fi

  # snap
  if rice_have snap; then
    snap list 2>/dev/null > "$out/snap.txt" || echo '# snap list failed' > "$out/snap.txt"
  else
    echo '# snap not installed' > "$out/snap.txt"
  fi

  # pip --user
  if rice_have pip3; then
    if ! pip3 list --user --format=freeze 2>/dev/null | sort > "$out/pip-user.txt"; then
      echo '# pip3 list --user failed' > "$out/pip-user.txt"
    fi
  elif rice_have python3; then
    python3 -m pip list --user --format=freeze 2>/dev/null | sort > "$out/pip-user.txt" \
      || echo '# python3 -m pip unavailable' > "$out/pip-user.txt"
  else
    echo '# pip not available' > "$out/pip-user.txt"
  fi

  # pipx (directory based - no pipx binary needed)
  local vd found=0
  for vd in "$RICE_PKG_HOME/.local/pipx/venvs" "$RICE_PKG_HOME/.local/share/pipx/venvs"; do
    if [ -d "$vd" ]; then
      find "$vd" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort > "$out/pipx.txt"
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ] || echo '# pipx venvs not found' > "$out/pipx.txt"

  # GNOME Shell extensions (names + enabled state; the files themselves are
  # backed up under .local/share/gnome-shell/extensions)
  if rice_have gnome-extensions; then
    gnome-extensions list 2>/dev/null > "$out/gnome-extensions.txt" \
      || echo '# gnome-extensions list failed' > "$out/gnome-extensions.txt"
    gnome-extensions list --enabled 2>/dev/null > "$out/gnome-extensions-enabled.txt" \
      || echo '# gnome-extensions list --enabled failed' > "$out/gnome-extensions-enabled.txt"
  else
    echo '# gnome-extensions not available' > "$out/gnome-extensions.txt"
    echo '# gnome-extensions not available' > "$out/gnome-extensions-enabled.txt"
  fi

  # npm -g
  if rice_have npm; then
    npm ls -g --depth=0 2>/dev/null | tail -n +2 | sed -e 's/^[| ├ └ ─ ]*//' \
      > "$out/npm-global.txt" || echo '# npm ls -g failed' > "$out/npm-global.txt"
    grep -q . "$out/npm-global.txt" 2>/dev/null \
      || echo '# npm reported no global packages' >> "$out/npm-global.txt"
  else
    echo '# npm not installed' > "$out/npm-global.txt"
  fi

  # cargo-installed binaries (file based - no cargo needed)
  local cf
  for cf in "$RICE_PKG_HOME/.cargo/.crates2.toml" "$RICE_PKG_HOME/.cargo/.crates.toml"; do
    if [ -r "$cf" ]; then
      grep -oE '^"[A-Za-z0-9_.-]+ [0-9][^"]*"' "$cf" 2>/dev/null | sed -e 's/^"//' -e 's/ .*//' \
        | sort -u > "$out/cargo.txt"
      grep -q . "$out/cargo.txt" 2>/dev/null || echo "# could not parse $cf" > "$out/cargo.txt"
      break
    fi
  done
  [ -s "$out/cargo.txt" ] || echo '# no cargo crates file found' > "$out/cargo.txt"
}

# tool availability matrix for meta/ (also used by the dry-run summary)
rice_packages_toolmatrix() {
  local t
  for t in dnf pacman apt-mark flatpak snap pip3 npm pipx cargo gnome-extensions gh curl; do
    if rice_have "$t"; then printf 'yes\t%s\n' "$t"; else printf 'no\t%s\n' "$t"; fi
  done
}

# dry-run helper: what WOULD be collected + tool availability (never executes them)
rice_packages_plan_summary() {
  local fam=${RICE_DISTRO:-unknown} parts=()
  case "$fam" in
    fedora) parts+=("dnf:$(rice_have dnf && printf yes || printf no)") ;;
    arch)   parts+=("pacman:$(rice_have pacman && printf yes || printf no)") ;;
    ubuntu) parts+=("apt-mark:$(rice_have apt-mark && printf yes || printf no)") ;;
    *)      parts+=("family:$fam") ;;
  esac
  parts+=("flatpak:$(rice_have flatpak && printf yes || printf no)")
  parts+=("snap:$(rice_have snap && printf yes || printf no)")
  parts+=("pip:$(rice_have pip3 && printf yes || printf no)")
  parts+=("pipx:$( if [ -d "$RICE_PKG_HOME/.local/pipx/venvs" ] || [ -d "$RICE_PKG_HOME/.local/share/pipx/venvs" ]; then printf yes; else printf no; fi )")
  parts+=("npm:$(rice_have npm && printf yes || printf no)")
  parts+=("cargo:$( if [ -r "$RICE_PKG_HOME/.cargo/.crates.toml" ] || [ -r "$RICE_PKG_HOME/.cargo/.crates2.toml" ]; then printf yes; else printf no; fi )")
  parts+=("gnome-ext:$(rice_have gnome-extensions && printf yes || printf no)")
  local IFS=';'
  printf '%s' "${parts[*]}"
}

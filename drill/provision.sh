#!/usr/bin/env bash
# drill/provision.sh — the round brings its own host dependencies (#825).
#
# Sourced by drill/rehearsal-all.sh before anything else touches the host. A
# drill host is generic (heavy-duty/infra's drillhost VM starts with only git,
# sudo and curl), so the round, not the host, knows what it needs:
#
#   - box at DRILL_BOX_REF, the box this crew is drilled against. The pin is
#     the drill's and moves with it; nobody passes it. box is installed for the
#     operator with box's own installer at that tag and the host is set up by
#     it (BOX_YES=1: the installer runs `box setup-host`, which adds the
#     operator to incus-admin). An installed box is never replaced: below the
#     pin the round refuses, naming it; above it the round notes it and runs.
#   - the host tools the legs call (jq, gh, python3, crontab, flock, …) and the
#     browser leg's node, npm and a Chromium, from the distro; playwright-core
#     in the tree the page reader runs from (node_modules is git-ignored).
#
# What is already there is left alone, and a host with everything installs
# nothing. Installing needs passwordless sudo and apt-get; without them the
# round refuses and lists what is missing, rather than failing an hour in.
#
# NEVER INSIDE A BOX. A box carries /etc/chrony/conf.d/box-makestep.conf from
# box's own seed; a nested box stack claims the guest's uplink and breaks its
# networking (heavy-duty/box#80), so the round refuses to install anything
# there. A drill-host VM has no such file.
#
# After `box setup-host` the operator is in incus-admin, but this process was
# started before that and does not hold the group, so the round restarts itself
# once under `sg incus-admin` (DRILL_PROVISIONED=1 marks the restart; a second
# pass that still lacks the group refuses instead of looping).

DRILL_BOX_REF="0.11.0"

# command:package, for the host tools the round's legs call.
DRILL_HOST_TOOLS=(
  git:git curl:curl jq:jq gh:gh python3:python3 crontab:cron flock:util-linux
  node:nodejs npm:npm
)
DRILL_CHROME_CANDIDATES=(
  /usr/bin/google-chrome /usr/bin/google-chrome-stable
  /opt/google/chrome/chrome /usr/bin/chromium-browser /usr/bin/chromium
)

# Test seams: the marker a box carries, the sudo prefix, the installer URL.
: "${DRILL_BOX_MARKER:=/etc/chrony/conf.d/box-makestep.conf}"
: "${DRILL_SUDO:=sudo -n}"
: "${DRILL_BOX_INSTALLER:=https://raw.githubusercontent.com/heavy-duty/box/$DRILL_BOX_REF/install.sh}"

# shellcheck source=shared/lib/platform.sh
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/shared/lib/platform.sh"

provision_say() { echo "provision: $*"; }
provision_die() { echo "provision: $*" >&2; exit 2; }

provision_chrome_present() {
  local c
  [ -n "${PW_CHROME:-}" ] && [ -x "$PW_CHROME" ] && return 0
  for c in "${DRILL_CHROME_CANDIDATES[@]}"; do [ -x "$c" ] && return 0; done
  return 1
}

# provision_round ROOT SELF [ARGS…] — ROOT is the checkout the round runs from,
# SELF the round script's absolute path, ARGS its own arguments (for the one
# restart under incus-admin).
provision_round() {
  local root="$1" self="$2"; shift 2
  local -a pkgs=() missing=()
  local pair cmd pkg box_v="" need_box=0 need_pw=0 sudo_ok=0
  [ -d "$HOME/.local/bin" ] && case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
  export PATH

  for pair in "${DRILL_HOST_TOOLS[@]}"; do
    cmd="${pair%%:*}" pkg="${pair#*:}"
    command -v "$cmd" >/dev/null 2>&1 || { pkgs+=("$pkg"); missing+=("$cmd"); }
  done
  provision_chrome_present || { pkgs+=(chromium); missing+=(chromium); }
  if ! command -v node >/dev/null 2>&1 || ! (cd "$root" && node -e "require('playwright-core')") >/dev/null 2>&1; then
    need_pw=1; missing+=(playwright-core)
  fi
  if command -v box >/dev/null 2>&1; then
    box_v="$(platform_version_of "$(box --version 2>/dev/null </dev/null | head -1)")"
    if [ -z "$box_v" ]; then
      provision_die "box is installed but 'box --version' gives no version — fix box first; this round drills against box $DRILL_BOX_REF"
    elif platform_below_floor "$box_v" "$DRILL_BOX_REF"; then
      provision_die "this round drills against box $DRILL_BOX_REF and this host has box $box_v — the round never replaces an installed box; upgrade it: curl -fsSL $DRILL_BOX_INSTALLER | BOX_REF=$DRILL_BOX_REF bash, then box setup-host"
    fi
  else
    need_box=1; missing+=("box@$DRILL_BOX_REF")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    provision_say "nothing to install — box $box_v$([ "$box_v" = "$DRILL_BOX_REF" ] || echo " (the round's pin is $DRILL_BOX_REF)"), every host tool present"
    provision_group "$self" "$@"
    return 0
  fi

  provision_say "this host lacks: ${missing[*]}"
  [ ! -e "$DRILL_BOX_MARKER" ] ||
    provision_die "refusing to install anything: this machine is a box ($DRILL_BOX_MARKER), and a box stack inside a box breaks its networking (heavy-duty/box#80). Run the round on a drill host."
  # shellcheck disable=SC2086  # DRILL_SUDO is a prefix of words on purpose
  $DRILL_SUDO true 2>/dev/null </dev/null && sudo_ok=1
  [ "$sudo_ok" -eq 1 ] ||
    provision_die "installing them needs passwordless sudo (sudo -n) — install them yourself, or give the operator NOPASSWD sudo on this drill host"

  if [ "${#pkgs[@]}" -gt 0 ]; then
    command -v apt-get >/dev/null 2>&1 ||
      provision_die "no apt-get on this host to install: ${pkgs[*]} — install them yourself"
    provision_say "apt-get install ${pkgs[*]}"
    # shellcheck disable=SC2086
    if ! { $DRILL_SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null >/dev/null &&
           $DRILL_SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" </dev/null >/dev/null; }; then
      provision_die "apt-get install ${pkgs[*]} failed"
    fi
    hash -r
  fi
  if [ "$need_pw" -eq 1 ]; then
    provision_say "npm i --no-save playwright-core (in $root)"
    (cd "$root" && npm i --no-save --no-audit --no-fund playwright-core </dev/null >/dev/null 2>&1) ||
      provision_die "npm i --no-save playwright-core failed in $root"
  fi
  if [ "$need_box" -eq 1 ]; then
    provision_say "box $DRILL_BOX_REF, with box's installer, and box setup-host"
    curl -fsSL "$DRILL_BOX_INSTALLER" </dev/null | BOX_REF="$DRILL_BOX_REF" BOX_YES=1 bash ||
      provision_die "box's installer failed (BOX_REF=$DRILL_BOX_REF)"
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
    export PATH; hash -r
    box_v="$(platform_version_of "$(box --version 2>/dev/null </dev/null | head -1)")"
    [ "$box_v" = "$DRILL_BOX_REF" ] ||
      provision_die "box's installer ran but 'box --version' reads '${box_v:-nothing}', not $DRILL_BOX_REF"
  fi
  provision_say "done — box $box_v"
  provision_group "$self" "$@"
}

# provision_group SELF [ARGS…] — restart once under incus-admin when the
# operator holds it in /etc/group but this process does not.
provision_group() {
  local self="$1"; shift
  case " $(id -nG 2>/dev/null) " in *" incus-admin "*) return 0 ;; esac
  case " $(id -nG "$(id -un)" 2>/dev/null) " in *" incus-admin "*) ;; *) return 0 ;; esac
  [ -z "${DRILL_PROVISIONED:-}" ] ||
    provision_die "restarted under incus-admin and still without the group — log in again and re-run the round"
  provision_say "restarting under incus-admin (box setup-host added $(id -un) to it)"
  export DRILL_PROVISIONED=1
  exec sg incus-admin -c "$(printf '%q ' bash "$self" "$@")"
}

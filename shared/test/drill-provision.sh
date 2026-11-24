#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted programs run in the shells they are handed to
# shared/test/drill-provision.sh — the round brings its own host dependencies
# (#825), offline.
#
# drill/provision.sh is driven against a PATH made only of the core utilities
# it needs plus stubs that log every call: box (answers a configured version),
# sudo, apt-get, curl (hands back a fake box installer), npm, node, sg, id. So
# each row reads exactly what the round would have installed, or refused.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROV="$ROOT/drill/provision.sh"
PIN="$(sed -n 's/^DRILL_BOX_REF="\(.*\)"$/\1/p' "$PROV")"

CORE="$TMP/core"; mkdir -p "$CORE"
for c in bash env dirname basename readlink awk cut head tr cat grep sed mkdir test true chmod; do
  p="$(command -v "$c")" && ln -s "$p" "$CORE/$c"
done

# fixture STATE — a fresh host: HOME, the checkout the round runs from, stubs.
fixture() {
  F="$TMP/$1"; rm -rf "$F"; mkdir -p "$F/home" "$F/root" "$F/bin" "$F/tools"
  export LOG="$F/calls"; : >"$LOG"
  cat >"$F/bin/box" <<'EOF'
#!/usr/bin/env bash
echo "box $*" >>"$LOG"
[ "${1:-}" = --version ] && [ -n "${BOX_V:-}" ] && echo "box $BOX_V (/opt/box/versions/$BOX_V)"
exit 0
EOF
  cat >"$F/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
[ "${1:-}" = -n ] && shift
[ "${1:-}" = true ] && exit "${SUDO_RC:-0}"
exec "$@"
EOF
  cat >"$F/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $* DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}" >>"$LOG"
EOF
  cat >"$F/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$LOG"
cat <<'INSTALLER'
echo "installer BOX_REF=$BOX_REF BOX_YES=$BOX_YES" >>"$LOG"
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env bash\necho "box $*" >>"$LOG"\n[ "${1:-}" = --version ] && echo "box %s (x)"\nexit 0\n' "${INSTALLED_V:-$BOX_REF}" >"$HOME/.local/bin/box"
chmod +x "$HOME/.local/bin/box"
INSTALLER
EOF
  cat >"$F/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $* in $PWD" >>"$LOG"
mkdir -p node_modules/playwright-core
EOF
  cat >"$F/bin/node" <<'EOF'
#!/usr/bin/env bash
[ -d node_modules/playwright-core ]
EOF
  cat >"$F/bin/sg" <<'EOF'
#!/usr/bin/env bash
echo "sg $* DRILL_PROVISIONED=${DRILL_PROVISIONED:-}" >>"$LOG"
EOF
  cat >"$F/bin/id" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  -un) echo op ;;
  -nG) echo "${ID_PROC:-op}" ;;
  "-nG op") echo "${ID_DB:-op}" ;;
esac
EOF
  for t in git curl jq gh python3 crontab flock npm; do
    [ -e "$F/bin/$t" ] || printf '#!/usr/bin/env bash\nexit 0\n' >"$F/bin/$t"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' >"$F/tools/chrome"
  chmod +x "$F"/bin/* "$F/tools/chrome"
  mkdir -p "$F/root/node_modules/playwright-core"
}
# drop CMD… — the host lacks these.
drop() { local c; for c in "$@"; do rm -f "$F/bin/$c"; done; }
# run [VAR=val…] — provision_round as the round calls it; sets OUT and RC.
run() {
  OUT="$(cd "$F/root" && env -i HOME="$F/home" PATH="$F/bin:$CORE" LOG="$LOG" \
    PW_CHROME="$F/tools/chrome" DRILL_BOX_MARKER="$F/no-marker" "$@" \
    bash -c '. "$1"; provision_round "$2" "$3" --parallel "a b"' _ "$PROV" "$F/root" "$F/self.sh" 2>&1)"
  RC=$?
}
has() { grep -c -- "$1" <<<"$OUT" || true; }
logged() { grep -c -- "$1" "$LOG" || true; }

# --- a host with everything installs nothing ------------------------------------------
fixture full; run BOX_V="$PIN"
t prov-full-rc 0 "$RC"
t prov-full-says-nothing 1 "$(has 'provision: nothing to install — box '"$PIN"', every host tool present')"
t prov-full-no-sudo 0 "$(logged '^sudo')"
t prov-full-no-apt 0 "$(logged '^apt-get')"
t prov-full-no-curl 0 "$(logged '^curl')"

# --- an installed box is never replaced -------------------------------------------------
fixture old; run BOX_V=0.10.0
t prov-old-box-refused 2 "$RC"
t prov-old-box-names-both 1 "$(has "drills against box $PIN and this host has box 0.10.0")"
t prov-old-box-never-installs 0 "$(logged '^curl\|^installer')"
fixture newer; run BOX_V=0.12.1
t prov-newer-box-runs 0 "$RC"
t prov-newer-box-noted 1 "$(has "box 0.12.1 (the round's pin is $PIN)")"
fixture blank; run BOX_V=
t prov-unreadable-box-refused 2 "$RC"
t prov-unreadable-box-says-so 1 "$(has "gives no version")"

# --- never inside a box -------------------------------------------------------------------
fixture inbox; drop box jq; touch "$F/marker"; run DRILL_BOX_MARKER="$F/marker"
t prov-inside-box-refused 2 "$RC"
t prov-inside-box-says-why 1 "$(has 'this machine is a box')"
t prov-inside-box-installs-nothing 0 "$(logged '^apt-get\|^curl\|^sudo')"

# --- installing needs passwordless sudo, and apt-get for packages --------------------------
fixture nosudo; drop jq; run BOX_V="$PIN" SUDO_RC=1
t prov-no-sudo-refused 2 "$RC"
t prov-no-sudo-lists-missing 1 "$(has 'this host lacks: jq')"
t prov-no-sudo-says-so 1 "$(has 'needs passwordless sudo')"
fixture noapt; drop jq apt-get; run BOX_V="$PIN"
t prov-no-apt-refused 2 "$RC"
t prov-no-apt-names-packages 1 "$(has 'no apt-get on this host to install: jq')"

# --- a bare drill host: packages, playwright-core, box at the pin --------------------------
fixture bare; drop box jq gh crontab flock; rm -rf "$F/root/node_modules"
run PW_CHROME=
t prov-bare-rc 0 "$RC"
t prov-bare-apt-packages 1 "$(logged '^apt-get install -y -qq jq gh cron util-linux chromium DEBIAN_FRONTEND=noninteractive')"
t prov-bare-apt-through-sudo 1 "$(logged '^sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install')"
t prov-bare-playwright-in-root 1 "$(logged "^npm i --no-save --no-audit --no-fund playwright-core in $F/root")"
t prov-bare-installer-at-pin 1 "$(logged "^curl -fsSL https://raw.githubusercontent.com/heavy-duty/box/$PIN/install.sh")"
t prov-bare-installer-env 1 "$(logged "^installer BOX_REF=$PIN BOX_YES=1")"
t prov-bare-done 1 "$(has "provision: done — box $PIN")"
fixture wrongv; drop box; run INSTALLED_V=0.9.0
t prov-installer-wrong-version-refused 2 "$RC"
t prov-installer-wrong-version-says 1 "$(has "reads '0.9.0', not $PIN")"

# --- the one restart under incus-admin ------------------------------------------------------
fixture group; run BOX_V="$PIN" ID_DB="op incus-admin"
t prov-group-restart-once 1 "$(logged "^sg incus-admin -c bash $F/self.sh --parallel a\\\\ b  DRILL_PROVISIONED=1")"
fixture held; run BOX_V="$PIN" ID_PROC="op incus-admin" ID_DB="op incus-admin"
t prov-group-held-no-restart 0 "$(logged '^sg')"
fixture loop; run BOX_V="$PIN" ID_DB="op incus-admin" DRILL_PROVISIONED=1
t prov-group-second-pass-refuses 2 "$RC"
t prov-group-second-pass-no-sg 0 "$(logged '^sg')"
fixture nogroup; run BOX_V="$PIN"
t prov-no-group-no-restart 0 "$(logged '^sg')"

# --- wiring --------------------------------------------------------------------------------
ALL="$ROOT/drill/rehearsal-all.sh"
t prov-wired-before-validation 1 \
  "$(awk '/provision_round "/{p=NR} /^# Validate operator input before source acquisition/{v=NR} END{print (p && v && p < v) ? 1 : 0}' "$ALL")"
t prov-wired-before-box-list 1 \
  "$(awk '/provision_round "/{p=NR} /existing_boxes="\$\(box list/{b=NR} END{print (p && b && p < b) ? 1 : 0}' "$ALL")"
t prov-opt-out-honoured 1 "$(grep -c 'DRILL_NO_PROVISION:-' "$ALL")"
t prov-summary-names-box 1 "$(grep -c '## drill host: box \$ROUND_BOX' "$ALL")"
# shellcheck source=shared/lib/platform.sh
source "$ROOT/shared/lib/platform.sh"
t prov-pin-not-below-platform-floor 1 "$(platform_below_floor "$PIN" "$CREW_PLATFORM_BOX_MIN" && echo 0 || echo 1)"
t prov-pin-is-a-version "$PIN" "$(platform_version_of "box $PIN (x)")"

suite_finish

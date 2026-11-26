#!/usr/bin/env bash
# shared/lib/host/service.sh — crew as a system service (#822): `crew service
# setup | check | teardown`, run as root, once per machine.
#
# WHAT SETUP MAKES, in the order box requires ("grant first, then start the
# service", box#281):
#
#   1. the group (members operate the fleet) and the system account crew runs
#      as — no login, its home the data dir, so its gh login lives there;
#   2. /var/lib/crew (fleets/, state/), owned by the account, setgid group;
#   3. `box grant --service <account> --share <group>` with project caps —
#      the account's own fenced box project, which every fleet's boxes live in;
#   4. a visudo-checked sudoers rule letting the group run the crew CLI as the
#      account, and nothing else (cli/crew re-runs itself through it);
#   5. /etc/crew/service.conf (what makes cli/crew re-run as the account) and
#      /etc/crew/floor.env (the console's address and password, generated once);
#   6. systemd units: <prefix>-floor.service, and <prefix>-tick, -restart and
#      -reset as oneshot services on timers — the schedule of the old
#      host-crontab.example, with Persistent= so a run missed while the host
#      was down runs at boot.
#
# NO FLEET (#831): a crew server starts with none. The floor serves its lobby,
# whose one action is New fleet, and members are added in that fleet's Roster.
#
# Every step is idempotent: setup on a set-up host converges it and changes
# nothing that is already right. `check` reads every step back, read-only, and
# exits 1 on drift. `teardown` stops and removes the units, the rule, the grant
# and service.conf, and keeps the data and the account; `--purge` removes those
# too.
#
# Paths and the root check have overrides so the suite and the drill can stand
# a service up somewhere that is not the host's real one: CREW_ETC_DIR,
# CREW_DATA_DIR, CREW_SYSTEMD_DIR, CREW_SUDOERS_DIR, and
# CREW_SERVICE_ASSUME_ROOT=1 (fixtures only — every privileged step is then a
# stub on PATH).

SERVICE_SYSTEMD_DIR="${CREW_SYSTEMD_DIR:-/etc/systemd/system}"
SERVICE_SUDOERS_DIR="${CREW_SUDOERS_DIR:-/etc/sudoers.d}"

service_is_root() { [ "${CREW_SERVICE_ASSUME_ROOT:-0}" = 1 ] || [ "$(id -u)" -eq 0 ]; }

# service_default_caps — the project caps setup applies unless told otherwise:
# 6 instances, 75% of the host's memory, every CPU (operator ruling, #822 D6).
service_default_caps() {
  local mem_kib cpus
  mem_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  cpus="$(nproc 2>/dev/null || echo 2)"
  printf -- '--instances 6 --memory %sMiB --cpu %s\n' "$(( ${mem_kib:-8388608} * 3 / 4 / 1024 ))" "$cpus"
}

service_unit_text() { # KIND USER GROUP CLI ETC DATA
  local kind="$1" user="$2" group="$3" cli="$4" etc="$5" data="$6" verb when
  case "$kind" in
    floor)
      cat <<EOF
# Written by \`crew service setup\` (#822). Edit /etc/crew/floor.env, not this.
[Unit]
Description=crew floor — the fleet console
After=network-online.target incus.service
Wants=network-online.target

[Service]
User=$user
Group=$group
Environment=HOME=$data
Environment=CREW_ETC_DIR=$etc
EnvironmentFile=$etc/floor.env
ExecStart=$cli floor
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
      return 0 ;;
    tick) verb="tick"; when="*:0/5" ;;
    restart) verb="restart --all"; when="*-*-* 04:10:00" ;;
    reset) verb="reset --all"; when="Sun *-*-* 05:10:00" ;;
    *) return 1 ;;
  esac
  case "${7:-service}" in
    service)
      cat <<EOF
# Written by \`crew service setup\` (#822).
[Unit]
Description=crew $verb — the host schedule
After=network-online.target incus.service

[Service]
Type=oneshot
User=$user
Group=$group
Environment=HOME=$data
Environment=CREW_ETC_DIR=$etc
ExecStart=$cli $verb
# 3 is "a box was skipped busy", 4 "nothing to do": reported, not failures.
SuccessExitStatus=3 4
EOF
      ;;
    timer)
      cat <<EOF
# Written by \`crew service setup\` (#822).
[Unit]
Description=crew $verb on schedule

[Timer]
OnCalendar=$when
Persistent=true

[Install]
WantedBy=timers.target
EOF
      ;;
  esac
}

# service_units PREFIX — every unit file name setup writes, one per line.
service_units() {
  printf '%s\n' "$1-floor.service" "$1-tick.service" "$1-tick.timer" \
    "$1-restart.service" "$1-restart.timer" "$1-reset.service" "$1-reset.timer"
}
service_unit_body() { # NAME PREFIX USER GROUP CLI ETC DATA
  local name="$1" prefix="$2" kind type
  kind="${name#"$prefix"-}"; type="${kind##*.}"; kind="${kind%.*}"
  if [ "$kind" = floor ]; then service_unit_text floor "$3" "$4" "$5" "$6" "$7"
  else service_unit_text "$kind" "$3" "$4" "$5" "$6" "$7" "$type"; fi
}

service_write_if_changed() { # DEST MODE — body on stdin; prints "changed" or "same"
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; echo same; return 0; fi
  install -m "$mode" "$tmp" "$dest" && rm -f "$tmp" && echo changed
}

# The PATH systemd gives a unit that sets none (systemd.exec(5)).
SERVICE_UNIT_PATH="${CREW_SERVICE_UNIT_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
service_setup() { # args: [--user U] [--group G] [--cli PATH] [--unit-prefix P] [--port N] [--bind A] [--instances N] [--memory SIZE] [--cpu N] [--pool NAME --pool-size SIZE] [--no-caps] [--no-start]
  local user=crew group=crew cli="" prefix=crew port=8420 bind=0.0.0.0
  local caps="" nocaps=0 nostart=0 etc="$CREW_ETC_DIR" data="$CREW_DATA_DIR" u body pass sud
  local -a grant_caps=() userset=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --user) need_value "$@"; user="$2"; shift 2 ;;
      --group) need_value "$@"; group="$2"; shift 2 ;;
      --cli) need_value "$@"; cli="$2"; shift 2 ;;
      --unit-prefix) need_value "$@"; prefix="$2"; shift 2 ;;
      --port) need_value "$@"; port="$2"; shift 2 ;;
      --bind) need_value "$@"; bind="$2"; shift 2 ;;
      --instances|--memory|--cpu|--pool|--pool-size) need_value "$@"; userset+=("$1" "$2"); shift 2 ;;
      --no-caps) nocaps=1; shift ;;
      --no-start) nostart=1; shift ;;
      *) usage_error "unknown argument '$1' (usage: $(synopsis_of service))" ;;
    esac
  done
  for u in "$user" "$group" "$prefix"; do
    case "$u" in ''|*[!a-z0-9_-]*|[!a-z]*) usage_error "'$u' is not a valid account, group or unit name" ;; esac
  done
  case "$port" in ''|*[!0-9]*) usage_error "--port takes a number" ;; esac
  [ -n "$cli" ] || cli="$(command -v crew 2>/dev/null || true)"
  [ -n "$cli" ] || cli="/usr/local/bin/crew"
  case "$cli" in /*) : ;; *) usage_error "--cli takes an absolute path" ;; esac
  service_is_root || die "crew service setup runs as root (sudo crew service setup)"
  for u in systemctl visudo useradd groupadd install getent; do
    command -v "$u" >/dev/null 2>&1 || die "crew service setup needs '$u' on this host"
  done
  # The units run with systemd's own PATH, as the account (#837): a box only
  # on the operator's PATH (a per-user install under a home directory) is one
  # neither root under sudo nor the service can run.
  PATH="$SERVICE_UNIT_PATH" command -v box >/dev/null 2>&1 ||
    die "crew service setup needs box installed system-wide, on the PATH its units run with ($SERVICE_UNIT_PATH) — box's installer run as root puts it in /usr/local/bin; a per-user box under a home directory is one the service account cannot run"
  # The engine reads GitHub from the host, as the account (#864): gh with its
  # App's token, python3 to mint it, openssl to sign it. A host without them
  # would run a floor whose pool refuses every GitHub token and a tick that
  # reads no board, each blaming the wrong thing.
  local tool
  for tool in gh python3 openssl; do
    PATH="$SERVICE_UNIT_PATH" command -v "$tool" >/dev/null 2>&1 ||
      die "crew service setup needs '$tool' installed system-wide, on the PATH its units run with ($SERVICE_UNIT_PATH): the engine reads GitHub with gh, minting its App's token with python3 and openssl — install it from the distribution (apt-get install $tool) and re-run"
  done
  need_box
  [ "$BOX_ENTRY_MODE_CACHED" = user ] ||
    die "crew service setup needs box 0.11.0 or later (its service grants, box#281); this host's box is older"

  echo "== crew service setup (account $user, group $group, data $data)"
  # 1. group and account
  if getent group "$group" >/dev/null 2>&1; then echo "  group $group: present"
  else groupadd --system "$group" || die "groupadd $group failed"; echo "  group $group: created"; fi
  if id -u "$user" >/dev/null 2>&1; then echo "  account $user: present"
  else
    useradd --system --gid "$group" --home-dir "$data" --no-create-home --shell /usr/sbin/nologin "$user" ||
      die "useradd $user failed"
    echo "  account $user: created (no login, home $data)"
  fi
  # 2. data and config dirs
  install -d -o "$user" -g "$group" -m 2770 "$data" "$data/fleets" "$data/state" || die "cannot create $data"
  install -d -m 0755 "$etc" || die "cannot create $etc"
  echo "  $data: owned by $user:$group"
  # 3. the box grant — before anything starts as the account
  if [ "$nocaps" -eq 0 ]; then
    if [ "${#userset[@]}" -gt 0 ]; then grant_caps=("${userset[@]}")
    else read -r -a grant_caps <<<"$(service_default_caps)"; fi
  fi
  box grant --service "$user" --share "$group" ${grant_caps[@]+"${grant_caps[@]}"} </dev/null ||
    die "box grant --service $user --share $group failed"
  caps="${grant_caps[*]:-none}"
  echo "  box grant: --service $user --share $group (caps: $caps)"
  # 4. the sudoers rule — the group runs the crew CLI as the account, nothing else
  sud="$(mktemp)"
  # shellcheck disable=SC2016  # the backticks are prose in the rule's comment
  printf '# Written by `crew service setup` (#822): %s runs crew as %s, and nothing else.\n%%%s ALL=(%s) NOPASSWD: %s\n' \
    "$group" "$user" "$group" "$user" "$cli" >"$sud"
  visudo -cf "$sud" >/dev/null || { rm -f "$sud"; die "the sudoers rule did not validate (visudo -cf)"; }
  install -d -m 0755 "$SERVICE_SUDOERS_DIR"
  echo "  sudoers $SERVICE_SUDOERS_DIR/$prefix: $(service_write_if_changed "$SERVICE_SUDOERS_DIR/$prefix" 0440 <"$sud")"
  rm -f "$sud"
  # 5. service.conf and floor.env
  echo "  $etc/service.conf: $(printf 'CREW_SERVICE_USER=%s\nCREW_SERVICE_GROUP=%s\nCREW_SERVICE_CLI=%s\nCREW_DATA_DIR=%s\nCREW_UNIT_PREFIX=%s\n' \
    "$user" "$group" "$cli" "$data" "$prefix" | service_write_if_changed "$etc/service.conf" 0644)"
  if [ -f "$etc/floor.env" ]; then echo "  $etc/floor.env: present (kept, password unchanged)"
  else
    pass="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
    printf 'CREW_FLOOR_USER=operator\nCREW_FLOOR_PASS=%s\nCREW_FLOOR_BIND=%s\nCREW_FLOOR_PORT=%s\n' "$pass" "$bind" "$port" |
      service_write_if_changed "$etc/floor.env" 0640 >/dev/null
    chgrp "$group" "$etc/floor.env" 2>/dev/null || true
    echo "  $etc/floor.env: written (operator / a generated password — read it as root)"
  fi
  # 6. the units
  install -d -m 0755 "$SERVICE_SYSTEMD_DIR"
  while read -r u; do
    body="$(service_unit_body "$u" "$prefix" "$user" "$group" "$cli" "$etc" "$data")"
    echo "  unit $u: $(printf '%s\n' "$body" | service_write_if_changed "$SERVICE_SYSTEMD_DIR/$u" 0644)"
  done < <(service_units "$prefix")
  systemctl daemon-reload || die "systemctl daemon-reload failed"
  # No fleet is made (#831): the floor's New fleet makes the first one.
  if [ -z "$(CREW_FLEETS_DIR="$data/fleets" fleet_dirs)" ]; then
    echo "  fleets: none yet — the floor's New fleet makes the first"
  else
    echo "  fleets: $(CREW_FLEETS_DIR="$data/fleets" fleet_dirs | cut -f1 | paste -sd' ' -)"
  fi
  if [ "$nostart" -eq 0 ]; then
    systemctl enable --now "$prefix-floor.service" "$prefix-tick.timer" "$prefix-restart.timer" "$prefix-reset.timer" ||
      die "systemctl enable --now failed"
    echo "  started: $prefix-floor.service and the tick, restart and reset timers"
    service_floor_current "$prefix"
  else
    echo "  not started (--no-start): systemctl enable --now $prefix-floor.service $prefix-{tick,restart,reset}.timer"
  fi
  echo
  echo "next:"
  echo "  sudo usermod -aG $group <you>        # then log in again: crew runs as $user for you"
  echo "  the floor: http://<this host>:$port/ — user and password in $etc/floor.env"
  echo "  the engine's GitHub App: the floor's Credentials → Engine (create one, or paste an existing App's ID and key)"
  if [ -z "$(CREW_FLEETS_DIR="$data/fleets" fleet_dirs)" ]; then
    echo "  then, in the floor: New fleet, add its members on Members, and Create each one"
  else
    echo "  your fleets are on the floor: Members (Create, Hire, Upgrade), Repositories, Credentials"
  fi
}

# service_floor_current PREFIX — a floor already running keeps the tree it
# started from: `systemctl enable --now` starts a stopped unit and leaves a
# running one alone. After an upgrade (the installer flips `current`), the
# floor would serve the previous version's code — and miss what the new one
# added — until the next reboot. The timers start a fresh process every run,
# so only the floor needs this. Its main process is the python `crew floor`
# exec'd, named by its versioned tree; one that is not THIS tree's is
# restarted, and said. One still starting (not yet python) is left alone.
service_floor_current() {
  local unit="$1-floor.service" proc="${CREW_SERVICE_PROC_DIR:-/proc}" pid cmd want old
  want="$CREW_ROOT/fleet-floor/server/floor.py"
  pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -r "$proc/$pid/cmdline" ] || return 0
  cmd="$(tr '\0' ' ' <"$proc/$pid/cmdline")"
  case "$cmd" in
    *"$want"*) return 0 ;;
    */fleet-floor/server/floor.py*) ;;
    *) return 0 ;;
  esac
  old="$(grep -o '[^ ]*/fleet-floor/server/floor.py' <<<"$cmd" | head -n1)"
  old="${old%/fleet-floor/server/floor.py}"
  systemctl restart "$unit" || die "systemctl restart $unit failed (it was running ${old:-another tree})"
  echo "  restarted: $unit — it was running ${old:-another tree}, now $CREW_ROOT"
}

service_check() { # [--unit-prefix P] — read-only; exit 1 on drift
  local prefix="" drift=0 u body etc="$CREW_ETC_DIR" user group cli data
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --unit-prefix) need_value "$@"; prefix="$2"; shift 2 ;;
      *) usage_error "unknown argument '$1' (usage: $(synopsis_of service))" ;;
    esac
  done
  ck() { if [ "$1" = ok ]; then echo "  ok     $2"; else echo "  DRIFT  $2"; drift=1; fi; }
  [ -f "$etc/service.conf" ] || { echo "  DRIFT  $etc/service.conf is missing — not a service host (sudo crew service setup)"; return 1; }
  user="$SERVICE_USER"; group="$SERVICE_GROUP"; cli="$SERVICE_CLI"; data="$CREW_DATA_DIR"
  [ -n "$prefix" ] || prefix="$(service_conf_value CREW_UNIT_PREFIX)"; prefix="${prefix:-crew}"
  echo "== crew service check (account $user, group $group, units $prefix-*)"
  if getent group "$group" >/dev/null 2>&1; then ck ok "group $group"; else ck no "group $group is missing"; fi
  if id -u "$user" >/dev/null 2>&1; then ck ok "account $user"; else ck no "account $user is missing"; fi
  if [ "$(stat -c '%U:%G' "$data" 2>/dev/null)" = "$user:$group" ]; then ck ok "$data owned by $user:$group"
  else ck no "$data is not owned by $user:$group ($(stat -c '%U:%G' "$data" 2>/dev/null || echo missing))"; fi
  if grep -qxF "%$group ALL=($user) NOPASSWD: $cli" "$SERVICE_SUDOERS_DIR/$prefix" 2>/dev/null; then ck ok "sudoers rule"
  else ck no "the sudoers rule $SERVICE_SUDOERS_DIR/$prefix is missing or changed"; fi
  if [ -f "$etc/floor.env" ]; then ck ok "$etc/floor.env"; else ck no "$etc/floor.env is missing"; fi
  while read -r u; do
    body="$(service_unit_body "$u" "$prefix" "$user" "$group" "$cli" "$etc" "$data")"
    if [ -f "$SERVICE_SYSTEMD_DIR/$u" ] && [ "$(cat "$SERVICE_SYSTEMD_DIR/$u")" = "$body" ]; then ck ok "unit $u"
    else ck no "unit $u is missing or changed (re-run setup)"; fi
  done < <(service_units "$prefix")
  for u in "$prefix-floor.service" "$prefix-tick.timer" "$prefix-restart.timer" "$prefix-reset.timer"; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then ck ok "$u active"; else ck no "$u is not active"; fi
  done
  if runuser -u "$user" -- box list </dev/null >/dev/null 2>&1; then ck ok "box grant: $user reaches its project"
  else ck no "$user cannot reach a box project (box grant --service $user)"; fi
  # The engine's GitHub App (#864): said, never drift — a fresh host has none
  # until the floor's Credentials → Engine gives it one.
  # Run from / (#885): the caller's working directory may be one the account
  # cannot enter, and a failure says its own last line instead of nothing.
  local eng eng_out
  eng_out="$(cd / && runuser -u "$user" -- env HOME="$data" "$cli" engine </dev/null 2>&1)" || true
  eng="$(grep -m1 '^engine: ' <<<"$eng_out")" || eng=""  # Decision-path empty fallback: a note, never drift; empty is said with crew engine's own words below
  [ -n "$eng" ] || eng="engine: crew engine did not answer ($(tail -n1 <<<"$eng_out" | cut -c1-200))"
  echo "  note   $eng"
  [ "$drift" -eq 0 ] && echo "service: clean" || echo "service: DRIFT — re-run: sudo crew service setup"
  return "$drift"
}

service_teardown() { # [--purge]
  local purge=0 etc="$CREW_ETC_DIR" prefix u pflag=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge) purge=1; shift ;;
      *) usage_error "unknown argument '$1' (usage: $(synopsis_of service))" ;;
    esac
  done
  [ "$purge" -eq 0 ] || pflag=" --purge"
  service_is_root || die "crew service teardown runs as root"
  [ -f "$etc/service.conf" ] || die "$etc/service.conf is missing — nothing to tear down"
  prefix="$(service_conf_value CREW_UNIT_PREFIX)"; prefix="${prefix:-crew}"
  echo "== crew service teardown (units $prefix-*$([ "$purge" -eq 0 ] || echo ", purge"))"
  # Units first: box refuses to revoke a service while a unit still runs as it.
  while read -r u; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    rm -f "$SERVICE_SYSTEMD_DIR/$u"
  done < <(service_units "$prefix")
  systemctl daemon-reload || true
  echo "  units: stopped and removed"
  rm -f "$SERVICE_SUDOERS_DIR/$prefix"; echo "  sudoers rule: removed"
  # `--purge` here IS the operator's confirmation: box asks again on a terminal
  # and refuses without one, so its consent (BOX_YES=1) goes with it (#858).
  local revoke_rc=0
  if [ "$purge" -eq 1 ]; then
    BOX_YES=1 box revoke "$SERVICE_USER" --purge </dev/null || revoke_rc=$?
  else
    box revoke "$SERVICE_USER" </dev/null || revoke_rc=$?
  fi
  if [ "$revoke_rc" -ne 0 ]; then
    # Stop BEFORE service.conf and the account go: a grant whose account was
    # deleted is an orphaned project no re-run could find. box's revoke exits 0
    # when nothing is left, so re-running teardown finishes the job.
    echo "  box grant: NOT revoked — box revoke $SERVICE_USER$pflag exited $revoke_rc (above)"
    die "teardown stopped: $etc/service.conf, the account and the data are kept — fix what box said, then re-run: sudo crew service teardown$pflag"
  fi
  echo "  box grant: revoked$([ "$purge" -eq 0 ] || echo ' (purged)')"
  rm -f "$etc/service.conf"; echo "  $etc/service.conf: removed — crew no longer runs as a service here"
  if [ "$purge" -eq 1 ]; then
    userdel "$SERVICE_USER" 2>/dev/null || true
    groupdel "$SERVICE_GROUP" 2>/dev/null || true
    rm -rf -- "${CREW_DATA_DIR:?}" "$etc/floor.env"
    echo "  account, group, $CREW_DATA_DIR and floor.env: removed"
  else
    echo "  kept: account $SERVICE_USER, group $SERVICE_GROUP, $CREW_DATA_DIR, $etc/floor.env (--purge removes them)"
  fi
}

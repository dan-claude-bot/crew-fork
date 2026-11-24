#!/usr/bin/env bash
# drill/memory-budget.sh — the drill host's memory, read before boxes are
# minted on it (#845). Sourced by rehearsal-all.sh; defines functions only.
#
# The rc14 round minted triage (4GiB), builder (8GiB) and reviewer (8GiB) at
# once on a 12GiB host with no swap. A qemu guest's memory is shared memory
# the host cannot reclaim once the guest has touched it, and three converging
# boxes touch all of theirs: the kernel OOM-killed the reviewer's qemu, and the
# round read it as "rig did not converge it" with nothing naming memory.
#
# Three things follow, one function each:
#   parallel_waves   — --parallel runs the roles in waves that fit the host;
#   mem_short_for    — a leg that mints a box later checks what is free first;
#   oom_kills_since  — a qemu the kernel killed is named, not inferred.
#
# Every figure is MiB. Knobs, for a host that needs them and for the tests:
#   REHEARSAL_HOST_MEM_MIB     the host's total (default: MemTotal)
#   REHEARSAL_HOST_AVAIL_MIB   what is free now (default: MemAvailable)
#   REHEARSAL_HOST_HEADROOM_MIB  what the host keeps for itself (default 2048)

budget_headroom_mib() { printf '%s\n' "${REHEARSAL_HOST_HEADROOM_MIB:-2048}"; }

# mem_to_mib SIZE — 4GiB, 4G, 512MiB, 512M → MiB; anything else prints nothing.
mem_to_mib() {
  local v="${1// /}"
  case "$v" in
    *[0-9]GiB|*[0-9]GB|*[0-9]G) v="${v%%[GgBi]*}"; [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$((v * 1024))" ;;
    *[0-9]MiB|*[0-9]MB|*[0-9]M) v="${v%%[MmBi]*}"; [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v" ;;
    *) return 0 ;;
  esac
  return 0
}

# mib_human MIB — 4096 → 4GiB, 1536 → 1.5GiB, 512 → 512MiB.
mib_human() {
  if [ "$1" -lt 1024 ]; then printf '%sMiB\n' "$1"
  elif [ $(($1 % 1024)) -eq 0 ]; then printf '%sGiB\n' "$(($1 / 1024))"
  else printf '%s.%sGiB\n' "$(($1 / 1024))" "$(( ($1 % 1024) * 10 / 1024 ))"
  fi
}

# role_box_mib TREE ROLE — the BOX_MEMORY the role conf declares, in MiB, read
# in a subshell exactly as rehearsal.sh sizes the box (#607 D4). Empty when the
# conf is missing or names no size.
role_box_mib() {
  local conf="$1/shared/conf/roles/$2.conf" size
  [ -f "$conf" ] || return 0
  size="$(bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${BOX_MEMORY:-}"' _ "$conf" 2>/dev/null)" || return 0
  mem_to_mib "$size"
}

meminfo_mib() { # FIELD — /proc/meminfo's kB figure for FIELD, in MiB
  awk -v f="$1:" '$1 == f { print int($2 / 1024); exit }' /proc/meminfo 2>/dev/null
}
host_mem_mib()   { printf '%s\n' "${REHEARSAL_HOST_MEM_MIB:-$(meminfo_mib MemTotal)}"; }
host_avail_mib() { printf '%s\n' "${REHEARSAL_HOST_AVAIL_MIB:-$(meminfo_mib MemAvailable)}"; }

# parallel_waves TOTAL_MIB ROLE:MIB… — one wave per line, roles in the order
# given. Each role goes into the first wave that still has room under
# TOTAL minus headroom; a role larger than that alone gets a wave of its own,
# which is what a serial round would do with it. A role with no size, or an
# unknown total, puts everything in one wave: a budget that cannot be read
# says nothing, and the round runs as it did before #845.
parallel_waves() {
  local total="$1"; shift
  local budget pair role mib i placed n=0
  local -a wave_roles=() wave_used=()
  budget=$(( ${total:-0} - $(budget_headroom_mib) ))
  local all="" known=1
  [[ "${total:-}" =~ ^[0-9]+$ ]] || known=0
  for pair in "$@"; do
    all="$all${all:+ }${pair%%:*}"
    [[ "${pair#*:}" =~ ^[0-9]+$ ]] || known=0
  done
  if [ "$known" -eq 0 ]; then printf '%s\n' "$all"; return 0; fi
  for pair in "$@"; do
    role="${pair%%:*}" mib="${pair#*:}" placed=0
    for ((i = 0; i < n; i++)); do
      if [ $((wave_used[i] + mib)) -le "$budget" ]; then
        wave_roles[i]="${wave_roles[i]} $role"; wave_used[i]=$((wave_used[i] + mib)); placed=1; break
      fi
    done
    if [ "$placed" -eq 0 ]; then
      wave_roles[n]="$role"; wave_used[n]="$mib"; n=$((n + 1))
    fi
  done
  for ((i = 0; i < n; i++)); do printf '%s\n' "${wave_roles[i]}"; done
}

# mem_short_for NEED_MIB — prints why and returns 0 when the host has less
# free than NEED plus headroom; returns 1 (prints nothing) when it fits or
# when nothing could be read.
mem_short_for() {
  local need="$1" avail head
  avail="$(host_avail_mib)"; head="$(budget_headroom_mib)"
  [[ "$avail" =~ ^[0-9]+$ ]] && [[ "$need" =~ ^[0-9]+$ ]] || return 1
  [ "$avail" -lt $((need + head)) ] || return 1
  printf 'host memory: %s free, the box needs %s plus %s headroom\n' \
    "$(mib_human "$avail")" "$(mib_human "$need")" "$(mib_human "$head")"
}

# oom_kills_since EPOCH — the kernel's "Killed process … (qemu-system…)" lines
# since EPOCH, one per kill. The kernel log is read with journalctl, then
# sudo -n journalctl; a host that lets neither read it prints nothing.
oom_kills_since() {
  local since="@$1" out
  out="$(journalctl -k -q --no-pager --since "$since" 2>/dev/null)" \
    || out="$(sudo -n journalctl -k -q --no-pager --since "$since" 2>/dev/null)" \
    || out=""
  grep -E 'Killed process [0-9]+ \(qemu-system' <<<"$out" || true
}

#!/usr/bin/env bash
# Snapshot and restore the box state borrowed by install-drill.sh. The caller
# supplies bx(), which executes one shell body inside the drill box.

INSTALL_BORROWED_SNAPSHOT_TAKEN=0
INSTALL_BORROWED_REPOS_STATE=""
# A basename keeps the path safe to interpolate into the remote shell while
# leaving that shell (not the host) responsible for resolving ~/duty.
# shellcheck disable=SC2034  # named by install-drill.sh's recovery message
INSTALL_BORROWED_REPOS_BACKUP=".repos.txt.install-drill.$$"
# shellcheck disable=SC2034  # read by the sourcing driver after helper calls
INSTALL_BORROWED_DETAIL=""
# EVERY FILE SECTION A'S HIRE REWRITES, NOT ONLY repos.txt (#801). Its
# `crew hire --force` runs install.sh with --converge-registries, which
# rewrites both registries AND their provenance records. Restoring only the
# repos.txt bytes left a provenance hash naming the hire's payload over the
# pre-hire bytes, so every later `crew upgrade` read the box as locally
# diverged and left its registry unchanged — the veto working as designed on
# a state the drill had made. Each file is snapshotted present or absent and
# put back exactly so.
INSTALL_BORROWED_FILES=(repos.txt .repos.txt.crew-provenance notify-repos.txt .notify-repos.txt.crew-provenance)
INSTALL_BORROWED_STATES=()
install_borrowed_backup_name() { printf '.%s.install-drill.%s' "${1#.}" "$$"; }

install_borrowed_box_snapshot() {
  local out f state script="" i
  INSTALL_BORROWED_REPOS_STATE=""
  INSTALL_BORROWED_STATES=()
  for f in "${INSTALL_BORROWED_FILES[@]}"; do
    script="${script}if [ -e ~/duty/$f ]; then cp ~/duty/$f ~/duty/$(install_borrowed_backup_name "$f") || exit 1; printf 'present\\n'; else printf 'absent\\n'; fi
"
  done
  # Classify and copy in one successful remote invocation. An outer `box
  # exec` failure may also return 1, so its status alone never means absent.
  out="$(bx "$script")" || {
    INSTALL_BORROWED_DETAIL="could not read and snapshot ~/duty/repos.txt and its companions"
    return 1
  }
  i=0
  while IFS= read -r state; do
    case "$state" in
      present|absent) INSTALL_BORROWED_STATES+=("$state") ;;
      *)
        INSTALL_BORROWED_DETAIL="could not classify ~/duty/${INSTALL_BORROWED_FILES[$i]} as present or absent"
        INSTALL_BORROWED_STATES=()
        return 1 ;;
    esac
    i=$((i + 1))
  done <<<"$out"
  if [ "${#INSTALL_BORROWED_STATES[@]}" -ne "${#INSTALL_BORROWED_FILES[@]}" ]; then
    INSTALL_BORROWED_DETAIL="could not classify every registry file as present or absent"
    INSTALL_BORROWED_STATES=()
    return 1
  fi
  # shellcheck disable=SC2034  # read by the sourcing driver and its suite
  INSTALL_BORROWED_REPOS_STATE="${INSTALL_BORROWED_STATES[0]}"
  INSTALL_BORROWED_SNAPSHOT_TAKEN=1
}

install_borrowed_box_disarm() {
  # Keep unrelated cron entries, and keep an absent crontab absent. The
  # locale-pinned no-table diagnostic is the only failed read that proves
  # absence; every other error is indeterminate and must preserve the table.
  # shellcheck disable=SC2016  # expanded by bash inside the box
  bx 'current=$(mktemp) || exit 1
      filtered=$(mktemp) || { rm -f -- "$current"; exit 1; }
      error=$(mktemp) || { rm -f -- "$current" "$filtered"; exit 1; }
      if LC_ALL=C crontab -l >"$current" 2>"$error"; then
        grep -vF "/duty/bin/tick.sh" "$current" >"$filtered" || true
        crontab "$filtered"; rc=$?
      else
        rc=$?
        if [ "$rc" -eq 1 ] && grep -q "^no crontab for " "$error"; then
          rc=0
        fi
      fi
      rm -f -- "$current" "$filtered" "$error"
      exit "$rc"'
}

install_borrowed_box_restore() {
  local i f
  [ "$INSTALL_BORROWED_SNAPSHOT_TAKEN" -eq 1 ] || return 0
  INSTALL_BORROWED_DETAIL=""
  install_borrowed_box_disarm || {
    INSTALL_BORROWED_DETAIL="could not remove duty tick.sh from the borrowed box's crontab"
    return 1
  }
  for i in "${!INSTALL_BORROWED_FILES[@]}"; do
    f="${INSTALL_BORROWED_FILES[$i]}"
    case "${INSTALL_BORROWED_STATES[$i]:-}" in
      present)
        bx "cp ~/duty/$(install_borrowed_backup_name "$f") ~/duty/$f" || {
          INSTALL_BORROWED_DETAIL="could not restore the borrowed box's ~/duty/$f"
          return 1
        } ;;
      absent)
        bx "rm -f -- ~/duty/$f" || {
          INSTALL_BORROWED_DETAIL="could not restore the borrowed box's absent ~/duty/$f state"
          return 1
        } ;;
      *)
        INSTALL_BORROWED_DETAIL="the borrowed box's registry snapshot state is unknown"
        return 1 ;;
    esac
  done
}

install_borrowed_box_verify() {
  local cron_state
  # An explicit answer from a successful remote invocation keeps transport or
  # read failures distinct from a proven absent/disarmed table.
  # shellcheck disable=SC2016  # expanded by bash inside the box
  cron_state="$(bx 'tmp=$(mktemp) || exit 1
                     error=$(mktemp) || { rm -f -- "$tmp"; exit 1; }
                     if LC_ALL=C crontab -l >"$tmp" 2>"$error"; then
                       if grep -F "/duty/bin/tick.sh" "$tmp" >/dev/null; then
                         printf "armed\\n"
                       else
                         printf "disarmed\\n"
                       fi
                     else
                       rc=$?
                       [ "$rc" -eq 1 ] && grep -q "^no crontab for " "$error" ||
                         { rm -f -- "$tmp" "$error"; exit "$rc"; }
                       printf "absent\\n"
                     fi
                     rm -f -- "$tmp" "$error"')" || {
    INSTALL_BORROWED_DETAIL="could not read the borrowed box's crontab"
    return 1
  }
  case "$cron_state" in
    disarmed|absent) ;;
    armed)
      INSTALL_BORROWED_DETAIL="the borrowed box is still armed"
      return 1 ;;
    *)
      INSTALL_BORROWED_DETAIL="could not classify the borrowed box's crontab state"
      return 1 ;;
  esac
  local i f
  for i in "${!INSTALL_BORROWED_FILES[@]}"; do
    f="${INSTALL_BORROWED_FILES[$i]}"
    case "${INSTALL_BORROWED_STATES[$i]:-}" in
      present)
        bx "cmp -s ~/duty/$(install_borrowed_backup_name "$f") ~/duty/$f" || {
          INSTALL_BORROWED_DETAIL="the borrowed box's ~/duty/$f differs from its pre-Section-A bytes"
          return 1
        } ;;
      absent)
        bx "test ! -e ~/duty/$f" || {
          # shellcheck disable=SC2034  # read by the sourcing driver
          INSTALL_BORROWED_DETAIL="Section A created ~/duty/$f on a box that arrived without one"
          return 1
        } ;;
    esac
  done
}

install_borrowed_box_discard_snapshot() {
  local i
  [ "$INSTALL_BORROWED_SNAPSHOT_TAKEN" -eq 1 ] || return 0
  for i in "${!INSTALL_BORROWED_FILES[@]}"; do
    if [ "${INSTALL_BORROWED_STATES[$i]:-}" = present ]; then
      bx "rm -f -- ~/duty/$(install_borrowed_backup_name "${INSTALL_BORROWED_FILES[$i]}")" || return 1
    fi
  done
  INSTALL_BORROWED_SNAPSHOT_TAKEN=0
}

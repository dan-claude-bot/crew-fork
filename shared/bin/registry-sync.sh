#!/usr/bin/env bash
# registry-sync.sh — converge this box's registries on the seeds the host just
# staged (#886). The host tick re-stages a member's fleet definition on every
# wake (cli/crew tick_restage), so a registry the operator changed after hire
# reaches the box then, not only at its next upgrade. The rule is install.sh's
# own (lib/registry-apply.sh): a copy the box changed locally is LEFT
# UNCHANGED and said. Nothing staged: nothing to do, exit 0.
set -euo pipefail
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
# shellcheck disable=SC2034  # read by lib/registry-apply.sh
CONVERGE_REGISTRIES=1
# shellcheck disable=SC2034  # read by lib/registry-apply.sh
BOX_ARG="${BOX_ARG:-}"
# shellcheck source=../lib/registry-apply.sh disable=SC1091
. "$DUTY_DIR/lib/registry-apply.sh"
seed="$DUTY_DIR/.crew-seed-repos.txt" example="$DUTY_DIR/.crew-example-repos.txt"
nseed="$DUTY_DIR/.crew-seed-notify-repos.txt" nexample="$DUTY_DIR/.crew-example-notify-repos.txt"
if [ ! -f "$seed" ] || [ ! -f "$example" ]; then
  echo "registry-sync: nothing staged"
  exit 0
fi
apply_registry "$seed" "$DUTY_DIR/repos.txt" "$example" "$DUTY_DIR/.repos.txt.crew-provenance" repos.txt
# The notify registry is triage's: converged where the box holds one.
if [ -f "$DUTY_DIR/notify-repos.txt" ] && [ -f "$nseed" ] && [ -f "$nexample" ]; then
  apply_registry "$nseed" "$DUTY_DIR/notify-repos.txt" "$nexample" "$DUTY_DIR/.notify-repos.txt.crew-provenance" notify-repos.txt
fi
rm -f "$seed" "$nseed" "$example" "$nexample"
# Agent profiles are staged beside the registries but converge only with an
# engine install (hire, upgrade); the wake's copy is not left lying about.
rm -rf "$DUTY_DIR/.crew-seed-agents"

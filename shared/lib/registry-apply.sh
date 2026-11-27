# shared/lib/registry-apply.sh — a box's registries converge on what the host
# staged, under the per-box veto (moved out of install.sh, #886). An untouched
# copy follows the host; a locally changed copy is containment state and is
# never widened. Sourced by install.sh (hire, upgrade) and bin/registry-sync.sh
# (the host tick's re-stage on every wake).
#
# Reads: DUTY_DIR, CONVERGE_REGISTRIES (1: converge with provenance; 0: seed a
# missing file only), BOX_ARG (optional, for messages).
#
# shellcheck shell=bash

replace_registry() { # SOURCE DESTINATION PROVENANCE
  local src="$1" dest="$2" provenance="$3" tmp hash_tmp incoming_hash
  incoming_hash="$(sha256sum "$src" | awk '{print $1}')"
  tmp="$(mktemp "$DUTY_DIR/.registry.XXXXXX")"
  cp "$src" "$tmp"
  mv "$tmp" "$dest"
  hash_tmp="$(mktemp "$DUTY_DIR/.registry-hash.XXXXXX")"
  printf '%s\n' "$incoming_hash" >"$hash_tmp"
  mv "$hash_tmp" "$provenance"
}

apply_registry() { # PAYLOAD DESTINATION SHIPPED_EXAMPLE PROVENANCE LABEL
  local payload="$1" dest="$2" example="$3" provenance="$4" label="$5"
  local current_hash incoming_hash recorded_hash example_hash
  if [ "$CONVERGE_REGISTRIES" -eq 0 ]; then
    if [ ! -f "$dest" ]; then cp "$payload" "$dest"; echo "seeded $dest"; fi
    return
  fi
  command -v sha256sum >/dev/null || { echo "sha256sum not found — registry provenance requires it"; exit 1; }
  incoming_hash="$(sha256sum "$payload" | awk '{print $1}')"
  if [ ! -f "$dest" ]; then
    replace_registry "$payload" "$dest" "$provenance"
    echo "converged $dest from the operator fleet definition"
    return
  fi
  current_hash="$(sha256sum "$dest" | awk '{print $1}')"
  if [ -f "$provenance" ]; then
    recorded_hash="$(head -1 "$provenance")"
    if [ "$current_hash" = "$recorded_hash" ] || [ "$current_hash" = "$incoming_hash" ]; then
      replace_registry "$payload" "$dest" "$provenance"
      if [ "$current_hash" = "$incoming_hash" ] && [ "$current_hash" != "$recorded_hash" ]; then
        echo "adopted and converged $dest from the operator fleet definition"
      else
        echo "converged $dest from the operator fleet definition"
      fi
      return
    fi
  else
    example_hash="$(sha256sum "$example" | awk '{print $1}')"
    if [ "$current_hash" = "$example_hash" ] || [ "$current_hash" = "$incoming_hash" ]; then
      replace_registry "$payload" "$dest" "$provenance"
      echo "adopted and converged $dest from the operator fleet definition"
      return
    fi
  fi
  echo "crew: ${BOX_ARG:-this box}: $label diverged from its last transported value — LEFT UNCHANGED" >&2
  echo "crew: to adopt it, make $dest byte-identical to the host's $label and run crew upgrade again" >&2
}

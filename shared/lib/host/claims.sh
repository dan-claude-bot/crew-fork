# shared/lib/host/claims.sh — hand an unhired member's claims back (#898).
#
# Off duty means the member's work goes back to the board for another member
# to take: every open issue it holds — labelled claimed and assigned to its
# own login — is unassigned and swapped claimed → ready, with one comment
# saying why. An issue whose work is already a pull request the member opened
# (a build/<issue>-* head) is NOT released: the pull request is the member's,
# and another member cannot push to it. It stays claimed and is named, so the
# operator closes or hands it over.
#
# Fired INTO the box with `box exec`, as the member (its gh login, the only
# account that may unassign itself without a maintainer's token), from the
# host — like pause.sh and credentials.sh, the shell lives here so the host
# owns it. stdin: the repositories, one per line, then a line `--`, then the
# labels: `<claimed> <ready>`. Prints one line per issue and a last line
# `released N kept M`; rc 0 when every issue was answered, 1 otherwise.
#
# shellcheck shell=bash

host_release_claims_sh() {
  cat <<'RELEASE_CLAIMS_SH'
# ---RELEASE_CLAIMS_SH---
repos=()
while IFS= read -r line; do
  [ "$line" = "--" ] && break
  [ -n "$line" ] && repos+=("$line")
done
read -r claimed ready _ || { echo "claims: no labels arrived — nothing released" >&2; exit 2; }
me="$(gh api user --jq .login 2>/dev/null)" || me=""
[ -n "$me" ] || { echo "claims: this box has no working GitHub login — nothing released (set it, or release by hand)"; exit 1; }
released=0; kept=0; failed=0
for repo in "${repos[@]}"; do
  nums="$(gh issue list -R "$repo" --state open --label "$claimed" --assignee "$me" --limit 100 --json number --jq '.[].number' 2>/dev/null)" \
    || { echo "  $repo: its issues could not be read — nothing released there"; failed=$((failed + 1)); continue; }
  heads="$(gh pr list -R "$repo" --state open --author "$me" --limit 100 --json headRefName,number --jq '.[] | "\(.headRefName) \(.number)"' 2>/dev/null || true)"
  for n in $nums; do
    pr="$(printf '%s\n' "$heads" | awk -v n="$n" 'index($1, "build/" n "-") == 1 { print $2; exit }')"
    if [ -n "$pr" ]; then
      echo "  $repo#$n: kept — its work is $me's pull request #$pr; close it or hand it over"
      kept=$((kept + 1)); continue
    fi
    if gh issue edit "$n" -R "$repo" --remove-assignee "$me" --remove-label "$claimed" --add-label "$ready" >/dev/null 2>&1; then
      gh issue comment "$n" -R "$repo" --body "Released: the operator took @$me off duty, so this goes back to \`$ready\` for another member to take." >/dev/null 2>&1 || true
      echo "  $repo#$n: released — back to $ready"
      released=$((released + 1))
    else
      echo "  $repo#$n: could NOT be released — still claimed by $me"
      failed=$((failed + 1))
    fi
  done
done
echo "released $released kept $kept"
[ "$failed" -eq 0 ]
# ---END---
RELEASE_CLAIMS_SH
}

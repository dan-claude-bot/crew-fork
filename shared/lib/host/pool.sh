# shared/lib/host/pool.sh — the host credential pool (#774).
#
# #765 made a member's credentials settable from the host, write-only. This is
# the layer above it: a credential is stored ONCE on the host, named, assigned
# to members in the roster (`creds=gh:<name>,agent:<name>`), and the system
# carries it to every member it is assigned to — when the member is hired,
# when the host tick wakes it, when a reset re-mints it, and at once to every
# running member when the entry is rotated. One `claude setup-token` for a
# whole crew is one paste, and its rotation is one more.
#
# WRITE-ONLY, LIKE #765. A secret goes in on stdin and comes out only on its
# way into a box, through #765's one credentials shell (host_credentials_set_sh
# over bxpipe, stdin only). No function here prints a secret, and the listing
# answers names, kinds, the login a gh entry answers as, who it is assigned to
# and the last verdict per member — never the value.
#
# THE LAYOUT, under the operator's fleet definition (mode 0700, files 0600):
#
#   credentials/entries/<svc>--<name>/secret   the value, exactly as given
#   credentials/entries/<svc>--<name>/meta     svc= kind= agent= login= set_at= digest=
#   credentials/delivered/<box>                <entry> <digest>, one per entry
#   credentials/verdicts/<box>                 <entry> <ts> <ok|fail> <verdict>
#
# `digest` is the sha256 of the secret: what tells a member holding an older
# value from one holding the current one, so a rotation reaches a sleeping
# member on its next wake and a running one at once. It is a hash of a
# high-entropy token, kept on the host beside the token itself.
#
# THE gh RULE IS PER REPOSITORY (operator ruling on #774, 2026-11-21). One gh
# entry may feed several members only while their repositories do not
# overlap: the engine keys claims, "my PRs" and the panel on the login, and
# GitHub refuses an author's own review, so two members answering as one login
# on one repository read each other's work as their own and cannot review
# each other. A member's repositories are its per-box selection
# (repos.d/<box>.txt) where it has one, the fleet's repos.txt where it does
# not — the same layering the floor's registry editor writes.
#
# TELEGRAM (#788). A `tg:<name>` entry is a bot token: the operator channel a
# box notifies through (shared/bin/notify.sh reads ~/.tg_bot_token and
# ~/.tg_chat_id). Bots are entries like any other — several may live in the
# pool, each member is assigned one, and any number of members may share one.
# The CHAT is not per entry: it is the fleet's one group chat (operator ruling
# on #788), stored once beside the entries (credentials/tg-chat, not a secret)
# and delivered with whichever bot a member holds. A changed chat makes every
# tg holder owe its value again, because the digest a member is compared on
# covers the token and the chat together.
#
# CREW_CREDENTIALS_DIR overrides where the pool lives: the drill points a
# round's throwaway fleet definition at the operator's own pool with it, so
# the round logs its boxes in from the pool without ever writing the
# operator's roster.
#
# shellcheck shell=bash

POOL_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

pool_dir() { printf '%s' "${CREW_CREDENTIALS_DIR:-$CONFIG_DIR/credentials}"; }

pool_init() {
  local d
  d="$(pool_dir)"
  ( umask 077; mkdir -p "$d/entries" "$d/delivered" "$d/verdicts" ) || return 1
  chmod 700 "$d" "$d/entries" "$d/delivered" "$d/verdicts" 2>/dev/null || true
}

# pool_entry_valid ID — `gh:<name>` or `agent:<name>`, the name a safe token.
pool_entry_valid() {
  local svc="${1%%:*}" name="${1#*:}"
  case "$1" in *:*) ;; *) return 1 ;; esac
  case "$svc" in gh|agent|tg) ;; *) return 1 ;; esac
  [[ "$name" =~ $POOL_NAME_RE ]]
}

pool_entry_path() { printf '%s/entries/%s--%s' "$(pool_dir)" "${1%%:*}" "${1#*:}"; }
pool_entry_exists() { [ -f "$(pool_entry_path "$1")/secret" ]; }

# pool_meta ID FIELD — one field of the entry's record, or nothing.
pool_meta() {
  sed -n "s/^$2=//p" "$(pool_entry_path "$1")/meta" 2>/dev/null | head -1
}

pool_digest() { printf '%s' "$1" | sha256sum | cut -c1-64; }

# The fleet's Telegram group chat (#788): a chat id, negative for a group.
# shellcheck disable=SC2034  # read by cli/crew's `crew creds chat`
POOL_TG_CHAT_RE='^-?[0-9]{1,20}$'
pool_tg_chat() { head -1 "$(pool_dir)/tg-chat" 2>/dev/null | tr -d '\r\n'; }
pool_tg_chat_set() { # CHAT
  local f tmp
  pool_init || return 1
  f="$(pool_dir)/tg-chat"
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  if ! { printf '%s\n' "$1" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"; }; then
    rm -f "$tmp"; return 1
  fi
}

# pool_want_digest ID — what a member holding ID's current value was sent:
# the secret's digest, and for a tg entry the chat's beside it.
pool_want_digest() {
  local d
  d="$(pool_meta "$1" digest)"
  [ -n "$d" ] || return 0
  if [ "${1%%:*}" = tg ]; then pool_digest "$d:$(pool_tg_chat)"; else printf '%s' "$d"; fi
}

# pool_put ID KIND AGENT LOGIN — the secret on stdin, written atomically,
# 0600, with its record. A rotation is a put over an existing entry.
pool_put() {
  local id="$1" kind="$2" agent="$3" login="$4" dir secret tmp
  pool_init || return 1
  dir="$(pool_entry_path "$id")"
  secret="$(cat)"
  [ -n "$secret" ] || return 2
  ( umask 077; mkdir -p "$dir" ) || return 1
  tmp="$(mktemp "$dir/.secret.XXXXXX")" || return 1
  if ! { printf '%s' "$secret" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dir/secret"; }; then
    rm -f "$tmp"; return 1
  fi
  tmp="$(mktemp "$dir/.meta.XXXXXX")" || return 1
  if ! { printf 'svc=%s\nkind=%s\nagent=%s\nlogin=%s\nset_at=%s\ndigest=%s\n' \
      "${id%%:*}" "$kind" "$agent" "$login" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(pool_digest "$secret")" \
      >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dir/meta"; }; then
    rm -f "$tmp"; return 1
  fi
  secret=""
}

pool_entries() {
  local d f base
  d="$(pool_dir)/entries"
  [ -d "$d" ] || return 0
  for f in "$d"/*--*/secret; do
    [ -f "$f" ] || continue
    base="${f%/secret}"; base="${base##*/}"
    printf '%s:%s\n' "${base%%--*}" "${base#*--}"
  done
}

# roster_creds_of NAME — the member's assigned entries, one per line, read
# raw from the roster line's `creds=` token (read_roster strips it, so no
# positional reader of the roster ever sees it).
roster_creds_of() {
  grep -vE '^[[:space:]]*(#|$)' "$ROSTER" 2>/dev/null \
    | awk -v n="$1" '$1 == n { for (i = 4; i <= NF; i++) if ($i ~ /^creds=/) { sub(/^creds=/, "", $i); print $i } exit }' \
    | tr ',' '\n' | sed '/^$/d'
}

# pool_members_of ID — every roster member assigned this entry.
pool_members_of() {
  local name
  while read -r name _; do
    grep -qxF -- "$1" <<<"$(roster_creds_of "$name")" && printf '%s\n' "$name"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$ROSTER" 2>/dev/null)
  return 0
}

# pool_repos_of NAME — the repositories a member works: its per-box selection
# where it has one (kept only where the fleet's list still names them, as the
# floor's `effective` reads it), the fleet's repos.txt where it does not.
pool_repos_of() {
  local fleet="$CONFIG_DIR/repos.txt" own="$CONFIG_DIR/repos.d/$1.txt" all
  all="$(grep -vE '^[[:space:]]*(#|$)' "$fleet" 2>/dev/null | awk '{print $1}' | sort -u)"
  if [ -f "$own" ]; then
    comm -12 <(grep -vE '^[[:space:]]*(#|$)' "$own" | awk '{print $1}' | sort -u) <(printf '%s\n' "$all" | sed '/^$/d')
  else
    printf '%s\n' "$all" | sed '/^$/d'
  fi
}

# pool_gh_conflict NAME ID — for a gh entry, the first other member assigned
# it whose repositories overlap NAME's, as `<member> <repo>[,<repo>…]`.
# Nothing when the entry may be shared.
pool_gh_conflict() {
  local name="$1" id="$2" other shared mine
  [ "${id%%:*}" = gh ] || return 0
  mine="$(pool_repos_of "$name")"
  while read -r other; do
    if [ -z "$other" ] || [ "$other" = "$name" ]; then continue; fi
    shared="$(comm -12 <(printf '%s\n' "$mine" | sed '/^$/d' | sort -u) \
      <(pool_repos_of "$other" | sort -u) | paste -sd, -)"
    if [ -n "$shared" ]; then
      printf '%s %s\n' "$other" "$shared"
      return 0
    fi
  done < <(pool_members_of "$id")
  return 0
}

# pool_record_verdict BOX ID OK VERDICT — the member's last word on the entry.
pool_record_verdict() {
  local f
  pool_init || return 0
  f="$(pool_dir)/verdicts/$1"
  { grep -v -- "^$2 " "$f" 2>/dev/null
    printf '%s %s %s %s\n' "$2" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$3" "$4"
  } >"$f.tmp" && mv -f "$f.tmp" "$f"
}

pool_record_delivered() {
  local f
  f="$(pool_dir)/delivered/$1"
  { grep -v -- "^$2 " "$f" 2>/dev/null; printf '%s %s\n' "$2" "$3"; } >"$f.tmp" && mv -f "$f.tmp" "$f"
}

# pool_forget_delivered BOX SVC — the box no longer holds any entry of SVC (its
# login was removed, #898): the next fan-out sends it again.
pool_forget_delivered() {
  local f
  f="$(pool_dir)/delivered/$1"
  [ -f "$f" ] || return 0
  { grep -v -- "^$2:" "$f" 2>/dev/null || true; } >"$f.tmp" && mv -f "$f.tmp" "$f"
}

# pool_is_stale BOX ID — the member does not hold the entry's current value.
pool_is_stale() {
  local want have
  want="$(pool_want_digest "$2")"
  have="$(awk -v e="$2" '$1 == e {print $2; exit}' "$(pool_dir)/delivered/$1" 2>/dev/null)"
  [ "$want" != "$have" ]
}

# pool_send BOX ID ACTOR — one entry onto one running box, through #765's
# credentials shell. Prints the box's verdict line; rc 0 set, 1 refused.
pool_send() {
  local box="$1" id="$2" actor="$3" svc kind secret verdict rc=0 digest header
  svc="${id%%:*}"
  kind="$(pool_meta "$id" kind)"
  digest="$(pool_want_digest "$id")"
  header="$svc $kind"
  if [ "$svc" = tg ]; then
    header="$header $(pool_tg_chat)"
    if [ -z "$(pool_tg_chat)" ]; then
      verdict="the fleet has no Telegram group chat yet (crew creds chat <id>) — nothing set"
      pool_record_verdict "$box" "$id" fail "$verdict"
      printf '%s\n' "$verdict"
      return 1
    fi
  fi
  secret="$(cat "$(pool_entry_path "$id")/secret" 2>/dev/null)" || secret="" # Decision-path empty fallback: an unreadable entry sets nothing and is refused just below
  if [ -z "$secret" ] || [ -z "$kind" ]; then
    verdict="the pool entry $id could not be read — nothing set"
    pool_record_verdict "$box" "$id" fail "$verdict"
    printf '%s\n' "$verdict"
    return 1
  fi
  verdict="$(bxpipe "$box" "$(host_credentials_set_sh)" "$(printf '%s\n%s\n' "$header" "$secret")" 2>&1 \
    | tr -d '\r' | tail -1)" || rc=$?
  secret=""
  [ "$rc" -ne 0 ] || case "$verdict" in *"NOT logged in"*|*refused*|*"nothing set"*) rc=1 ;; esac
  if [ "$rc" -eq 0 ]; then
    pool_record_delivered "$box" "$id" "$digest"
    pool_record_verdict "$box" "$id" ok "${verdict:-set}"
    # A login set again lifts the operator's removal of it (#898).
    ! declare -F logout_lift >/dev/null || logout_lift "$box" "$svc"
  else
    pool_record_verdict "$box" "$id" fail "${verdict:-no answer from the box}"
  fi
  printf '%s actor=%s box=%s service=%s kind=%s entry=%s ok=%s verdict=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$actor" "$box" "$svc" "$kind" "$id" \
    "$([ "$rc" -eq 0 ] && echo yes || echo no)" "${verdict:-none}" \
    >>"$CONFIG_DIR/.credentials-journal.log" 2>/dev/null || true
  printf '%s\n' "${verdict:-no answer from the box}"
  [ "$rc" -eq 0 ]
}

# pool_fanout BOX MODE ACTOR [ENTRIES] — every assigned entry (or the comma
# list ENTRIES) onto a running box: MODE `all` sends each, `stale` only those
# the box does not hold at their current value. One line per entry sent;
# silent when nothing was owed. rc 1 when any entry was refused.
pool_fanout() {
  local box="$1" mode="$2" actor="$3" list="${4:-}" id verdict rc=0
  if [ -z "$list" ]; then list="$(roster_creds_of "$box" | paste -sd, -)"; fi
  [ -n "$list" ] || return 0
  for id in ${list//,/ }; do
    if ! pool_entry_valid "$id" || ! pool_entry_exists "$id"; then
      echo "  $box: credential $id: no such pool entry — nothing set"
      rc=1; continue
    fi
    [ "$mode" = all ] || pool_is_stale "$box" "$id" || continue
    if verdict="$(pool_send "$box" "$id" "$actor")"; then
      echo "  $box: credential $id: $verdict"
    else
      echo "  $box: credential $id: REFUSED — $verdict"
      rc=1
    fi
  done
  return "$rc"
}

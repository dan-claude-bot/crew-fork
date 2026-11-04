# shared/lib/host/credentials.sh — the one copy of the credentials shell
# (#765). A member's GitHub login and its agent's login are SET from the host
# — `crew login` and the floor's credentials-set — and never read back: the
# secret travels as stdin into `box exec`, lands where its own CLI reads it
# (0600, atomically), and the reply is the box's verdict alone. cli/crew
# sources this file; the floor's actions.py reads the blocks between the
# markers below, as it reads pause.sh, so there is exactly one copy.
#
# Kinds are the agent profile's (AGENT_CRED_KINDS in conf/agents/<agent>.conf,
# `kind:how:where`), read by the BOX from its own engine's profile:
#   env:VAR        exported from ~/.config/crew/credentials.env, which tick.sh
#                  and every login shell source
#   file:PATH      a file under $HOME, JSON-checked
#   file-fn:FN     a file at the path the profile's FN prints (CODEX_HOME…)
#   codex-login:   `codex login --with-api-key`, the secret on its stdin
# gh takes one kind, `token`: `gh auth login --with-token`, then setup-git.
#
# shellcheck shell=bash

# credentials_kinds AGENT — the kinds a member of this agent takes, by name,
# space-separated, from the profile the box is given: cli/crew's agent_conf
# when it is loaded (an operator's agents/<agent>.conf wins over the shipped
# one, #75 — round 10), the shipped profile otherwise. The box decides
# against its own copy.
credentials_kinds() {
  local spec s out="" conf="$CREW_ROOT/shared/conf/agents/$1.conf"
  if declare -F agent_conf >/dev/null; then conf="$(agent_conf "$1")"; fi
  spec="$(sed -n 's/^AGENT_CRED_KINDS="\(.*\)"$/\1/p' "$conf" 2>/dev/null | tail -1)"
  for s in $spec; do out="$out ${s%%:*}"; done
  printf '%s' "${out# }"
}

# host_credentials_set_sh — stdin: one header line `<gh|agent> <kind>`, then
# the secret. Prints one verdict line; never the secret. rc 0 set and not
# known bad, 1 set and refused or logged out, 2 nothing set (a bad request).
host_credentials_set_sh() {
  cat <<'CREDENTIALS_SH'
# ---CREDENTIALS_SH---
umask 077
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
CRED_ENV="$HOME/.config/crew/credentials.env"
IFS=' ' read -r svc kind _ || { echo "credentials: nothing arrived — nothing set" >&2; exit 2; }
secret="$(cat)"
# A pasted token's trailing newline is the paste's; a JSON file keeps its own.
case "$kind" in *-json) ;; *) secret="${secret%$'\n'}"; secret="${secret%$'\r'}" ;; esac
[ -n "$secret" ] || { echo "credentials: an empty secret — nothing set" >&2; exit 2; }
cred_hook() {
  # Every login shell (`box exec -- bash -lc`: the floor's probe, `crew hire`)
  # reads the env kinds the way tick.sh does.
  local p
  for p in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do [ -f "$p" ] && break; done
  [ -f "$p" ] || p="$HOME/.profile"
  grep -qF '.config/crew/credentials.env' "$p" 2>/dev/null && return 0
  printf '\n# crew: credentials set from the host (write-only, #765)\n%s\n' \
    '[ -r "$HOME/.config/crew/credentials.env" ] && . "$HOME/.config/crew/credentials.env"' >>"$p"
}
cred_write() { # PATH — the secret, atomically, 0600
  local dir tmp
  dir="$(dirname "$1")"; mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.crew-cred.XXXXXX")" || return 1
  printf '%s\n' "$secret" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}
case "$svc" in
  gh)
    [ "$kind" = token ] || { echo "gh: the one kind is 'token' (a personal access token) — nothing set" >&2; exit 2; }
    case "$secret" in *[[:space:]]*) echo "gh: a token is one word — nothing set" >&2; exit 2 ;; esac
    # In plain text (0600, hosts.yml), never a keyring: the file is what the
    # weekly reset carries across, and a headless box has no keyring to keep
    # it in. A gh too old for the flag takes the token the old way.
    if ! printf '%s\n' "$secret" | gh auth login --hostname github.com --with-token --insecure-storage >/dev/null 2>&1 \
       && ! printf '%s\n' "$secret" | gh auth login --hostname github.com --with-token >/dev/null 2>&1; then
      echo "gh: the token was refused by gh auth login — the previous login stands"; exit 1
    fi
    gh auth setup-git >/dev/null 2>&1 || true
    login="$(gh api user --jq .login 2>/dev/null || true)"
    echo "gh: set — logged in as ${login:-(the login could not be read)}"
    ;;
  agent)
    # shellcheck disable=SC1091
    [ -r "$DUTY_DIR/conf/instance.conf" ] && . "$DUTY_DIR/conf/instance.conf"
    agent="${BOT_AGENT:-}"; conf="$DUTY_DIR/conf/agents/$agent.conf"
    { [ -n "$agent" ] && [ -r "$conf" ]; } || { echo "agent: this box names no agent profile (is it hired?) — nothing set" >&2; exit 2; }
    # shellcheck disable=SC1090
    . "$conf"
    spec=""; names=""; envs=""
    for s in ${AGENT_CRED_KINDS:-}; do
      names="$names ${s%%:*}"
      case "$s" in *:env:*) envs="$envs ${s##*:}" ;; esac
      [ "${s%%:*}" = "$kind" ] && spec="$s"
    done
    [ -n "$spec" ] || { echo "agent: $agent takes no '$kind' (it takes:${names:- nothing}) — nothing set" >&2; exit 2; }
    how="${spec#*:}"; where="${how#*:}"; how="${how%%:*}"
    # The kind set LAST is the one the CLI uses: every other env kind of this
    # agent leaves credentials.env, so an old token can never shadow a new
    # login (an env token wins over a credentials file).
    drop="$envs"
    mkdir -p "$(dirname "$CRED_ENV")"
    tmp="$(mktemp "$CRED_ENV.XXXXXX")" || { echo "agent: could not write credentials.env — nothing set" >&2; exit 2; }
    [ ! -f "$CRED_ENV" ] || awk -v drop="$drop" 'BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) skip["export " d[i]] = 1 }
      { split($0, kv, "="); if (!(kv[1] in skip)) print }' "$CRED_ENV" >"$tmp"
    case "$how" in
      env)
        case "$where" in ''|*[!A-Z0-9_]*) echo "agent: profile names a bad variable '$where' — nothing set" >&2; rm -f "$tmp"; exit 2 ;; esac
        case "$secret" in *$'\n'*) echo "agent: a $kind is one line — nothing set" >&2; rm -f "$tmp"; exit 2 ;; esac
        printf 'export %s=%q\n' "$where" "$secret" >>"$tmp" ;;
      file|file-fn)
        if [ "$how" = file-fn ]; then path="$("$where")"; else path="$HOME/$where"; fi
        case "$path" in ''|*/../*|../*) echo "agent: profile names a bad path — nothing set" >&2; rm -f "$tmp"; exit 2 ;; esac
        if ! printf '%s' "$secret" | jq -e . >/dev/null 2>&1; then
          echo "agent: a $kind is a JSON file and this is not JSON — nothing set" >&2; rm -f "$tmp"; exit 2
        fi
        cred_write "$path" || { echo "agent: $path could not be written — nothing set" >&2; rm -f "$tmp"; exit 2; } ;;
      codex-login)
        if ! printf '%s\n' "$secret" | codex login --with-api-key >/dev/null 2>&1; then
          echo "agent: codex login --with-api-key refused the key — the previous login stands"; rm -f "$tmp"; exit 1
        fi ;;
      *) echo "agent: profile names an unknown way '$how' — nothing set" >&2; rm -f "$tmp"; exit 2 ;;
    esac
    chmod 600 "$tmp" && mv -f "$tmp" "$CRED_ENV" || { rm -f "$tmp"; echo "agent: credentials.env could not be replaced" >&2; exit 1; }
    cred_hook
    # The verdict is the profile's own local reading, under the env just written.
    # shellcheck disable=SC1090
    . "$CRED_ENV"
    rc=0; bot_cli_present || rc=$?
    case "$rc" in
      0) echo "agent: $kind set ($agent) — logged in" ;;
      1) echo "agent: $kind set ($agent) — but $agent still reads as NOT logged in"; exit 1 ;;
      *) echo "agent: $kind set ($agent) — it cannot be checked locally; the next session is the test" ;;
    esac
    ;;
  *) echo "credentials: the service is gh or agent — nothing set" >&2; exit 2 ;;
esac
# ---END---
CREDENTIALS_SH
}

# host_credentials_export_sh — the member's live credentials, as ONE line on
# stdout, ALWAYS: `CREDS1 <files> <env>` — `CREDS1 - -` when it has none — or
# `CREDS-FAIL <why>` when they could not be read (round 14: a reply with no
# such line is never "no credentials"; a login shell that died before this
# ran answers nothing, and that is a failure to read). <files> is a base64
# tar of the credential files (or `-`); <env> the base64 of `NAME
# base64(value)` lines read from credentials.env in the box's own shell, `=`
# for a credentials.env that is there and EMPTY — what setting a file kind
# leaves, and what must cross so an older env token does not come back over
# the new login (round 14) — or `-` for none. The weekly reset reads it off the running box before the disk
# goes back and writes it after (host_credentials_import_sh), so a credential
# set or rotated since the checkpoint is not rolled back to it. Nothing is
# staged on the box's disk — a full disk is what a reset is for (round 13) —
# and the host holds it in memory only. A readers takes the LAST line that
# starts `CREDS1 `: a login banner before it is not the payload. An env file
# that does not read whole fails the export (rc 1): the reset then says the
# credentials could not be read rather than carrying half of them.
host_credentials_export_sh() {
  cat <<'CREDENTIALS_EXPORT_SH'
# ---CREDENTIALS_EXPORT_SH---
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
envf="$HOME/.config/crew/credentials.env"
env64="-"
if [ -f "$envf" ]; then
  # Sourced in a subshell, silenced, and believed only when it reaches its
  # own end: a syntax error, an `exit` or a stray print in a hand-edited file
  # fails the export instead of carrying a part of it.
  pairs="$( ( . "$envf" >/dev/null 2>&1 || exit 1
              for n in $(sed -n 's/^export \([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$envf"); do
                printf '%s %s\n' "$n" "$(printf '%s' "${!n}" | base64 -w0)"
              done
              echo "CREDS-END" ) 2>/dev/null )" || { echo; echo "CREDS-FAIL credentials.env did not read"; exit 1; }
  case "$pairs" in *CREDS-END) ;; *) echo; echo "CREDS-FAIL credentials.env did not read whole"; exit 1 ;; esac
  pairs="${pairs%CREDS-END}"
  if [ -n "$pairs" ]; then env64="$(printf '%s' "$pairs" | base64 -w0)"; else env64="="; fi
fi
set -- "$HOME/.config/gh/hosts.yml"
# shellcheck disable=SC1091
[ -r "$DUTY_DIR/conf/instance.conf" ] && . "$DUTY_DIR/conf/instance.conf" >/dev/null 2>&1
conf="$DUTY_DIR/conf/agents/${BOT_AGENT:-}.conf"
if [ -n "${BOT_AGENT:-}" ] && [ -r "$conf" ]; then
  # shellcheck disable=SC1090
  . "$conf" >/dev/null 2>&1
  for s in ${AGENT_CRED_KINDS:-}; do
    how="${s#*:}"; where="${how#*:}"; how="${how%%:*}"
    case "$how" in
      file) set -- "$@" "$HOME/$where" ;;
      file-fn) set -- "$@" "$("$where")" ;;
    esac
  done
fi
have=()
for f in "$@"; do [ -f "$f" ] && have+=("${f#/}"); done
files64="-"
if [ "${#have[@]}" -gt 0 ]; then
  files64="$(tar -C / -czf - "${have[@]}" 2>/dev/null | base64 -w0)" || { echo; echo "CREDS-FAIL the files did not pack"; exit 1; }
  [ -n "$files64" ] || { echo; echo "CREDS-FAIL the files did not pack"; exit 1; }
fi
echo
echo "CREDS1 $files64 $env64"
# ---END---
CREDENTIALS_EXPORT_SH
}

# host_credentials_import_sh — stdin: the export's `CREDS1 …` line. The files
# are unpacked over the restored disk, 0600; credentials.env is written again
# HERE from the carried data, each value quoted by printf %q — it never
# crosses as shell text — and the login-shell hook put back when it came
# across. Prints `carried N`. ONLY the credential files come across, and only
# as regular files: the archive is listed first against the same list the
# export reads, and one entry outside it — another path, a link, a directory —
# refuses the whole import before anything is written (round 10). An env line
# that is not a name and its base64 refuses it too.
host_credentials_import_sh() {
  cat <<'CREDENTIALS_IMPORT_SH'
# ---CREDENTIALS_IMPORT_SH---
umask 077
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
envf="$HOME/.config/crew/credentials.env"
tag=""
while IFS=' ' read -r tag files64 env64 _; do [ "$tag" = CREDS1 ] && break; done
[ "$tag" = CREDS1 ] || { echo "credentials: not a carry — nothing carried" >&2; exit 1; }
set -- "$HOME/.config/gh/hosts.yml"
# shellcheck disable=SC1091
[ -r "$DUTY_DIR/conf/instance.conf" ] && . "$DUTY_DIR/conf/instance.conf" >/dev/null 2>&1
conf="$DUTY_DIR/conf/agents/${BOT_AGENT:-}.conf"
if [ -n "${BOT_AGENT:-}" ] && [ -r "$conf" ]; then
  # shellcheck disable=SC1090
  . "$conf" >/dev/null 2>&1
  for s in ${AGENT_CRED_KINDS:-}; do
    how="${s#*:}"; where="${how#*:}"; how="${how%%:*}"
    case "$how" in
      file) set -- "$@" "$HOME/$where" ;;
      file-fn) set -- "$@" "$("$where")" ;;
    esac
  done
fi
allow=" "; for f in "$@"; do allow="$allow${f#/} "; done
# The env data first, all checked before anything is written.
pairs=""
if [ "${env64:--}" != - ] && [ "$env64" != = ]; then
  pairs="$(printf '%s' "$env64" | base64 -d 2>/dev/null)" || { echo "credentials: the env data did not decode — nothing carried" >&2; exit 1; }
  bad="$(printf '%s\n' "$pairs" | grep -cvE '^([A-Z_][A-Z0-9_]* [A-Za-z0-9+/]*=*|)$' || true)"
  if [ "${bad:-0}" -ne 0 ]; then
    echo "credentials: the env data holds a line that is not a name and its value — nothing carried" >&2; exit 1
  fi
fi
names=()
if [ "${files64:--}" != - ]; then
  arc="$(mktemp "$HOME/.crew-carry.XXXXXX")" || { echo "credentials: no room to stage the archive" >&2; exit 1; }
  trap 'rm -f "$arc"' EXIT
  printf '%s' "$files64" | base64 -d >"$arc" 2>/dev/null || { echo "credentials: the archive did not decode" >&2; exit 1; }
  # Names listed literally where the tar can (GNU escapes other bytes by
  # default; busybox has no such option and lists them as they are).
  entries="$(tar --quoting-style=literal -tzvf "$arc" 2>/dev/null || tar -tzvf "$arc" 2>/dev/null)" \
    || { echo "credentials: the archive did not list" >&2; exit 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # The five listing columns cut off as they stand: a field rewrite would
    # collapse a run of spaces inside the name itself (round 11).
    name="$(printf '%s\n' "$line" | sed -E 's/^([^ ]+ +){5}//')"
    case "$line" in -*) ;; *) echo "credentials: '$name' is not a regular file — nothing carried" >&2; exit 1 ;; esac
    case "$allow" in *" $name "*) names+=("$name") ;; *) echo "credentials: '$name' is not a credential file — nothing carried" >&2; exit 1 ;; esac
  done <<<"$entries"
  if [ "${#names[@]}" -gt 0 ]; then
    tar -C / -xzf "$arc" -- "${names[@]}" 2>/dev/null || { echo "credentials: the archive did not unpack" >&2; exit 1; }
  fi
fi
n="${#names[@]}"
if [ "${env64:--}" != - ]; then
  mkdir -p "$(dirname "$envf")"
  tmp="$(mktemp "$envf.XXXXXX")" || { echo "credentials: credentials.env could not be written" >&2; exit 1; }
  while read -r cname cval; do
    [ -n "$cname" ] || continue
    printf 'export %s=%q\n' "$cname" "$(printf '%s' "$cval" | base64 -d 2>/dev/null)" >>"$tmp" \
      || { rm -f "$tmp"; echo "credentials: credentials.env could not be written" >&2; exit 1; }
  done <<<"$pairs"
  chmod 600 "$tmp" && mv -f "$tmp" "$envf" || { rm -f "$tmp"; echo "credentials: credentials.env could not be written" >&2; exit 1; }
  n=$((n + 1))
  for p in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do [ -f "$p" ] && break; done
  [ -f "$p" ] || p="$HOME/.profile"
  grep -qF '.config/crew/credentials.env' "$p" 2>/dev/null \
    || printf '\n# crew: credentials set from the host (write-only, #765)\n%s\n' \
         '[ -r "$HOME/.config/crew/credentials.env" ] && . "$HOME/.config/crew/credentials.env"' >>"$p"
fi
echo "carried $n"
# ---END---
CREDENTIALS_IMPORT_SH
}

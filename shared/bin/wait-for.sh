#!/usr/bin/env bash
# wait-for.sh — the wait idiom, owned by the engine (#760; discussion #527).
#
#   wait-for.sh checks <owner/repo> <pr-number> [--timeout <s>]
#   wait-for.sh pid <pid> [--timeout <s>]
#
# A session that must wait for its pull request's checks, or for a command it
# started, calls this instead of composing a poll of its own: the one a
# reviewer composed — `until ! pgrep -f "<pattern>"` — matched its own shell
# and never returned (78 minutes, no verdict). This polls a fact, never a
# command line, and returns when the fact holds or the budget runs out.
#
# Exit 0 = the wait ended because the fact holds (checks settled, or the pid
# is gone); 1 = the budget ran out with the fact not yet true; 2 = bad usage.
# For a wait longer than a session should hold open, park-until.sh instead.
set -uo pipefail
what="${1:-}"; shift || true
timeout_s=1800
case "$what" in
  checks)
    repo="${1:-}"; num="${2:-}"; shift 2 || { echo "usage: wait-for.sh checks <owner/repo> <pr> [--timeout <s>]" >&2; exit 2; }
    [ "${1:-}" != --timeout ] || { timeout_s="${2:-1800}"; shift 2 || true; }
    [ -n "$repo" ] && [ -n "$num" ] || { echo "usage: wait-for.sh checks <owner/repo> <pr> [--timeout <s>]" >&2; exit 2; }
    waited=0
    while [ "$waited" -lt "$timeout_s" ]; do
      pending="$(gh pr view "$num" -R "$repo" --json statusCheckRollup \
        --jq '[.statusCheckRollup[]? | select((.conclusion // "") == "" and ((.status // "") == "QUEUED" or (.status // "") == "IN_PROGRESS" or (.status // "") == "PENDING" or (.status // "") == "WAITING" or (.state // "") == "PENDING"))] | length' 2>/dev/null)"
      case "$pending" in 0) echo "checks settled on $repo#$num"; exit 0 ;; ''|*[!0-9]*) : ;; esac
      sleep 30; waited=$((waited + 30))
    done
    echo "checks on $repo#$num still pending after ${timeout_s}s" >&2; exit 1 ;;
  pid)
    pid="${1:-}"; shift || true
    [ "${1:-}" != --timeout ] || { timeout_s="${2:-1800}"; shift 2 || true; }
    case "$pid" in ''|*[!0-9]*) echo "usage: wait-for.sh pid <pid> [--timeout <s>]" >&2; exit 2 ;; esac
    waited=0
    while [ "$waited" -lt "$timeout_s" ]; do
      kill -0 "$pid" 2>/dev/null || { echo "pid $pid is gone"; exit 0; }
      sleep 5; waited=$((waited + 5))
    done
    echo "pid $pid still alive after ${timeout_s}s" >&2; exit 1 ;;
  *) echo "usage: wait-for.sh checks <owner/repo> <pr> [--timeout <s>] | pid <pid> [--timeout <s>]" >&2; exit 2 ;;
esac

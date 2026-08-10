#!/usr/bin/env bash
# Shared session-lock owner identity.
#
# ONE owner of the "which process holds this home's session lock, is it still
# live, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire, inspect, and release state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.
#
# Two owner kinds hold the same lock. An interactive harness session is
# identified by walking process ancestry (below). A service owner - a
# long-running non-harness process such as a backend driving these scripts
# against its own FM_HOME - has no harness ancestry to walk, so it declares its
# identity instead; see "service-owner identity" further down.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Walk the current process ancestry (up to 16 hops) and print a harness pid.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). The harness pid lives
# as long as the session, unlike the transient subshell pid of any one tool
# call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args best='' bc extending=0 hit=0 is_claude=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    bc=$(basename -- "$comm")
    hit=0; is_claude=0
    if printf '%s' "$bc" | grep -qE "$FM_HARNESS_RE"; then
      hit=1
      case "$bc" in *claude*) is_claude=1 ;; esac
    else
      # Bare interpreter (e.g. node): match the harness name in its script path.
      case "$comm" in
        *node*|*python*)
          if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
            hit=1
            case "$args" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
    if [ "$hit" -eq 1 ]; then
      best="$pid"
      if [ "$is_claude" -eq 1 ]; then
        extending=1
      else
        break
      fi
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename -- "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}

# --- service-owner identity --------------------------------------------------
#
# A service owner declares itself through bin/fm-lock.sh's service mode instead
# of being discovered by an ancestry walk. state/.lock keeps its exact bare-pid
# shape, so every reader that only wants the owning pid is unchanged; the
# declaration lives beside it in state/.lock.owner:
#
#   kind=service
#   pid=<pid recorded in state/.lock>
#   name=<declared owner identity>
#   start=<start-time token of that pid>
#
# The record is honored ONLY while it names the pid state/.lock records AND
# that pid still carries the recorded start-time token. Ownership is therefore
# a declaration bound to one live process incarnation: it is never inferred
# from a process name, and a recycled pid never inherits it. A malformed or
# lock-mismatched record returns to the harness rules above. A dead or replaced
# recorded service owner is proven stale and reclaimable, while an unreadable
# start token for a live recorded pid refuses reclamation.

# Path of the service-owner record beside state dir $1's session lock.
fm_service_owner_record() {
  printf '%s/.lock.owner\n' "$1"
}

# True when $1 is a well-formed service-owner name: 1-64 characters of
# alphanumerics, dot, underscore, or dash, starting alphanumeric. The bracket
# match rejects every other byte, including a newline that would otherwise
# forge a second record field.
fm_service_owner_name_valid() {
  local name=$1
  [ -n "$name" ] && [ "${#name}" -le 64 ] || return 1
  case "$name" in
    [A-Za-z0-9]*) : ;;
    *) return 1 ;;
  esac
  case "$name" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Print the start-time token binding pid $1 to one process incarnation. Fails
# when ps cannot report it, so an unreadable start time refuses service
# ownership rather than degrading to a bare pid match.
fm_process_start_token() {
  local pid=$1 token
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  token=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null) || return 1
  token=$(printf '%s\n' "$token" | head -n 1 | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//')
  [ -n "$token" ] || return 1
  printf '%s\n' "$token"
}

# Read service-owner record file $1 only when it contains each allowed field
# exactly once and no other content.
fm_service_owner_record_read() {
  local file=$1 line kind='' pid='' name='' start=''
  local seen_kind=0 seen_pid=0 seen_name=0 seen_start=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*)
        [ "$seen_kind" -eq 0 ] || return 1
        kind=${line#kind=}
        seen_kind=1
        ;;
      pid=*)
        [ "$seen_pid" -eq 0 ] || return 1
        pid=${line#pid=}
        seen_pid=1
        ;;
      name=*)
        [ "$seen_name" -eq 0 ] || return 1
        name=${line#name=}
        seen_name=1
        ;;
      start=*)
        [ "$seen_start" -eq 0 ] || return 1
        start=${line#start=}
        seen_start=1
        ;;
      *) return 1 ;;
    esac
  done < "$file" || return 1
  [ "$seen_kind" -eq 1 ] && [ "$seen_pid" -eq 1 ] \
    && [ "$seen_name" -eq 1 ] && [ "$seen_start" -eq 1 ] || return 1
  FM_SERVICE_OWNER_RECORD_KIND=$kind
  FM_SERVICE_OWNER_RECORD_PID=$pid
  FM_SERVICE_OWNER_RECORD_NAME=$name
  FM_SERVICE_OWNER_RECORD_START=$start
}

# Read the valid service-owner record bound to state dir $1's current lock.
fm_service_owner_record_for_lock() {
  local state=$1 record lock_pid
  FM_SERVICE_OWNER_NAME=''
  FM_SERVICE_OWNER_PID=''
  FM_SERVICE_OWNER_START=''
  record=$(fm_service_owner_record "$state")
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_service_owner_record_read "$record" || return 1
  [ "$FM_SERVICE_OWNER_RECORD_KIND" = service ] || return 1
  [ "$FM_SERVICE_OWNER_RECORD_PID" = "$lock_pid" ] || return 1
  fm_service_owner_name_valid "$FM_SERVICE_OWNER_RECORD_NAME" || return 1
  [ -n "$FM_SERVICE_OWNER_RECORD_START" ] || return 1
  FM_SERVICE_OWNER_NAME=$FM_SERVICE_OWNER_RECORD_NAME
  FM_SERVICE_OWNER_PID=$FM_SERVICE_OWNER_RECORD_PID
  FM_SERVICE_OWNER_START=$FM_SERVICE_OWNER_RECORD_START
}

# Print the service-owner name declared for the pid currently in state dir $1's
# lock, live or not. Fails when no well-formed record names that pid.
fm_service_owner_declared_name() {
  fm_service_owner_record_for_lock "$1" || return 1
  printf '%s\n' "$FM_SERVICE_OWNER_NAME"
}

# True when state dir $1's lock is held by a live declared service owner. On
# success FM_SERVICE_OWNER_NAME, FM_SERVICE_OWNER_PID, and
# FM_SERVICE_OWNER_START identify it for the caller. FM_SERVICE_OWNER_STATE is
# live, stale, unverifiable, or none after every check.
fm_service_lock_owner_live() {
  local state=$1 token
  FM_SERVICE_OWNER_STATE=none
  fm_service_owner_record_for_lock "$state" || return 1
  if ! kill -0 "$FM_SERVICE_OWNER_PID" 2>/dev/null; then
    FM_SERVICE_OWNER_STATE=stale
    return 1
  fi
  token=$(fm_process_start_token "$FM_SERVICE_OWNER_PID") || {
    FM_SERVICE_OWNER_STATE=unverifiable
    return 1
  }
  if [ "$token" != "$FM_SERVICE_OWNER_START" ]; then
    FM_SERVICE_OWNER_STATE=stale
    return 1
  fi
  FM_SERVICE_OWNER_STATE=live
  return 0
}

# True when the process recorded in state dir $1's lock is a live owner of
# either kind or a live service pid whose identity cannot be verified. This is
# the ONE predicate that answers "must reclamation be refused?", so acquisition
# and the Claude Stop auto-arm displace a live service owner no more readily
# than a live harness owner. The service check runs first because a record bound
# to that exact pid is the more specific claim.
fm_session_lock_owner_live() {
  local state=$1 lock_pid
  fm_service_lock_owner_live "$state" && return 0
  case "$FM_SERVICE_OWNER_STATE" in
    unverifiable) return 0 ;;
    stale) return 1 ;;
  esac
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$lock_pid"
}

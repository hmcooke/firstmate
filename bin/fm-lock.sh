#!/usr/bin/env bash
# Acquire, inspect, or release the per-home firstmate session lock.
#
# Two owner kinds hold the same state/.lock:
#   - harness (default): writes the harness (agent) process PID found by walking
#     the shell's ancestry, which lives as long as the firstmate session - unlike
#     the transient subshell PID of any one tool call, which is dead moments
#     after it is written.
#   - service: a long-running non-harness process - such as a backend that
#     drives these scripts against its own FM_HOME - has no harness ancestry to
#     walk, so it declares its identity and pid instead. The declaration is
#     recorded in state/.lock.owner beside the unchanged bare-pid state/.lock
#     and is bound to one live process incarnation, so no look-alike process
#     name and no recycled pid can claim it.
# Neither kind displaces a live owner of the other: a live service owner refuses
# a harness session into read-only exactly as a live harness session does, and a
# dead owner of either kind is reclaimable on the same terms.
#
# usage:
#   fm-lock.sh                               acquire for this harness session; exit 1 unless ownership is verified
#   fm-lock.sh status                        print holder and liveness; always exits 0
#   fm-lock.sh service-acquire <name> [pid]  acquire for the declared service owner
#   fm-lock.sh service-verify <name> [pid]   exit 0 only while that exact service owner holds the lock
#   fm-lock.sh service-release <name> [pid]  release a lock that service owner holds
#   fm-lock.sh --help                        print usage
#
# <name> is 1-64 characters of alphanumerics, dot, underscore, or dash, starting
# alphanumeric. [pid] is the process that owns the lock for its lifetime and
# defaults to the caller's parent, which is the service itself when it runs this
# script directly.
set -u

usage() {
  cat <<'EOF'
usage:
  fm-lock.sh                               acquire for this harness session
  fm-lock.sh status                        print holder and liveness; always exits 0
  fm-lock.sh service-acquire <name> [pid]  acquire for the declared service owner
  fm-lock.sh service-verify <name> [pid]   exit 0 only while that service owner holds the lock
  fm-lock.sh service-release <name> [pid]  release a lock that service owner holds
See the header comment for the full contract; [pid] defaults to the caller's parent.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"

MODE=${1:-acquire}
case "$MODE" in
  -h|--help|help)
    usage
    exit 0
    ;;
  acquire|status|service-acquire|service-verify|service-release) ;;
  *)
    printf 'error: unknown mode %s\n' "$MODE" >&2
    usage >&2
    exit 2
    ;;
esac

# Owner identity (FM_HARNESS_RE, the ancestry walk, holder liveness, and the
# service-owner record contract) is owned by the shared session-lock lib so the
# Claude Stop auto-arm applies the exact same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
RECORD=$(fm_service_owner_record "$STATE")

if [ "$MODE" = status ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_service_lock_owner_live "$STATE"; then
    echo "lock: held by live service owner $FM_SERVICE_OWNER_NAME (pid $FM_SERVICE_OWNER_PID)"
  elif [ "$FM_SERVICE_OWNER_STATE" = unverifiable ]; then
    echo "lock: recorded service owner $FM_SERVICE_OWNER_NAME (pid $FM_SERVICE_OWNER_PID) identity could not be verified"
  elif [ "$FM_SERVICE_OWNER_STATE" = stale ]; then
    echo "lock: stale (service owner $FM_SERVICE_OWNER_NAME pid $old dead or replaced)"
  elif fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

# --- service-owner argument validation ---------------------------------------
if [ "$MODE" != acquire ]; then
  NAME=${2:-}
  PID=${3:-$PPID}
  fm_service_owner_name_valid "$NAME" || {
    echo "error: service owner name must be 1-64 characters of alphanumerics, dot, underscore, or dash, starting alphanumeric" >&2
    usage >&2
    exit 2
  }
  case "$PID" in
    ''|*[!0-9]*)
      echo "error: service owner pid must be numeric" >&2
      exit 2
      ;;
  esac
  [ "$PID" -gt 1 ] || {
    echo "error: service owner pid $PID is not a claimable process" >&2
    exit 2
  }
fi

# Verification is read-only: it answers "does this exact service owner still
# hold the lock?" without touching any state.
if [ "$MODE" = service-verify ]; then
  if fm_service_lock_owner_live "$STATE" \
    && [ "$FM_SERVICE_OWNER_NAME" = "$NAME" ] && [ "$FM_SERVICE_OWNER_PID" = "$PID" ]; then
    echo "lock: held by live service owner $NAME (pid $PID)"
    exit 0
  fi
  if [ "$FM_SERVICE_OWNER_STATE" = unverifiable ] \
    && [ "$FM_SERVICE_OWNER_NAME" = "$NAME" ] && [ "$FM_SERVICE_OWNER_PID" = "$PID" ]; then
    echo "error: recorded service owner $NAME (pid $PID) identity could not be verified" >&2
    exit 1
  fi
  echo "error: service owner $NAME (pid $PID) does not hold the session lock" >&2
  exit 1
fi

if [ "$MODE" = service-release ] && [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
  echo "lock: free"
  exit 0
fi

mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

if [ "$MODE" = acquire ]; then
  me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
else
  me=$PID
  if [ "$MODE" = service-acquire ]; then
    kill -0 "$PID" 2>/dev/null || {
      echo "error: service owner pid $PID is not running" >&2
      exit 1
    }
    START=$(fm_process_start_token "$PID") || {
      echo "error: cannot read the start time of pid $PID; service ownership cannot be bound to it" >&2
      exit 1
    }
  fi
fi

probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

# A harness session that already owns the lock, or that meets a live harness
# owner, settles here without contending for the claim lock. The shortcut is
# scoped to an ordinary harness acquire on a home with no service-owner record,
# which is the exact case it was written for and leaves its behavior unchanged.
# Both service ownership conditions must fall through to the identity-aware path
# below instead: the service modes need the record, the start-time binding, and
# the release contract (answering service-release here would report a re-acquired
# harness lock and never release), and a recorded service owner must be judged by
# that record rather than by a harness-name check that cannot recognize it.
if [ "$MODE" = acquire ] && [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ] \
  && [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    echo "lock acquired: harness pid $me"
    exit 0
  fi
  if fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

# Refuse rather than displace whenever a lock file names an owner that is still
# live, whichever kind it is. Sets OLD to the recorded pid when one is readable.
OLD=''
assert_no_live_other_owner() {
  if [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
    return 0
  fi
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  OLD=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$OLD" = "$me" ]; then
    if [ "$MODE" = acquire ] || [ "$MODE" = service-release ]; then
      return 0
    fi
    if fm_service_lock_owner_live "$STATE" \
      && [ "$FM_SERVICE_OWNER_NAME" = "$NAME" ] \
      && [ "$FM_SERVICE_OWNER_PID" = "$PID" ] \
      && [ "$FM_SERVICE_OWNER_START" = "$START" ]; then
      return 0
    fi
  fi
  if fm_session_lock_owner_live "$STATE"; then
    case "$FM_SERVICE_OWNER_STATE" in
      live)
        echo "error: a live service owner holds the lock ($FM_SERVICE_OWNER_NAME, pid $FM_SERVICE_OWNER_PID); operate read-only until resolved" >&2
        ;;
      unverifiable)
        echo "error: recorded service owner $FM_SERVICE_OWNER_NAME (pid $FM_SERVICE_OWNER_PID) identity could not be verified; operate read-only until resolved" >&2
        ;;
      *)
        echo "error: another live firstmate session holds the lock (pid $OLD); operate read-only until resolved" >&2
        ;;
    esac
    exit 1
  fi
  return 0
}

if [ "$MODE" = service-release ]; then
  assert_no_live_other_owner
  declared=$(fm_service_owner_declared_name "$STATE") || declared=''
  if [ "$OLD" != "$PID" ] || [ "$declared" != "$NAME" ]; then
    echo "error: service owner $NAME (pid $PID) does not hold the session lock; refusing to release it" >&2
    exit 1
  fi
  rm -f "$LOCK" "$RECORD" 2>/dev/null || true
  if [ -e "$LOCK" ] || [ -e "$RECORD" ]; then
    echo "error: cannot release the session lock; operate read-only until resolved" >&2
    exit 1
  fi
  release_claim_lock
  echo "lock released: service owner $NAME pid $PID"
  exit 0
fi

assert_no_live_other_owner

if [ "$MODE" = service-acquire ]; then
  # Publish the record before updating the lock pid. Readers require an exact
  # pid match, so this record cannot attribute a lock naming another pid to the
  # service if acquisition stops before lock publication.
  tmp=$(mktemp "$STATE/.lock.owner.XXXXXX" 2>/dev/null) || {
    echo "error: cannot write the service-owner record; operate read-only until resolved" >&2
    exit 1
  }
  if ! { printf 'kind=service\npid=%s\nname=%s\nstart=%s\n' "$PID" "$NAME" "$START" > "$tmp"; } 2>/dev/null \
    || ! mv -f "$tmp" "$RECORD" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    echo "error: cannot write the service-owner record; operate read-only until resolved" >&2
    exit 1
  fi
elif [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
  # A harness owner is never a service owner: clear any record left by a dead
  # service before this session's pid lands in the lock.
  rm -f "$RECORD" 2>/dev/null || true
  if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
    echo "error: cannot clear the stale service-owner record; operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
if [ "$MODE" = service-acquire ]; then
  if ! fm_service_lock_owner_live "$STATE" \
    || [ "$FM_SERVICE_OWNER_NAME" != "$NAME" ] || [ "$FM_SERVICE_OWNER_PID" != "$PID" ]; then
    echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
    exit 1
  fi
  release_claim_lock
  echo "lock acquired: service owner $NAME pid $PID"
  exit 0
fi
release_claim_lock
echo "lock acquired: harness pid $me"

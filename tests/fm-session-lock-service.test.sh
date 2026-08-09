#!/usr/bin/env bash
# Behavior tests for service-owner session locks (bin/fm-lock.sh service modes,
# bin/fm-session-lock-lib.sh, docs/service-owner-lock.md).
#
# A service owner is a long-running non-harness process that declares its
# identity instead of being discovered by an ancestry walk. These tests drive
# the real script against real processes: a plain `sleep` stands in for the
# service, and a bash symlink named "claude" stands in for an interactive
# harness session, so the ancestry walk and the start-time identity binding both
# run against the host's real ps rather than a fake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-service)
LOCK_SH="$ROOT/bin/fm-lock.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# new_home <name>: fresh FM_HOME with an empty state dir; echoes its path.
new_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# start_service: start a live stand-in service process and set SERVICE_PID to
# its pid. It stays a child of the test shell (rather than of a command
# substitution) so stop_service can reap it, and its output goes nowhere so no
# caller ever waits on a pipe it still holds open.
SERVICE_PID=
start_service() {
  sleep 300 >/dev/null 2>&1 &
  SERVICE_PID=$!
}

stop_service() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# run_lock <home> [args...]: run fm-lock.sh against <home>, capturing both
# streams; the exit code is returned.
run_lock() {
  local home=$1
  shift
  FM_HOME="$home" "$LOCK_SH" "$@" 2>&1
}

# run_lock_as_harness <home> [args...]: same, but from a child of a live
# harness-named process, which is the shape an interactive session has.
run_lock_as_harness() {
  local home=$1
  shift
  # shellcheck disable=SC2016 # single quotes are deliberate: the harness child expands these itself
  FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@"' "$LOCK_SH" "$@" 2>&1
}

test_lifecycle_acquire_verify_release() {
  local home svc out status=0
  home=$(new_home lifecycle)
  start_service; svc=$SERVICE_PID

  out=$(run_lock "$home" service-acquire crowsnest-backend "$svc") || status=$?
  expect_code 0 "$status" "service-acquire on a free lock"
  assert_contains "$out" "lock acquired: service owner crowsnest-backend pid $svc" \
    "service-acquire did not confirm the declared owner"

  # The compatibility guarantee: state/.lock keeps its exact bare-pid shape, so
  # every existing reader that only wants the owning pid is unchanged.
  [ "$(cat "$home/state/.lock")" = "$svc" ] \
    || fail "service-acquire did not leave the owning pid alone in state/.lock"

  out=$(run_lock "$home" status)
  assert_contains "$out" "lock: held by live service owner crowsnest-backend (pid $svc)" \
    "status did not report the live service owner"

  status=0
  out=$(run_lock "$home" service-verify crowsnest-backend "$svc") || status=$?
  expect_code 0 "$status" "service-verify for the holding owner"

  status=0
  out=$(run_lock "$home" service-release crowsnest-backend "$svc") || status=$?
  expect_code 0 "$status" "service-release by the holding owner"
  assert_absent "$home/state/.lock" "service-release left the lock file behind"
  assert_absent "$home/state/.lock.owner" "service-release left the owner record behind"
  assert_contains "$(run_lock "$home" status)" "lock: free" "status after release"

  stop_service "$svc"
  pass "service owner: acquire, status, verify, and release complete one lifetime"
}

test_pid_defaults_to_calling_process() {
  local home out status=0 caller
  home=$(new_home default-pid)
  # No pid argument: the service is the process that ran the script, so the
  # default must be the caller itself rather than the script's own subshell.
  # The trailing no-op keeps the caller alive as a real parent instead of
  # letting bash exec the script in its place.
  out=$(FM_HOME="$home" bash -c 'printf "%s\n" "$$" > "$1/caller"; "$2" service-acquire defaulted; :' \
    _ "$home" "$LOCK_SH" 2>&1) || status=$?
  expect_code 0 "$status" "service-acquire with a defaulted pid"
  caller=$(cat "$home/caller")
  assert_contains "$out" "pid $caller" "defaulted pid did not name the calling process"
  [ "$(cat "$home/state/.lock")" = "$caller" ] || fail "defaulted pid was not recorded in the lock"
  pass "service owner: an omitted pid defaults to the calling process"
}

test_live_service_owner_is_never_displaced() {
  local home svc out status=0
  home=$(new_home live-service)
  start_service; svc=$SERVICE_PID
  run_lock "$home" service-acquire crowsnest-backend "$svc" >/dev/null

  out=$(run_lock_as_harness "$home") || status=$?
  expect_code 1 "$status" "a harness session must refuse rather than displace a live service owner"
  assert_contains "$out" "a live service owner holds the lock (crowsnest-backend, pid $svc)" \
    "the refusal did not name the service owner holding the lock"
  assert_contains "$out" "operate read-only until resolved" \
    "the refusal did not keep the ordinary read-only wording"
  [ "$(cat "$home/state/.lock")" = "$svc" ] || fail "a harness session overwrote a live service owner's lock"

  # A second service owner is refused on the same terms.
  status=0
  out=$(run_lock "$home" service-acquire other-service $$) || status=$?
  expect_code 1 "$status" "a second service owner must refuse rather than displace the first"
  [ "$(cat "$home/state/.lock")" = "$svc" ] || fail "a second service owner overwrote the live owner's lock"

  stop_service "$svc"
  pass "service owner: a live service owner is never displaced by a harness or another service"
}

test_dead_service_owner_is_reclaimable() {
  local home svc out status=0 owner
  home=$(new_home dead-service)
  start_service; svc=$SERVICE_PID
  run_lock "$home" service-acquire crowsnest-backend "$svc" >/dev/null
  stop_service "$svc"

  assert_contains "$(run_lock "$home" status)" "lock: stale (service owner crowsnest-backend pid $svc" \
    "status did not report a dead service owner as stale"

  # Exactly like a dead harness owner: the next session claims it.
  out=$(run_lock_as_harness "$home") || status=$?
  expect_code 0 "$status" "a harness session must reclaim a dead service owner's lock"
  assert_contains "$out" "lock acquired: harness pid" "reclaim did not report harness ownership"
  owner=$(cat "$home/state/.lock")
  [ "$owner" != "$svc" ] || fail "reclaim left the dead service owner's pid in the lock"
  assert_absent "$home/state/.lock.owner" "reclaim left the dead service owner's record in place"
  pass "service owner: a dead service owner's lock is reclaimable exactly like a dead harness owner's"
}

test_recycled_pid_never_inherits_ownership() {
  local home svc out status=0
  home=$(new_home recycled-pid)
  start_service; svc=$SERVICE_PID
  run_lock "$home" service-acquire crowsnest-backend "$svc" >/dev/null
  # The pid stays live, but it is no longer the incarnation that took the lock:
  # exactly what a reused pid looks like to a later reader.
  sed -e 's/^start=.*/start=Mon Jan 1 00:00:00 2001/' "$home/state/.lock.owner" > "$home/state/.lock.owner.new"
  mv "$home/state/.lock.owner.new" "$home/state/.lock.owner"

  assert_contains "$(run_lock "$home" status)" "lock: stale" \
    "a pid that no longer carries the recorded start time was still treated as the owner"
  status=0
  out=$(run_lock "$home" service-verify crowsnest-backend "$svc") || status=$?
  expect_code 1 "$status" "service-verify must fail once the pid binding no longer holds"

  status=0
  out=$(run_lock_as_harness "$home") || status=$?
  expect_code 0 "$status" "an unbound record must leave the lock reclaimable"

  stop_service "$svc"
  pass "service owner: a live pid that no longer matches the recorded incarnation inherits nothing"
}

test_record_must_name_the_lock_pid() {
  local home svc out
  home=$(new_home forged-record)
  start_service; svc=$SERVICE_PID
  # A record naming a live process that the lock does not name is not a claim on
  # this lock: the lock still reads by the ordinary harness rules.
  printf 'kind=service\npid=%s\nname=forged\nstart=%s\n' "$svc" "$(ps -o lstart= -p "$svc")" \
    > "$home/state/.lock.owner"
  printf '4242\n' > "$home/state/.lock"

  out=$(run_lock "$home" status)
  assert_contains "$out" "lock: stale (pid 4242 dead or not a harness)" \
    "a record naming a different pid was honored for this lock"
  assert_not_contains "$out" forged "a record naming a different pid named an owner"

  stop_service "$svc"
  pass "service owner: a record is honored only for the pid the lock itself records"
}

test_live_harness_owner_refuses_service_acquire() {
  local home holder out status=0
  home=$(new_home live-harness)
  # The trailing no-op keeps the harness-named process alive instead of letting
  # bash exec the final sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' >/dev/null 2>&1 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"

  out=$(run_lock "$home" service-acquire crowsnest-backend $$) || status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 1 "$status" "a service owner must refuse rather than displace a live harness session"
  assert_contains "$out" "another live firstmate session holds the lock (pid $holder)" \
    "the refusal did not name the live harness owner"
  pass "service owner: a live harness session is never displaced by a service owner"
}

test_release_is_owner_bound_and_idempotent() {
  local home svc out status=0
  home=$(new_home release-guard)

  status=0
  out=$(run_lock "$home" service-release crowsnest-backend $$) || status=$?
  expect_code 0 "$status" "releasing a free lock must be a clean no-op"
  assert_contains "$out" "lock: free" "releasing a free lock did not report it free"

  start_service; svc=$SERVICE_PID
  run_lock "$home" service-acquire crowsnest-backend "$svc" >/dev/null

  status=0
  out=$(run_lock "$home" service-release other-service "$svc") || status=$?
  expect_code 1 "$status" "a different owner name must not release this lock"
  status=0
  out=$(run_lock "$home" service-release crowsnest-backend $$) || status=$?
  expect_code 1 "$status" "a different pid must not release this lock"
  [ "$(cat "$home/state/.lock")" = "$svc" ] || fail "a non-owner released the service owner's lock"

  stop_service "$svc"
  pass "service owner: release is bound to the recorded owner and is a no-op on a free lock"
}

test_reacquire_by_same_owner_refreshes() {
  local home svc out status=0
  home=$(new_home reacquire)
  start_service; svc=$SERVICE_PID
  run_lock "$home" service-acquire crowsnest-backend "$svc" >/dev/null

  out=$(run_lock "$home" service-acquire crowsnest-backend "$svc") || status=$?
  expect_code 0 "$status" "an owner must be able to re-assert its own lock"
  assert_contains "$out" "lock acquired: service owner crowsnest-backend pid $svc" \
    "re-acquisition did not confirm the same owner"

  stop_service "$svc"
  pass "service owner: re-acquiring its own lock is idempotent"
}

test_malformed_requests_refuse() {
  local home out status=0
  home=$(new_home malformed)

  status=0
  out=$(run_lock "$home" service-acquire 'bad name' $$) || status=$?
  expect_code 2 "$status" "an invalid owner name must refuse"
  assert_contains "$out" "service owner name must be" "the name refusal did not explain the rule"

  status=0
  out=$(run_lock "$home" service-acquire crowsnest-backend not-a-pid) || status=$?
  expect_code 2 "$status" "a non-numeric pid must refuse"

  status=0
  out=$(run_lock "$home" service-acquire) || status=$?
  expect_code 2 "$status" "a missing owner name must refuse"

  status=0
  out=$(run_lock "$home" bogus-mode) || status=$?
  expect_code 2 "$status" "an unknown mode must refuse instead of silently acquiring"
  assert_absent "$home/state/.lock" "a refused request still took the lock"

  status=0
  out=$(run_lock "$home" service-verify crowsnest-backend $$) || status=$?
  expect_code 1 "$status" "verify must fail when no service owner holds the lock"
  pass "service owner: malformed names, pids, and modes refuse without taking the lock"
}

test_lifecycle_acquire_verify_release
test_pid_defaults_to_calling_process
test_live_service_owner_is_never_displaced
test_dead_service_owner_is_reclaimable
test_recycled_pid_never_inherits_ownership
test_record_must_name_the_lock_pid
test_live_harness_owner_refuses_service_acquire
test_release_is_owner_bound_and_idempotent
test_reacquire_by_same_owner_refreshes
test_malformed_requests_refuse

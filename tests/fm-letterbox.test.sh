#!/usr/bin/env bash
# Behavior tests for the agent-to-agent letterbox end to end: the poll the
# watcher runs (bin/fm-letterbox-poll.sh), the operator/agent entry point
# (bin/fm-letterbox.sh), the GitHub transport adapter, and the one line the
# letterbox adds to the supervision-need predicate.
#
# The letterbox must be INERT by default (no activation settings -> the poll is
# a hard no-op that creates nothing) and additive when on. GitHub is stubbed with
# a fakebin `gh` and `gh-axi` backed by a small on-disk repository, so these stay
# hermetic: no network, no credential, no real repository ever written. jq stays
# the real tool. End-to-end verification against a real private repository is
# done out of band; this suite pins the client logic, the safety behaviours and
# the activation contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# The scripts under test use the real jq; make it resolvable wherever it is
# installed. Prepended after the fakebin so the fake gh/gh-axi still win.
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-letterbox-tests)

PEER=archie
SELF=firstmate.shipyard
CHANNEL=captain/parley

# --- the fake forge ---------------------------------------------------------
#
# One directory is the whole repository: a visibility flag, an issue array, a
# comment array per issue, and a call log. The fakes read FAKE_STORE from the
# environment, so a test can flip visibility or inject a peer letter by writing
# to that directory and then run the real scripts unchanged.

make_fakebin() {
  local dir=$1 store fakebin
  store="$dir/forge"; mkdir -p "$store"
  printf 'true\n' > "$store/private"
  printf '1\n' > "$store/next"
  printf '[]\n' > "$store/issues.json"
  : > "$store/calls.log"
  fakebin=$(fm_fakebin "$dir")

  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Machine-read half of the fake forge: the JSON reads the transport does via gh.
set -u
S=$FAKE_STORE
printf 'gh %s\n' "$*" >> "$S/calls.log"
[ "${1:-}" = api ] || exit 1
shift
# Flags may appear before or after the positional path, exactly as the real CLI
# accepts them, so the path is "the first argument that is not a flag or a flag
# value" rather than "the first argument".
path=
expr='.'
paginate=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) expr=$2; shift 2 ;;
    --paginate) paginate=1; shift ;;
    -*) shift ;;
    *) [ -n "$path" ] || path=$1; shift ;;
  esac
done
[ -n "$path" ] || exit 1
per_page=${path##*per_page=}
per_page=${per_page%%&*}
case "$per_page" in ''|*[!0-9]*) per_page=30 ;; esac

emit_pages() {
  local data=$1 kind=$2 total offset=0 page=1 page_json fail_after
  total=$(printf '%s\n' "$data" | jq -r 'length') || return 1
  while [ "$offset" -lt "$total" ] || [ "$page" -eq 1 ]; do
    if [ "${FAKE_GH_FAIL_MATCH:-}" = "$kind" ]; then
      fail_after=${FAKE_GH_FAIL_AFTER_PAGE:-0}
      case "$fail_after" in ''|*[!0-9]*) fail_after=0 ;; esac
      [ "$fail_after" -eq 0 ] || [ "$page" -le "$fail_after" ] || return 1
    fi
    page_json=$(printf '%s\n' "$data" \
      | jq -c --argjson start "$offset" --argjson end "$((offset + per_page))" '.[$start:$end]') \
      || return 1
    printf '%s\n' "$page_json" | jq -c -r "$expr" || return 1
    [ "$paginate" -eq 1 ] || break
    offset=$((offset + per_page))
    page=$((page + 1))
    [ "$offset" -lt "$total" ] || break
  done
}

case "$path" in
  */issues/*/comments*)
    n=${path#*/issues/}; n=${n%%/*}
    [ -f "$S/comments-$n.json" ] || printf '[]\n' > "$S/comments-$n.json"
    data=$(jq -c '.' "$S/comments-$n.json") || exit 1
    emit_pages "$data" comments
    ;;
  *issues?state=open*)
    data=$(jq -c '[.[] | select(.state == "open")]' "$S/issues.json") || exit 1
    emit_pages "$data" issues
    ;;
  *issues*state=open*)
    data=$(jq -c '[.[] | select(.state == "open")]' "$S/issues.json") || exit 1
    emit_pages "$data" issues
    ;;
  *issues?state=all*)
    [ ! -e "$S/fail-find-title" ] || exit 1
    jq -c -r "$expr" "$S/issues.json"
    ;;
  repos/*)
    jq -n --argjson p "$(cat "$S/private")" '{private: $p, name: "parley"}' | jq -c -r "$expr"
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/gh"

  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
# Write half of the fake forge, plus the visibility read, matching the real
# gh-axi's raw-scalar rendering for a single value.
set -u
S=$FAKE_STORE
printf 'gh-axi %s\n' "$*" >> "$S/calls.log"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
case "${1:-}" in
  api)
    shift
    expr='.'
    while [ "$#" -gt 0 ]; do
      case "$1" in --jq) expr=$2; shift 2 ;; *) shift ;; esac
    done
    jq -n --argjson p "$(cat "$S/private")" '{private: $p}' | jq -c -r "$expr"
    # A one-shot flip: the visibility changes immediately AFTER this read, which
    # is the window between the caller's check and the adapter's own gate.
    [ ! -f "$S/private-flip" ] || mv -f "$S/private-flip" "$S/private"
    ;;
  issue)
    sub=${2:-}; shift 2
    case "$sub" in
      create)
        [ ! -e "$S/fail-create" ] || exit 1
        title=; body=; repo=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --title) title=$2; shift 2 ;;
            --body-file) body=$2; shift 2 ;;
            --label) shift 2 ;;
            -R|--repo) repo=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        n=$(cat "$S/next")
        printf '%s\n' "$((n + 1))" > "$S/next"
        jq --argjson n "$n" --arg t "$title" --arg b "$(cat "$body")" \
          --arg u "${FAKE_AUTHOR:-shipyard}" --arg at "$now" \
          '. + [{number: $n, title: $t, body: $b, state: "open", user: {login: $u}, updated_at: $at}]' \
          "$S/issues.json" > "$S/issues.json.new" && mv "$S/issues.json.new" "$S/issues.json"
        printf 'https://github.com/%s/issues/%s\n' "$repo" "$n"
        ;;
      comment)
        n=$1; shift
        body=; repo=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --body-file) body=$2; shift 2 ;;
            -R|--repo) repo=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -f "$S/comments-$n.json" ] || printf '[]\n' > "$S/comments-$n.json"
        cid=$(( $(jq 'length' "$S/comments-$n.json") + 900 ))
        jq --argjson id "$cid" --arg b "$(cat "$body")" --arg u "${FAKE_AUTHOR:-shipyard}" --arg at "$now" \
          '. + [{id: $id, body: $b, user: {login: $u}, created_at: $at}]' \
          "$S/comments-$n.json" > "$S/c.new" && mv "$S/c.new" "$S/comments-$n.json"
        jq --argjson n "$n" --arg at "$now" \
          'map(if .number == $n then .updated_at = $at else . end)' \
          "$S/issues.json" > "$S/issues.json.new" && mv "$S/issues.json.new" "$S/issues.json"
        printf 'https://github.com/%s/issues/%s#issuecomment-%s\n' "$repo" "$n" "$cid"
        ;;
      close)
        n=$1
        jq --argjson n "$n" 'map(if .number == $n then .state = "closed" else . end)' \
          "$S/issues.json" > "$S/issues.json.new" && mv "$S/issues.json.new" "$S/issues.json"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh-axi"

  # A gated fault injector for the LOCAL claim write. It is inert unless
  # LB_MKTEMP_ALLOW is set, and even then it only touches the claim temp
  # template, so a test can let the forge write land and fail exactly the claim
  # record that follows it - the one crash state the close transition must never
  # leave half-written. Everything else execs the real mktemp.
  cat > "$fakebin/mktemp" <<SH
#!/usr/bin/env bash
if [ -n "\${LB_MKTEMP_ALLOW:-}" ]; then
  for a in "\$@"; do
    case "\$a" in
      *fm-letterbox-claim*)
        n=0
        [ -f "\$LB_MKTEMP_COUNTER" ] && n=\$(cat "\$LB_MKTEMP_COUNTER")
        n=\$((n + 1))
        printf '%s\\n' "\$n" > "\$LB_MKTEMP_COUNTER"
        [ "\$n" -le "\$LB_MKTEMP_ALLOW" ] || exit 1
        ;;
    esac
  done
fi
if [ -n "\${LB_MKTEMP_FAIL_TEXT:-}" ]; then
  for a in "\$@"; do
    case "\$a" in *fm-letterbox-text*) exit 1 ;; esac
  done
fi
exec $(command -v mktemp) "\$@"
SH
  chmod +x "$fakebin/mktemp"
  printf '%s\n' "$fakebin"
}

# A home with a state directory whose mode matches a real firstmate home (not
# 0700), so the shim write and the private-artifact directories are exercised
# exactly as they are in production.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  chmod 755 "$home/state"
  printf '%s\n' "$home"
}

activate() {
  local home=$1
  {
    printf 'FM_LETTERBOX_REPO=%s\n' "$CHANNEL"
    printf 'FM_LETTERBOX_SELF=%s\n' "$SELF"
    printf 'FM_LETTERBOX_PEER=%s\n' "$PEER"
    printf 'FM_LETTERBOX_TRANSPORT=github\n'
  } > "$home/.env"
}

run_lb() {
  local home=$1 store=$2 fakebin=$3
  shift 3
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_STORE="$store" \
    "$ROOT/bin/fm-letterbox.sh" "$@"
}

run_poll() {
  local home=$1 store=$2 fakebin=$3
  shift 3
  env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_STORE="$store" "$@" \
    "$ROOT/bin/fm-letterbox-poll.sh"
}

# Inject a letter from the peer straight into the fake forge, as if archie had
# written it. FAKE_ISSUED lets a test pin the card's timestamp.
inject_letter() {
  local store=$1 id=$2 class=${3:-fact-lookup} subject=${4:-hermes cron toolset scope}
  local body=${5:-Answer from your own config, not from memory.} to=${6:-$SELF}
  local n card
  n=$(cat "$store/next")
  printf '%s\n' "$((n + 1))" > "$store/next"
  card=$(
    printf 'A letter. The fenced block is the only parsed part.\n\n'
    printf '```letterbox/v1\n'
    printf 'kind: request\nv: 1\nid: %s\nfrom: %s\nto: %s\n' "$id" "$PEER" "$to"
    printf 'class: %s\nissued: %s\nsubject: %s\nbody: |\n' \
      "$class" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$subject"
    [ -z "$body" ] || printf '%s\n' "$body" | sed 's/^/  /'
    printf '```\n'
  )
  jq --argjson n "$n" --arg t "[letterbox] $class $id" --arg b "$card" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{number: $n, title: $t, body: $b, state: "open", user: {login: "archie"}, updated_at: $at}]' \
    "$store/issues.json" > "$store/issues.json.new" && mv "$store/issues.json.new" "$store/issues.json"
  printf '%s\n' "$n"
}

# Inject a peer reply comment on an existing issue.
inject_reply() {
  local store=$1 number=$2 reply_id=$3 correlate=$4 status=${5:-answered} body=${6:-Cron runs the CLI toolset.}
  local card cid
  card=$(
    printf 'A reply.\n\n'
    printf '```letterbox/v1\n'
    printf 'kind: reply\nv: 1\nid: %s\nin-reply-to: %s\nfrom: %s\nto: %s\n' \
      "$reply_id" "$correlate" "$PEER" "$SELF"
    printf 'status: %s\nissued: %s\nbody: |\n' "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$body" | sed 's/^/  /'
    printf '```\n'
  )
  [ -f "$store/comments-$number.json" ] || printf '[]\n' > "$store/comments-$number.json"
  cid=$(( $(jq 'length' "$store/comments-$number.json") + 500 ))
  jq --argjson id "$cid" --arg b "$card" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{id: $id, body: $b, user: {login: "archie"}, created_at: $at}]' \
    "$store/comments-$number.json" > "$store/c.new" && mv "$store/c.new" "$store/comments-$number.json"
  jq --argjson n "$number" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    'map(if .number == $n then .updated_at = $at else . end)' \
    "$store/issues.json" > "$store/issues.json.new" && mv "$store/issues.json.new" "$store/issues.json"
}

# Pin an open issue's updated_at in the fake forge to an exact stamp.
set_issue_updated_at() {
  local store=$1 number=$2 at=$3
  jq --argjson n "$number" --arg at "$at" \
    'map(if .number == $n then .updated_at = $at else . end)' \
    "$store/issues.json" > "$store/issues.json.new" && mv "$store/issues.json.new" "$store/issues.json"
}

# An ISO stamp N seconds in the past, BSD date first and GNU second.
past_stamp() {
  local ago=$1
  date -u -r "$(( $(date -u +%s) - ago ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$(( $(date -u +%s) - ago ))" +%Y-%m-%dT%H:%M:%SZ
}

fixture() {
  local name=$1 home store fakebin
  home=$(make_home "$name")
  fakebin=$(make_fakebin "$home")
  store="$home/forge"
  activate "$home"
  printf '%s\n%s\n%s\n' "$home" "$store" "$fakebin"
}

path_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

# The id of the one letter this home has sent, read from its receipt.
sole_sent_id() {
  local f
  for f in "$1"/state/letterbox/sent/*.receipt; do
    [ -e "$f" ] || continue
    f=${f##*/}
    printf '%s\n' "${f%.receipt}"
    return 0
  done
  return 1
}

sole_outbox_id() {
  local f
  for f in "$1"/state/letterbox/outbox/*.json; do
    [ -e "$f" ] || continue
    f=${f##*/}
    printf '%s\n' "${f%.json}"
    return 0
  done
  return 1
}

count_files() {
  local f n=0
  for f in "$1"/*; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# ---------------------------------------------------------------------------
# inert by default

test_poll_unconfigured_is_a_hard_noop() {
  local home fakebin out rc
  home=$(make_home poll-inert)
  fakebin=$(make_fakebin "$home")
  out=$(run_poll "$home" "$home/forge" "$fakebin"); rc=$?
  expect_code 0 "$rc" "unconfigured poll exit"
  [ -z "$out" ] || fail "an unconfigured poll must be silent (got: $out)"
  assert_absent "$home/state/letterbox" "an unconfigured poll must create no state"
  [ ! -s "$home/forge/calls.log" ] || fail "an unconfigured poll must make no API call"
  pass "the letterbox poll is a hard no-op with no activation settings (inert default)"
}

test_poll_partial_configuration_stays_inert() {
  local home fakebin out rc
  home=$(make_home poll-partial)
  fakebin=$(make_fakebin "$home")
  printf 'FM_LETTERBOX_REPO=%s\nFM_LETTERBOX_SELF=%s\n' "$CHANNEL" "$SELF" > "$home/.env"
  out=$(run_poll "$home" "$home/forge" "$fakebin"); rc=$?
  expect_code 0 "$rc" "partially configured poll exit"
  [ -z "$out" ] || fail "a partial configuration must stay inert (got: $out)"
  assert_absent "$home/state/letterbox" "a partial configuration must create no state"
  pass "any missing activation setting leaves the whole feature inert"
}

test_poll_reports_a_configuration_fault_once() {
  local home fakebin out
  home=$(make_home poll-badconf)
  fakebin=$(make_fakebin "$home")
  activate "$home"
  printf 'FM_LETTERBOX_TRANSPORT=carrier-pigeon\n' >> "$home/.env"
  out=$(run_poll "$home" "$home/forge" "$fakebin")
  assert_contains "$out" "letterbox error: unsupported transport carrier-pigeon" \
    "an opted-in home with a broken setting must be told, not silently ignored"
  out=$(run_poll "$home" "$home/forge" "$fakebin")
  [ -z "$out" ] || fail "the same configuration fault must be announced once, not every cycle (got: $out)"
  pass "a configuration fault in an opted-in home is surfaced once, then rate-limited"
}

# ---------------------------------------------------------------------------
# arming, the shim, and the supervision predicate

test_arm_generates_the_shim_and_registers_it() {
  local home store fakebin out shim
  read -r home store fakebin <<< "$(fixture arm | tr '\n' ' ')"
  out=$(run_lb "$home" "$store" "$fakebin" arm) || fail "arm must succeed: $out"
  shim="$home/state/letterbox.check.sh"
  assert_present "$shim" "arm must generate state/letterbox.check.sh"
  [ "$(path_mode "$shim")" = 700 ] || fail "the shim must be mode 0700 (got $(path_mode "$shim"))"
  assert_present "$home/state/letterbox.check-trust" "arm must register the shim"
  [ "$(wc -l < "$shim" | tr -d ' ')" = 5 ] || fail "the shim must be the five-line shape"
  assert_grep "exec " "$shim" "the shim must exec the poll script"
  assert_grep "fm-letterbox-poll.sh" "$shim" "the shim must exec the letterbox poll"
  local d
  for d in inbox claims outbox sent; do
    assert_present "$home/state/letterbox/$d" "arm must create the $d directory"
    [ "$(path_mode "$home/state/letterbox/$d")" = 700 ] \
      || fail "state/letterbox/$d must be mode 0700"
  done
  # Idempotent.
  out=$(run_lb "$home" "$store" "$fakebin" arm) || fail "arm must be idempotent: $out"
  pass "arm generates the five-line shim at 0700, registers it, and is idempotent"
}

test_registered_shim_survives_the_watchers_validation() {
  local home store fakebin out
  read -r home store fakebin <<< "$(fixture arm-valid | tr '\n' ' ')"
  run_lb "$home" "$store" "$fakebin" arm >/dev/null || fail "arm must succeed"
  out=$(FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-check-lib.sh"
    fm_custom_check_registered "$2" letterbox && echo REGISTERED
    fm_custom_check_snapshot_prepare "$2" letterbox && echo SNAPSHOT
    fm_custom_check_snapshot_cleanup
  ' _ "$ROOT" "$home/state") || fail "the watcher's validation harness must run: $out"
  assert_contains "$out" REGISTERED "the shim must pass the registered-check predicate"
  assert_contains "$out" SNAPSHOT "the watcher must be able to snapshot the shim for execution"
  # Tampering must break the binding, which is the whole point of registration.
  printf 'echo tampered\n' >> "$home/state/letterbox.check.sh"
  out=$(bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-check-lib.sh"
    fm_custom_check_registered "$2" letterbox && echo STILL-REGISTERED
    echo CHECKED
  ' _ "$ROOT" "$home/state")
  assert_not_contains "$out" STILL-REGISTERED "an edited shim must lose its registration"
  pass "the generated shim registers through the ordinary custom-check path and is byte-bound"
}

test_supervision_is_required_with_only_the_letterbox_shim() {
  local home out
  home=$(make_home supervision)
  out=$(bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_supervision_status "$2"
    printf "empty=%s\n" "$FM_SUP_NEEDED"
    : > "$2/letterbox.check.sh"
    fm_supervision_status "$2"
    printf "letterbox=%s in_flight=%s sources=%s\n" "$FM_SUP_NEEDED" "$FM_SUP_IN_FLIGHT" "$FM_SUP_SOURCES"
  ' _ "$ROOT" "$home/state") || fail "supervision predicate harness must run: $out"
  assert_contains "$out" "empty=false" "an idle home with nothing armed needs no supervision"
  assert_contains "$out" "letterbox=true" \
    "a letterbox poll must make supervision required even with no fleet work"
  assert_contains "$out" "in_flight=0 sources=0" \
    "the letterbox must be the reason, not a stray task or event source"
  pass "the letterbox poll alone keeps supervision required, so a letter cannot wait for a session"
}

test_retire_removes_the_poll_and_keeps_the_records() {
  local home store fakebin out
  read -r home store fakebin <<< "$(fixture retire | tr '\n' ' ')"
  run_lb "$home" "$store" "$fakebin" arm >/dev/null || fail "arm must succeed"
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  out=$(run_lb "$home" "$store" "$fakebin" retire) || fail "retire must succeed: $out"
  assert_absent "$home/state/letterbox.check.sh" "retire must remove the shim"
  assert_absent "$home/state/letterbox.check-trust" "retire must remove the registration"
  assert_present "$home/state/letterbox/inbox/archie-20260824T140311Z-9f2c1ab4.json" \
    "retire must keep the letters it already received"
  pass "retire removes the poll and its registration while keeping durable records"
}

test_retire_fails_and_names_every_registration_artifact_left_behind() {
  local home store fakebin out rc
  read -r home store fakebin <<< "$(fixture retire-residual | tr '\n' ' ')"
  run_lb "$home" "$store" "$fakebin" arm >/dev/null || fail "arm must succeed"
  install_failing_rm_for "$fakebin" "$home/state/letterbox.check.sh"
  out=$(run_lb "$home" "$store" "$fakebin" retire 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "retire must fail while an armed shim remains"
  assert_contains "$out" "$home/state/letterbox.check.sh" "retire must name the artifact it could not remove"
  assert_not_contains "$out" "letterbox retired:" "retire must not claim that a residual shim was removed"
  assert_present "$home/state/letterbox.check.sh" "the injected removal failure must leave the shim in place"
  assert_absent "$home/state/letterbox.check-trust" "retire must still remove the independently removable registration"
  pass "retire reports failure and names every registration artifact still present"
}

# ---------------------------------------------------------------------------
# receiving

test_poll_stashes_claims_and_announces_a_new_letter() {
  local home store fakebin out inbox claim
  read -r home store fakebin <<< "$(fixture receive | tr '\n' ' ')"
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 fact-lookup "hermes cron toolset scope" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "letterbox 1 items: new archie-20260824T140311Z-9f2c1ab4 fact-lookup archie" \
    "the wake line must name the verb, the id, the class and the sender"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the poll must print exactly one line, so a busy cycle is still one wake"
  inbox="$home/state/letterbox/inbox/archie-20260824T140311Z-9f2c1ab4.json"
  claim="$home/state/letterbox/claims/archie-20260824T140311Z-9f2c1ab4.json"
  assert_present "$inbox" "the card must be stashed in the inbox"
  assert_present "$claim" "the id must be claimed"
  [ "$(path_mode "$inbox")" = 600 ] || fail "a stashed card must be mode 0600"
  [ "$(path_mode "$claim")" = 600 ] || fail "a claim must be mode 0600"
  assert_grep "hermes cron toolset scope" "$inbox" "the stashed card must carry the subject"
  assert_grep "Answer from your own config" "$inbox" "the stashed card must carry the body"
  # The content lives in the inbox, never in the wake line.
  assert_not_contains "$out" "Answer from your own config" \
    "the wake line is an event and must never carry the letter's content"
  pass "a new letter is stashed, claimed, and announced as one compact line"
}

test_second_sighting_of_the_same_letter_produces_nothing() {
  local home store fakebin out first
  read -r home store fakebin <<< "$(fixture claim-dedupe | tr '\n' ' ')"
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 >/dev/null
  first=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$first" "new archie-20260824T140311Z-9f2c1ab4" "the first sighting must announce"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a second sighting of a claimed id must print nothing (got: $out)"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "and a third (got: $out)"
  [ "$(count_files "$home/state/letterbox/claims")" = 1 ] \
    || fail "the same letter must be claimed exactly once"
  pass "an already-claimed letter is silent, so one letter is exactly one wake"
}

test_poll_ignores_a_letter_addressed_elsewhere() {
  local home store fakebin out
  read -r home store fakebin <<< "$(fixture not-ours | tr '\n' ' ')"
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 fact-lookup "not for us" "body" someone.else >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a letter addressed to another estate must be ignored (got: $out)"
  assert_absent "$home/state/letterbox/claims/archie-20260824T140311Z-9f2c1ab4.json" \
    "a letter addressed elsewhere must not even be claimed"
  pass "a letter addressed to another estate is ignored, never answered"
}

test_poll_announces_a_refused_card_once() {
  local home store fakebin out
  read -r home store fakebin <<< "$(fixture refuse | tr '\n' ' ')"
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 merge-pr "please merge" "body" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused archie-20260824T140311Z-9f2c1ab4 unknown-class" \
    "a card outside the class allowlist must be named as a refusal, so an 'unable' reply can follow"
  assert_absent "$home/state/letterbox/inbox/archie-20260824T140311Z-9f2c1ab4.json" \
    "a refused card must not be stashed as an accepted letter"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a refusal must be announced once, not every cycle (got: $out)"
  pass "a card that fails the grammar is refused, named once, and never stashed as accepted"
}

test_poll_refuses_credential_shaped_content_before_stashing_it() {
  local home store fakebin out secret
  read -r home store fakebin <<< "$(fixture scan | tr '\n' ' ')"
  # Synthetic, generated for this test, and not a real credential.
  secret="ghp_$(awk 'BEGIN { while (i++ < 36) printf "A" }')"
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 fact-lookup "a leak" "the value is $secret here" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused archie-20260824T140311Z-9f2c1ab4 provider-key-prefix" \
    "credential-shaped content must be refused, naming the class"
  assert_not_contains "$out" "$secret" "the refusal must never carry the value"
  assert_absent "$home/state/letterbox/inbox/archie-20260824T140311Z-9f2c1ab4.json" \
    "credential-shaped content must be refused BEFORE the inbox stash, not after"
  grep -rF "$secret" "$home/state" >/dev/null 2>&1 \
    && fail "no local state may contain the refused value"
  pass "the credential scan runs before the inbox stash and refuses rather than redacting"
}

# ---------------------------------------------------------------------------
# sending

test_send_writes_the_outbox_before_the_transport_call() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture send | tr '\n' ' ')"
  printf 'Does a cron job run with the CLI toolset?\n' > "$home/body.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class fact-lookup \
    --subject "hermes cron toolset scope" --file "$home/body.txt") || fail "send must succeed: $out"
  assert_contains "$out" "sent firstmate-" "send must report the letter it sent"
  id=$(sole_sent_id "$home")
  assert_present "$home/state/letterbox/outbox/$id.json" "the outbox record must exist"
  assert_present "$home/state/letterbox/sent/$id.receipt" "the receipt must exist"
  assert_grep "[letterbox] fact-lookup $id" "$store/issues.json" \
    "the issue title must be exactly [letterbox] <class> <id>"
  jq -e '[.[] | select(.title | test("hermes cron toolset scope"))] | length == 0' \
    "$store/issues.json" >/dev/null \
    || fail "the subject must live inside the card, never in the generated title"
  jq -e --arg t "[letterbox] fact-lookup $id" \
    '[.[] | select(.title == $t)] | length == 1' "$store/issues.json" >/dev/null \
    || fail "exactly one letter must have been created"
  pass "send records the id and bytes in the outbox first, then creates one letter"
}

test_send_adopts_an_existing_letter_instead_of_duplicating_it() {
  local home store fakebin out id titles
  read -r home store fakebin <<< "$(fixture idempotent | tr '\n' ' ')"
  printf 'first letter\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject "first" --file "$home/body.txt" >/dev/null \
    || fail "the first send must succeed"
  id=$(sole_sent_id "$home")
  # The exact crash the design's matrix covers: the forge write landed, the
  # receipt never did. The outbox record still holds the id chosen beforehand.
  rm -f "$home/state/letterbox/sent/$id.receipt"
  : > "$store/calls.log"
  printf 'second letter\n' > "$home/body2.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject "second" --file "$home/body2.txt") \
    || fail "the retry send must succeed: $out"
  assert_contains "$out" "adopted existing letter $id" \
    "the retry must adopt the existing letter by title-matched id"
  assert_present "$home/state/letterbox/sent/$id.receipt" "the adopted letter must get its receipt"
  titles=$(jq -r --arg t "[letterbox] fact-lookup $id" '[.[] | select(.title == $t)] | length' "$store/issues.json")
  [ "$titles" = 1 ] || fail "re-delivery must be a no-op, not a second letter (found $titles)"
  grep -F 'state=all' "$store/calls.log" >/dev/null \
    || fail "the retry must look the letter up by exact title, never through the search API"
  grep -F '/search/' "$store/calls.log" >/dev/null \
    && fail "the search API must never be used"
  [ "$(grep -c 'issue create' "$store/calls.log")" = 1 ] \
    || fail "the retry must create only the NEW letter, never a duplicate of the adopted one"
  pass "a send interrupted before its receipt adopts the existing letter; re-delivery is a no-op"
}

test_send_stops_when_reconciliation_lookup_fails() {
  local home store fakebin out rc id before after
  read -r home store fakebin <<< "$(fixture reconcile-lookup-failure | tr '\n' ' ')"
  printf 'first letter\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject first --file "$home/body.txt" >/dev/null \
    || fail "the first send must succeed"
  id=$(sole_sent_id "$home") || fail "the first send must leave a receipt"
  rm -f "$home/state/letterbox/sent/$id.receipt"
  : > "$store/fail-find-title"
  before=$(jq -r 'length' "$store/issues.json")
  printf 'second letter\n' > "$home/body2.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject second --file "$home/body2.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed reconciliation lookup must abort the send"
  assert_contains "$out" "cannot determine whether unsent letter $id already exists" \
    "a lookup failure must remain unknown rather than becoming an authoritative miss"
  after=$(jq -r 'length' "$store/issues.json")
  [ "$before" = "$after" ] || fail "a lookup failure must not create a duplicate or a new letter"
  assert_absent "$home/state/letterbox/sent/$id.receipt" \
    "the interrupted letter must remain in the unsent set for a later retry"
  pass "a reconciliation lookup failure aborts without creating a duplicate letter"
}

test_send_refuses_credential_shaped_content_before_any_write() {
  local home store fakebin out rc secret
  read -r home store fakebin <<< "$(fixture send-scan | tr '\n' ' ')"
  secret="sk-$(awk 'BEGIN { while (i++ < 48) printf "b" }')"
  printf 'the value is %s\n' "$secret" > "$home/body.txt"
  : > "$store/calls.log"
  out=$(run_lb "$home" "$store" "$fakebin" send --class fact-lookup \
    --subject "a leak" --file "$home/body.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a credential-shaped send must fail"
  assert_contains "$out" "credential-shaped content (provider-key-prefix)" \
    "the refusal must name the class"
  assert_not_contains "$out" "$secret" "the refusal must never carry the value"
  [ ! -s "$store/calls.log" ] || fail "nothing may reach the transport: $(cat "$store/calls.log")"
  ls "$home/state/letterbox/outbox/"*.json >/dev/null 2>&1 \
    && fail "nothing may reach the local outbox either"
  grep -rF "$secret" "$home/state" >/dev/null 2>&1 \
    && fail "no local state may contain the refused value"
  pass "a credential-shaped send is refused before the outbox write and before the transport call"
}

test_send_refuses_an_unlisted_class_and_a_host_path() {
  local home store fakebin out rc
  read -r home store fakebin <<< "$(fixture send-refuse | tr '\n' ' ')"
  printf 'body\n' > "$home/body.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class do-task --subject s --file "$home/body.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted class must not be sendable"
  assert_contains "$out" "not in the v1 allowlist" "the refusal must name the allowlist"
  printf 'the file is at /home/captain/notes.md\n' > "$home/path.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject s --file "$home/path.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a host path must not be sendable"
  assert_contains "$out" "absolute host path" "the refusal must name the host path"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject s --file "$home/body.txt" \
    --expires 2026-99-99T99:99:99Z 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an impossible calendar instant must not be sendable"
  assert_contains "$out" "must name a real ISO 8601 UTC instant" \
    "the sender must validate the calendar instant, not only its shape"
  [ ! -s "$store/calls.log" ] || fail "none of the refusals may reach the transport"
  pass "the sender enforces class, host-path, and real-expiry validation before transport"
}

# ---------------------------------------------------------------------------
# the visibility precondition

test_write_refuses_when_the_channel_is_not_private() {
  local home store fakebin out rc
  read -r home store fakebin <<< "$(fixture visibility | tr '\n' ' ')"
  printf 'false\n' > "$store/private"
  printf 'body\n' > "$home/body.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject "s" --file "$home/body.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a write into a public channel must be refused"
  assert_contains "$out" "refusing to write" "the refusal must be explicit"
  assert_contains "$out" "is not private" "the refusal must name the cause"
  [ "$(grep -c 'issue create' "$store/calls.log")" = 0 ] \
    || fail "no letter may be created while the channel is public"
  assert_present "$home/state/letterbox/write-error" \
    "the refusal must be recorded durably so it survives a lost turn"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "error: letterbox write refused" "the poll must raise the refused write as a wake"
  assert_contains "$out" "is not private" "the wake must name the visibility cause"
  # Back to private: normal operation resumes and the alarm clears.
  printf 'true\n' > "$store/private"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject "s" --file "$home/body.txt") \
    || fail "a private channel must accept the write again: $out"
  assert_absent "$home/state/letterbox/write-error" "a landed write must clear the alarm"
  pass "every write checks the channel is private, refuses if it is not, and raises a wake"
}

test_visibility_is_checked_before_a_reply_and_a_close() {
  local home store fakebin out rc number
  read -r home store fakebin <<< "$(fixture visibility-reply | tr '\n' ' ')"
  number=$(inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 fact-lookup "q" "body")
  run_poll "$home" "$store" "$fakebin" >/dev/null
  printf 'false\n' > "$store/private"
  printf 'the answer\n' > "$home/reply.txt"
  : > "$store/calls.log"
  out=$(run_lb "$home" "$store" "$fakebin" reply archie-20260824T140311Z-9f2c1ab4 \
    --status answered --file "$home/reply.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a reply into a public channel must be refused"
  assert_contains "$out" "refusing to write" "the reply refusal must be explicit"
  [ "$(grep -c 'issue comment' "$store/calls.log")" = 0 ] || fail "no reply may be posted"
  assert_absent "$store/comments-$number.json" "the forge must have received nothing"
  pass "the visibility precondition gates replies and closes, not only new letters"
}

# ---------------------------------------------------------------------------
# replying, consuming and closing

test_reply_posts_a_comment_and_never_closes_the_letter() {
  local home store fakebin out number
  read -r home store fakebin <<< "$(fixture reply | tr '\n' ' ')"
  number=$(inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 fact-lookup "q" "please answer")
  run_poll "$home" "$store" "$fakebin" >/dev/null
  printf 'Cron runs the CLI toolset; verified from the engine config.\n' > "$home/reply.txt"
  out=$(run_lb "$home" "$store" "$fakebin" reply archie-20260824T140311Z-9f2c1ab4 \
    --status answered --file "$home/reply.txt") || fail "reply must succeed: $out"
  assert_contains "$out" "the requester closes the letter" \
    "the responder must be told it does not close the letter"
  assert_present "$store/comments-$number.json" "the reply must be posted as a comment"
  assert_grep "in-reply-to: archie-20260824T140311Z-9f2c1ab4" "$store/comments-$number.json" \
    "the reply must correlate by card id, never by issue number"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "open"' \
    "$store/issues.json" >/dev/null \
    || fail "the responder must never close the letter"
  assert_grep '"replied":"answered"' <(jq -c . "$home/state/letterbox/claims/archie-20260824T140311Z-9f2c1ab4.json") \
    "the claim must record the terminal reply"
  pass "a reply is a comment correlated by card id, and the responder never closes"
}

test_close_closes_then_records_the_consumed_reply_and_dedupes_a_replay() {
  local home store fakebin out id number
  read -r home store fakebin <<< "$(fixture close | tr '\n' ' ')"
  printf 'Question for the peer.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject "q" --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home")
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" answered
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id answered" "a terminal peer reply must wake the requester"
  assert_present "$home/state/letterbox/inbox/archie-20260824T141902Z-3b71c40d.json" \
    "the reply must be stashed"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "an already-claimed reply must be silent (got: $out)"

  out=$(run_lb "$home" "$store" "$fakebin" close "$id") || fail "close must succeed: $out"
  assert_grep "archie-20260824T141902Z-3b71c40d" \
    <(jq -r '.consumed[]' "$home/state/letterbox/claims/$id.json") \
    "the consumed reply id must be recorded"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "closed"' \
    "$store/issues.json" >/dev/null || fail "the requester must close the letter"

  # A replayed reply must be dropped, not re-consumed, even if the claim marker
  # that suppresses re-announcement is gone.
  jq --argjson n "$number" 'map(if .number == $n then .state = "open" else . end)' \
    "$store/issues.json" > "$store/i.new" && mv "$store/i.new" "$store/issues.json"
  rm -f "$home/state/letterbox/claims/archie-20260824T141902Z-3b71c40d.json"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a replayed terminal reply must be dropped (got: $out)"
  pass "consuming a terminal reply closes the letter and records the reply id, so a replay is a no-op"
}

test_reply_refuses_a_letter_this_estate_sent() {
  local home store fakebin out rc id
  read -r home store fakebin <<< "$(fixture reply-refuse | tr '\n' ' ')"
  printf 'A question.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home")
  : > "$store/calls.log"
  out=$(run_lb "$home" "$store" "$fakebin" reply "$id" --status answered --file "$home/body.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "this estate must not reply to its own letter"
  assert_contains "$out" "nothing here to reply to" "the refusal must name the cause"
  [ "$(grep -c 'issue comment' "$store/calls.log")" = 0 ] || fail "nothing may be posted"
  pass "reply refuses a letter this estate sent, so an estate never answers itself"
}

test_close_refuses_without_a_terminal_reply_and_refuses_a_received_letter() {
  local home store fakebin out rc id
  read -r home store fakebin <<< "$(fixture close-refuse | tr '\n' ' ')"
  printf 'body\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject "q" --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home")
  out=$(run_lb "$home" "$store" "$fakebin" close "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "closing before a terminal reply must be refused"
  assert_contains "$out" "somebody still owes something" \
    "the refusal must name the open-issue invariant"
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  out=$(run_lb "$home" "$store" "$fakebin" close archie-20260824T140311Z-9f2c1ab4 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "the responder must not be able to close a received letter"
  assert_contains "$out" "the requester closes a letter, never the responder" \
    "the refusal must name who closes"
  pass "an open letter means somebody still owes something, and only the requester closes it"
}

test_a_notice_ack_is_the_terminal_reply_that_closes_the_exchange() {
  local home store fakebin out id number
  read -r home store fakebin <<< "$(fixture notice | tr '\n' ' ')"
  printf 'The fork now ships the letterbox poll.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject "letterbox armed" --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home")
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" ack "received"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id ack" \
    "a notice's ack is the terminal reply and must wake the requester"
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "the notice must be closeable on its ack"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "closed"' \
    "$store/issues.json" >/dev/null || fail "consuming the ack must close the notice"
  pass "a notice's ack is terminal and required, and closing it preserves the open-issue invariant"
}

test_protocol_unable_is_legal_for_a_notice_and_a_parse_refusal() {
  local home store fakebin out notice_id refused_id notice_number refused_number
  read -r home store fakebin <<< "$(fixture protocol-unable | tr '\n' ' ')"
  notice_id=archie-20260824T140311Z-9f2c1ab4
  refused_id=archie-20260824T140411Z-0badcafe
  notice_number=$(inject_letter "$store" "$notice_id" notice "an announcement" "information")
  run_poll "$home" "$store" "$fakebin" >/dev/null
  printf 'the notice could not be accepted\n' > "$home/unable.txt"
  out=$(run_lb "$home" "$store" "$fakebin" reply "$notice_id" --status unable --file "$home/unable.txt") \
    || fail "a protocol-level unable must be legal for a notice: $out"
  assert_grep "status: unable" "$store/comments-$notice_number.json" \
    "the unable notice reply must reach the forge"

  refused_number=$(inject_letter "$store" "$refused_id" merge-pr "not a v1 class" "body")
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused $refused_id unknown-class" "the parse refusal must be surfaced"
  out=$(run_lb "$home" "$store" "$fakebin" reply "$refused_id" --status unable --file "$home/unable.txt") \
    || fail "a protocol-level unable must be legal for a parse-refused card: $out"
  assert_grep "status: unable" "$store/comments-$refused_number.json" \
    "the parse-refusal unable reply must reach the forge"
  pass "unable is a protocol-level refusal accepted for notices and parse-refused cards"
}

test_consuming_an_unable_notice_closes_and_records_the_resend_obligation() {
  local home store fakebin out id number reply_id
  read -r home store fakebin <<< "$(fixture notice-unable-resend | tr '\n' ' ')"
  printf 'The notice that may need correction.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject update --file "$home/body.txt" >/dev/null \
    || fail "the notice send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  reply_id=archie-20260824T141902Z-3b71c40d
  inject_reply "$store" "$number" "$reply_id" "$id" unable "the notice could not be accepted"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id unable" "an unable notice is terminal and must wake the requester"
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "the unable notice must close"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "closed"' \
    "$store/issues.json" >/dev/null || fail "consuming the unable reply must close the notice"
  [ "$(jq -r '.resend_required' "$home/state/letterbox/claims/$id.json")" = true ] \
    || fail "the claim must durably record that a corrected notice is still required"
  assert_grep "$reply_id" <(jq -r '.consumed[]' "$home/state/letterbox/claims/$id.json") \
    "the unable reply must still be consumed exactly like another terminal reply"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "RESEND REQUIRED: $id notice" \
    "the handling interface must keep the corrected-notice obligation visible"
  pass "an unable notice closes while its corrected-notice resend remains durable and visible"
}

test_a_failed_close_record_leaves_the_obligation_visible_and_retryable() {
  local home store fakebin out rc id number reply_id
  read -r home store fakebin <<< "$(fixture close-record-atomic | tr '\n' ' ')"
  printf 'The notice that may need correction.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject update --file "$home/body.txt" >/dev/null \
    || fail "the notice send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  reply_id=archie-20260824T141902Z-3b71c40d
  inject_reply "$store" "$number" "$reply_id" "$id" unable "the notice could not be accepted"
  run_poll "$home" "$store" "$fakebin" >/dev/null

  # Let the forge close land and fail the local claim record that follows it.
  printf '0\n' > "$home/mktemp.count"
  out=$(env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_STORE="$store" \
    LB_MKTEMP_ALLOW=0 LB_MKTEMP_COUNTER="$home/mktemp.count" \
    "$ROOT/bin/fm-letterbox.sh" close "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a close whose record cannot be written must fail loudly"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "closed"' \
    "$store/issues.json" >/dev/null || fail "the forge close must still have landed"

  # Nothing was consumed, so the letter is still reported as awaiting a reply
  # and the close is simply retryable. Under a half-written record status would
  # suppress the consumed sent claim and the stale backstop needs an open issue,
  # so nothing would ask for the retry.
  [ "$(jq -r '.consumed | length' "$home/state/letterbox/claims/$id.json")" = 0 ] \
    || fail "a failed close record must consume nothing, or the obligation goes invisible"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "1 sent and awaiting a reply from the peer" \
    "the letter must stay visible as an outstanding obligation after a failed close record"

  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "the retry must complete the close"
  assert_grep "$reply_id" <(jq -r '.consumed[]' "$home/state/letterbox/claims/$id.json") \
    "the retry must consume the reply"
  [ "$(jq -r '.resend_required' "$home/state/letterbox/claims/$id.json")" = true ] \
    || fail "the retry must record the resend obligation in the same rewrite"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "RESEND REQUIRED: $id notice" \
    "the corrected-notice obligation must be visible once the record lands"
  pass "a close whose record fails consumes nothing, stays visible in status, and is retryable"
}

test_the_close_record_survives_only_one_claim_write() {
  local home store fakebin id number reply_id consumed resend
  read -r home store fakebin <<< "$(fixture close-record-single | tr '\n' ' ')"
  printf 'The notice.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject update --file "$home/body.txt" >/dev/null \
    || fail "the notice send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  reply_id=archie-20260824T141902Z-3b71c40d
  inject_reply "$store" "$number" "$reply_id" "$id" unable "the notice could not be accepted"
  run_poll "$home" "$store" "$fakebin" >/dev/null

  # Allow exactly ONE claim write during the close. This is the assertion that
  # discriminates: as two sequential writes the consume lands and the resend
  # flag does not, leaving a closed issue, a consumed reply and no visible
  # obligation. As one rewrite both halves land together or neither does.
  printf '0\n' > "$home/mktemp.count"
  env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_STORE="$store" \
    LB_MKTEMP_ALLOW=1 LB_MKTEMP_COUNTER="$home/mktemp.count" \
    "$ROOT/bin/fm-letterbox.sh" close "$id" >/dev/null 2>&1
  consumed=$(jq -r '.consumed | length' "$home/state/letterbox/claims/$id.json")
  resend=$(jq -r '.resend_required' "$home/state/letterbox/claims/$id.json")
  if [ "$consumed" != 0 ] && [ "$resend" != true ]; then
    fail "half-written close record: the reply is consumed but the resend obligation is invisible (consumed=$consumed resend=$resend)"
  fi
  [ "$consumed" = 1 ] && [ "$resend" = true ] \
    || fail "one claim write must carry both halves (consumed=$consumed resend=$resend)"
  pass "the close record survives on a single claim write, so it can never be half-written"
}

test_a_corrected_notice_discharges_the_resend_obligation_through_send() {
  local home store fakebin out rc id number new_id
  read -r home store fakebin <<< "$(fixture notice-resends | tr '\n' ' ')"
  printf 'The notice that needs correction.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject update --file "$home/body.txt" >/dev/null \
    || fail "the notice send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  printf 'The corrected notice.\n' > "$home/fixed.txt"
  # Before the peer has refused it there is nothing to re-send.
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject fixed --file "$home/fixed.txt" --resends "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--resends must refuse a notice that does not require a resend"
  assert_contains "$out" "does not require a resend" "the refusal must say why"
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" unable "not acceptable"
  run_poll "$home" "$store" "$fakebin" >/dev/null
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "the unable notice must close"
  out=$(run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/fixed.txt" --resends "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--resends must refuse a corrected letter that is not a notice"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject fixed --file "$home/fixed.txt" --resends "$id") \
    || fail "the corrected notice must send: $out"
  new_id=$(printf '%s\n' "$out" | sed -n 's/^sent \([^ ]*\) .*/\1/p')
  [ -n "$new_id" ] && [ "$new_id" != "$id" ] || fail "the corrected notice must carry a new id (got: $out)"
  assert_contains "$out" "recorded $new_id as the corrected notice for $id" "send must report the discharge"
  [ "$(jq -r '.resent_as' "$home/state/letterbox/claims/$id.json")" = "$new_id" ] \
    || fail "resent_as must be recorded on the refused notice's claim"
  [ "$(jq -r '.resend_required' "$home/state/letterbox/claims/$id.json")" = "" ] \
    || fail "the resend obligation must be cleared"
  [ "$(jq -r '.resends' "$home/state/letterbox/outbox/$new_id.json")" = "$id" ] \
    || fail "the outbox record must carry what it resends, so a retry completes the same discharge"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_not_contains "$out" "RESEND REQUIRED" "a discharged obligation must no longer be reported"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject again --file "$home/fixed.txt" --resends "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a notice already re-sent must not be re-sent again through --resends"
  assert_contains "$out" "already re-sent as $new_id" "the second discharge must be refused by name"
  pass "send --resends discharges the resend obligation in the receipt's own success boundary"
}

test_a_landed_letter_is_adopted_even_when_its_bytes_now_fail_the_gate() {
  local home store fakebin out id number
  read -r home store fakebin <<< "$(fixture adopt-past-gate | tr '\n' ' ')"
  printf 'ordinary question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject first --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  # A crash after the forge create and before any local record: the issue is
  # open at the peer, and the outbox bytes would fail today's gate.
  rm -f "$home/state/letterbox/sent/$id.receipt" "$home/state/letterbox/claims/$id.json"
  jq '.card = (.card + "\nsee ~/notes")' "$home/state/letterbox/outbox/$id.json" > "$home/o.new" \
    && cat "$home/o.new" > "$home/state/letterbox/outbox/$id.json"
  printf 'second letter\n' > "$home/body2.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject second --file "$home/body2.txt" 2>&1) \
    || fail "the next send must succeed: $out"
  assert_contains "$out" "adopted existing letter $id as issue $number" "a landed letter must be adopted, not gated"
  assert_not_contains "$out" "UNSENDABLE" "adoption transmits nothing, so the gate must not apply to it"
  assert_present "$home/state/letterbox/sent/$id.receipt" "adoption must complete the receipt"
  assert_present "$home/state/letterbox/claims/$id.json" "adoption must record the sent claim"
  [ "$(jq -r '.issue' "$home/state/letterbox/claims/$id.json")" = "$number" ] \
    || fail "the adopted claim must correlate to the existing issue"
  [ "$(grep -c "\[letterbox\] fact-lookup $id" "$store/issues.json")" = 1 ] || fail "no duplicate may be created"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_not_contains "$out" "UNSENDABLE" "an adopted letter is no longer unsent"
  pass "an outbox record whose issue already landed is adopted before any gate is applied"
}

# A crash at the exact moment the receipt is published: the private-artifact
# publisher's final step is `mv` of the staged receipt into state/letterbox/sent,
# so a fakebin `mv` that refuses that one destination fails the publish and
# nothing else. (A mode-500 sent directory cannot model this: ensure_dirs runs
# before any bookkeeping and refuses a directory that is not mode 700, so the
# send would die too early under either ordering.)
install_receipt_crashing_mv() {
  local fakebin=$1 real
  real=$(command -v mv)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
for a in "\$@"; do :; done
case "\$a" in */sent/*.receipt) exit 1 ;; esac
exec "$real" "\$@"
SH
  chmod +x "$fakebin/mv"
}

test_a_crash_before_the_resend_receipt_is_completed_by_the_retry() {
  local home store fakebin out rc id number new_id
  read -r home store fakebin <<< "$(fixture resend-crash | tr '\n' ' ')"
  printf 'notice\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject update --file "$home/body.txt" >/dev/null \
    || fail "the notice send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" unable "not acceptable"
  run_poll "$home" "$store" "$fakebin" >/dev/null
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "the unable notice must close"
  printf 'fixed\n' > "$home/fixed.txt"
  install_receipt_crashing_mv "$fakebin"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject fixed --file "$home/fixed.txt" --resends "$id" 2>&1); rc=$?
  rm -f "$fakebin/mv"
  [ "$rc" -ne 0 ] || fail "the send must fail when its receipt cannot be published (got: $out)"
  assert_contains "$out" "cannot record the receipt" "the failure must be the receipt publish itself"
  new_id=$(for f in "$home"/state/letterbox/outbox/*.json; do
    f=${f##*/}; f=${f%.json}
    [ -e "$home/state/letterbox/sent/$f.receipt" ] || { printf '%s\n' "$f"; break; }
  done)
  [ -n "$new_id" ] || fail "the corrected notice must have an outbox record with no receipt"
  [ "$new_id" != "$id" ] || fail "the corrected notice must carry a new id"
  assert_absent "$home/state/letterbox/sent/$new_id.receipt" "the crash left no receipt"
  # The discriminating assertion: the bookkeeping precedes the receipt, so it
  # is already durable when the receipt publish dies.
  [ "$(jq -r '.resent_as' "$home/state/letterbox/claims/$id.json")" = "$new_id" ] \
    || fail "resent_as must already be recorded before the receipt is published"
  [ "$(jq -r '.resend_required' "$home/state/letterbox/claims/$id.json")" = "" ] \
    || fail "resend_required must already be cleared before the receipt is published"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "UNSENT: $new_id" "the interrupted letter must stay in the unsent set"
  assert_not_contains "$out" "RESEND REQUIRED" "the obligation must not reappear"
  : > "$home/empty.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class ping --subject p --file "$home/empty.txt" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "the retry send must succeed: $out"
  assert_contains "$out" "adopted existing letter $new_id" "the retry must adopt the corrected notice"
  assert_present "$home/state/letterbox/sent/$new_id.receipt" "the retry must complete the receipt"
  [ "$(jq -r '.resent_as' "$home/state/letterbox/claims/$id.json")" = "$new_id" ] \
    || fail "the discharge must survive the retry"
  [ "$(jq -r '.resend_required' "$home/state/letterbox/claims/$id.json")" = "" ] \
    || fail "the obligation must stay cleared"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject again --file "$home/fixed.txt" --resends "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a re-sent notice must not be re-sent again"
  assert_contains "$out" "already re-sent as $new_id" "the completed discharge must be refused by name"
  pass "a crash at the receipt publish leaves the resend bookkeeping durable and the letter unsent, and the retry completes it"
}

test_link_records_the_owning_task_through_a_supported_verb() {
  local home store fakebin out rc id
  read -r home store fakebin <<< "$(fixture link-task | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" work-proposal "p" "a proposal" >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  out=$(run_lb "$home" "$store" "$fakebin" link "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "link without --task must be refused"
  out=$(run_lb "$home" "$store" "$fakebin" link "$id" --task "../escape" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "link must refuse a task id that is not a plain name"
  out=$(run_lb "$home" "$store" "$fakebin" link "$id" --task letter-work-1) || fail "link must succeed: $out"
  assert_contains "$out" "linked $id -> task letter-work-1" "link must report the record"
  [ "$(jq -r '.task' "$home/state/letterbox/claims/$id.json")" = letter-work-1 ] \
    || fail "the task must be recorded on the claim"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "OWED: $id work-proposal -> task letter-work-1" "status must show the owning task"
  printf 'body\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject s --file "$home/body.txt" >/dev/null || fail "send must succeed"
  out=$(run_lb "$home" "$store" "$fakebin" link "$(sole_sent_id "$home")" --task other 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a letter this estate sent is not owned by a task"
  pass "link records the owning task on a received letter's claim without touching private state by hand"
}

test_a_refused_card_with_no_usable_id_is_unanswerable_not_owed() {
  local home store fakebin out n card
  read -r home store fakebin <<< "$(fixture unanswerable | tr '\n' ' ')"
  n=$(cat "$store/next"); printf '%s\n' "$((n + 1))" > "$store/next"
  # shellcheck disable=SC2016 # Backticks are the literal card fence, not a substitution.
  card=$(printf '```letterbox/v1\nkind: request\nv: 1\nid: not an id\nfrom: archie\nto: firstmate.shipyard\nclass: ping\nissued: %s\nsubject: s\nbody: |\n```\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  jq --argjson n "$n" --arg b "$card" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{number: $n, title: "x", body: $b, state: "open", user: {login: "archie"}, updated_at: $at}]' \
    "$store/issues.json" > "$store/i.new" && mv "$store/i.new" "$store/issues.json"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused issue-$n bad-id" "the malformed card must be announced under its issue key"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "UNANSWERABLE: issue-$n bad-id" "status must list the synthetic key as unanswerable"
  assert_not_contains "$out" "OWED: issue-$n" "a card nothing can reply to must never be counted as owed"
  assert_contains "$out" "0 letter(s) awaiting a reply from this estate" "the owed count must exclude it"
  assert_contains "$out" "1 unanswerable" "the summary must count it separately"
  pass "a parse-refused card with no usable id is reported as unanswerable rather than as an obligation"
}

test_an_ack_on_any_other_class_leaves_the_exchange_open() {
  local home store fakebin out id number
  read -r home store fakebin <<< "$(fixture ack-open | tr '\n' ' ')"
  printf 'A real question.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject "q" --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home")
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" ack "working on it"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a non-terminal ack must not be consumed as an answer (got: $out)"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "open"' \
    "$store/issues.json" >/dev/null || fail "the letter must stay open while an answer is still owed"
  pass "an ack on a class other than notice leaves the letter open, as an owed answer"
}

test_a_letter_announced_but_not_yet_claimed_is_announced_again() {
  local home store fakebin out id claims
  read -r home store fakebin <<< "$(fixture crash-claim | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" fact-lookup "q" "the content that must survive" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "new $id" "the first intake must announce"
  assert_present "$home/state/letterbox/claims/$id.json" "the claim must be taken after the announcement"

  # The crash window claim-last exists for: the card was stashed and announced,
  # and the process died before the claim landed. Losing a letter is
  # unrecoverable and announcing one twice is not, so the next poll must
  # announce it again rather than assume it was handled.
  rm -f "$home/state/letterbox/claims/$id.json"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "new $id" "an unclaimed card must be announced again (at-least-once)"
  assert_present "$home/state/letterbox/claims/$id.json" "the repeat must complete the claim"
  assert_grep "the content that must survive" "$home/state/letterbox/inbox/$id.json" \
    "the repeated intake must leave the full content stashed"
  claims=$(count_files "$home/state/letterbox/claims")
  [ "$claims" = 1 ] || fail "one card must produce one claim, not $claims"

  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "once the claim exists the card is complete and silent (got: $out)"
  pass "a card announced but not yet claimed is announced again: announcement is at-least-once"
}

test_a_claimed_letter_is_not_reannounced_when_its_stash_is_removed() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture claim-boundary | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" fact-lookup "q" "please answer" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "new $id" "the first intake must announce"
  # The claim is taken last, so its presence proves the card was stashed AND
  # announced. A stash removed afterwards is a lost cache entry, not an
  # unannounced letter, and the forge remains the record.
  rm -f "$home/state/letterbox/inbox/$id.json"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a claimed card must not be re-announced (got: $out)"
  pass "the claim is the completion boundary: a claimed card is never re-announced"
}

test_reply_works_before_the_claim_exists() {
  local home store fakebin out number id
  read -r home store fakebin <<< "$(fixture reply-unclaimed | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  number=$(inject_letter "$store" "$id" fact-lookup "q" "please answer")
  run_poll "$home" "$store" "$fakebin" >/dev/null
  # The at-least-once window: a handling turn can reach the letter before its
  # claim landed, so replying must work from the stashed card alone.
  rm -f "$home/state/letterbox/claims/$id.json"
  printf 'the answer\n' > "$home/reply.txt"
  out=$(run_lb "$home" "$store" "$fakebin" reply "$id" --status answered --file "$home/reply.txt") \
    || fail "reply must work before the claim exists: $out"
  assert_grep "in-reply-to: $id" "$store/comments-$number.json" "the reply must be posted"
  assert_grep '"replied":"answered"' <(jq -c . "$home/state/letterbox/claims/$id.json") \
    "replying must create the claim it records itself in"
  pass "a reply works inside the at-least-once window, before the claim exists"
}

test_an_answered_letter_is_not_redone_when_its_stash_is_cleaned_up() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture answered-cleanup | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" fact-lookup "q" "please answer" >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  printf 'the answer\n' > "$home/reply.txt"
  run_lb "$home" "$store" "$fakebin" reply "$id" --status answered --file "$home/reply.txt" >/dev/null \
    || fail "reply must succeed"
  rm -f "$home/state/letterbox/inbox/$id.json"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a letter this estate already answered is finished, not incomplete (got: $out)"
  pass "an already-answered letter is not redone merely because its stash was cleaned up"
}

test_a_refused_card_is_not_redone_for_having_no_stash() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture crash-refused | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" merge-pr "please merge" "body" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused $id unknown-class" "the refusal must be announced"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a refused card deliberately has no stash and must not be redone (got: $out)"
  pass "a refused card has no stash by design and is never mistaken for an incomplete intake"
}

test_close_interrupted_after_the_forge_close_re_closes_harmlessly() {
  local home store fakebin out id number
  read -r home store fakebin <<< "$(fixture crash-close | tr '\n' ' ')"
  printf 'Question for the peer.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject "q" --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home")
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" answered
  run_poll "$home" "$store" "$fakebin" >/dev/null
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "close must succeed"

  # The crash window the requester order exists for: the forge close landed, the
  # consumed record did not. Re-running close must be harmless and must complete
  # the record rather than leaving the reply unrecorded forever.
  jq '.consumed = []' "$home/state/letterbox/claims/$id.json" > "$home/c.new" \
    && cat "$home/c.new" > "$home/state/letterbox/claims/$id.json"
  out=$(run_lb "$home" "$store" "$fakebin" close "$id") || fail "a repeated close must be harmless: $out"
  assert_contains "$out" "closed $id" "the repeated close must succeed"
  assert_grep "archie-20260824T141902Z-3b71c40d" \
    <(jq -r '.consumed[]' "$home/state/letterbox/claims/$id.json") \
    "the repeated close must complete the consumed record"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "closed"' \
    "$store/issues.json" >/dev/null || fail "the letter must remain closed"
  pass "a close interrupted before its record re-closes harmlessly and completes the record"
}

test_close_never_records_a_consumed_reply_it_could_not_close() {
  local home store fakebin out rc id number
  read -r home store fakebin <<< "$(fixture crash-close-refused | tr '\n' ' ')"
  printf 'Question for the peer.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject "q" --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home")
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" answered
  run_poll "$home" "$store" "$fakebin" >/dev/null
  printf 'false\n' > "$store/private"
  out=$(run_lb "$home" "$store" "$fakebin" close "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a close into a public channel must be refused"
  [ "$(jq -r '.consumed | length' "$home/state/letterbox/claims/$id.json")" = 0 ] \
    || fail "a reply must not be recorded as consumed when the close never happened"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "open"' \
    "$store/issues.json" >/dev/null || fail "the letter must still be open"
  pass "a refused close records nothing, so the letter stays visibly owed"
}

# ---------------------------------------------------------------------------
# regressions for the sequences the independent cross-vendor review reproduced

test_death_between_the_sent_claim_and_the_receipt_stays_reconcilable() {
  local home store fakebin out id titles
  read -r home store fakebin <<< "$(fixture blocker1 | tr '\n' ' ')"
  printf 'first letter\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject first --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  # The claim is published BEFORE the receipt, so this is the only crash window
  # that order leaves: claim present, receipt absent. It must stay reconcilable.
  rm -f "$home/state/letterbox/sent/$id.receipt"
  assert_present "$home/state/letterbox/claims/$id.json" "the sent claim must already exist"
  printf 'second letter\n' > "$home/body2.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject second --file "$home/body2.txt") \
    || fail "the next send must reconcile the interrupted one: $out"
  assert_contains "$out" "adopted existing letter $id" "the interrupted letter must be adopted, not duplicated"
  assert_present "$home/state/letterbox/sent/$id.receipt" "the receipt must be completed"
  titles=$(jq -r --arg t "[letterbox] fact-lookup $id" '[.[] | select(.title == $t)] | length' "$store/issues.json")
  [ "$titles" = 1 ] || fail "reconciliation must not create a duplicate letter (found $titles)"
  pass "a death between the sent claim and its receipt leaves the letter reconcilable, never stranded"
}

test_a_retried_outbox_card_is_rescanned_before_transport() {
  local home store fakebin out rc id secret before after
  read -r home store fakebin <<< "$(fixture blocker2 | tr '\n' ' ')"
  printf 'ordinary question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject first --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  # Model an interrupted send whose issue never landed, then tamper with the
  # durable outbox bytes. The outbox is neither immutable nor hash-bound, so the
  # scan that ran before the FIRST transport call is not a scan before this one.
  rm -f "$home/state/letterbox/sent/$id.receipt"
  jq --argjson n "$(jq -r --arg t "[letterbox] fact-lookup $id" '[.[] | select(.title == $t) | .number] | first' "$store/issues.json")" \
    'map(select(.number != $n))' "$store/issues.json" > "$store/i.new" && mv "$store/i.new" "$store/issues.json"
  secret="ghp_$(awk 'BEGIN { while (i++ < 36) printf "A" }')"
  jq --arg s "$secret" '.card = (.card + "\n" + $s)' "$home/state/letterbox/outbox/$id.json" > "$home/o.new" \
    && cat "$home/o.new" > "$home/state/letterbox/outbox/$id.json"
  before=$(jq -r 'length' "$store/issues.json")
  printf 'second letter\n' > "$home/body2.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject second --file "$home/body2.txt" 2>&1); rc=$?
  expect_code 0 "$rc" "a poisoned outbox record must not block an unrelated send"
  assert_contains "$out" "UNSENDABLE: $id" "the refused retry must be reported by id"
  assert_contains "$out" "credential-shaped content" "the refusal must name the class"
  assert_not_contains "$out" "$secret" "the refusal must never carry the value"
  after=$(jq -r 'length' "$store/issues.json")
  [ "$((before + 1))" = "$after" ] || fail "only the new letter may reach the forge, never the refused retry"
  grep -rF "$secret" "$store" >/dev/null 2>&1 && fail "no forge state may contain the refused value"
  assert_present "$home/state/letterbox/outbox/$id.json" "the unsendable record must be kept, not discarded"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "UNSENDABLE: $id (credential-shaped content" "status must keep the record and its reason visible"
  pass "a retried outbox card is re-scanned on its exact recovered bytes, refused, reported and stepped past"
}

test_a_retried_outbox_card_is_host_path_checked_before_transport() {
  local home store fakebin out rc id before after
  read -r home store fakebin <<< "$(fixture blocker2b | tr '\n' ' ')"
  printf 'ordinary question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject first --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  rm -f "$home/state/letterbox/sent/$id.receipt"
  jq --argjson n "$(jq -r --arg t "[letterbox] fact-lookup $id" '[.[] | select(.title == $t) | .number] | first' "$store/issues.json")" \
    'map(select(.number != $n))' "$store/issues.json" > "$store/i.new" && mv "$store/i.new" "$store/issues.json"
  jq '.card = (.card + "\nfile:///home/captain/secret")' "$home/state/letterbox/outbox/$id.json" > "$home/o.new" \
    && cat "$home/o.new" > "$home/state/letterbox/outbox/$id.json"
  before=$(jq -r 'length' "$store/issues.json")
  printf 'second letter\n' > "$home/body2.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject second --file "$home/body2.txt" 2>&1); rc=$?
  expect_code 0 "$rc" "a retry naming a host path must not block an unrelated send"
  assert_contains "$out" "UNSENDABLE: $id (absolute host path" "the refusal must name the host path"
  after=$(jq -r 'length' "$store/issues.json")
  [ "$((before + 1))" = "$after" ] || fail "only the new letter may reach the forge, never the refused retry"
  grep -F 'file:///home/captain/secret' "$store/issues.json" >/dev/null && fail "the host path must never reach the forge"
  pass "a retried outbox card is host-path checked on its exact recovered bytes, refused and stepped past"
}

test_a_retried_outbox_card_must_pass_the_complete_sender_grammar() {
  local mode home store fakebin out rc id number before after huge
  for mode in higher-version forbidden-authority wrong-recipient oversized-body; do
    read -r home store fakebin <<< "$(fixture "retry-grammar-$mode" | tr '\n' ' ')"
    printf 'ordinary question\n' > "$home/body.txt"
    run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject first --file "$home/body.txt" >/dev/null \
      || fail "the seed send must succeed for $mode"
    id=$(sole_sent_id "$home") || fail "the seed send must leave a receipt for $mode"
    number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
    rm -f "$home/state/letterbox/sent/$id.receipt"
    jq --argjson n "$number" 'map(select(.number != $n))' "$store/issues.json" > "$store/i.new" \
      && mv "$store/i.new" "$store/issues.json"
    case "$mode" in
      higher-version)
        jq '.card |= sub("v: 1"; "v: 2")' "$home/state/letterbox/outbox/$id.json" > "$home/o.new"
        ;;
      forbidden-authority)
        jq --arg replacement $'authority: captain\nsubject: first' \
          '.card |= sub("subject: first"; $replacement)' \
          "$home/state/letterbox/outbox/$id.json" > "$home/o.new"
        ;;
      wrong-recipient)
        jq '.card |= sub("to: archie"; "to: another-estate")' \
          "$home/state/letterbox/outbox/$id.json" > "$home/o.new"
        ;;
      oversized-body)
        huge=$(awk 'BEGIN { while (i++ < 9000) printf "x" }')
        jq --arg body "$huge" '.card |= sub("  ordinary question"; ("  " + $body))' \
          "$home/state/letterbox/outbox/$id.json" > "$home/o.new"
        ;;
    esac
    mv "$home/o.new" "$home/state/letterbox/outbox/$id.json"
    before=$(jq -r 'length' "$store/issues.json")
    printf 'second letter\n' > "$home/body2.txt"
    out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject second --file "$home/body2.txt" 2>&1); rc=$?
    expect_code 0 "$rc" "a recovered $mode card must not block an unrelated send"
    assert_contains "$out" "UNSENDABLE: $id" "the recovered-card refusal must be explicit for $mode"
    after=$(jq -r 'length' "$store/issues.json")
    [ "$((before + 1))" = "$after" ] || fail "a recovered $mode card must not reach the forge"
    grep -F "[letterbox] fact-lookup $id" "$store/issues.json" >/dev/null && fail "the refused $mode retry must not be created"
  done
  pass "every recovered outbox card passes the full sender grammar and addressing checks, or is skipped and reported"
}

test_send_refuses_every_absolute_host_path_form() {
  local home store fakebin out rc form
  read -r home store fakebin <<< "$(fixture blocker3 | tr '\n' ' ')"
  # shellcheck disable=SC2088 # The literal, unexpanded tilde form is the input under test.
  for form in "/etc" "file:///home/captain/secret" "path:/Users/captain/secret" "/home/captain/secret" "~/.ssh/id_rsa"; do
    printf 'the value lives at %s on that host\n' "$form" > "$home/body.txt"
    : > "$store/calls.log"
    out=$(run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "an absolute host path must not be sendable: $form"
    assert_contains "$out" "absolute host path" "the refusal must name the host path for $form"
    [ "$(grep -c 'issue create' "$store/calls.log")" = 0 ] || fail "nothing may reach the forge for $form"
  done
  # The positive control: a network URL, a relative path and ordinary prose
  # with a spaced slash are not host paths.
  printf 'See https://example.test/releases/v2 and the docs/letterbox page, read / write, 50 / 2.\n' > "$home/ok.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/ok.txt" >/dev/null \
    || fail "a URL, a relative path and a spaced slash must remain sendable"
  pass "root-level, file-URI, label-prefixed and home-relative paths are all refused; URLs and prose still pass"
}

test_a_card_with_an_unknown_kind_is_refused_not_ignored() {
  local home store fakebin out n
  read -r home store fakebin <<< "$(fixture blocker4 | tr '\n' ' ')"
  n=$(cat "$store/next"); printf '%s\n' "$((n + 1))" > "$store/next"
  # shellcheck disable=SC2016 # Backticks are the literal card fence, not a substitution.
  jq --argjson n "$n" --arg t "[letterbox] fact-lookup archie-20260824T140311Z-9f2c1ab4" \
    --arg b "$(printf 'prose\n\n```letterbox/v1\nkind: dispatch\nv: 1\nid: archie-20260824T140311Z-9f2c1ab4\nfrom: archie\nto: firstmate.shipyard\nclass: fact-lookup\nissued: %s\nsubject: q\nbody: |\n  do this\n```\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{number: $n, title: $t, body: $b, state: "open", user: {login: "archie"}, updated_at: $at}]' \
    "$store/issues.json" > "$store/i.new" && mv "$store/i.new" "$store/issues.json"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused" "a fenced card with an unknown kind must be refused, never ignored"
  assert_contains "$out" "bad-kind" "the refusal must name the fault class"
  [ "$(count_files "$home/state/letterbox/claims")" -ge 1 ] \
    || fail "a refused card must leave a claim, so it has backstop state"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "the refusal must be announced once, not every cycle (got: $out)"
  pass "a fenced card with an unknown kind is a named bad-kind refusal, not a silent ignore"
}

test_a_parse_refused_reply_is_named_before_the_cursor_advances() {
  local home store fakebin out id number card cid
  read -r home store fakebin <<< "$(fixture high6 | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  # A correlated reply refused at parse - here for an unsupported version.
  # shellcheck disable=SC2016 # Backticks are the literal card fence, not a substitution.
  card=$(printf 'prose\n\n```letterbox/v1\nkind: reply\nv: 2\nid: archie-20260824T141902Z-3b71c40d\nin-reply-to: %s\nfrom: archie\nto: firstmate.shipyard\nstatus: answered\nissued: %s\nbody: |\n  an answer\n```\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  [ -f "$store/comments-$number.json" ] || printf '[]\n' > "$store/comments-$number.json"
  cid=$(( $(jq 'length' "$store/comments-$number.json") + 700 ))
  jq --argjson i "$cid" --arg b "$card" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{id: $i, body: $b, user: {login: "archie"}, created_at: $at}]' \
    "$store/comments-$number.json" > "$store/c.new" && mv "$store/c.new" "$store/comments-$number.json"
  jq --argjson n "$number" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    'map(if .number == $n then .updated_at = $at else . end)' \
    "$store/issues.json" > "$store/i.new" && mv "$store/i.new" "$store/issues.json"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused" "a parse-refused reply must be named, not silently cursor-suppressed"
  assert_contains "$out" "unsupported-version" "the refusal must carry its reason"
  assert_contains "$out" "for $id" "the wake must name the sent letter the requester can act on"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "open"' \
    "$store/issues.json" >/dev/null || fail "the sent letter must stay open: the peer still owes a clean answer"
  pass "a reply refused at parse is named with its reason before the cursor can bury it"
}

test_only_the_first_terminal_reply_is_consumed() {
  local home store fakebin out id number stashed
  read -r home store fakebin <<< "$(fixture high7 | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" answered "the answer"
  inject_reply "$store" "$number" archie-20260824T142002Z-4c82d51e "$id" unable "actually no"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id answered" "the first terminal reply must win"
  assert_not_contains "$out" "unable" "a later terminal reply must be ignored, never a second answer"
  stashed=$(count_files "$home/state/letterbox/inbox")
  [ "$stashed" = 1 ] || fail "exactly one terminal reply may be stashed, not $stashed"
  [ "$(jq -r '.first_reply' "$home/state/letterbox/claims/$id.json")" = archie-20260824T141902Z-3b71c40d ] \
    || fail "the winning reply must be recorded on the sent claim"
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "close must consume the winner"
  [ "$(jq -r '.consumed | length' "$home/state/letterbox/claims/$id.json")" = 1 ] \
    || fail "close must consume exactly one reply"
  pass "the first terminal reply wins and later ones are ignored, on both the poll and close paths"
}

test_a_status_the_class_forbids_is_refused_on_both_paths() {
  local home store fakebin out rc id number
  read -r home store fakebin <<< "$(fixture high8 | tr '\n' ' ')"
  # Sender path: a notice may not be answered.
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" notice "the peer announces something" "for information" >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  printf 'an answer\n' > "$home/reply.txt"
  : > "$store/calls.log"
  out=$(run_lb "$home" "$store" "$fakebin" reply "$id" --status answered --file "$home/reply.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a notice must not be answered; answered is not an understood notice status"
  assert_contains "$out" "not a legal reply to a notice letter" "the refusal must name the class"
  [ "$(grep -c 'issue comment' "$store/calls.log")" = 0 ] || fail "nothing may be posted"
  run_lb "$home" "$store" "$fakebin" reply "$id" --status ack --file "$home/reply.txt" >/dev/null \
    || fail "ack must remain legal for a notice"

  # Requester path: a reply whose status the sent class forbids is refused too.
  printf 'a proposal\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class work-proposal --subject p --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" answered "done it"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "status-not-valid-for-class" \
    "a work-proposal cannot be 'answered'; the requester must refuse it rather than consume it"
  assert_not_contains "$out" "reply $id answered" "it must not be taken as the answer"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "open"' \
    "$store/issues.json" >/dev/null || fail "the letter must stay open"
  pass "a class/status combination the protocol forbids is refused on the sender and requester paths"
}

test_unannounced_overflow_is_left_for_the_next_poll() {
  local home store fakebin out id number rid i
  read -r home store fakebin <<< "$(fixture refusal-overflow | tr '\n' ' ')"
  printf 'a notice\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject n --file "$home/body.txt" >/dev/null \
    || fail "the notice send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  i=1
  while [ "$i" -le 4 ]; do
    rid=$(printf 'archie-20260824T15%02d00Z-%08x' "$i" "$i")
    inject_reply "$store" "$number" "$rid" "$id" answered "not a legal notice answer"
    i=$((i + 1))
  done
  set_issue_updated_at "$store" "$number" "$(past_stamp 120)"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "archie-20260824T150100Z-00000001" "the first refusal must be announced"
  assert_contains "$out" "archie-20260824T150300Z-00000003" "the third refusal must be announced"
  assert_not_contains "$out" "archie-20260824T150400Z-00000004" \
    "the fourth refusal must not be hidden behind an anonymous overflow count"
  assert_not_contains "$out" "+1 more" "nothing unannounced may be described as already handled"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "archie-20260824T150400Z-00000004" \
    "the unannounced fourth refusal must remain discoverable on the next poll"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "all four announced refusals must then be suppressed (got: $out)"
  pass "wake overflow is deferred unsuppressed and surfaced by the next poll"
}

test_reads_are_paginated_beyond_one_page() {
  local home store fakebin out id number i cid target now
  read -r home store fakebin <<< "$(fixture medium9 | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  [ -f "$store/comments-$number.json" ] || printf '[]\n' > "$store/comments-$number.json"
  # 120 ordinary comments push the terminal reply past a single 100-item page.
  i=0
  while [ "$i" -lt 120 ]; do
    cid=$((i + 100))
    jq --argjson id "$cid" --arg b "just prose, no card" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + [{id: $id, body: $b, user: {login: "archie"}, created_at: $at}]' \
      "$store/comments-$number.json" > "$store/c.new" && mv "$store/c.new" "$store/comments-$number.json"
    i=$((i + 1))
  done
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" answered "the answer on page two"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id answered" \
    "a terminal reply beyond the first page must still be seen"
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "close must succeed on a page-two reply"

  read -r home store fakebin <<< "$(fixture medium9-open | tr '\n' ' ')"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg at "$now" \
    '[range(1; 121) as $n | {number:$n,title:("ordinary-" + ($n|tostring)),body:"ordinary prose",
      state:"open",user:{login:"someone"},updated_at:$at}]' > "$store/issues.json"
  printf '121\n' > "$store/next"
  target=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$target" fact-lookup q "page two" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "new $target" "an open letter beyond the first issue page must still be seen"
  pass "both comment and open-issue reads expose records beyond the first page"
}

test_a_paginated_read_failure_is_never_accepted_as_partial_data() {
  local home store fakebin out rc id number i cid at
  read -r home store fakebin <<< "$(fixture pagination-failure | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "the send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg at "$at" '. + [range(2; 102) as $n |
    {number:$n,title:("ordinary-" + ($n|tostring)),body:"ordinary prose",state:"open",
     user:{login:"someone"},updated_at:$at}]' "$store/issues.json" > "$store/i.new" \
    && mv "$store/i.new" "$store/issues.json"
  out=$(env PATH="$fakebin:$BASE_PATH" FM_LETTERBOX_REPO="$CHANNEL" FAKE_STORE="$store" \
    FAKE_GH_FAIL_MATCH=issues FAKE_GH_FAIL_AFTER_PAGE=1 \
    "$ROOT/bin/fm-letterbox-transport-github.sh" list-open 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "an issue pagination failure after page one must fail the read"
  [ -z "$out" ] || fail "a failed paginated issue read must expose no partial array"

  printf '[]\n' > "$store/comments-$number.json"
  i=0
  while [ "$i" -lt 100 ]; do
    cid=$((i + 100))
    jq --argjson id "$cid" --arg at "$at" \
      '. + [{id:$id,body:"ordinary prose",user:{login:"archie"},created_at:$at}]' \
      "$store/comments-$number.json" > "$store/c.new" && mv "$store/c.new" "$store/comments-$number.json"
    i=$((i + 1))
  done
  inject_reply "$store" "$number" archie-20260824T141902Z-3b71c40d "$id" answered "page two answer"
  set_issue_updated_at "$store" "$number" "$(past_stamp 120)"
  out=$(run_poll "$home" "$store" "$fakebin" \
    FAKE_GH_FAIL_MATCH=comments FAKE_GH_FAIL_AFTER_PAGE=1)
  [ -z "$out" ] || fail "a partial comment read must be treated as no data (got: $out)"
  if [ -f "$home/state/letterbox/cursor" ]; then
    jq -e --arg n "$number" 'has($n) | not' "$home/state/letterbox/cursor" >/dev/null \
      || fail "a partial comment read must not advance that issue's cursor"
  fi
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id answered" \
    "the next complete read must still see the reply beyond the failed page"
  pass "pagination failures expose no partial data and never advance the reply cursor"
}

# ---------------------------------------------------------------------------
# the stale backstop and the poll's cost shape

test_stale_letter_is_resurfaced_once_per_window() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture stale | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" fact-lookup "q" "please answer" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "new $id" "the first sighting must announce"
  # No reply, no task: with a one-window-old claim the backstop must raise it.
  jq '.claimed = 1 | .resurfaced = 0' "$home/state/letterbox/claims/$id.json" > "$home/c.new" \
    && cat "$home/c.new" > "$home/state/letterbox/claims/$id.json"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  assert_contains "$out" "stale $id fact-lookup" \
    "a claimed letter with no reply and no live task must be re-surfaced"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  [ -z "$out" ] || fail "the backstop is rate-limited to once per window (got: $out)"
  pass "a dropped obligation is re-surfaced by the poll, once per window"
}

test_a_linked_live_task_suppresses_the_stale_backstop() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture stale-task | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" fact-lookup "q" "please answer" >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  jq '.claimed = 1 | .resurfaced = 0 | .task = "letter-work"' \
    "$home/state/letterbox/claims/$id.json" > "$home/c.new" \
    && cat "$home/c.new" > "$home/state/letterbox/claims/$id.json"
  printf 'id=letter-work\n' > "$home/state/letter-work.meta"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  [ -z "$out" ] || fail "an obligation that is an ordinary task must not be re-surfaced (got: $out)"
  # Once the task is gone with no reply posted, the obligation is loose again.
  rm -f "$home/state/letter-work.meta"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  assert_contains "$out" "stale $id" "a vanished task must let the backstop raise the letter again"
  pass "an obligation carried by an ordinary task is not re-surfaced; a lost one is"
}

test_a_replied_letter_is_not_resurfaced() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture stale-replied | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" fact-lookup "q" "please answer" >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  printf 'the answer\n' > "$home/reply.txt"
  run_lb "$home" "$store" "$fakebin" reply "$id" --status answered --file "$home/reply.txt" >/dev/null \
    || fail "reply must succeed"
  jq '.claimed = 1 | .resurfaced = 0' "$home/state/letterbox/claims/$id.json" > "$home/c.new" \
    && cat "$home/c.new" > "$home/state/letterbox/claims/$id.json"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  [ -z "$out" ] || fail "a letter this estate already answered must not be re-surfaced (got: $out)"
  pass "a letter with a posted terminal reply is never re-surfaced"
}

test_a_quiet_poll_costs_one_read_and_writes_nothing() {
  local home store fakebin out reads writes
  read -r home store fakebin <<< "$(fixture cost | tr '\n' ' ')"
  printf 'body\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  set_issue_updated_at "$store" "$(head -n1 "$home"/state/letterbox/sent/*.receipt)" "$(past_stamp 120)"
  run_poll "$home" "$store" "$fakebin" >/dev/null
  : > "$store/calls.log"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a quiet cycle must be silent (got: $out)"
  reads=$(grep -c '^gh api' "$store/calls.log" || true)
  writes=$(grep -cE 'issue (create|comment|close)' "$store/calls.log" || true)
  [ "$reads" = 1 ] || fail "a quiet cycle must cost exactly one read, not $reads (the cursor's job)"
  [ "$writes" = 0 ] || fail "the poll must never write to the channel"
  pass "a quiet poll cycle costs one read, makes no comment call, and never writes"
}

# GitHub's updated_at has one-second resolution, so a peer reply landing in the
# same second as the value the cursor recorded leaves updated_at unchanged. The
# cursor must never persist a value at the boundary of the poll's own second,
# or that reply is hidden on every later cycle. The first poll is retried until
# it demonstrably ran inside the same second as the stamp it observed.
test_a_reply_in_the_cursors_own_second_is_still_fetched() {
  local home store fakebin out id number stamp after tries=0 fetches
  read -r home store fakebin <<< "$(fixture cursor-second | tr '\n' ' ')"
  printf 'Question for the peer.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home")
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  while :; do
    tries=$((tries + 1))
    rm -f "$home/state/letterbox/cursor"
    stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    set_issue_updated_at "$store" "$number" "$stamp"
    out=$(run_poll "$home" "$store" "$fakebin")
    after=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    [ "$after" != "$stamp" ] || break
    [ "$tries" -lt 20 ] || fail "could not run a poll inside one clock second after $tries tries"
  done
  [ -z "$out" ] || fail "the first poll has nothing to announce (got: $out)"
  # The peer's terminal reply lands within that same second.
  inject_reply "$store" "$number" archie-20260827T100010Z-5c1e2d7a "$id" answered
  set_issue_updated_at "$store" "$number" "$stamp"
  : > "$store/calls.log"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id answered" \
    "a reply landing in the cursor's own second must still wake the requester"
  fetches=$(grep -c '/comments' "$store/calls.log" || true)
  [ "$fetches" = 1 ] || fail "the reply's comments must be fetched once, not $fetches"
  assert_present "$home/state/letterbox/inbox/archie-20260827T100010Z-5c1e2d7a.json" \
    "the reply must be stashed"
  out=$(run_lb "$home" "$store" "$fakebin" close "$id") || fail "close must succeed: $out"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "closed"' \
    "$store/issues.json" >/dev/null || fail "the requester must close the letter"
  pass "a terminal reply in the same second as the cursor's stamp is fetched, stashed and closable"
}

test_a_settled_sent_letter_makes_no_comment_fetch_on_a_quiet_poll() {
  local home store fakebin out id number fetches
  read -r home store fakebin <<< "$(fixture cursor-quiet | tr '\n' ' ')"
  printf 'Question for the peer.\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home")
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  set_issue_updated_at "$store" "$number" "$(past_stamp 120)"
  run_poll "$home" "$store" "$fakebin" >/dev/null
  assert_present "$home/state/letterbox/cursor" "a safely past updated_at must be recorded"
  : > "$store/calls.log"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a quiet cycle must be silent (got: $out)"
  fetches=$(grep -c '/comments' "$store/calls.log" || true)
  [ "$fetches" = 0 ] || fail "a quiet cycle must make zero comment fetches, not $fetches"
  pass "the cursor still suppresses the comment fetch for an untouched sent letter"
}

test_the_poll_stays_silent_when_the_transport_read_fails() {
  local home store fakebin out rc
  read -r home store fakebin <<< "$(fixture transport-down | tr '\n' ' ')"
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 >/dev/null
  rm -f "$store/issues.json"
  out=$(run_poll "$home" "$store" "$fakebin"); rc=$?
  expect_code 0 "$rc" "a failed read must exit 0"
  [ -z "$out" ] || fail "a transport read failure must not spend a firstmate turn (got: $out)"
  printf '[]\n' > "$store/issues.json"
  pass "a transport read failure is silent: the next cycle retries instead of waking"
}

test_status_reports_activation_and_what_is_owed() {
  local home store fakebin out
  read -r home store fakebin <<< "$(fixture status | tr '\n' ' ')"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "poll: not armed" "status must say when the poll is not armed"
  run_lb "$home" "$store" "$fakebin" arm >/dev/null || fail "arm must succeed"
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 fact-lookup "q" "answer me" >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "poll: armed and registered" "status must confirm the armed poll"
  assert_contains "$out" "OWED: archie-20260824T140311Z-9f2c1ab4 fact-lookup" \
    "status must name the letter this estate still owes a reply to"
  out=$(run_lb "$home" "$store" "$fakebin" read archie-20260824T140311Z-9f2c1ab4) \
    || fail "read must succeed: $out"
  assert_contains "$out" "answer me" "read must print the stashed card"
  pass "status reports activation, the armed poll and the letters still owed a reply"
}

test_status_reports_an_unreadable_claim_without_inventing_an_obligation() {
  local home store fakebin out id claim
  read -r home store fakebin <<< "$(fixture status-unreadable | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" fact-lookup q body >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  claim="$home/state/letterbox/claims/$id.json"
  printf '{not-json\n' > "$claim"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must report unreadable durable state: $out"
  assert_contains "$out" "UNREADABLE: $id claim" "status must admit that the claim cannot be classified"
  assert_not_contains "$out" "OWED: $id" "an unreadable claim must not become an invented inbound obligation"
  assert_contains "$out" "0 letter(s) awaiting a reply from this estate" \
    "an unreadable claim must not update the owed counter"
  assert_contains "$out" "1 unreadable" "the summary must count unreadable claims separately"
  pass "status reports unreadable claims without inventing obligation state"
}

test_a_visibility_refusal_keeps_alarming_while_reads_continue() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture visibility-realarm | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  printf 'false\n' > "$store/private"
  printf 'body\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject "s" --file "$home/body.txt" >/dev/null 2>&1 \
    && fail "a write into a public channel must be refused"
  [ "$(head -n1 "$home/state/letterbox/write-error")" = visibility ] \
    || fail "a confirmed-public channel must be recorded as a visibility refusal"
  inject_letter "$store" "$id" fact-lookup "q" "still delivered" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "error: letterbox write refused" "the refusal must be raised"
  assert_contains "$out" "new $id fact-lookup archie" \
    "a refused write must not disable intake: the letter must still be stashed and announced"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the error and the letter must share one wake line"
  assert_present "$home/state/letterbox/inbox/$id.json" "the letter must be stashed despite the write-error"
  assert_present "$home/state/letterbox/write-error" "a successful read must NOT clear a visibility refusal"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  [ -z "$out" ] || fail "inside the window the visibility alarm is rate-limited (got: $out)"
  # Age the alarm marker past the window: the exposed channel must be raised again.
  { printf '1\n'; sed '1d' "$home/state/letterbox/poll-error"; } > "$home/pe.new" \
    && cat "$home/pe.new" > "$home/state/letterbox/poll-error"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  assert_contains "$out" "error: letterbox write refused" \
    "an exposed channel must be re-raised once per window, never only once"
  assert_contains "$out" "is not private" "the re-raised wake must still name the cause"
  assert_present "$home/state/letterbox/write-error" "only a write that lands clears a visibility refusal"
  pass "a visibility refusal never stops reads and re-alarms once per window until a write lands"
}

test_a_transport_write_error_survives_a_successful_read_until_a_write_lands() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture write-transport | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  printf 'body\n' > "$home/body.txt"
  # The visibility check itself cannot run: the fake forge has no visibility record.
  rm -f "$store/private"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject "s" --file "$home/body.txt" 2>&1) \
    && fail "a write whose visibility check cannot run must be refused"
  assert_contains "$out" "cannot read $CHANNEL visibility" "the refusal must name the transport cause"
  [ "$(head -n1 "$home/state/letterbox/write-error")" = transport ] \
    || fail "an unreadable visibility must be recorded as a transport failure, not a visibility refusal"
  printf 'true\n' > "$store/private"
  inject_letter "$store" "$id" fact-lookup "q" "still delivered" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "error: letterbox write refused" "the transport failure must be raised"
  assert_contains "$out" "new $id" "a transport write-error must not suppress inbound intake"
  assert_present "$home/state/letterbox/inbox/$id.json" "the letter must be stashed"

  # A read proves the transport is back; it proves NOTHING about whether the
  # alarm was ever delivered. The watcher appends the durable wake only after
  # this process exits, so a death in that gap loses the announcement - and a
  # retiring read would then erase the last evidence that a write was refused.
  assert_present "$home/state/letterbox/write-error" \
    "a successful read must NOT retire a transport-class write-error"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  [ -z "$out" ] || fail "inside the window the alarm is rate-limited (got: $out)"
  # Age the alarm marker past the window: the refused write must be raised again.
  { printf '1\n'; sed '1d' "$home/state/letterbox/poll-error"; } > "$home/pe.new" \
    && cat "$home/pe.new" > "$home/state/letterbox/poll-error"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  assert_contains "$out" "error: letterbox write refused" \
    "a transport write-error must re-alarm once per window, so a lost wake is recoverable"

  # The one acknowledgement this side can observe is a write that lands: it
  # proves both that the condition cleared and that someone acted on it.
  run_lb "$home" "$store" "$fakebin" send --class notice --subject "s" --file "$home/body.txt" >/dev/null \
    || fail "the send must succeed once the transport is back"
  assert_absent "$home/state/letterbox/write-error" "a write that lands retires the alarm"
  pass "a transport write-error survives a successful read and retires only when a write lands"
}

test_title_adoption_does_not_clear_a_write_error() {
  local home store fakebin out rc id number card at
  read -r home store fakebin <<< "$(fixture adoption-write-error | tr '\n' ' ')"
  printf 'false\n' > "$store/private"
  printf 'first notice\n' > "$home/body.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject first --file "$home/body.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "the first write must be refused while the channel is public"
  assert_present "$home/state/letterbox/write-error" "the refused write must leave its durable alarm"
  id=$(sole_outbox_id "$home") || fail "the refused write must leave an outbox record"
  card=$(jq -r '.card' "$home/state/letterbox/outbox/$id.json")
  number=$(cat "$store/next")
  printf '%s\n' "$((number + 1))" > "$store/next"
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --argjson n "$number" --arg t "[letterbox] notice $id" --arg b "$card" --arg at "$at" \
    '. + [{number:$n,title:$t,body:$b,state:"open",user:{login:"shipyard"},updated_at:$at}]' \
    "$store/issues.json" > "$store/i.new" && mv "$store/i.new" "$store/issues.json"
  printf 'true\n' > "$store/private"
  : > "$store/fail-create"
  printf 'second notice\n' > "$home/body2.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject second --file "$home/body2.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "the new create is deliberately failed after adoption"
  assert_contains "$out" "adopted existing letter $id" "the interrupted letter must be adopted by title"
  assert_present "$home/state/letterbox/write-error" \
    "a read-only title adoption must not clear an earlier write alarm"
  pass "only a confirmed write clears a write-error; title adoption never does"
}

test_a_lost_wake_does_not_lose_the_write_error_alarm() {
  local home store fakebin out
  read -r home store fakebin <<< "$(fixture write-lostwake | tr '\n' ' ')"
  printf 'body\n' > "$home/body.txt"
  rm -f "$store/private"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject "s" --file "$home/body.txt" >/dev/null 2>&1 \
    && fail "the write must be refused"
  printf 'true\n' > "$store/private"
  # Model the exact reproduced sequence: the poll produces its alarm line, and
  # the watcher dies before durably appending the wake. The output is observed
  # here and deliberately never enqueued.
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "error: letterbox write refused" "the first poll must raise the alarm"
  # A later poll, after the window, must still be able to raise it: the evidence
  # that a write was refused is durable and was not consumed by the lost wake.
  { printf '1\n'; sed '1d' "$home/state/letterbox/poll-error"; } > "$home/pe.new" \
    && cat "$home/pe.new" > "$home/state/letterbox/poll-error"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  assert_contains "$out" "error: letterbox write refused" \
    "an alarm whose wake was lost must be recoverable, never permanently consumed"
  assert_present "$home/state/letterbox/write-error" "the durable evidence must survive"
  pass "an alarm whose wake never reached the queue is raised again, not lost"
}

test_a_scan_refused_reply_names_the_sent_letter_and_keeps_it_open() {
  local home store fakebin out id number secret
  read -r home store fakebin <<< "$(fixture refused-reply | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  # Synthetic, generated for this test, and not a real credential.
  secret="ghp_$(awk 'BEGIN { while (i++ < 36) printf "B" }')"
  inject_reply "$store" "$number" archie-20260824T150000Z-0badcafe "$id" answered "token $secret"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused archie-20260824T150000Z-0badcafe provider-key-prefix for $id" \
    "a refused reply must name the SENT letter the requester can act on"
  assert_not_contains "$out" "$secret" "the refusal must never carry the value"
  assert_absent "$home/state/letterbox/inbox/archie-20260824T150000Z-0badcafe.json" \
    "a refused reply must not be stashed"
  [ "$(jq -r --argjson n "$number" '.[] | select(.number == $n) | .state' "$store/issues.json")" = open ] \
    || fail "the sent letter must stay open: the peer still owes a clean answer"
  out=$(run_lb "$home" "$store" "$fakebin" close "$id" 2>&1) \
    && fail "close must refuse an answer that was never read"
  assert_contains "$out" "no terminal reply" "close must say why it refuses"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "the refused reply is claimed and must not be re-announced (got: $out)"
  # Past the window, the sent-letter backstop keeps the requester awake.
  jq '.claimed = 1 | .resurfaced = 0' "$home/state/letterbox/claims/$id.json" > "$home/c.new" \
    && cat "$home/c.new" > "$home/state/letterbox/claims/$id.json"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  assert_contains "$out" "unanswered $id fact-lookup" \
    "a sent letter with no consumed terminal reply must be re-surfaced"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  [ -z "$out" ] || fail "the sent-letter backstop is rate-limited to once per window (got: $out)"
  # The grammar-conformant resolution is an ordinary notice naming the refusal.
  printf 'reply archie-20260824T150000Z-0badcafe was refused: provider-key-prefix\n' > "$home/notice.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject "refused reply" --file "$home/notice.txt") \
    || fail "the notice resolving a refused reply must send: $out"
  pass "a scan-refused reply names the sent letter, leaves it open, and the backstop keeps raising it"
}

test_a_sent_letter_with_a_consumed_reply_is_not_resurfaced() {
  local home store fakebin out id number
  read -r home store fakebin <<< "$(fixture unanswered-consumed | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  jq '.claimed = 1 | .resurfaced = 0' "$home/state/letterbox/claims/$id.json" > "$home/c.new" \
    && cat "$home/c.new" > "$home/state/letterbox/claims/$id.json"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  assert_contains "$out" "unanswered $id" "a sent letter with no reply at all must be re-surfaced"
  inject_reply "$store" "$number" archie-20260824T150000Z-0c1ea11e "$id" answered "clean answer"
  # The fake forge stamps to the second, so a reply landing in the same second as
  # the previous poll would be hidden by the cursor; drop it so the fetch runs.
  rm -f "$home/state/letterbox/cursor"
  jq '.resurfaced = 0' "$home/state/letterbox/claims/$id.json" > "$home/c.new" \
    && cat "$home/c.new" > "$home/state/letterbox/claims/$id.json"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  assert_contains "$out" "reply $id answered" "the clean reply must be announced"
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "close must succeed"
  jq '.resurfaced = 0' "$home/state/letterbox/claims/$id.json" > "$home/c.new" \
    && cat "$home/c.new" > "$home/state/letterbox/claims/$id.json"
  out=$(run_poll "$home" "$store" "$fakebin" FM_LETTERBOX_STALE_SECS=300)
  [ -z "$out" ] || fail "a closed letter with its reply consumed must not be re-surfaced (got: $out)"
  pass "the sent-letter backstop stops once the terminal reply is consumed and the letter closed"
}

test_a_reply_card_in_an_issue_body_is_ignored() {
  local home store fakebin out n card
  read -r home store fakebin <<< "$(fixture reply-as-issue | tr '\n' ' ')"
  n=$(cat "$store/next")
  printf '%s\n' "$((n + 1))" > "$store/next"
  card=$(
    printf '```letterbox/v1\n'
    printf 'kind: reply\nv: 1\nid: archie-20260824T140311Z-9f2c1ab4\n'
    printf 'in-reply-to: firstmate-20260824T140000Z-00000001\nfrom: %s\nto: %s\n' "$PEER" "$SELF"
    printf 'status: answered\nissued: %s\nbody: |\n  not a letter\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '```\n'
  )
  jq --argjson n "$n" --arg b "$card" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{number: $n, title: "misfiled", body: $b, state: "open", user: {login: "archie"}, updated_at: $at}]' \
    "$store/issues.json" > "$store/issues.json.new" && mv "$store/issues.json.new" "$store/issues.json"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "a reply card posted as an issue body must be ignored, not announced (got: $out)"
  assert_absent "$home/state/letterbox/inbox/archie-20260824T140311Z-9f2c1ab4.json" \
    "a reply card in an issue body must not be stashed as a request"
  assert_absent "$home/state/letterbox/claims/archie-20260824T140311Z-9f2c1ab4.json" \
    "a reply card in an issue body must not be claimed"
  pass "a reply card posted as an issue body is ignored exactly like a card addressed elsewhere"
}

test_a_missing_gh_is_diagnosed_not_silent() {
  local home store fakebin out rc no_gh
  read -r home store fakebin <<< "$(fixture missing-gh | tr '\n' ' ')"
  # The base PATH may carry a real gh, so its absence is simulated the way the
  # bootstrap suite hides jq: command -v gh fails in every shell under test.
  rm -f "$fakebin/gh"
  no_gh="$home/no-gh.bash"
  cat > "$no_gh" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = gh ]; then
    return 1
  fi
  builtin command "$@"
}
SH
  inject_letter "$store" archie-20260824T140311Z-9f2c1ab4 >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin" BASH_ENV="$no_gh"); rc=$?
  expect_code 0 "$rc" "a poll without gh must still exit 0"
  assert_contains "$out" "letterbox error: missing transport dependency: gh" \
    "a home without gh must be told once rather than polling silently forever"
  out=$(run_poll "$home" "$store" "$fakebin" BASH_ENV="$no_gh")
  [ -z "$out" ] || fail "the missing-gh diagnostic must be rate-limited (got: $out)"
  out=$(BASH_ENV="$no_gh" run_lb "$home" "$store" "$fakebin" arm 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "arm must refuse without gh, which every read verb needs"
  assert_contains "$out" "missing transport dependency: gh" "arm must name the missing dependency"
  assert_absent "$home/state/letterbox.check.sh" "arm must not generate a shim it cannot serve"
  pass "a missing gh is diagnosed once by the poll and refused by arm"
}

test_the_transport_adapter_owns_its_dependency_check() {
  local home store fakebin out scoped_command id
  read -r home store fakebin <<< "$(fixture adapter-dependencies | tr '\n' ' ')"
  scoped_command="$home/scoped-command.bash"
  cat > "$scoped_command" <<'SH'
command() {
  if [ "${1:-}" = -v ]; then
    case "${2:-}" in
      gh|gh-axi)
        case "${BASH_SOURCE[1]-}" in
          *fm-letterbox-transport-github.sh) builtin command "$@" ;;
          *) return 1 ;;
        esac
        return
        ;;
    esac
  fi
  builtin command "$@"
}
SH
  out=$(BASH_ENV="$scoped_command" run_lb "$home" "$store" "$fakebin" arm) \
    || fail "arm must accept the adapter's own dependency verdict: $out"
  assert_contains "$out" "letterbox armed" "the core must ask the adapter instead of probing forge tools itself"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin" BASH_ENV="$scoped_command")
  assert_contains "$out" "new $id" "the poll must rely on the same adapter-owned dependency verdict"
  pass "the transport adapter owns its dependencies, so the core is transport-neutral"
}

test_status_counts_only_sent_letters_still_awaiting_a_reply() {
  local home store fakebin out id number
  read -r home store fakebin <<< "$(fixture status-sent | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "1 sent and awaiting a reply from the peer" \
    "an open sent letter must be counted as awaiting a reply"
  inject_reply "$store" "$number" archie-20260824T150000Z-0c1ea11e "$id" answered "the answer"
  run_poll "$home" "$store" "$fakebin" >/dev/null
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "close must succeed"
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "0 sent and awaiting a reply from the peer" \
    "a sent letter whose reply was consumed and closed must not be counted as still open"
  pass "status counts a sent letter only while its terminal reply is still unconsumed"
}

test_status_on_an_unconfigured_home_says_inert() {
  local home out
  home=$(make_home status-inert)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-letterbox.sh" status) || fail "status must succeed: $out"
  assert_contains "$out" "inert (not configured in this home)" \
    "an unconfigured home must report inertness plainly"
  assert_absent "$home/state/letterbox" "status must not create state in an inert home"
  pass "status on an unconfigured home reports inert and creates nothing"
}


# ---------------------------------------------------------------------------
# review round three: the activation gate, staged JSON, durable winners, stable
# keys, the adapter's visibility class, scanning before terminality, option
# values, and the fetch budget

test_cli_partial_configuration_is_not_configured_and_creates_nothing() {
  local home store fakebin out rc cmd
  home=$(make_home cli-partial)
  fakebin=$(make_fakebin "$home")
  store="$home/forge"
  printf 'FM_LETTERBOX_REPO=%s\nFM_LETTERBOX_SELF=%s\n' "$CHANNEL" "$SELF" > "$home/.env"
  printf 'body\n' > "$home/body.txt"
  for cmd in arm list "read archie-20260824T140311Z-9f2c1ab4" "close archie-20260824T140311Z-9f2c1ab4" \
    "send --class notice --subject s --file $home/body.txt" \
    "reply archie-20260824T140311Z-9f2c1ab4 --status ack --file $home/body.txt"; do
    # shellcheck disable=SC2086 # Word-split on purpose: each entry is a command line.
    out=$(run_lb "$home" "$store" "$fakebin" $cmd 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$cmd must refuse on a partial configuration"
    assert_contains "$out" "not configured" "$cmd must report the letterbox as not configured, not as a fault"
  done
  out=$(run_lb "$home" "$store" "$fakebin" status) || fail "status must succeed: $out"
  assert_contains "$out" "inert (not configured in this home)" "status must report a partial configuration as inert"
  assert_absent "$home/state/letterbox" "a partial configuration must create no state directory"
  assert_absent "$home/state/letterbox.check.sh" "a partial configuration must arm nothing"
  [ ! -s "$store/calls.log" ] || fail "a partial configuration must make no transport call"
  pass "every CLI command treats a partial configuration as not configured: no state, no shim, no transport call"
}

# A jq that fails only for the inbox stash, so the poll's staging is exercised
# on the exact pipeline the review named while every other jq call stays real.
install_failing_jq() {
  local fakebin=$1 match=$2 real
  real=$(command -v jq)
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
case " \$* " in *" $match "*) exit 5 ;; esac
exec "$real" "\$@"
SH
  chmod +x "$fakebin/jq"
}

install_failing_card_cat() {
  local fakebin=$1 counter=$2 real
  real=$(command -v cat)
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  */fm-letterbox.*/card.md)
    count=0
    [ ! -f "$counter" ] || count=\$("$real" "$counter")
    count=\$((count + 1))
    printf '%s\n' "\$count" > "$counter"
    [ "\$count" -ne 2 ] || exit 5
    ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$fakebin/cat"
}

install_failing_rm_for() {
  local fakebin=$1 target=$2 real
  real=$(command -v rm)
  cat > "$fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != "$target" ] || exit 5
done
exec "$real" "\$@"
SH
  chmod +x "$fakebin/rm"
}

test_a_failed_stash_is_never_published_announced_or_claimed() {
  local home store fakebin out id
  read -r home store fakebin <<< "$(fixture stash-jq | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" fact-lookup "q" "body" >/dev/null
  install_failing_jq "$fakebin" "--arg kind request"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "cannot write the letterbox inbox" "a stash that could not be built must be reported"
  assert_not_contains "$out" "new $id" "a letter whose stash failed must not be announced"
  assert_absent "$home/state/letterbox/inbox/$id.json" "no empty stash may be published over a jq failure"
  assert_absent "$home/state/letterbox/claims/$id.json" "a letter that was never stashed must not be claimed"
  rm -f "$fakebin/jq"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "new $id fact-lookup archie" "the letter must be stashed and announced once jq works"
  jq -e '.body == "body"' "$home/state/letterbox/inbox/$id.json" >/dev/null \
    || fail "the eventual stash must carry the card"
  pass "a stash is staged and validated before publish, so a jq failure never announces or claims an unreadable letter"
}

test_a_failed_outbox_record_stops_the_send_before_any_transport_call() {
  local home store fakebin out rc
  read -r home store fakebin <<< "$(fixture outbox-jq | tr '\n' ' ')"
  printf 'body\n' > "$home/body.txt"
  install_failing_jq "$fakebin" "--arg expires"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject s --file "$home/body.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a send whose outbox record could not be built must fail"
  assert_contains "$out" "cannot record the outbox entry" "the failure must be named"
  [ "$(count_files "$home/state/letterbox/outbox")" = 0 ] || fail "no empty outbox record may be published"
  [ "$(grep -c 'issue create' "$store/calls.log")" = 0 ] || fail "nothing may be transmitted without its outbox record"
  rm -f "$fakebin/jq"
  pass "an outbox record is staged and validated before publish, and a failure stops the send"
}

test_the_first_terminal_reply_survives_a_crash_before_it_is_cached() {
  local home store fakebin out id number first
  read -r home store fakebin <<< "$(fixture winner-crash | tr '\n' ' ')"
  first=archie-20260824T141902Z-3b71c40d
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_reply "$store" "$number" "$first" "$id" answered "the answer"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id answered" "the first terminal reply must be announced"
  # The crash: the reply claim landed but the sent claim's cache did not.
  jq '.first_reply = "" | .first_reply_status = ""' "$home/state/letterbox/claims/$id.json" > "$home/c.new" \
    && cat "$home/c.new" > "$home/state/letterbox/claims/$id.json"
  inject_reply "$store" "$number" archie-20260824T142002Z-4c82d51e "$id" unable "actually no"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_not_contains "$out" "unable" "a later terminal reply must never overtake the first after a crash"
  assert_absent "$home/state/letterbox/inbox/archie-20260824T142002Z-4c82d51e.json" \
    "the later reply must not be stashed"
  [ "$(jq -r '.first_reply' "$home/state/letterbox/claims/$id.json")" = "$first" ] \
    || fail "the winner must be recovered from its reply claim and re-cached"
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null || fail "close must consume the winner"
  [ "$(jq -r '.consumed | join(" ")' "$home/state/letterbox/claims/$id.json")" = "$first" ] \
    || fail "close must consume exactly the first reply"
  pass "the first-terminal-reply winner is durable from its own claim, so a crash before the cache cannot change it"
}

# A malformed reply comment with no usable card id, given a fixed forge comment id.
inject_malformed_comment() {
  local store=$1 number=$2 cid=$3 ago=${4:-120} body
  # shellcheck disable=SC2016 # Backticks are the literal card fence, not a substitution.
  body=$(printf '```letterbox/v1\nkind: reply\nv: 1\nid: not an id\nin-reply-to: x\nfrom: archie\nstatus: answered\nissued: %s\nbody: |\n  x\n```\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  [ -f "$store/comments-$number.json" ] || printf '[]\n' > "$store/comments-$number.json"
  jq --argjson i "$cid" --arg b "$body" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{id: $i, body: $b, user: {login: "archie"}, created_at: $at}]' \
    "$store/comments-$number.json" > "$store/c.new" && mv "$store/c.new" "$store/comments-$number.json"
  set_issue_updated_at "$store" "$number" "$(past_stamp "$ago")"
}

test_a_malformed_reply_is_keyed_by_its_forge_comment_id_not_its_position() {
  local home store fakebin out id number
  read -r home store fakebin <<< "$(fixture comment-key | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  inject_malformed_comment "$store" "$number" 700
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused issue-$number-comment-700 bad-id for $id" \
    "a malformed reply must be keyed by the forge comment id"
  assert_present "$home/state/letterbox/claims/issue-$number-comment-700.json" "the refusal must be claimed under that key"
  # The peer deletes the first comment and posts a new malformed one: it now
  # sits at index 0, exactly where the claimed one was.
  printf '[]\n' > "$store/comments-$number.json"
  inject_malformed_comment "$store" "$number" 701 60
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused issue-$number-comment-701 bad-id for $id" \
    "a new malformed reply at a reused index must be named, never buried under the old claim"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "an announced malformed reply must then be suppressed (got: $out)"
  pass "synthetic reply claims use the stable forge comment id, so a shifted index cannot hide a refusal"
}

test_a_repository_that_flips_between_the_two_checks_is_a_visibility_refusal() {
  local home store fakebin out rc
  read -r home store fakebin <<< "$(fixture visibility-flip | tr '\n' ' ')"
  printf 'body\n' > "$home/body.txt"
  printf 'false\n' > "$store/private-flip"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject s --file "$home/body.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a write must be refused when the adapter's own gate sees a public repository"
  assert_contains "$out" "refusing to write" "the refusal must be explicit"
  assert_contains "$out" "is not private" "the refusal must name visibility, not a generic failure"
  [ "$(grep -c 'issue create' "$store/calls.log")" = 0 ] || fail "no letter may be created"
  assert_present "$home/state/letterbox/write-error" "the refusal must be recorded durably"
  [ "$(head -n1 "$home/state/letterbox/write-error")" = visibility ] \
    || fail "the record must carry the visibility class, not transport"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "error: letterbox write refused" "the poll must raise the refusal as a wake"
  assert_contains "$out" "is not private" "the wake must name the visibility cause"
  pass "a visibility refusal at the adapter's own gate is recorded under its class and wakes firstmate"
}

test_a_non_terminal_ack_carrying_a_credential_is_refused_not_skipped() {
  local home store fakebin out id number rid
  read -r home store fakebin <<< "$(fixture ack-scan | tr '\n' ' ')"
  rid=archie-20260824T141902Z-3b71c40d
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  # A legal, non-terminal ack whose body carries a synthetic provider key.
  inject_reply "$store" "$number" "$rid" "$id" ack "working on it, token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused $rid provider-key-prefix for $id" \
    "a non-terminal reply is scanned before terminality is decided, and refused by class"
  assert_not_contains "$out" "ghp_" "the wake must never carry the matched value"
  assert_absent "$home/state/letterbox/inbox/$rid.json" "a refused reply is never stashed"
  [ "$(jq -r '.refusal' "$home/state/letterbox/claims/$rid.json")" = provider-key-prefix ] \
    || fail "the refusal must be claimed so it is announced once"
  out=$(run_poll "$home" "$store" "$fakebin")
  [ -z "$out" ] || fail "the refusal must then be suppressed (got: $out)"
  pass "every valid correlated reply is credential-scanned, terminal or not"
}

# Run one command line with a bound: the parser under test used to loop forever
# on a missing option value, so a hang is itself the failure.
run_bounded() {
  local label=$1 pid i=0 rc
  shift
  "$@" >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || { kill "$pid" 2>/dev/null; fail "$label must terminate, not loop forever"; }
    sleep 0.1
  done
  wait "$pid"; rc=$?
  [ "$rc" -ne 0 ] || fail "$label must fail"
}

test_a_missing_option_value_is_refused_not_looped() {
  local home store fakebin out rc
  read -r home store fakebin <<< "$(fixture option-values | tr '\n' ' ')"
  printf 'body\n' > "$home/body.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class 2>&1); rc=$?
  expect_code 1 "$rc" "send --class with no value"
  assert_contains "$out" "--class needs a value" "the missing value must be named"
  run_bounded "send --file" run_lb "$home" "$store" "$fakebin" send --class notice --subject s --file
  run_bounded "reply --status" run_lb "$home" "$store" "$fakebin" reply archie-20260824T140311Z-9f2c1ab4 --status
  out=$(PATH="$fakebin:$BASE_PATH" FAKE_STORE="$store" FM_LETTERBOX_REPO="$CHANNEL" \
    "$ROOT/bin/fm-letterbox-transport-github.sh" create --title 2>&1); rc=$?
  expect_code 1 "$rc" "transport create --title with no value"
  assert_contains "$out" "needs a value" "the transport parser must refuse a missing value too"
  run_bounded "transport comment --body-file" env PATH="$fakebin:$BASE_PATH" FAKE_STORE="$store" \
    FM_LETTERBOX_REPO="$CHANNEL" "$ROOT/bin/fm-letterbox-transport-github.sh" comment 1 --body-file
  [ ! -s "$store/calls.log" ] || fail "a rejected command line must make no transport call"
  pass "every option parser rejects a missing value before shifting, on the send, reply and transport paths"
}

test_the_reply_fetch_budget_is_read_from_the_home_env() {
  local home store fakebin out id1 id2 n1 n2
  read -r home store fakebin <<< "$(fixture fetch-budget | tr '\n' ' ')"
  printf 'FM_LETTERBOX_REPLY_FETCH_MAX=1\n' >> "$home/.env"
  printf 'one\n' > "$home/one.txt"
  printf 'two\n' > "$home/two.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject a --file "$home/one.txt" >/dev/null \
    || fail "first send must succeed"
  id1=$(sole_sent_id "$home")
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject b --file "$home/two.txt" >/dev/null \
    || fail "second send must succeed"
  for id2 in "$home"/state/letterbox/sent/*.receipt; do
    id2=${id2##*/}; id2=${id2%.receipt}
    [ "$id2" != "$id1" ] && break
  done
  n1=$(head -n1 "$home/state/letterbox/sent/$id1.receipt")
  n2=$(head -n1 "$home/state/letterbox/sent/$id2.receipt")
  set_issue_updated_at "$store" "$n1" "$(past_stamp 120)"
  set_issue_updated_at "$store" "$n2" "$(past_stamp 120)"
  : > "$store/calls.log"
  run_poll "$home" "$store" "$fakebin" >/dev/null
  out=$(grep -c 'comments' "$store/calls.log")
  [ "$out" = 1 ] || fail "with FM_LETTERBOX_REPLY_FETCH_MAX=1 in .env exactly one comment fetch may run per cycle, not $out"
  pass "FM_LETTERBOX_REPLY_FETCH_MAX is honoured from the home .env, as documented"
}

test_a_failed_reply_stash_leaves_the_cursor_retryable() {
  local home store fakebin out id number reply_id
  read -r home store fakebin <<< "$(fixture reply-stash-cursor | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  reply_id=archie-20260824T150000Z-0c1ea11e
  inject_reply "$store" "$number" "$reply_id" "$id" answered "the answer"
  set_issue_updated_at "$store" "$number" "$(past_stamp 120)"
  install_failing_jq "$fakebin" "--arg kind reply"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_not_contains "$out" "reply $id" "a reply whose stash failed must not be announced"
  assert_absent "$home/state/letterbox/inbox/$reply_id.json" "a failed reply stash must publish nothing"
  rm -f "$fakebin/jq"
  if [ -f "$home/state/letterbox/cursor" ]; then
    jq -e --arg n "$number" 'has($n) | not' "$home/state/letterbox/cursor" >/dev/null \
      || fail "a failed reply stash must not advance the cursor past that reply"
  fi
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id answered" "the reply must be fetched again after the stash recovers"
  assert_present "$home/state/letterbox/inbox/$reply_id.json" "the retried reply must be stashed"
  pass "a failed terminal-reply stash leaves the cursor behind for a retry"
}

test_a_failed_reply_extraction_leaves_the_cursor_retryable() {
  local home store fakebin out id number reply_id
  read -r home store fakebin <<< "$(fixture reply-extract-cursor | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  reply_id=archie-20260824T150000Z-0c1ea11e
  inject_reply "$store" "$number" "$reply_id" "$id" answered "the answer"
  set_issue_updated_at "$store" "$number" "$(past_stamp 120)"
  install_failing_jq "$fakebin" "--argjson j 0"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_not_contains "$out" "reply $id" "a reply whose body could not be extracted must not be announced"
  rm -f "$fakebin/jq"
  if [ -f "$home/state/letterbox/cursor" ]; then
    jq -e --arg n "$number" 'has($n) | not' "$home/state/letterbox/cursor" >/dev/null \
      || fail "a failed reply extraction must not advance the cursor past that reply"
  fi
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id answered" "the reply must be extracted again after jq recovers"
  assert_present "$home/state/letterbox/inbox/$reply_id.json" "the retried reply must be stashed"
  pass "a failed terminal-reply extraction leaves the cursor behind for a retry"
}

test_a_failed_deferred_claim_cannot_advance_the_cursor() {
  local home store fakebin out id number reply_id
  read -r home store fakebin <<< "$(fixture reply-claim-cursor | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  reply_id=archie-20260824T150000Z-0c1ea11e
  inject_reply "$store" "$number" "$reply_id" "$id" answered "the answer"
  set_issue_updated_at "$store" "$number" "$(past_stamp 120)"
  printf '0\n' > "$home/mktemp.count"
  out=$(run_poll "$home" "$store" "$fakebin" LB_MKTEMP_ALLOW=1 LB_MKTEMP_COUNTER="$home/mktemp.count")
  assert_contains "$out" "reply $id answered" "the reply must be announced before its deferred claim"
  assert_absent "$home/state/letterbox/claims/$reply_id.json" "the injected failure must prevent the reply claim"
  if [ -f "$home/state/letterbox/cursor" ]; then
    jq -e --arg n "$number" 'has($n) | not' "$home/state/letterbox/cursor" >/dev/null \
      || fail "a failed deferred claim must not advance the cursor past its announcement"
  fi
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "reply $id answered" "the unclaimed reply must be announced again"
  assert_present "$home/state/letterbox/claims/$reply_id.json" "the retry must take the reply claim"
  pass "cursor publication waits for every deferred suppression write it depends on"
}

test_close_reply_array_building_cannot_mask_a_failed_stage() {
  local home store fakebin id number reply_id
  read -r home store fakebin <<< "$(fixture close-reply-array | tr '\n' ' ')"
  printf 'question\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" >/dev/null \
    || fail "send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  reply_id=archie-20260824T150000Z-0c1ea11e
  inject_reply "$store" "$number" "$reply_id" "$id" answered "the answer"
  run_poll "$home" "$store" "$fakebin" >/dev/null
  install_failing_jq "$fakebin" "-R ."
  run_lb "$home" "$store" "$fakebin" close "$id" >/dev/null \
    || fail "close must build and publish the consumed reply array as one checked operation"
  rm -f "$fakebin/jq"
  assert_grep "$reply_id" <(jq -r '.consumed[]' "$home/state/letterbox/claims/$id.json") \
    "close must never report success after silently dropping the consumed reply"
  pass "close builds the reply array in one checked operation, so no failed stage is masked"
}

test_duplicate_ids_are_reserved_within_one_poll_cycle() {
  local home store fakebin out id first_number rest new_count=0
  read -r home store fakebin <<< "$(fixture duplicate-cycle | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  first_number=$(inject_letter "$store" "$id" fact-lookup first "first body")
  inject_letter "$store" "$id" fact-lookup second "second body" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  rest=$out
  while [[ "$rest" == *"new $id"* ]]; do
    rest=${rest#*"new $id"}
    new_count=$((new_count + 1))
  done
  [ "$new_count" = 1 ] \
    || fail "one poll cycle must announce a duplicated card id only once (got: $out)"
  [ "$(jq -r '.subject' "$home/state/letterbox/inbox/$id.json")" = first ] \
    || fail "the first reserved card must remain in the inbox"
  [ "$(jq -r '.issue' "$home/state/letterbox/claims/$id.json")" = "$first_number" ] \
    || fail "the durable claim must identify the same issue as the stashed card"
  pass "one-cycle reservations keep a duplicated card id's stash and durable claim consistent"
}

test_inbound_subject_control_characters_are_refused() {
  local home store fakebin out tab_id escape_id tab_subject escape_subject
  read -r home store fakebin <<< "$(fixture subject-controls | tr '\n' ' ')"
  tab_id=archie-20260824T140311Z-9f2c1ab4
  escape_id=archie-20260824T140312Z-8e1b2c3d
  tab_subject=$(printf 'bad\tsubject')
  escape_subject=$(printf 'bad\033subject')
  inject_letter "$store" "$tab_id" fact-lookup "$tab_subject" "body" >/dev/null
  inject_letter "$store" "$escape_id" fact-lookup "$escape_subject" "body" >/dev/null
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "refused $tab_id subject-control-character" \
    "an inbound tab must be refused at the parser boundary"
  assert_contains "$out" "refused $escape_id subject-control-character" \
    "an inbound terminal escape must be refused at the parser boundary"
  assert_absent "$home/state/letterbox/inbox/$tab_id.json" "a tab-bearing subject must never reach the inbox"
  assert_absent "$home/state/letterbox/inbox/$escape_id.json" "an escape-bearing subject must never reach the inbox"
  pass "inbound subjects reject control characters before list can emit them"
}

test_close_refuses_unreadable_class_and_winning_status_before_the_forge_write() {
  local home store fakebin out rc id number reply_id claim reply_claim inbox
  read -r home store fakebin <<< "$(fixture close-state-reads | tr '\n' ' ')"
  printf 'notice\n' > "$home/body.txt"
  run_lb "$home" "$store" "$fakebin" send --class notice --subject update --file "$home/body.txt" >/dev/null \
    || fail "the notice send must succeed"
  id=$(sole_sent_id "$home") || fail "the send must leave a receipt"
  number=$(head -n1 "$home/state/letterbox/sent/$id.receipt")
  reply_id=archie-20260824T150000Z-0c1ea11e
  inject_reply "$store" "$number" "$reply_id" "$id" unable "cannot accept"
  run_poll "$home" "$store" "$fakebin" >/dev/null
  claim="$home/state/letterbox/claims/$id.json"
  reply_claim="$home/state/letterbox/claims/$reply_id.json"
  inbox="$home/state/letterbox/inbox/$reply_id.json"

  jq 'del(.class)' "$claim" > "$claim.new" && chmod 600 "$claim.new" && mv "$claim.new" "$claim"
  out=$(run_lb "$home" "$store" "$fakebin" close "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "close must refuse a sent claim whose class cannot be read"
  assert_contains "$out" "no valid request class" "the malformed sent class must be named before closing"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "open"' \
    "$store/issues.json" >/dev/null || fail "an unreadable sent class must leave the forge issue open"
  [ "$(jq -r '.consumed | length' "$claim")" = 0 ] || fail "an unreadable class must consume nothing"

  jq '.class = "notice" | del(.first_reply_status)' "$claim" > "$claim.new" \
    && chmod 600 "$claim.new" && mv "$claim.new" "$claim"
  jq 'del(.status)' "$reply_claim" > "$reply_claim.new" \
    && chmod 600 "$reply_claim.new" && mv "$reply_claim.new" "$reply_claim"
  jq 'del(.status)' "$inbox" > "$inbox.new" \
    && chmod 600 "$inbox.new" && mv "$inbox.new" "$inbox"
  out=$(run_lb "$home" "$store" "$fakebin" close "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "close must refuse a winning reply whose status cannot be read"
  assert_contains "$out" "cannot read the winning reply state" "the unreadable winning status must be named"
  jq -e --argjson n "$number" 'map(select(.number == $n)) | first | .state == "open"' \
    "$store/issues.json" >/dev/null || fail "an unreadable winning status must leave the forge issue open"
  [ "$(jq -r '.consumed | length' "$claim")" = 0 ] || fail "an unreadable winning status must consume nothing"
  pass "close validates the sent class and winning status before touching the forge"
}

test_a_visibility_refusal_reports_when_its_alarm_cannot_be_published() {
  local home store fakebin out rc
  read -r home store fakebin <<< "$(fixture visibility-alarm-write | tr '\n' ' ')"
  printf 'false\n' > "$store/private"
  printf 'body\n' > "$home/body.txt"
  out=$(env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_STORE="$store" LB_MKTEMP_FAIL_TEXT=1 \
    "$ROOT/bin/fm-letterbox.sh" send --class notice --subject update --file "$home/body.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a visibility refusal whose durable alarm failed must fail"
  assert_contains "$out" "cannot record the required letterbox alarm" \
    "the caller must be told that the promised wake was not made durable"
  assert_absent "$home/state/letterbox/write-error" "a failed alarm publication must not pretend a wake is durable"
  [ "$(jq -r 'length' "$store/issues.json")" = 0 ] || fail "the refused write must still reach no forge issue"
  pass "a refused write reports when its required durable wake cannot be recorded"
}

test_output_failure_cannot_flush_announcement_or_diagnostic_suppressions() {
  local home store fakebin id out rc fault_home fault_store fault_fakebin
  read -r home store fakebin <<< "$(fixture output-failure | tr '\n' ' ')"
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" fact-lookup q body >/dev/null
  run_poll "$home" "$store" "$fakebin" >&- 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed announcement write must fail the poll"
  assert_absent "$home/state/letterbox/claims/$id.json" "an unprinted announcement must not take its claim"
  out=$(run_poll "$home" "$store" "$fakebin")
  assert_contains "$out" "new $id" "the unprinted letter must be announced again"

  read -r fault_home fault_store fault_fakebin <<< "$(fixture diagnostic-output-failure | tr '\n' ' ')"
  sed -i.bak 's/FM_LETTERBOX_TRANSPORT=github/FM_LETTERBOX_TRANSPORT=carrier-pigeon/' "$fault_home/.env"
  run_poll "$fault_home" "$fault_store" "$fault_fakebin" >&- 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "a failed diagnostic write must fail the poll"
  assert_absent "$fault_home/state/letterbox/poll-error" "an unprinted diagnostic must not get a rate-limit marker"
  out=$(run_poll "$fault_home" "$fault_store" "$fault_fakebin")
  assert_contains "$out" "unsupported transport carrier-pigeon" "the unprinted diagnostic must be announced again"
  pass "output must land before any announcement or diagnostic suppression"
}

test_reconciliation_never_adopts_after_a_required_outbox_field_read_fails() {
  local home store fakebin out rc id
  read -r home store fakebin <<< "$(fixture reconcile-required-fields | tr '\n' ' ')"
  printf 'first\n' > "$home/first.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject first --file "$home/first.txt" >/dev/null \
    || fail "the first send must succeed"
  id=$(sole_sent_id "$home") || fail "the first send must leave a receipt"
  rm -f "$home/state/letterbox/sent/$id.receipt"
  install_failing_jq "$fakebin" ".resends"
  printf 'second\n' > "$home/second.txt"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject second --file "$home/second.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed required outbox-field read must stop reconciliation"
  assert_absent "$home/state/letterbox/sent/$id.receipt" "a failed resend-target read must not publish an adoption receipt"
  rm -f "$fakebin/jq"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject second --file "$home/second.txt") \
    || fail "reconciliation must recover once the outbox record is readable: $out"
  assert_contains "$out" "adopted existing letter $id" "the unreadable record must remain retryable"
  pass "all required outbox fields are checked before adoption or receipt publication"
}

test_a_failed_serialized_card_read_cannot_publish_an_empty_outbox_record() {
  local home store fakebin out rc counter
  read -r home store fakebin <<< "$(fixture serialized-card-read | tr '\n' ' ')"
  printf 'body\n' > "$home/body.txt"
  counter="$home/card-read-count"
  install_failing_card_cat "$fakebin" "$counter"
  out=$(run_lb "$home" "$store" "$fakebin" send --class notice --subject update --file "$home/body.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable serialized card must stop the send"
  assert_contains "$out" "cannot read the serialized letter card" \
    "the pre-publication serialized-card read failure must be named"
  [ "$(cat "$counter")" = 2 ] || fail "the injector must fail the second card read at the publication boundary"
  [ "$(count_files "$home/state/letterbox/outbox")" = 0 ] \
    || fail "an unreadable card must never become an empty outbox record"
  [ "$(jq -r 'length' "$store/issues.json")" = 0 ] || fail "an unreadable card must never reach the forge"
  pass "a checked serialized-card read precedes outbox publication and transport"
}

# ---------------------------------------------------------------------------

if [ -n "${FM_LETTERBOX_TEST_ONLY:-}" ]; then
  case "$FM_LETTERBOX_TEST_ONLY" in
    test_*)
      declare -F "$FM_LETTERBOX_TEST_ONLY" >/dev/null \
        || fail "unknown selected letterbox test: $FM_LETTERBOX_TEST_ONLY"
      "$FM_LETTERBOX_TEST_ONLY"
      exit 0
      ;;
    *) fail "invalid selected letterbox test: $FM_LETTERBOX_TEST_ONLY" ;;
  esac
fi

test_poll_unconfigured_is_a_hard_noop
test_poll_partial_configuration_stays_inert
test_poll_reports_a_configuration_fault_once
test_arm_generates_the_shim_and_registers_it
test_registered_shim_survives_the_watchers_validation
test_supervision_is_required_with_only_the_letterbox_shim
test_retire_removes_the_poll_and_keeps_the_records
test_retire_fails_and_names_every_registration_artifact_left_behind
test_poll_stashes_claims_and_announces_a_new_letter
test_second_sighting_of_the_same_letter_produces_nothing
test_poll_ignores_a_letter_addressed_elsewhere
test_poll_announces_a_refused_card_once
test_poll_refuses_credential_shaped_content_before_stashing_it
test_send_writes_the_outbox_before_the_transport_call
test_send_adopts_an_existing_letter_instead_of_duplicating_it
test_send_stops_when_reconciliation_lookup_fails
test_send_refuses_credential_shaped_content_before_any_write
test_send_refuses_an_unlisted_class_and_a_host_path
test_write_refuses_when_the_channel_is_not_private
test_visibility_is_checked_before_a_reply_and_a_close
test_reply_posts_a_comment_and_never_closes_the_letter
test_close_closes_then_records_the_consumed_reply_and_dedupes_a_replay
test_reply_refuses_a_letter_this_estate_sent
test_close_refuses_without_a_terminal_reply_and_refuses_a_received_letter
test_a_notice_ack_is_the_terminal_reply_that_closes_the_exchange
test_protocol_unable_is_legal_for_a_notice_and_a_parse_refusal
test_consuming_an_unable_notice_closes_and_records_the_resend_obligation
test_a_failed_close_record_leaves_the_obligation_visible_and_retryable
test_the_close_record_survives_only_one_claim_write
test_a_corrected_notice_discharges_the_resend_obligation_through_send
test_a_landed_letter_is_adopted_even_when_its_bytes_now_fail_the_gate
test_a_crash_before_the_resend_receipt_is_completed_by_the_retry
test_link_records_the_owning_task_through_a_supported_verb
test_a_refused_card_with_no_usable_id_is_unanswerable_not_owed
test_an_ack_on_any_other_class_leaves_the_exchange_open
test_a_letter_announced_but_not_yet_claimed_is_announced_again
test_a_claimed_letter_is_not_reannounced_when_its_stash_is_removed
test_reply_works_before_the_claim_exists
test_an_answered_letter_is_not_redone_when_its_stash_is_cleaned_up
test_a_refused_card_is_not_redone_for_having_no_stash
test_close_interrupted_after_the_forge_close_re_closes_harmlessly
test_close_never_records_a_consumed_reply_it_could_not_close
test_death_between_the_sent_claim_and_the_receipt_stays_reconcilable
test_a_retried_outbox_card_is_rescanned_before_transport
test_a_retried_outbox_card_is_host_path_checked_before_transport
test_a_retried_outbox_card_must_pass_the_complete_sender_grammar
test_send_refuses_every_absolute_host_path_form
test_a_card_with_an_unknown_kind_is_refused_not_ignored
test_a_parse_refused_reply_is_named_before_the_cursor_advances
test_only_the_first_terminal_reply_is_consumed
test_a_status_the_class_forbids_is_refused_on_both_paths
test_unannounced_overflow_is_left_for_the_next_poll
test_reads_are_paginated_beyond_one_page
test_a_paginated_read_failure_is_never_accepted_as_partial_data
test_stale_letter_is_resurfaced_once_per_window
test_a_linked_live_task_suppresses_the_stale_backstop
test_a_replied_letter_is_not_resurfaced
test_a_quiet_poll_costs_one_read_and_writes_nothing
test_a_reply_in_the_cursors_own_second_is_still_fetched
test_a_settled_sent_letter_makes_no_comment_fetch_on_a_quiet_poll
test_the_poll_stays_silent_when_the_transport_read_fails
test_status_reports_activation_and_what_is_owed
test_status_reports_an_unreadable_claim_without_inventing_an_obligation
test_status_on_an_unconfigured_home_says_inert
test_a_visibility_refusal_keeps_alarming_while_reads_continue
test_a_transport_write_error_survives_a_successful_read_until_a_write_lands
test_title_adoption_does_not_clear_a_write_error
test_a_lost_wake_does_not_lose_the_write_error_alarm
test_a_scan_refused_reply_names_the_sent_letter_and_keeps_it_open
test_a_sent_letter_with_a_consumed_reply_is_not_resurfaced
test_a_reply_card_in_an_issue_body_is_ignored
test_a_missing_gh_is_diagnosed_not_silent
test_the_transport_adapter_owns_its_dependency_check
test_status_counts_only_sent_letters_still_awaiting_a_reply
test_cli_partial_configuration_is_not_configured_and_creates_nothing
test_a_failed_stash_is_never_published_announced_or_claimed
test_a_failed_outbox_record_stops_the_send_before_any_transport_call
test_the_first_terminal_reply_survives_a_crash_before_it_is_cached
test_a_malformed_reply_is_keyed_by_its_forge_comment_id_not_its_position
test_a_repository_that_flips_between_the_two_checks_is_a_visibility_refusal
test_a_non_terminal_ack_carrying_a_credential_is_refused_not_skipped
test_a_missing_option_value_is_refused_not_looped
test_the_reply_fetch_budget_is_read_from_the_home_env
test_a_failed_reply_stash_leaves_the_cursor_retryable
test_a_failed_reply_extraction_leaves_the_cursor_retryable
test_a_failed_deferred_claim_cannot_advance_the_cursor
test_close_reply_array_building_cannot_mask_a_failed_stage
test_duplicate_ids_are_reserved_within_one_poll_cycle
test_inbound_subject_control_characters_are_refused
test_close_refuses_unreadable_class_and_winning_status_before_the_forge_write
test_a_visibility_refusal_reports_when_its_alarm_cannot_be_published
test_output_failure_cannot_flush_announcement_or_diagnostic_suppressions
test_reconciliation_never_adopts_after_a_required_outbox_field_read_fails
test_a_failed_serialized_card_read_cannot_publish_an_empty_outbox_record

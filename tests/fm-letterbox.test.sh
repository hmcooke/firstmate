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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) expr=$2; shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) [ -n "$path" ] || path=$1; shift ;;
  esac
done
[ -n "$path" ] || exit 1
case "$path" in
  */issues/*/comments*)
    n=${path#*/issues/}; n=${n%%/*}
    [ -f "$S/comments-$n.json" ] || printf '[]\n' > "$S/comments-$n.json"
    jq -c -r "$expr" "$S/comments-$n.json"
    ;;
  *issues?state=open*)
    jq '[.[] | select(.state == "open")]' "$S/issues.json" | jq -c -r "$expr"
    ;;
  *issues*state=open*)
    jq '[.[] | select(.state == "open")]' "$S/issues.json" | jq -c -r "$expr"
    ;;
  *issues?state=all*)
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
    ;;
  issue)
    sub=${2:-}; shift 2
    case "$sub" in
      create)
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
  [ ! -s "$store/calls.log" ] || fail "neither refusal may reach the transport"
  pass "the sender enforces the same class allowlist and host-path rule as the receiver"
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
  [ "$rc" -ne 0 ] || fail "a retry of tampered outbox bytes must be refused"
  assert_contains "$out" "credential-shaped content" "the refusal must name the class"
  assert_not_contains "$out" "$secret" "the refusal must never carry the value"
  after=$(jq -r 'length' "$store/issues.json")
  [ "$before" = "$after" ] || fail "nothing may reach the forge on a refused retry"
  grep -rF "$secret" "$store" >/dev/null 2>&1 && fail "no forge state may contain the refused value"
  pass "a retried outbox card is re-scanned on its exact recovered bytes before the transport call"
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
  [ "$rc" -ne 0 ] || fail "a retry naming a host path must be refused"
  assert_contains "$out" "absolute host path" "the refusal must name the host path"
  after=$(jq -r 'length' "$store/issues.json")
  [ "$before" = "$after" ] || fail "nothing may reach the forge on a refused retry"
  pass "a retried outbox card is host-path checked on its exact recovered bytes before the transport call"
}

test_send_refuses_every_absolute_host_path_form() {
  local home store fakebin out rc form
  read -r home store fakebin <<< "$(fixture blocker3 | tr '\n' ' ')"
  for form in "/etc" "file:///home/captain/secret" "path:/Users/captain/secret" "/home/captain/secret"; do
    printf 'the value lives at %s on that host\n' "$form" > "$home/body.txt"
    : > "$store/calls.log"
    out=$(run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/body.txt" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "an absolute host path must not be sendable: $form"
    assert_contains "$out" "absolute host path" "the refusal must name the host path for $form"
    [ "$(grep -c 'issue create' "$store/calls.log")" = 0 ] || fail "nothing may reach the forge for $form"
  done
  # The positive control: a network URL and a relative path are not host paths.
  printf 'See https://example.test/releases/v2 and the docs/letterbox page.\n' > "$home/ok.txt"
  run_lb "$home" "$store" "$fakebin" send --class fact-lookup --subject q --file "$home/ok.txt" >/dev/null \
    || fail "a URL and a relative path must remain sendable"
  pass "root-level, file-URI and label-prefixed absolute paths are all refused; URLs still pass"
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
  # Sender path: a notice may only be acked.
  id=archie-20260824T140311Z-9f2c1ab4
  inject_letter "$store" "$id" notice "the peer announces something" "for information" >/dev/null
  run_poll "$home" "$store" "$fakebin" >/dev/null
  printf 'an answer\n' > "$home/reply.txt"
  : > "$store/calls.log"
  out=$(run_lb "$home" "$store" "$fakebin" reply "$id" --status answered --file "$home/reply.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a notice must not be answered; ack is its only legal reply"
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

test_reads_are_paginated_beyond_one_page() {
  local home store fakebin out id number i cid card
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
  pass "comment reads are paginated, so a terminal reply past page one is not stranded"
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
  assert_contains "$out" "letterbox error: missing gh" \
    "a home without gh must be told once rather than polling silently forever"
  out=$(run_poll "$home" "$store" "$fakebin" BASH_ENV="$no_gh")
  [ -z "$out" ] || fail "the missing-gh diagnostic must be rate-limited (got: $out)"
  out=$(BASH_ENV="$no_gh" run_lb "$home" "$store" "$fakebin" arm 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "arm must refuse without gh, which every read verb needs"
  assert_contains "$out" "gh is required" "arm must name the missing dependency"
  assert_absent "$home/state/letterbox.check.sh" "arm must not generate a shim it cannot serve"
  pass "a missing gh is diagnosed once by the poll and refused by arm"
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

test_poll_unconfigured_is_a_hard_noop
test_poll_partial_configuration_stays_inert
test_poll_reports_a_configuration_fault_once
test_arm_generates_the_shim_and_registers_it
test_registered_shim_survives_the_watchers_validation
test_supervision_is_required_with_only_the_letterbox_shim
test_retire_removes_the_poll_and_keeps_the_records
test_poll_stashes_claims_and_announces_a_new_letter
test_second_sighting_of_the_same_letter_produces_nothing
test_poll_ignores_a_letter_addressed_elsewhere
test_poll_announces_a_refused_card_once
test_poll_refuses_credential_shaped_content_before_stashing_it
test_send_writes_the_outbox_before_the_transport_call
test_send_adopts_an_existing_letter_instead_of_duplicating_it
test_send_refuses_credential_shaped_content_before_any_write
test_send_refuses_an_unlisted_class_and_a_host_path
test_write_refuses_when_the_channel_is_not_private
test_visibility_is_checked_before_a_reply_and_a_close
test_reply_posts_a_comment_and_never_closes_the_letter
test_close_closes_then_records_the_consumed_reply_and_dedupes_a_replay
test_reply_refuses_a_letter_this_estate_sent
test_close_refuses_without_a_terminal_reply_and_refuses_a_received_letter
test_a_notice_ack_is_the_terminal_reply_that_closes_the_exchange
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
test_send_refuses_every_absolute_host_path_form
test_a_card_with_an_unknown_kind_is_refused_not_ignored
test_a_parse_refused_reply_is_named_before_the_cursor_advances
test_only_the_first_terminal_reply_is_consumed
test_a_status_the_class_forbids_is_refused_on_both_paths
test_reads_are_paginated_beyond_one_page
test_stale_letter_is_resurfaced_once_per_window
test_a_linked_live_task_suppresses_the_stale_backstop
test_a_replied_letter_is_not_resurfaced
test_a_quiet_poll_costs_one_read_and_writes_nothing
test_a_reply_in_the_cursors_own_second_is_still_fetched
test_a_settled_sent_letter_makes_no_comment_fetch_on_a_quiet_poll
test_the_poll_stays_silent_when_the_transport_read_fails
test_status_reports_activation_and_what_is_owed
test_status_on_an_unconfigured_home_says_inert
test_a_visibility_refusal_keeps_alarming_while_reads_continue
test_a_transport_write_error_survives_a_successful_read_until_a_write_lands
test_a_lost_wake_does_not_lose_the_write_error_alarm
test_a_scan_refused_reply_names_the_sent_letter_and_keeps_it_open
test_a_sent_letter_with_a_consumed_reply_is_not_resurfaced
test_a_reply_card_in_an_issue_body_is_ignored
test_a_missing_gh_is_diagnosed_not_silent
test_status_counts_only_sent_letters_still_awaiting_a_reply

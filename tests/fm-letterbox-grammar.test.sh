#!/usr/bin/env bash
# Behavior tests for the letterbox card grammar and the credential-refusal
# scanner: bin/fm-letterbox-lib.sh's parse/serialise state machine and
# bin/fm-secret-scan.sh.
#
# These are the two pieces that decide what the channel can and cannot carry, so
# every refusal in the design's grammar section has a test here, and every named
# negative control from the measurement plan's credential-refusal section has one
# too - including the honesty control that records what the scanner does NOT
# catch as a measured fact rather than a hope.
#
# Every value that looks like a credential in this file is synthetic, generated
# for the test, and is not a real credential of any kind.
#
# No network and no CLI: the grammar is pure text and the scanner reads a file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-letterbox-grammar-tests)
SCAN="$ROOT/bin/fm-secret-scan.sh"

# The library is sourced, so each case drives it through a small snippet run in
# a fresh shell with an estate identity bound and a pinned clock. Snippets are
# written as quoted heredocs and receive their file paths as positional
# arguments, so nothing has to be interpolated into a script string.
NOW=1787600000
HARNESS="$TMP_ROOT/lb-harness.sh"
cat > "$HARNESS" <<'SH'
#!/usr/bin/env bash
set -u
LB_SCRIPT_DIR="$LBT_ROOT/bin"
# shellcheck source=/dev/null
. "$LBT_ROOT/bin/fm-x-lib.sh"
# shellcheck source=/dev/null
. "$LBT_ROOT/bin/fm-letterbox-lib.sh"
LB_SELF=$LBT_SELF
LB_PEER=$LBT_PEER
NOW=$LBT_NOW
snippet=$1
shift
# shellcheck source=/dev/null
. "$snippet"
SH

lb_run() {
  local self=$1 peer=$2 snippet=$3
  shift 3
  LBT_SELF="$self" LBT_PEER="$peer" LBT_NOW="$NOW" LBT_ROOT="$ROOT" \
    bash "$HARNESS" "$snippet" "$@"
}

# A well-formed inbound request from archie to this estate.
write_request() {
  local out=$1 id=${2:-archie-20260824T140311Z-9f2c1ab4} class=${3:-fact-lookup}
  local subject=${4:-hermes cron toolset scope} body=${5:-Answer from your own config, not from memory.}
  {
    printf 'Prose above the fence is never parsed.\n\n'
    printf '```letterbox/v1\n'
    printf 'kind: request\nv: 1\nid: %s\nfrom: archie\nto: firstmate.shipyard\n' "$id"
    printf 'class: %s\nissued: 2026-08-24T14:03:11Z\nsubject: %s\nbody: |\n' "$class" "$subject"
    printf '%s\n' "$body" | sed 's/^/  /'
    printf '```\n'
    printf '\nProse below the fence is never parsed either.\n'
  } > "$out"
}

# ---------------------------------------------------------------------------
# the card

test_card_round_trips_through_serialise_and_parse() {
  local dir out
  dir="$TMP_ROOT/round-trip"; mkdir -p "$dir"
  printf 'Does a cron job run with the CLI toolset?\n\nAnswer from your own engine.\n' > "$dir/body.txt"
  cat > "$dir/snippet.sh" <<'SH'
lb_card_request_write "$1" firstmate-20260824T140311Z-9f2c1ab4 \
  fact-lookup "hermes cron toolset scope" 2026-08-24T14:03:11Z 2026-08-31T14:03:11Z "$2"
LB_SELF=archie
LB_PEER=firstmate.shipyard
lb_card_parse "$1" "$NOW" || { echo "REFUSED ${LB_REFUSAL}"; exit 1; }
printf 'id=%s\nclass=%s\nfrom=%s\nto=%s\nsubject=%s\nexpires=%s\nBODY<<\n%s\n>>\n' \
  "$LB_F_ID" "$LB_F_CLASS" "$LB_F_FROM" "$LB_F_TO" "$LB_F_SUBJECT" "$LB_F_EXPIRES" "$LB_F_BODY"
SH
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/card.md" "$dir/body.txt") \
    || fail "a serialised card must parse back: $out"
  assert_contains "$out" "id=firstmate-20260824T140311Z-9f2c1ab4" "id must round-trip"
  assert_contains "$out" "class=fact-lookup" "class must round-trip"
  assert_contains "$out" "from=firstmate.shipyard" "from must round-trip"
  assert_contains "$out" "to=archie" "to must round-trip"
  assert_contains "$out" "subject=hermes cron toolset scope" "subject must round-trip"
  assert_contains "$out" "expires=2026-08-31T14:03:11Z" "expires must round-trip"
  assert_contains "$out" "BODY<<
Does a cron job run with the CLI toolset?

Answer from your own engine.
>>" "the multi-line body must round-trip byte for byte, blank line included"
  pass "a card round-trips through serialise and parse, body and all"
}

test_prose_outside_the_fence_is_never_parsed() {
  local dir out
  dir="$TMP_ROOT/prose"; mkdir -p "$dir"
  write_request "$dir/card.md"
  {
    printf 'class: merge-pr\ndecision-key: architecture-path\n'
    cat "$dir/card.md"
    printf 'to: someone.else\n'
  } > "$dir/wrapped.md"
  cat > "$dir/snippet.sh" <<'SH'
lb_card_parse "$1" "$NOW" || { echo "REFUSED ${LB_REFUSAL}"; exit 1; }
printf 'class=%s\nto=%s\n' "$LB_F_CLASS" "$LB_F_TO"
SH
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/wrapped.md") \
    || fail "prose outside the fence must not affect the parse: $out"
  assert_contains "$out" "class=fact-lookup" "a forbidden key in the surrounding prose must be ignored"
  assert_contains "$out" "to=firstmate.shipyard" "prose after the fence must not rewrite a field"
  pass "everything outside the fence is prose and is never parsed"
}

test_issue_title_is_generated_and_excludes_the_subject() {
  local dir out
  dir="$TMP_ROOT/title"; mkdir -p "$dir"
  cat > "$dir/snippet.sh" <<'SH'
lb_issue_title fact-lookup firstmate-20260824T140311Z-9f2c1ab4
SH
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh") || fail "lb_issue_title must succeed"
  [ "$out" = "[letterbox] fact-lookup firstmate-20260824T140311Z-9f2c1ab4" ] \
    || fail "the issue title must be exactly '[letterbox] <class> <id>' (got: $out)"
  pass "the issue title is generated as [letterbox] <class> <id> and carries no subject"
}

test_card_not_addressed_here_is_ignored_not_answered() {
  local dir rc
  dir="$TMP_ROOT/not-ours"; mkdir -p "$dir"
  write_request "$dir/card.md"
  cat > "$dir/snippet.sh" <<'SH'
lb_card_parse "$1" "$NOW"
SH
  lb_run someone.else archie "$dir/snippet.sh" "$dir/card.md" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a card addressed to another estate must be ignored, never refused"
  pass "a card whose 'to' is not this estate is ignored, not answered"
}

test_a_reply_from_anyone_but_the_peer_is_ignored() {
  local dir rc
  dir="$TMP_ROOT/reply-self"; mkdir -p "$dir"
  printf 'body\n' > "$dir/body.txt"
  cat > "$dir/snippet.sh" <<'SH'
lb_card_reply_write "$1" firstmate-20260824T141902Z-3b71c40d \
  archie-20260824T140311Z-9f2c1ab4 answered 2026-08-24T14:19:02Z "$2"
lb_card_parse "$1" "$NOW"
SH
  lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/reply.md" "$dir/body.txt" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "this estate's own reply must not be re-read as an inbound reply"
  pass "a reply this estate wrote is ignored rather than consumed as the peer's"
}

# Every named refusal from the grammar's "what the card can never carry".
REFUSAL_SNIPPET="$TMP_ROOT/refusal-snippet.sh"
cat > "$REFUSAL_SNIPPET" <<'SH'
lb_card_parse "$1" "$NOW"
prc=$?
[ "$prc" -ne 0 ] || { echo ACCEPTED; exit 0; }
printf '%s %s\n' "$prc" "${LB_REFUSAL:-<none>}"
SH

refusal_case() {
  local label=$1 expect=$2 file=$3 out rc
  out=$(lb_run firstmate.shipyard archie "$REFUSAL_SNIPPET" "$file"); rc=$?
  expect_code 0 "$rc" "$label harness"
  [ "$out" = "1 $expect" ] \
    || fail "$label: expected refusal '1 $expect', got '$out'"
}

test_unknown_class_is_refused_at_parse() {
  local dir
  dir="$TMP_ROOT/unknown-class"; mkdir -p "$dir"
  write_request "$dir/card.md" archie-20260824T140311Z-9f2c1ab4 merge-pr
  refusal_case "an unknown class" unknown-class "$dir/card.md"
  pass "a class outside the v1 allowlist is refused at parse, never guessed at"
}

test_higher_version_is_refused_by_name() {
  local dir
  dir="$TMP_ROOT/version"; mkdir -p "$dir"
  write_request "$dir/card.md"
  sed 's/^v: 1$/v: 2/' "$dir/card.md" > "$dir/v2.md"
  refusal_case "a v2 card" unsupported-version "$dir/v2.md"
  sed 's/^v: 1$/v: one/' "$dir/card.md" > "$dir/vbad.md"
  refusal_case "an unparseable version" bad-version "$dir/vbad.md"
  pass "a card with a higher version is refused by name, never silently downgraded"
}

test_absolute_host_path_is_refused() {
  local dir
  dir="$TMP_ROOT/host-path"; mkdir -p "$dir"
  write_request "$dir/body.md" archie-20260824T140311Z-9f2c1ab4 fact-lookup \
    "config location" "The value lives in /home/captain/config.yaml on that host."
  refusal_case "a body naming a host path" absolute-host-path "$dir/body.md"
  write_request "$dir/subject.md" archie-20260824T140311Z-9f2c1ab4 fact-lookup \
    "check /Users/captain/notes for it" "Nothing else."
  refusal_case "a subject naming a host path" absolute-host-path "$dir/subject.md"
  pass "an absolute host path is refused in the subject and in the body"
}

test_ordinary_url_is_not_mistaken_for_a_host_path() {
  local dir out
  dir="$TMP_ROOT/url"; mkdir -p "$dir"
  write_request "$dir/card.md" archie-20260824T140311Z-9f2c1ab4 fact-lookup \
    "release notes" "See https://example.test/releases/v2 and the docs/letterbox page."
  cat > "$dir/snippet.sh" <<'SH'
lb_card_parse "$1" "$NOW" || { echo "REFUSED ${LB_REFUSAL}"; exit 1; }
echo ACCEPTED
SH
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/card.md") \
    || fail "an ordinary URL must not be refused as a host path: $out"
  assert_contains "$out" ACCEPTED "a URL and a relative path are legal card content"
  pass "an absolute URL and a relative path are not host paths (the positive control)"
}

test_authority_fields_are_refused() {
  local dir field
  dir="$TMP_ROOT/authority"; mkdir -p "$dir"
  write_request "$dir/card.md"
  for field in decision-key approved-by captain attribution on-behalf-of; do
    sed "s|^subject: |$field: architecture-path\\
subject: |" "$dir/card.md" > "$dir/$field.md"
    refusal_case "a card carrying $field" forbidden-authority-field "$dir/$field.md"
  done
  pass "a decision key, an approval and a captain attribution are all refused at parse"
}

test_unknown_field_is_refused() {
  local dir
  dir="$TMP_ROOT/unknown-field"; mkdir -p "$dir"
  write_request "$dir/card.md"
  sed "s|^subject: |deliver-file: report\\
subject: |" "$dir/card.md" > "$dir/extra.md"
  refusal_case "an unknown field" unknown-field "$dir/extra.md"
  pass "any field outside the grammar is refused rather than ignored"
}

test_oversized_body_is_refused_not_truncated() {
  local dir big out
  dir="$TMP_ROOT/oversize"; mkdir -p "$dir"
  big=$(awk 'BEGIN { while (i++ < 9000) printf "x" }')
  write_request "$dir/card.md" archie-20260824T140311Z-9f2c1ab4 fact-lookup "big" "$big"
  refusal_case "a 9000-byte body" body-too-large "$dir/card.md"
  cat > "$dir/snippet.sh" <<'SH'
lb_card_parse "$1" "$NOW" >/dev/null 2>&1
printf '%s\n' "${#LB_F_BODY}"
SH
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/card.md")
  [ "$out" -gt 8192 ] || fail "the refusal must not have truncated the body first (len $out)"
  pass "a body over 8 KiB is refused, not truncated"
}

test_future_issued_card_is_refused() {
  local dir
  dir="$TMP_ROOT/future"; mkdir -p "$dir"
  write_request "$dir/card.md"
  sed 's/^issued: .*$/issued: 2027-08-24T14:03:11Z/' "$dir/card.md" > "$dir/future.md"
  refusal_case "a card issued a year ahead" future-issued "$dir/future.md"
  pass "a card issued more than 24 hours in the future is refused (the clock-skew guard)"
}

test_structural_refusals() {
  local dir
  dir="$TMP_ROOT/structural"; mkdir -p "$dir"
  write_request "$dir/card.md"
  sed 's/^id: .*/id: not-an-id/' "$dir/card.md" > "$dir/bad-id.md"
  refusal_case "a malformed id" bad-id "$dir/bad-id.md"
  sed "s|^subject: |class: ping\\
subject: |" "$dir/card.md" > "$dir/dupe.md"
  refusal_case "a duplicated field" duplicate-field "$dir/dupe.md"
  sed '/^```$/,$d' "$dir/card.md" > "$dir/open.md"
  refusal_case "an unterminated card" unterminated-card "$dir/open.md"
  { cat "$dir/card.md"; cat "$dir/card.md"; } > "$dir/two.md"
  refusal_case "two cards in one document" multiple-cards "$dir/two.md"
  write_request "$dir/ping.md" archie-20260824T140311Z-9f2c1ab4 ping "liveness" "this should be empty"
  refusal_case "a ping carrying content" ping-carries-content "$dir/ping.md"
  pass "malformed ids, duplicate fields, unterminated and doubled cards are each refused by name"
}

test_notice_ack_is_terminal_and_other_acks_are_not() {
  local dir out
  dir="$TMP_ROOT/terminality"; mkdir -p "$dir"
  cat > "$dir/snippet.sh" <<'SH'
lb_status_terminal ack notice          && echo 'notice-ack=terminal'
lb_status_terminal ack fact-lookup     || echo 'factlookup-ack=open'
lb_status_terminal answered fact-lookup && echo 'answered=terminal'
lb_status_allowed ack && echo 'ack=allowed'
lb_status_allowed done || echo 'done=rejected'
exit 0
SH
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh") || fail "status helpers must succeed: $out"
  assert_contains "$out" "notice-ack=terminal" "a notice ack is the terminal reply for that class"
  assert_contains "$out" "factlookup-ack=open" "an ack on any other class leaves the exchange open"
  assert_contains "$out" "answered=terminal" "answered is terminal"
  assert_contains "$out" "ack=allowed" "ack is a legal reply status"
  assert_contains "$out" "done=rejected" "there is no 'done' reply status"
  pass "a notice's ack is terminal and required, while an ack elsewhere is not"
}

test_class_allowlist_is_exactly_v1() {
  local dir out
  dir="$TMP_ROOT/allowlist"; mkdir -p "$dir"
  cat > "$dir/snippet.sh" <<'SH'
for c in ping notice fact-lookup capability-query work-proposal; do
  lb_class_allowed "$c" || echo "MISSING $c"
done
for c in do-task run merge deliver-file schedule notify-captain answer-decision; do
  lb_class_allowed "$c" && echo "LEAKED $c"
done
echo CHECKED
SH
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh") || fail "class allowlist harness: $out"
  assert_contains "$out" CHECKED "allowlist harness must complete"
  assert_not_contains "$out" MISSING "every v1 class must be allowed"
  assert_not_contains "$out" LEAKED "no class outside v1 may be accepted"
  pass "the class allowlist is exactly the v1 set and nothing that acts unilaterally"
}

test_a_document_with_no_card_is_ignored_not_refused() {
  local dir rc
  dir="$TMP_ROOT/no-card"; mkdir -p "$dir"
  printf 'Just an ordinary human comment on the issue.\nNo fence anywhere.\n' > "$dir/prose.md"
  cat > "$dir/snippet.sh" <<'SH'
lb_card_parse "$1" "$NOW"
SH
  lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/prose.md" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a document with no card must be ignored, never refused"
  printf '' > "$dir/empty.md"
  lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/empty.md" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an empty document must be ignored too"
  pass "ordinary prose with no card is ignored, so a human comment never becomes a refusal"
}

test_unknown_or_missing_kind_is_a_named_refusal() {
  local dir
  dir="$TMP_ROOT/bad-kind"; mkdir -p "$dir"
  write_request "$dir/card.md"
  sed 's/^kind: request$/kind: dispatch/' "$dir/card.md" > "$dir/unknown.md"
  refusal_case "a card with an unknown kind" bad-kind "$dir/unknown.md"
  sed '/^kind: request$/d' "$dir/card.md" > "$dir/missing.md"
  refusal_case "a card with no kind at all" bad-kind "$dir/missing.md"
  pass "a fenced card with an unknown or missing kind is refused by name, never ignored"
}

test_every_absolute_host_path_form_is_refused() {
  local dir out
  dir="$TMP_ROOT/host-forms"; mkdir -p "$dir"
  cat > "$dir/snippet.sh" <<'SH'
while IFS= read -r value; do
  [ -n "$value" ] || continue
  if lb_has_host_path "$value"; then printf 'REFUSED %s
' "$value"; else printf 'accepted %s
' "$value"; fi
done < "$1"
SH
  {
    printf '/etc
'
    printf 'file:///home/captain/secret
'
    printf 'path:/Users/captain/secret
'
    printf '/home/captain/secret
'
    printf 'the file is at /var/log/thing
'
    # shellcheck disable=SC2016 # The literal, unexpanded form is the input under test.
    printf '/$HOME/secret
'
    printf '/+cache/file
'
    printf '/
'
    printf 'the root is / on every host
'
    printf '(/etc/hosts)
'
  } > "$dir/refuse.txt"
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/refuse.txt") || fail "harness: $out"
  assert_not_contains "$out" "accepted" "every absolute host path form must be refused"$'
'"$out"
  {
    printf 'See https://example.test/releases/v2 and the docs/letterbox page.
'
    printf 'run bin/fm-letterbox.sh status
'
    printf 'and/or
'
    printf '24/7
'
    printf 'n/a
'
  } > "$dir/accept.txt"
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/accept.txt") || fail "harness: $out"
  assert_not_contains "$out" "REFUSED" "a URL and a relative path are not host paths"$'
'"$out"
  pass "root-level, file-URI, label-prefixed and non-alphanumeric-start paths are refused; URLs and relative paths are not"
}

test_a_hyphenated_estate_identity_generates_a_valid_id() {
  local dir out
  dir="$TMP_ROOT/id-prefix"; mkdir -p "$dir"
  cat > "$dir/snippet.sh" <<'SH'
id=$(lb_id_new) || { echo "GENERATE-FAILED"; exit 0; }
if lb_id_valid "$id"; then printf 'valid %s\n' "${id%%-2*}"; else printf 'INVALID %s\n' "$id"; fi
SH
  out=$(lb_run first-mate.shipyard archie "$dir/snippet.sh") || fail "harness: $out"
  assert_contains "$out" "valid firstmate" \
    "a hyphenated first segment must normalise to the id alphabet and validate"$'\n'"$out"
  out=$(lb_run a-very-long-estate-name.shipyard archie "$dir/snippet.sh") || fail "harness: $out"
  assert_contains "$out" "valid averylongest" "the normalised prefix is cut to twelve characters"$'\n'"$out"
  pass "a valid estate identity with hyphens generates an id its own validator accepts"
}

# ---------------------------------------------------------------------------
# the credential-refusal scanner, control by control

scan_case() {
  local label=$1 expect_rc=$2 expect_class=$3 file=$4 out rc
  out=$("$SCAN" "$file"); rc=$?
  expect_code "$expect_rc" "$rc" "$label exit"
  if [ -n "$expect_class" ]; then
    [ "$out" = "refused: $expect_class" ] \
      || fail "$label: expected 'refused: $expect_class', got '$out'"
  else
    [ -z "$out" ] || fail "$label: expected no output, got '$out'"
  fi
}

test_scanner_negative_controls() {
  local dir
  dir="$TMP_ROOT/scan"; mkdir -p "$dir"

  printf 'the key is ghp_%s and it must never travel\n' \
    "$(awk 'BEGIN { while (i++ < 36) printf "A" }')" > "$dir/n1"
  scan_case "N1 a GitHub personal token prefix" 1 provider-key-prefix "$dir/n1"

  printf 'github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz1234567890\n' > "$dir/n2"
  scan_case "N2 a fine-grained GitHub token shape" 1 provider-key-prefix "$dir/n2"

  printf 'sk-%s\n' "$(awk 'BEGIN { while (i++ < 48) printf "b" }')" > "$dir/n3"
  scan_case "N3 an sk- provider key" 1 provider-key-prefix "$dir/n3"

  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA\n-----END OPENSSH PRIVATE KEY-----\n' > "$dir/n4"
  scan_case "N4 a PEM private key header" 1 private-key-header "$dir/n4"

  printf 'TELEGRAM_BOT_TOKEN=123456789:AAFakeFakeFakeFakeFakeFakeFakeFakeFa\n' > "$dir/n5"
  scan_case "N5 an env-style credential assignment" 1 env-assignment "$dir/n5"

  printf 'the value is 0123456789abcdef0123456789abcdef01234567 exactly\n' > "$dir/n6"
  scan_case "N6 a bare 40-character hex string" 1 high-entropy "$dir/n6"

  printf 'the note is called hermes-archie-env in the vault\n' > "$dir/vault"
  scan_case "the vault note name" 1 vault-note-name "$dir/vault"

  pass "N1-N6 and the vault note name are each refused, naming the class and never the value"
}

test_scanner_refusal_never_echoes_the_value() {
  local dir out
  dir="$TMP_ROOT/scan-quiet"; mkdir -p "$dir"
  printf 'ghp_%s\n' "$(awk 'BEGIN { while (i++ < 36) printf "Z" }')" > "$dir/secret"
  out=$("$SCAN" "$dir/secret" 2>&1)
  assert_not_contains "$out" "ghp_" "a refusal must never reproduce the matched value"
  assert_not_contains "$out" "ZZZZ" "a refusal must never reproduce the matched value"
  pass "a refusal names the class and never the value, so it is safe to log"
}

test_scanner_honesty_control_n7_records_the_measured_limit() {
  local dir out rc
  dir="$TMP_ROOT/scan-n7"; mkdir -p "$dir"
  # N7: the same synthetic secret, split across two lines AND base64-encoded.
  # This is EXPECTED NOT TO BE CAUGHT. bin/fm-secret-scan.sh's own header states
  # that it is defence in depth rather than a boundary, and that it will not
  # catch a secret that has been split or encoded. This test pins that limit as
  # a measured fact so it can never quietly become an assumption: if the scanner
  # is ever strengthened to catch this, this test fails and the header, the docs
  # and the claim all get revisited together.
  printf 'part one Z2hwX0FBQUFBQUFBQUFB\npart two QUFBQUFBQUFBQUFBQUE=\n' > "$dir/n7"
  out=$("$SCAN" "$dir/n7"); rc=$?
  expect_code 0 "$rc" "N7 measured outcome"
  [ -z "$out" ] || fail "N7 measured outcome: expected no refusal, got '$out'"
  pass "N7 measured: a split and encoded secret is NOT caught - the scanner's stated limit"
}

test_scanner_positive_control_passes_ordinary_prose() {
  local dir
  dir="$TMP_ROOT/scan-p1"; mkdir -p "$dir"
  {
    printf 'The build phase issues a token before the release step.\n'
    printf 'The operator holds the key to that stage; ask them for the session name.\n'
    printf 'The password policy is documented in the handbook, not here.\n'
  } > "$dir/p1"
  scan_case "P1 ordinary prose using credential nouns" 0 "" "$dir/p1"
  pass "P1 passes unrefused, proving the scanner is not a blanket refusal"
}

test_scanner_treats_its_own_failure_as_a_refusal() {
  local dir rc out
  dir="$TMP_ROOT/scan-missing"; mkdir -p "$dir"
  out=$("$SCAN" "$dir/does-not-exist" 2>&1); rc=$?
  expect_code 2 "$rc" "an unreadable target must be a usage error, not a pass"
  assert_contains "$out" "unreadable" "the caller must be told nothing was scanned"
  out=$("$SCAN" 2>&1); rc=$?
  expect_code 2 "$rc" "no argument must be a usage error"
  pass "an unscannable input exits non-zero, so a caller can never read it as clean"
}

test_scanner_fails_closed_when_grep_cannot_run() {
  local dir out rc
  dir="$TMP_ROOT/scan-grep"; mkdir -p "$dir/bin"
  printf 'ordinary content\n' > "$dir/plain.txt"
  # A grep that reports an execution error, as a missing or broken grep would.
  printf '#!/usr/bin/env bash\nexit 2\n' > "$dir/bin/grep"
  chmod +x "$dir/bin/grep"
  out=$(PATH="$dir/bin:$PATH" "$SCAN" "$dir/plain.txt" 2>&1); rc=$?
  expect_code 2 "$rc" "a grep execution error must be reported as not scanned, never as clean"
  assert_contains "$out" "could not run" "the caller must be told the check did not run"
  # A grep that dies only on the final extractor, which used to discard its status.
  cat > "$dir/bin/grep" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -oE "*) exit 2 ;; esac
exec /usr/bin/grep "$@"
SH
  [ -x /usr/bin/grep ] || sed -i.bak 's#/usr/bin/grep#'"$(command -v grep)"'#' "$dir/bin/grep"
  out=$(PATH="$dir/bin:$PATH" "$SCAN" "$dir/plain.txt" 2>&1); rc=$?
  expect_code 2 "$rc" "an extractor failure must be reported as not scanned"
  cat > "$dir/snippet.sh" <<'SH'
if lb_scan_refuses "$1"; then echo "REFUSED ${LB_SCAN_REASON}"; else echo CLEAN; fi
SH
  out=$(PATH="$dir/bin:$PATH" lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/plain.txt") \
    || fail "scan gate harness must run: $out"
  assert_contains "$out" "REFUSED scanner-unavailable" "the gate must refuse when a check could not run"
  pass "the scanner fails closed: a grep error is a refusal, never a pass"
}

test_scanner_gate_refuses_when_the_scanner_cannot_run() {
  local dir out
  dir="$TMP_ROOT/scan-gate"; mkdir -p "$dir"
  printf 'ordinary content\n' > "$dir/plain.txt"
  cat > "$dir/snippet.sh" <<'SH'
LB_SCRIPT_DIR=/nonexistent-scanner-dir
if lb_scan_refuses "$1"; then echo "REFUSED ${LB_SCAN_REASON}"; else echo CLEAN; fi
SH
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/plain.txt") \
    || fail "scan gate harness must run: $out"
  assert_contains "$out" "REFUSED scanner-unavailable" \
    "a scanner that cannot run must be a refusal, because nothing was proven clean"
  pass "the scan gate refuses when the scanner itself cannot run"
}

test_crlf_card_parses_identically_to_its_lf_twin() {
  local dir lf crlf
  dir="$TMP_ROOT/crlf"; mkdir -p "$dir"
  write_request "$dir/lf.md" archie-20260824T140311Z-9f2c1ab4 fact-lookup "web authored" "line one
line two"
  sed "s/\$/$(printf '\r')/" "$dir/lf.md" > "$dir/crlf.md"
  grep -q "$(printf '\r')" "$dir/crlf.md" || fail "the CRLF twin must actually carry carriage returns"
  cat > "$dir/snippet.sh" <<'SH'
lb_card_parse "$1" "$NOW" || { echo "REFUSED ${LB_REFUSAL}"; exit 1; }
printf 'id=%s\nclass=%s\nfrom=%s\nto=%s\nsubject=%s\nissued=%s\nBODY<<%s>>\n' \
  "$LB_F_ID" "$LB_F_CLASS" "$LB_F_FROM" "$LB_F_TO" "$LB_F_SUBJECT" "$LB_F_ISSUED" "$LB_F_BODY"
SH
  lf=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/lf.md") || fail "the LF card must parse: $lf"
  crlf=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/crlf.md") \
    || fail "a CRLF card authored through a web editor must parse, not be silently ignored: $crlf"
  [ "$lf" = "$crlf" ] || fail "a CRLF card must parse to exactly the fields of its LF twin
LF:
$lf
CRLF:
$crlf"
  case "$crlf" in *"$(printf '\r')"*) fail "no field may keep a carriage return" ;; esac
  # Every refusal still fires on a CRLF card: the normalisation is line endings only.
  write_request "$dir/bad-lf.md" archie-20260824T140311Z-9f2c1ab4 merge-pr
  sed "s/\$/$(printf '\r')/" "$dir/bad-lf.md" > "$dir/bad-crlf.md"
  crlf=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/bad-crlf.md") \
    && fail "a CRLF card outside the class allowlist must still be refused"
  assert_contains "$crlf" "REFUSED unknown-class" "the CRLF refusal must name the same class"
  pass "a CRLF-authored card parses to the same fields as its LF twin and is refused on the same faults"
}

test_claim_rewrites_never_publish_over_a_claim_jq_cannot_read() {
  local dir out
  dir="$TMP_ROOT/claim-jq"; mkdir -p "$dir"
  cat > "$dir/snippet.sh" <<'SH'
state=$1
id=archie-20260824T140311Z-9f2c1ab4
lb_claim_create "$state" "$id" fact-lookup archie 7; printf 'create=%s\n' "$?"
lb_claim_create "$state" "$id" fact-lookup archie 7; printf 'again=%s\n' "$?"
lb_claim_create "$state" archie-20260824T140311Z-00000002 fact-lookup archie notanumber; printf 'badissue=%s\n' "$?"
[ -e "$(lb_claim_path "$state" archie-20260824T140311Z-00000002)" ] && printf 'badissue-file=present\n'
lb_claim_set "$state" "$id" task letter-work; printf 'set=%s\n' "$?"
printf 'task=%s\n' "$(lb_claim_field "$state" "$id" task)"
lb_claim_set_number "$state" "$id" resurfaced notanumber; printf 'setnum=%s\n' "$?"
printf 'not json\n' > "$(lb_claim_path "$state" "$id")"
lb_claim_set "$state" "$id" task other; printf 'corrupt-set=%s\n' "$?"
lb_claim_set_number "$state" "$id" resurfaced 5; printf 'corrupt-setnum=%s\n' "$?"
lb_claim_consume "$state" "$id" archie-20260824T150000Z-0c1ea11e; printf 'corrupt-consume=%s\n' "$?"
printf 'after<<%s>>\n' "$(cat "$(lb_claim_path "$state" "$id")")"
SH
  out=$(lb_run firstmate.shipyard archie "$dir/snippet.sh" "$dir/state")
  assert_contains "$out" "create=0" "the first claim must succeed"
  assert_contains "$out" "again=1" "a second claim of the same id must report already claimed"
  assert_contains "$out" "badissue=2" "a claim jq cannot build must report an error, not success"
  assert_not_contains "$out" "badissue-file=present" "a claim jq could not build must leave no file"
  assert_contains "$out" "set=0" "a field rewrite on a good claim must succeed"
  assert_contains "$out" "task=letter-work" "the rewrite must land"
  assert_contains "$out" "setnum=1" "a non-numeric number must be refused"
  assert_contains "$out" "corrupt-set=1" "a rewrite of an unreadable claim must fail"
  assert_contains "$out" "corrupt-setnum=1" "a numeric rewrite of an unreadable claim must fail"
  assert_contains "$out" "corrupt-consume=1" "a consume on an unreadable claim must fail"
  assert_contains "$out" "after<<not json>>" \
    "a failed rewrite must leave the claim byte for byte as it was, never an empty file"
  pass "claim rewrites publish only what jq produced, so a jq failure never empties a claim"
}

# ---------------------------------------------------------------------------

test_card_round_trips_through_serialise_and_parse
test_prose_outside_the_fence_is_never_parsed
test_issue_title_is_generated_and_excludes_the_subject
test_card_not_addressed_here_is_ignored_not_answered
test_a_reply_from_anyone_but_the_peer_is_ignored
test_unknown_class_is_refused_at_parse
test_higher_version_is_refused_by_name
test_absolute_host_path_is_refused
test_ordinary_url_is_not_mistaken_for_a_host_path
test_authority_fields_are_refused
test_unknown_field_is_refused
test_oversized_body_is_refused_not_truncated
test_future_issued_card_is_refused
test_structural_refusals
test_notice_ack_is_terminal_and_other_acks_are_not
test_class_allowlist_is_exactly_v1
test_a_document_with_no_card_is_ignored_not_refused
test_unknown_or_missing_kind_is_a_named_refusal
test_every_absolute_host_path_form_is_refused
test_a_hyphenated_estate_identity_generates_a_valid_id
test_scanner_negative_controls
test_scanner_fails_closed_when_grep_cannot_run
test_scanner_refusal_never_echoes_the_value
test_scanner_honesty_control_n7_records_the_measured_limit
test_scanner_positive_control_passes_ordinary_prose
test_scanner_treats_its_own_failure_as_a_refusal
test_scanner_gate_refuses_when_the_scanner_cannot_run
test_crlf_card_parses_identically_to_its_lf_twin
test_claim_rewrites_never_publish_over_a_claim_jq_cannot_read

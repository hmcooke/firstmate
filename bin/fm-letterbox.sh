#!/usr/bin/env bash
# The agent-to-agent letterbox: one entry point for arming the poll and for
# every read and write of the peer channel.
#
# A letter is INPUT, never instruction and never authority. This script moves
# cards; it never acts on their content. The handling procedure, the class
# semantics and that rule live in
# .agents/skills/letterbox-correspondence/SKILL.md, and docs/letterbox.md owns
# operator setup, activation, state layout and the crash matrix.
#
# Usage:
#   fm-letterbox.sh arm
#       Generate state/letterbox.check.sh and register it with
#       bin/fm-check-register.sh, so the watcher's ordinary check sweep runs the
#       poll. Idempotent. Refuses unless all four activation settings are valid.
#   fm-letterbox.sh status
#       Local-only report: activation, whether the poll is armed and registered,
#       unanswered letters, letters this estate sent whose terminal reply it has
#       not yet consumed, any outbox record without a matching receipt (with its
#       refusal reason when it can no longer be sent), and refused
#       cards with no usable id, which no command can answer and are listed as
#       UNANSWERABLE rather than owed. Makes no API call.
#   fm-letterbox.sh list
#       Local-only tab-separated summary of every stashed letter and reply.
#   fm-letterbox.sh read <id>
#       Print one stashed card from the inbox.
#   fm-letterbox.sh send --class <c> --subject <s> --file <f> [--expires <iso>]
#                        [--resends <notice-id>]
#       Send one letter. The id is chosen and recorded in the outbox BEFORE the
#       transport call, so a retry adopts the existing issue by title-matched id
#       instead of creating a second one. The body file is read exactly once,
#       and the assembled card is validated as a whole immediately before it is
#       recorded or transmitted. --resends names a notice this estate sent that
#       the peer answered "unable": the new letter must itself be a notice, and
#       its id is recorded as resent_as on that claim in the same success
#       boundary as the receipt, which discharges the RESEND REQUIRED obligation.
#       An earlier outbox record that can no longer pass the scan or the grammar
#       is reported as UNSENDABLE and left in place; it never blocks a new send.
#   fm-letterbox.sh reply <id> --status <s> --file <f>
#       Reply to a received letter. The responder NEVER closes the issue. The
#       attempt is recorded on the claim BEFORE the comment is posted, so a
#       replayed wake completes an interrupted reply from the comment that
#       already landed instead of posting a second one; an answered letter is
#       refused, and status lists it as REPLIED.
#   fm-letterbox.sh link <id> --task <task-id>
#       Record the ordinary firstmate task that now owns a received letter's
#       obligation, so the stale backstop stops re-surfacing it while that task
#       is alive. This is the supported way to set task on a claim.
#   fm-letterbox.sh close <id>
#       Requester-side receipt: close the issue, which is idempotent, and then
#       record the consumed terminal reply id, so a crash between the two
#       re-closes harmlessly instead of stranding an open letter whose reply is
#       already marked consumed. An open issue means somebody still owes
#       something, so closing is the one signal that the exchange is finished.
#   fm-letterbox.sh retire
#       Remove the poll shim and its registration. Letters, claims and receipts
#       are durable records and are kept.
#
# Every write first verifies through the transport that the channel repository is
# still private and REFUSES if it is not, recording the refusal durably so the
# poll raises it even if this turn is lost. The record is classed: its first line
# is "visibility" when the repository is confirmed not private, or "transport"
# when the check itself could not run. The transport adapter re-checks at its
# own boundary and reports the class in its exit status, so a repository that
# flips between the two checks is still recorded under "visibility". Neither
# class is cleared by a read, and a visibility record is never downgraded by a
# later transport failure; both keep alarming until a write lands. Every write
# that carries card bytes also runs bin/fm-secret-scan.sh over the assembled card
# first and refuses on anything but a clean result; it refuses, it never redacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LB_SCRIPT_DIR=$SCRIPT_DIR
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-letterbox-lib.sh
. "$SCRIPT_DIR/fm-letterbox-lib.sh"

WORK=
reply_note=
# Cleanup failure cannot change the command result after private work is done.
trap '[ -z "$WORK" ] || rm -rf -- "$WORK" || true' EXIT HUP INT TERM

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '2,69{s/^# \{0,1\}//;p;}' "$0"
  exit "${1:-0}"
}

workdir() {
  [ -n "$WORK" ] && return 0
  WORK=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-letterbox.XXXXXX") || die "cannot create a work directory"
}

# All four activation keys, present and valid, or nothing: a partially
# configured home is "not configured" and creates no state, exactly as the poll
# treats it. Only a fully opted-in home with a bad value is a fault to report.
require_active() {
  lb_load_config
  [ "$LB_ACTIVE" = 1 ] || [ -n "$LB_CONFIG_ERROR" ] \
    || die "the letterbox is not configured in this home (see docs/letterbox.md)"
  [ -z "$LB_CONFIG_ERROR" ] || die "$LB_CONFIG_ERROR"
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

# A flag that takes a value must have one; otherwise "$2" is empty, "shift 2"
# fails without terminating the script, and the parser loops forever.
need_value() {
  [ "$#" -ge 2 ] || die "$1 needs a value"
}

ROOT_DIR() { lb_root "$STATE"; }

ensure_dirs() {
  local d
  for d in inbox claims outbox sent; do
    fmx_private_artifact_dir_prepare "$(lb_dir "$STATE" "$d")" >/dev/null \
      || die "cannot create the letterbox state directories under $(ROOT_DIR)"
  done
}

# A refused write is durable state so it survives a lost turn: the poll raises it
# on the next cycle. Cleared by the next write that actually lands. The first
# line is the class (visibility or transport) so the poll reports it structurally
# rather than inferring its kind from the prose.
#
# A visibility record is NEVER replaced by a transport one: a confirmed-public
# channel is the most captain-facing event this feature can raise, and a later
# check that merely could not run proves nothing about whether the channel is
# private again. Only a landed write retires it, through clear_write_error.
record_write_error() {
  local class=$1 msg=$2 existing
  if [ "$class" = transport ] && fmx_private_artifact_file_valid "$(ROOT_DIR)" "write-error" 600; then
    if ! existing=$(head -n1 "$(ROOT_DIR)/write-error" 2>/dev/null); then
      # An unreadable existing alarm is preserved rather than overwritten blind.
      existing=visibility
    fi
    [ "$existing" != visibility ] || return 0
  fi
  lb_text_publish "$(ROOT_DIR)" "write-error" 600 "$class" "$msg" 2>/dev/null
}

clear_write_error() {
  fmx_private_artifact_dir_device "$(ROOT_DIR)" >/dev/null 2>&1 || return 0
  # A failed cleanup leaves the prior alarm loud, which is safer than hiding it.
  rm -f "$(ROOT_DIR)/write-error" 2>/dev/null || true
}

# The visibility precondition, enforced immediately before every write. One API
# call, and it is what turns an accidentally public channel from a silent
# ongoing exposure into a hard stop plus an alarm.
require_private_channel() {
  local reason rc class
  if reason=$(lb_transport require-private 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || return 0
  case "$rc" in
    2) class=visibility ;;
    *) class=transport ;;
  esac
  [ -n "$reason" ] || reason="cannot confirm $LB_REPO is private"
  record_write_error "$class" "letterbox write refused: $reason" \
    || die "refusing to write: $reason; cannot record the required letterbox alarm"
  die "refusing to write: $reason"
}

# Refuses on anything but a clean scan, including the scanner failing to run.
require_clean() {
  if lb_scan_refuses "$1"; then
    die "refusing to send: credential-shaped content ($LB_SCAN_REASON); nothing was written or transmitted"
  fi
}

# The one write boundary. Every transport write goes through here, so the
# adapter's own visibility gate - which runs after this script's check and can
# see a repository that flipped in between - is recorded under its class
# exactly as the first check would have been, and the alarm is never lost to a
# generic failure. Prints the adapter's stdout; the caller decides what a
# non-gate failure means.
transport_write() {
  local verb=$1 out rc reason
  shift
  workdir
  if out=$(lb_transport "$verb" "$@" 2>"$WORK/transport.err"); then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0)
      clear_write_error
      printf '%s\n' "$out"
      return 0
      ;;
    2|3)
      if ! reason=$(sed -n 's/^letterbox transport: refusing to write, //p' "$WORK/transport.err" 2>/dev/null); then
        # The adapter status still identifies the refusal class when its detail is unreadable.
        reason=
      fi
      reason=${reason##*$'\n'}
      [ -n "$reason" ] || reason="cannot confirm $LB_REPO is private"
      if [ "$rc" -eq 2 ]; then
        record_write_error visibility "letterbox write refused: $reason" \
          || die "refusing to write: $reason; cannot record the required letterbox alarm"
      else
        record_write_error transport "letterbox write refused: $reason" \
          || die "refusing to write: $reason; cannot record the required letterbox alarm"
      fi
      die "refusing to write: $reason"
      ;;
  esac
  # An unreadable optional diagnostic must not replace the transport's real status.
  cat "$WORK/transport.err" >&2 2>/dev/null || true
  return "$rc"
}

file_size_bytes() {
  local size
  size=$(wc -c < "$1") || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$size"
}

# Whole-card enforcement on the EXACT bytes that will be recorded or
# transmitted: the card this process just assembled, and a card recovered from
# the outbox for a retry. It is the receiver's own grammar applied with the
# identities swapped, plus this estate's addressing, so a card this estate could
# not accept is never emitted either. The field-level gate below gives a fresh
# send its readable messages; this one is what is trusted, and it runs after
# every read of mutable input has already happened.
#   card_unsendable_reason <file> <kind> <id> <class-or-status> [in-reply-to]
# Prints one reason and returns 0 when the card must not be transmitted;
# prints nothing and returns 1 when it may.
card_unsendable_reason() {
  local file=$1 kind=$2 expected_id=$3 expected=$4 correlate=${5-} size self peer rc card
  size=$(file_size_bytes "$file") || { printf 'unreadable size\n'; return 0; }
  [ "$size" -le 65536 ] || { printf 'implausibly large\n'; return 0; }
  card=$(cat "$file") || { printf 'unreadable card\n'; return 0; }
  if lb_has_host_path "$card"; then printf 'absolute host path\n'; return 0; fi
  self=$LB_SELF
  peer=$LB_PEER
  LB_SELF=$peer
  LB_PEER=$self
  lb_card_parse "$file"
  rc=$?
  LB_SELF=$self
  LB_PEER=$peer
  if [ "$rc" -ne 0 ]; then
    printf 'fails the v1 grammar (%s)\n' "${LB_REFUSAL:-invalid-addressing}"
    return 0
  fi
  [ "$LB_F_KIND" = "$kind" ] || { printf 'not a %s\n' "$kind"; return 0; }
  [ "$LB_F_ID" = "$expected_id" ] && [ "$LB_F_FROM" = "$self" ] && [ "$LB_F_TO" = "$peer" ] \
    || { printf 'does not match its identity or addressing\n'; return 0; }
  if [ "$kind" = request ]; then
    [ "$LB_F_CLASS" = "$expected" ] || { printf 'does not match its recorded class\n'; return 0; }
  else
    [ "$LB_F_STATUS" = "$expected" ] && [ "$LB_F_IN_REPLY_TO" = "$correlate" ] \
      || { printf 'does not match its status or correlation\n'; return 0; }
  fi
  return 1
}

require_card_sendable() {
  local reason
  if reason=$(card_unsendable_reason "$@"); then
    die "the card $reason; refusing to transmit it"
  fi
  return 0
}

# Why an outbox record can no longer be retried, or nothing when it can. Runs
# the same two gates the retry runs, on the exact recovered bytes, without
# dying, so status can report the record and send can step past it.
outbox_unsendable_reason() {
  local id=$1 class card reason
  class=$(jq -r '.class // ""' "$(lb_dir "$STATE" outbox)/$id.json" 2>/dev/null)
  lb_class_allowed "$class" || { printf 'invalid class\n'; return 0; }
  workdir
  card="$WORK/recovered.$id.md"
  jq -r '.card // ""' "$(lb_dir "$STATE" outbox)/$id.json" > "$card" 2>/dev/null \
    || { printf 'unreadable outbox record\n'; return 0; }
  if lb_scan_refuses "$card"; then printf 'credential-shaped content (%s)\n' "$LB_SCAN_REASON"; return 0; fi
  if reason=$(card_unsendable_reason "$card" request "$id" "$class"); then
    printf '%s\n' "$reason"
    return 0
  fi
  return 1
}

# Sender-side grammar enforcement. The same refusals the receiver applies, so a
# card that this estate could not accept is never emitted either.
require_sendable() {
  local subject=$1 bodyfile=$2 size body
  [ "${#subject}" -le 120 ] || die "subject is longer than 120 characters"
  case "$subject" in
    *[[:cntrl:]]*) die "subject must be one line" ;;
  esac
  lb_has_host_path "$subject" && die "subject names an absolute host path; refer to files by role"
  size=$(file_size_bytes "$bodyfile") || die "cannot measure body size"
  [ "$size" -le 8192 ] || die "body is larger than 8 KiB; it is refused, not truncated"
  body=$(cat "$bodyfile") || die "cannot read body"
  lb_has_host_path "$body" \
    && die "body names an absolute host path; refer to files by role"
  return 0
}

# --- the generated shim -----------------------------------------------------
#
# Five lines, the Relay poll shim's shape with one path changed. It goes through
# the GENERIC registered-check path, which is why bin/fm-watch.sh needs no change.
shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-letterbox.sh arm - letterbox poll shim.' \
    '# The watcher runs this each check cycle from a hash-validated snapshot.' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "exec $(printf '%q' "$FM_ROOT/bin/fm-letterbox-poll.sh")"
}

# The shim lives directly in state/, whose mode is the home's own, so it is
# written and verified as a single-link 0700 regular file on the state device
# rather than through the private-directory helpers used inside state/letterbox.
write_shim() {
  local dest=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$device" || return 1
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-letterbox-shim.XXXXXX") || return 1
  if ! shim_content > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  fmx_single_link_file_mode_valid "$dest" 700 "$device"
}

# --- commands ---------------------------------------------------------------

cmd_arm() {
  require_active
  lb_transport_dependencies || die "$LB_TRANSPORT_DIAGNOSTIC"
  [ -f "$FM_ROOT/bin/fm-letterbox-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-letterbox-poll.sh" ] \
    || die "bin/fm-letterbox-poll.sh is unavailable"
  ensure_dirs
  write_shim "$STATE/letterbox.check.sh" || die "cannot write state/letterbox.check.sh"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" letterbox \
    || die "cannot register state/letterbox.check.sh"
  printf 'letterbox armed: %s <-> %s over %s in %s\n' "$LB_SELF" "$LB_PEER" "$LB_TRANSPORT" "$LB_REPO"
}

cmd_retire() {
  local armed=0 path residual=''
  for path in "$STATE/letterbox.check.sh" "$STATE/letterbox.check-trust"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      armed=1
      if ! rm -f -- "$path" && { [ -e "$path" ] || [ -L "$path" ]; }; then
        residual="${residual}${residual:+, }$path"
        continue
      fi
      if [ -e "$path" ] || [ -L "$path" ]; then
        residual="${residual}${residual:+, }$path"
      fi
    fi
  done
  [ -z "$residual" ] || die "letterbox retirement incomplete; still present: $residual"
  if [ "$armed" -eq 1 ]; then
    printf 'letterbox retired: poll shim and registration removed; letters, claims and receipts kept\n'
  else
    printf 'letterbox was not armed in this home\n'
  fi
}

# Every outbox record with no matching receipt may name a transport call that did
# not land or one that landed before local receipt bookkeeping completed.
# It is reported rather than hidden, and the next send reconciles it.
unsent_ids() {
  local record id
  for record in "$(lb_dir "$STATE" outbox)"/*.json; do
    [ -e "$record" ] || continue
    id=$(basename "$record" .json)
    [ -e "$(lb_dir "$STATE" sent)/$id.receipt" ] && continue
    printf '%s\n' "$id"
  done
}

status_claim_fields() {
  local claim=$1 sep
  sep=$(printf '\037')
  jq -er --arg sep "$sep" '
    def clean_text:
      type == "string" and (explode | all(. >= 32 and . != 127));
    def field_text($key):
      has($key) and (.[$key] | clean_text);
    select(
      type == "object"
      and (.class | (clean_text and (length > 0)))
      and (.from | (clean_text and (length > 0)))
      and field_text("refusal")
      and field_text("resend_required")
      and field_text("resent_as")
      and field_text("replied")
      and field_text("task")
      and (.consumed | type == "array" and all(.[]; clean_text))
    )
    | [
        .class,
        .from,
        .refusal,
        .resend_required,
        .resent_as,
        (.consumed | length | tostring),
        .replied,
        .task,
        "valid"
      ]
    | join($sep)
  ' "$claim"
}

cmd_status() {
  lb_load_config
  if [ "$LB_ACTIVE" != 1 ] && [ -z "$LB_CONFIG_ERROR" ]; then
    printf 'letterbox: inert (not configured in this home)\n'
    return 0
  fi
  if [ -n "$LB_CONFIG_ERROR" ]; then
    printf 'letterbox: configuration fault - %s\n' "$LB_CONFIG_ERROR"
    return 1
  fi
  printf 'letterbox: %s <-> %s over %s in %s\n' "$LB_SELF" "$LB_PEER" "$LB_TRANSPORT" "$LB_REPO"
  if fm_custom_check_registered "$STATE" letterbox; then
    printf '  poll: armed and registered\n'
  elif [ -e "$STATE/letterbox.check.sh" ]; then
    printf '  poll: shim present but NOT registered; run: fm-letterbox.sh arm\n'
  else
    printf '  poll: not armed; run: fm-letterbox.sh arm\n'
  fi
  local id claim reason fields sep cclass cfrom crefusal cresend cresent cconsumed creplied ctask marker
  local owed=0 sent_open=0 unsent=0 resend=0 unanswerable=0 unreadable=0 replied=0 task_suffix creply_id
  sep=$(printf '\037')
  workdir
  for id in $(unsent_ids); do
    unsent=$((unsent + 1))
    if reason=$(outbox_unsendable_reason "$id"); then
      printf '  UNSENDABLE: %s (%s; the outbox record is kept and never retried, and it does not block other sends)\n' "$id" "$reason"
    else
      printf '  UNSENT: %s (no matching receipt; the next send reconciles it)\n' "$id"
    fi
  done
  for claim in "$(lb_claim_dir "$STATE")"/*.json; do
    [ -e "$claim" ] || continue
    id=$(basename "$claim" .json)
    if ! fields=$(status_claim_fields "$claim" 2>/dev/null); then
      unreadable=$((unreadable + 1))
      printf '  UNREADABLE: %s claim (cannot classify its obligation)\n' "$id"
      continue
    fi
    IFS="$sep" read -r cclass cfrom crefusal cresend cresent cconsumed creplied ctask marker <<< "$fields"
    if [ "$marker" != valid ] \
      || { [ "$cfrom" != "$LB_SELF" ] && [ "$cfrom" != "$LB_PEER" ]; } \
      || { [ "$cclass" != reply ] && [ "$cclass" != refused ] && ! lb_class_allowed "$cclass"; } \
      || { [ -n "$cresend" ] && [ "$cresend" != true ]; } \
      || { [ "$cresend" = true ] && [ "$cclass" != notice ]; } \
      || { [ -n "$cresent" ] && { [ "$cclass" != notice ] || ! lb_id_valid "$cresent"; }; } \
      || { [ -n "$creplied" ] && ! lb_status_allowed_for_class "$creplied" "$cclass"; }; then
      unreadable=$((unreadable + 1))
      printf '  UNREADABLE: %s claim (cannot classify its obligation)\n' "$id"
      continue
    fi
    [ "$cclass" != reply ] || continue
    if ! lb_id_valid "$id"; then
      unanswerable=$((unanswerable + 1))
      printf '  UNANSWERABLE: %s %s (no usable card id, so nothing can reply to it; resolve it with a notice naming that key)\n' \
        "$id" "$crefusal"
      continue
    fi
    if [ "$cfrom" = "$LB_SELF" ]; then
      [ -e "$(lb_dir "$STATE" sent)/$id.receipt" ] || continue
      if [ "$cresend" = true ] && [ -z "$cresent" ]; then
        resend=$((resend + 1))
        printf '  RESEND REQUIRED: %s notice (the peer refused it; send a corrected notice under a new id)\n' "$id"
      fi
      [ "$cconsumed" -eq 0 ] || continue
      sent_open=$((sent_open + 1))
    else
      if [ -n "$creplied" ]; then
        replied=$((replied + 1))
        creply_id=$(lb_claim_field "$STATE" "$id" reply_id) || creply_id='?'
        printf '  REPLIED: %s %s %s as %s (done; the peer closes it)\n' "$id" "$cclass" "$creplied" "${creply_id:-?}"
        continue
      fi
      owed=$((owed + 1))
      task_suffix=
      [ -z "$ctask" ] || task_suffix=" -> task $ctask"
      printf '  OWED: %s %s%s\n' "$id" "$cclass" "$task_suffix"
    fi
  done
  printf '  %s letter(s) awaiting a reply from this estate, %s replied, %s sent and awaiting a reply from the peer, %s unsent, %s requiring resend, %s unanswerable, %s unreadable\n' \
    "$owed" "$replied" "$sent_open" "$unsent" "$resend" "$unanswerable" "$unreadable"
}

cmd_list() {
  require_active
  local file id
  for file in "$(lb_dir "$STATE" inbox)"/*.json; do
    [ -e "$file" ] || continue
    id=$(basename "$file" .json)
    jq -r --arg id "$id" \
      '"\($id)\t\(.kind)\t\(.class // .status // "")\t\(.from)\t\(.subject // ."in-reply-to" // "")"' \
      "$file" 2>/dev/null
  done
}

cmd_read() {
  local id=${1-}
  require_active
  lb_id_valid "$id" || die "not a letter id: ${id:-<none>}"
  local file
  file="$(lb_dir "$STATE" inbox)/$id.json"
  [ -f "$file" ] && [ ! -L "$file" ] || die "no stashed card for $id"
  jq '.' "$file"
}

# Complete any earlier transport call that never recorded a receipt. The card id
# was chosen and recorded BEFORE that call, so the recovery is an exact
# title-matched lookup: adopt the existing issue, or create it if it never
# landed. Re-delivery is therefore a no-op and never a duplicate letter.
#
# The adoption lookup runs FIRST. Adoption is a read plus local records and
# transmits nothing, so a letter whose issue already landed is adopted whatever
# its recovered bytes would pass today; gating it would only strand an open
# obligation at the peer. The scan and grammar gate applies to the CREATE path
# alone: a record whose recovered bytes can no longer pass it is refused for
# retry but NEVER blocks the letter being sent now - it is reported, left in the
# outbox where status keeps naming it, and skipped. Only a lookup failure stops
# the send, because creating without an authoritative miss is exactly the
# duplicate this reconciliation exists to prevent.
reconcile_unsent() {
  local id class title number url out reason resends record normalized
  for id in $(unsent_ids); do
    workdir
    record="$(lb_dir "$STATE" outbox)/$id.json"
    normalized="$WORK/outbox.$id.json"
    if ! jq -ce '
      if type == "object"
        and (.class | type == "string")
        and ((.resends // "") | type == "string")
        and (.card | type == "string")
      then {class: .class, resends: (.resends // ""), card: .card}
      else error("invalid outbox record")
      end' "$record" > "$normalized" 2>/dev/null; then
      printf 'UNSENDABLE: %s (unreadable outbox record); the outbox record is kept and skipped\n' "$id" >&2
      continue
    fi
    class=$(jq -er '.class' "$normalized" 2>/dev/null) \
      || die "cannot read the validated class for unsent letter $id"
    resends=$(jq -er '.resends' "$normalized" 2>/dev/null) \
      || die "cannot read the validated resend target for unsent letter $id"
    if ! lb_class_allowed "$class"; then
      printf 'UNSENDABLE: %s (invalid class); the outbox record is kept and skipped\n' "$id" >&2
      continue
    fi
    title=$(lb_issue_title "$class" "$id")
    # Both create and find-title answer "<number> <url>", so this script never
    # has to know what a forge URL looks like.
    if ! out=$(lb_transport find-title "$title" 2>/dev/null); then
      die "cannot determine whether unsent letter $id already exists; refusing to create a duplicate"
    fi
    number=${out%% *}
    url=${out#* }
    case "$number" in ''|*[!0-9]*) number=''; url='' ;; esac
    if [ -n "$number" ]; then
      printf 'adopted existing letter %s as issue %s\n' "$id" "$number"
    else
      # The outbox is durable local state, not immutable and not hash-bound, so
      # the scan that ran before the original transport call is NOT a scan
      # immediately before THIS one. Both gates run again on the exact recovered
      # bytes, because a server-side rejection would already be too late, and
      # the create transmits exactly the bytes that were gated.
      if reason=$(outbox_unsendable_reason "$id"); then
        printf 'UNSENDABLE: %s (%s); the outbox record is kept and skipped\n' "$id" "$reason" >&2
        continue
      fi
      require_private_channel
      out=$(transport_write create --title "$title" --body-file "$WORK/recovered.$id.md" \
        --label "to:${LB_PEER%%.*}") || die "the transport refused the retried letter $id"
      number=${out%% *}
      url=${out#* }
      printf 'retried letter %s as issue %s\n' "$id" "$number"
    fi
    record_receipt "$id" "$number" "$url" "$class" "$resends"
  done
}

# ORDER: the sent claim is published BEFORE the receipt. The receipt is what
# makes unsent_ids stop offering this letter for reconciliation, and the claim is
# what makes status, close and the sent-letter backstop able to see it at all.
# Writing the receipt first leaves a window where a death strands the obligation
# permanently: reconciliation skips it (receipt present) and every claim-driven
# path is blind to it (claim absent). With this order a death between the two
# leaves the letter in unsent_ids, where the next send adopts it by title and
# completes the receipt, so the obligation is always visible to something.
#
# A corrected notice discharges the refused notice's resend obligation HERE, in
# the same success boundary as its receipt and BEFORE the receipt for the same
# reason the sent claim is: the receipt is what removes the letter from
# unsent_ids, so a death after the bookkeeping but before the receipt leaves
# the letter there and the retry, which adopts by title, idempotently redoes
# both from the same outbox record.
record_receipt() {
  local id=$1 number=$2 url=$3 class=$4 resends=${5-} rc
  if lb_claim_create "$STATE" "$id" "$class" "$LB_SELF" "$number" >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  # 0 = created here, 1 = already claimed by an earlier attempt; both are fine.
  [ "$rc" -le 1 ] || die "cannot record the sent claim for $id"
  if [ -n "$resends" ]; then
    # Both halves of the discharge in ONE rewrite: separately, a failure between
    # them leaves resent_as recorded with resend_required still set, or the flag
    # cleared with no pointer to the letter that discharged it.
    if ! lb_claim_set_many "$STATE" "$resends" resent_as "$id" resend_required ""; then
      die "letter $id was sent, but the resend of notice $resends could not be recorded; run status"
    fi
  fi
  lb_text_publish "$(lb_dir "$STATE" sent)" "$id.receipt" 600 \
    "$number" "$url" "$(date -u +%s)" \
    || die "cannot record the receipt for $id"
}

# The notice a corrected notice replaces must be one this estate sent, must be
# a notice, and must actually carry the resend obligation, so --resends can
# never silently clear something else.
# The corrected notice recorded as resent_as whose receipt was never published:
# the interrupted invocation's own retry must be allowed through reconciliation
# to complete it, rather than refused as "already re-sent".
resend_in_flight() {
  local notice=$1 corrected record
  corrected=$(lb_claim_field "$STATE" "$notice" resent_as) || return 1
  [ -n "$corrected" ] || return 1
  lb_id_valid "$corrected" || return 1
  record="$(lb_dir "$STATE" outbox)/$corrected.json"
  [ -f "$record" ] && [ ! -e "$(lb_dir "$STATE" sent)/$corrected.receipt" ] || return 1
  [ "$(jq -r '.resends // ""' "$record" 2>/dev/null)" = "$notice" ] || return 1
  printf '%s\n' "$corrected"
}

# The corrected notice recorded as resent_as whose receipt is now present and
# whose outbox record names this notice: the obligation is discharged. Reported
# outcomes are a function of this STATE, not of which crash window an earlier
# attempt happened to die in, because firstmate and replayed agents route on
# exit codes and a failing exit for finished work causes retries of nothing.
resend_discharged() {
  local notice=$1 corrected record
  corrected=$(lb_claim_field "$STATE" "$notice" resent_as) || return 1
  [ -n "$corrected" ] || return 1
  lb_id_valid "$corrected" || return 1
  record="$(lb_dir "$STATE" outbox)/$corrected.json"
  [ -f "$record" ] && [ -e "$(lb_dir "$STATE" sent)/$corrected.receipt" ] || return 1
  [ "$(jq -r '.resends // ""' "$record" 2>/dev/null)" = "$notice" ] || return 1
  printf '%s\n' "$corrected"
}

require_resend_target() {
  local notice=$1 class=$2
  [ "$class" = notice ] || die "--resends is only valid for a notice; the corrected letter must be class notice"
  lb_id_valid "$notice" || die "not a letter id: $notice"
  lb_claim_exists "$STATE" "$notice" || die "no claimed letter $notice in this home"
  [ "$(lb_claim_field "$STATE" "$notice" from)" = "$LB_SELF" ] \
    || die "$notice was received, not sent, by this estate; only a sent notice can be re-sent"
  [ "$(lb_claim_field "$STATE" "$notice" class)" = notice ] \
    || die "$notice is not a notice; only a refused notice carries a resend obligation"
  [ -z "$(lb_claim_field "$STATE" "$notice" resent_as)" ] \
    || die "$notice was already re-sent as $(lb_claim_field "$STATE" "$notice" resent_as)"
  [ "$(lb_claim_field "$STATE" "$notice" resend_required)" = true ] \
    || die "$notice does not require a resend"
}

cmd_send() {
  local class='' subject='' file='' expires='' resends='' id title out number url body card in_flight='' completed
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --class) need_value "$@"; class=$2; shift 2 ;;
      --subject) need_value "$@"; subject=$2; shift 2 ;;
      --file) need_value "$@"; file=$2; shift 2 ;;
      --expires) need_value "$@"; expires=$2; shift 2 ;;
      --resends) need_value "$@"; resends=$2; shift 2 ;;
      *) die "unknown send flag $1" ;;
    esac
  done
  require_active
  lb_class_allowed "$class" \
    || die "class ${class:-<none>} is not in the v1 allowlist (ping, notice, fact-lookup, capability-query, work-proposal)"
  if [ -n "$resends" ]; then
    if in_flight=$(resend_in_flight "$resends"); then
      [ "$class" = notice ] || die "--resends is only valid for a notice; the corrected letter must be class notice"
    else
      in_flight=''
      require_resend_target "$resends" "$class"
    fi
  fi
  [ -n "$subject" ] || die "send needs --subject"
  [ -n "$file" ] && [ -f "$file" ] && [ ! -L "$file" ] || die "send needs a readable --file"
  if [ -n "$expires" ]; then
    lb_iso_valid "$expires" || die "--expires must be an ISO 8601 UTC stamp such as 2026-08-31T14:03:11Z"
    lb_iso_epoch "$expires" >/dev/null 2>&1 \
      || die "--expires must name a real ISO 8601 UTC instant"
  fi
  workdir
  # The body is read EXACTLY ONCE, into a private snapshot, and every check and
  # the serialisation below use that snapshot. Validating the caller's file and
  # then re-reading it for the card would let a file changed in between put
  # forbidden bytes into the transmitted card.
  body="$WORK/body"
  cat -- "$file" > "$body" 2>/dev/null || die "cannot read --file"
  if [ "$class" = ping ] && [ -s "$body" ]; then
    die "a ping carries no content"
  fi
  require_sendable "$subject" "$body"
  ensure_dirs
  reconcile_unsent
  # Reconciliation can discharge the very obligation this send names: a
  # corrected notice that failed at the transport is retried or adopted above
  # and recorded as resent_as, so the target is checked AGAIN before a new id
  # exists, or one transport failure would yield two corrected notices. The
  # early check above admitted this invocation only while the target was NOT
  # yet discharged, so a discharge present now was completed by the
  # reconciliation this invocation just ran, whichever window the earlier
  # attempt died in: create failed outright, death between the sent claim and
  # the resent_as rewrite, or death before the receipt. All three are the same
  # success, reported the same way.
  if [ -n "$resends" ]; then
    if completed=$(resend_discharged "$resends"); then
      printf 'completed the corrected notice %s for %s; nothing new was sent\n' "$completed" "$resends"
      return 0
    fi
    [ -z "$in_flight" ] \
      || die "the corrected notice $in_flight for $resends is still unsent; run status"
    require_resend_target "$resends" "$class"
  fi

  id=$(lb_id_new) || die "cannot generate a letter id"
  title=$(lb_issue_title "$class" "$id")
  lb_card_request_write "$WORK/card.md" "$id" "$class" "$subject" "$(lb_now_iso)" "$expires" "$body" \
    || die "cannot serialize the letter card"
  # The whole assembled card is validated as the receiver would, immediately
  # before it is recorded or transmitted, and scanned BEFORE the outbox write
  # and before the transport call: a server-side rejection would already be too
  # late, and so would a local record.
  require_card_sendable "$WORK/card.md" request "$id" "$class"
  require_clean "$WORK/card.md"
  card=$(cat "$WORK/card.md") || die "cannot read the serialized letter card"

  # The id and the exact bytes are recorded BEFORE the transport call, which is
  # what makes the retry above an adoption instead of a second letter.
  # shellcheck disable=SC2016 # A jq filter, expanded by jq.
  lb_json_publish "$(lb_dir "$STATE" outbox)" "$id.json" \
    --arg id "$id" --arg class "$class" --arg subject "$subject" \
    --arg expires "$expires" --arg resends "$resends" --arg card "$card" \
    --argjson issued "$(date -u +%s)" \
    '{id:$id,class:$class,subject:$subject,expires:$expires,resends:$resends,issued:$issued,card:$card}' \
    || die "cannot record the outbox entry for $id"

  require_private_channel
  out=$(transport_write create --title "$title" --body-file "$WORK/card.md" \
    --label "to:${LB_PEER%%.*}") || die "the transport refused the letter; the outbox record is kept for retry"
  number=${out%% *}
  url=${out#* }
  case "$number" in ''|*[!0-9]*) die "the transport returned no issue number; the outbox record is kept for retry" ;; esac
  record_receipt "$id" "$number" "$url" "$class" "$resends"
  printf 'sent %s (%s) as %s\n' "$id" "$class" "$url"
  [ -z "$resends" ] || printf 'recorded %s as the corrected notice for %s\n' "$id" "$resends"
}

cmd_link() {
  local id=${1-} task=''
  if [ "$#" -gt 0 ]; then shift; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) need_value "$@"; task=$2; shift 2 ;;
      *) die "unknown link flag $1" ;;
    esac
  done
  require_active
  lb_id_valid "$id" || die "not a letter id: ${id:-<none>}"
  [ -n "$task" ] || die "link needs --task <task-id>"
  case "$task" in *[!A-Za-z0-9._-]*|.*) die "not a task id: $task" ;; esac
  lb_claim_exists "$STATE" "$id" || die "no claimed letter $id in this home"
  [ "$(lb_claim_field "$STATE" "$id" from)" = "$LB_PEER" ] \
    || die "$id was sent by this estate, not received; only a received letter is owned by a task"
  lb_claim_set "$STATE" "$id" task "$task" || die "cannot record task $task on $id"
  printf 'linked %s -> task %s\n' "$id" "$task"
}

# Does a comment on this issue already carry the reply card with this id? Used
# only when a recorded attempt has no completion, to decide between completing
# the record and re-posting. A read failure is a refusal: posting on an unknown
# answer is exactly the duplicate this check exists to prevent.
reply_landed() {
  local number=$1 reply_id=$2 comments
  workdir
  comments="$WORK/comments.$number.json"
  lb_transport comments "$number" > "$comments" 2>/dev/null \
    || die "cannot read the comments on issue $number to check whether reply $reply_id already landed; refusing to post it twice"
  jq -e --arg id "$reply_id" \
    'type == "array" and any(.[]; (.body // "") | contains("\nid: " + $id + "\n"))' \
    "$comments" >/dev/null 2>&1
}

# ORDER, and why it is the OPPOSITE of close. close acts first and records
# second because closing an issue is idempotent: a crash re-closes harmlessly.
# Posting a comment is NOT idempotent - a second post is a second visible
# terminal reply to the peer - so reply records the attempt FIRST, keyed by the
# reply id it is about to post, posts that same id, and completes the record
# last. The rule is not "always record first" or "always act first"; it is
# decided by whether the external operation can be safely repeated. A replay
# that finds an attempt without a completion looks for that reply id on the
# issue and completes the record WITHOUT posting when it is already there.
cmd_reply() {
  local id=${1-} status='' file='' number reply_id class sender stash body
  local replied attempt attempt_status
  if [ "$#" -gt 0 ]; then shift; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --status) need_value "$@"; status=$2; shift 2 ;;
      --file) need_value "$@"; file=$2; shift 2 ;;
      *) die "unknown reply flag $1" ;;
    esac
  done
  require_active
  lb_id_valid "$id" || die "not a letter id: ${id:-<none>}"
  lb_status_allowed "$status" \
    || die "status ${status:-<none>} is not a reply status (ack, answered, declined, unable, accepted-for-review, expired)"
  [ -n "$file" ] && [ -f "$file" ] && [ ! -L "$file" ] || die "reply needs a readable --file"
  # Announcement is at-least-once and the claim is taken last, so a letter can be
  # announced and handled in the narrow window before its claim exists. The
  # stashed card is the fallback source of truth for those fields, and the claim
  # is created here so the reply has somewhere to record itself.
  stash="$(lb_dir "$STATE" inbox)/$id.json"
  if lb_claim_exists "$STATE" "$id"; then
    sender=$(lb_claim_field "$STATE" "$id" from) || die "cannot read the claim for $id"
    class=$(lb_claim_field "$STATE" "$id" class) || die "cannot read the claim for $id"
    number=$(lb_claim_field "$STATE" "$id" issue) || die "cannot read the claim for $id"
  elif [ -f "$stash" ] && [ ! -L "$stash" ]; then
    sender=$(jq -er '.from | strings' "$stash" 2>/dev/null) || die "cannot read the stashed card for $id"
    class=$(jq -er '.class | strings' "$stash" 2>/dev/null) || die "cannot read the stashed card for $id"
    number=$(jq -er '.issue | numbers' "$stash" 2>/dev/null) || die "cannot read the stashed card for $id"
  else
    die "no letter $id in this home"
  fi
  [ "$sender" = "$LB_PEER" ] \
    || die "$id was sent by this estate, not received; there is nothing here to reply to"
  [ "$class" != reply ] || die "$id is a reply, not a letter; replies are not themselves answered"
  # The class decides which statuses are legal, so this estate can never emit a
  # combination the protocol forbids - an "answered" notice, for instance.
  lb_status_allowed_for_class "$status" "$class" \
    || die "status $status is not a legal reply to a $class letter"
  case "$number" in ''|*[!0-9]*) die "the record for $id names no issue" ;; esac
  lb_claim_exists "$STATE" "$id" \
    || lb_claim_create "$STATE" "$id" "$class" "$sender" "$number" >/dev/null 2>&1 \
    || die "cannot record a claim for $id"
  replied=$(lb_claim_field "$STATE" "$id" replied) || die "cannot read the claim for $id"
  [ -z "$replied" ] || die "$id was already answered $replied as $(lb_claim_field "$STATE" "$id" reply_id); a replayed wake needs no second reply"
  attempt=$(lb_claim_field "$STATE" "$id" reply_attempt) || die "cannot read the claim for $id"
  attempt_status=$(lb_claim_field "$STATE" "$id" reply_attempt_status) || die "cannot read the claim for $id"
  if [ -n "$attempt" ]; then
    lb_id_valid "$attempt" || die "the recorded reply attempt on $id is not a reply id: $attempt"
    [ "$attempt_status" = "$status" ] \
      || die "a $attempt_status reply to $id is already in flight as $attempt; finish it with --status $attempt_status"
    if reply_landed "$number" "$attempt"; then
      complete_reply_record "$id" "$class" "$status" "$attempt"
      printf 'reply %s to %s had already landed; completed its record without posting again\n' "$attempt" "$id"
      [ -z "$reply_note" ] || printf '%s\n' "$reply_note"
      return 0
    fi
    reply_id=$attempt
  fi
  workdir
  # Read once, validate the snapshot, serialise from the snapshot: the same
  # discipline as send, for the same reason.
  body="$WORK/body"
  cat -- "$file" > "$body" 2>/dev/null || die "cannot read --file"
  require_sendable "reply to $id" "$body"
  ensure_dirs

  if [ -z "$attempt" ]; then
    reply_id=$(lb_id_new) || die "cannot generate a reply id"
  fi
  lb_card_reply_write "$WORK/reply.md" "$reply_id" "$id" "$status" "$(lb_now_iso)" "$body" \
    || die "cannot serialize the reply card"
  require_card_sendable "$WORK/reply.md" reply "$reply_id" "$status" "$id"
  require_clean "$WORK/reply.md"
  if [ -z "$attempt" ]; then
    lb_claim_set_many "$STATE" "$id" reply_attempt "$reply_id" reply_attempt_status "$status" \
      || die "cannot record the reply attempt for $id; nothing was posted"
  fi
  require_private_channel
  transport_write comment "$number" --body-file "$WORK/reply.md" >/dev/null \
    || die "the transport refused the reply; the attempt $reply_id stays recorded and is completed or re-posted by the next reply"
  complete_reply_record "$id" "$class" "$status" "$reply_id"
  [ -z "$reply_note" ] || printf '%s\n' "$reply_note"
}

# The responder NEVER closes: the requester closes when it consumes this. A
# terminal reply is recorded as replied plus reply_id in ONE rewrite together
# with clearing the attempt: replied is what stops the stale backstop raising
# this letter, so it must never be recorded without the reply id that explains
# it. Sets reply_note for the caller to print.
complete_reply_record() {
  local id=$1 class=$2 status=$3 reply_id=$4
  if lb_status_terminal "$status" "$class"; then
    lb_claim_set_many "$STATE" "$id" replied "$status" reply_id "$reply_id" \
      reply_attempt "" reply_attempt_status "" \
      || die "reply $reply_id landed, but its local record failed; rerun reply $id --status $status to complete it without posting again"
    reply_note="replied $status to $id; the requester closes the letter when it consumes this"
  else
    lb_claim_set_many "$STATE" "$id" reply_attempt "" reply_attempt_status "" \
      || die "reply $reply_id landed, but its local record failed; rerun reply $id --status $status to complete it without posting again"
    reply_note="acknowledged $id (non-terminal); a terminal reply is still owed"
  fi
}

cmd_close() {
  local id=${1-} number reply file winner winner_status class sender resend found=0 rc
  local -a reply_list=()
  require_active
  lb_id_valid "$id" || die "not a letter id: ${id:-<none>}"
  lb_claim_exists "$STATE" "$id" || die "no claimed letter $id in this home"
  sender=$(lb_claim_field "$STATE" "$id" from) || die "cannot read the sent claim for $id"
  [ "$sender" = "$LB_SELF" ] \
    || die "$id was received, not sent, by this estate; the requester closes a letter, never the responder"
  number=$(lb_claim_field "$STATE" "$id" issue) || die "cannot read the sent claim for $id"
  class=$(lb_claim_field "$STATE" "$id" class) || die "cannot read the sent claim for $id"
  case "$number" in ''|*[!0-9]*) die "the claim for $id records no issue" ;; esac
  lb_class_allowed "$class" || die "the claim for $id records no valid request class"

  # FIRST TERMINAL REPLY WINS. The winner is derived from the reply claim that
  # names this letter (lb_first_reply), with the sent claim's first_reply field
  # as its cache, so close consumes exactly that one even when the poll died
  # before writing the cache; any later reply is ignored rather than folded in
  # as a second answer.
  if winner=$(lb_first_reply "$STATE" "$id"); then
    rc=0
  else
    rc=$?
    winner=
  fi
  [ "$rc" -ne 2 ] || die "cannot read the winning reply state for $id"
  winner_status=${winner#* }
  winner=${winner%% *}
  [ "$winner_status" != "$winner" ] || winner_status=
  if [ -n "$winner" ]; then
    found=1
    lb_claim_consumed "$STATE" "$id" "$winner" || reply_list+=("$winner")
  else
    for file in "$(lb_dir "$STATE" inbox)"/*.json; do
      [ -e "$file" ] || continue
      reply=$(jq -r --arg id "$id" \
        'select(.kind == "reply" and ."in-reply-to" == $id) | .id // ""' "$file" 2>/dev/null) \
        || die "cannot read a stashed reply while closing $id"
      [ -n "$reply" ] || continue
      winner_status=$(jq -er '.status | strings | select(length > 0)' "$file" 2>/dev/null) \
        || die "cannot read the winning reply status for $id"
      found=1
      lb_claim_consumed "$STATE" "$id" "$reply" && continue
      reply_list+=("$reply")
      break
    done
  fi
  [ "$found" -eq 1 ] \
    || die "no terminal reply to $id has been received; an open letter means somebody still owes something"
  lb_status_allowed_for_class "$winner_status" "$class" \
    || die "the winning reply to $id has no valid status for class $class"
  lb_status_terminal "$winner_status" "$class" \
    || die "the winning reply to $id is not terminal"

  resend=
  if [ "$class" = notice ] && [ "$winner_status" = unable ]; then resend=true; fi

  # ORDER: close the issue FIRST, then record what was consumed. Closing is
  # idempotent, so a crash between the two simply re-closes harmlessly on the
  # next run and then completes the record. The reverse order would leave the
  # issue open with the reply already marked consumed, which would break the
  # channel's one invariant - an open issue means somebody still owes something -
  # with nothing left to re-close it.
  require_private_channel
  transport_write close "$number" >/dev/null || die "the transport refused the close"
  # The consumed reply and any resend obligation are published in ONE rewrite.
  # Written as two steps, a failure between them left a closed issue, a consumed
  # reply and no visible obligation: status suppresses a consumed sent claim and
  # the stale backstop needs an open issue, so nothing asked for the retry.
  # Atomically, a failure consumes nothing, the letter is still reported as
  # awaiting a reply, and close can simply be run again.
  lb_claim_close_record "$STATE" "$id" "$resend" "${reply_list[@]+"${reply_list[@]}"}" \
    || die "cannot record the close of $id; the letter is still reported as awaiting a reply, so run close again"
  printf 'closed %s (issue %s)\n' "$id" "$number"
}

CMD=${1-}
if [ "$#" -gt 0 ]; then shift; fi
case "$CMD" in
  arm) cmd_arm "$@" ;;
  retire) cmd_retire "$@" ;;
  status) cmd_status "$@" ;;
  list) cmd_list "$@" ;;
  read) cmd_read "$@" ;;
  send) cmd_send "$@" ;;
  reply) cmd_reply "$@" ;;
  link) cmd_link "$@" ;;
  close) cmd_close "$@" ;;
  -h|--help|help) usage 0 ;;
  '') usage 2 ;;
  *) printf 'error: unknown command %s\n' "$CMD" >&2; usage 2 ;;
esac

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
#       Reply to a received letter. The responder NEVER closes the issue.
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
# class is cleared by a read; both keep alarming until a write lands. Every write
# that carries card bytes also runs bin/fm-secret-scan.sh over the assembled card
# first and refuses on anything but a clean result; it refuses, it never redacts.
set -u

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
trap '[ -z "$WORK" ] || rm -rf -- "$WORK"' EXIT HUP INT TERM

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '2,64p' "$0" | sed -e 's/^# \{0,1\}//'
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
record_write_error() {
  printf '%s\n%s\n' "$1" "$2" \
    | fmx_private_artifact_publish_stdin "$(ROOT_DIR)" "write-error" 600 2>/dev/null || true
}

clear_write_error() {
  fmx_private_artifact_dir_device "$(ROOT_DIR)" >/dev/null 2>&1 || return 0
  rm -f "$(ROOT_DIR)/write-error" 2>/dev/null || true
}

# The visibility precondition, enforced immediately before every write. One API
# call, and it is what turns an accidentally public channel from a silent
# ongoing exposure into a hard stop plus an alarm.
require_private_channel() {
  local reason rc class
  reason=$(lb_transport require-private 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || return 0
  case "$rc" in
    2) class=visibility ;;
    *) class=transport ;;
  esac
  [ -n "$reason" ] || reason="cannot confirm $LB_REPO is private"
  record_write_error "$class" "letterbox write refused: $reason"
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
  out=$(lb_transport "$verb" "$@" 2>"$WORK/transport.err"); rc=$?
  case "$rc" in
    0)
      clear_write_error
      printf '%s\n' "$out"
      return 0
      ;;
    2|3)
      reason=$(sed -n 's/^letterbox transport: refusing to write, //p' "$WORK/transport.err" 2>/dev/null | tail -n1)
      [ -n "$reason" ] || reason="cannot confirm $LB_REPO is private"
      if [ "$rc" -eq 2 ]; then
        record_write_error visibility "letterbox write refused: $reason"
      else
        record_write_error transport "letterbox write refused: $reason"
      fi
      die "refusing to write: $reason"
      ;;
  esac
  cat "$WORK/transport.err" >&2 2>/dev/null
  return "$rc"
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
  local file=$1 kind=$2 expected_id=$3 expected=$4 correlate=${5-} size self peer rc
  size=$(wc -c < "$file" | tr -d ' ')
  [ "$size" -le 65536 ] || { printf 'implausibly large\n'; return 0; }
  if lb_has_host_path "$(cat "$file")"; then printf 'absolute host path\n'; return 0; fi
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
  local subject=$1 bodyfile=$2 size
  [ "${#subject}" -le 120 ] || die "subject is longer than 120 characters"
  case "$subject" in
    *[[:cntrl:]]*) die "subject must be one line" ;;
  esac
  lb_has_host_path "$subject" && die "subject names an absolute host path; refer to files by role"
  size=$(wc -c < "$bodyfile" | tr -d ' ')
  [ "$size" -le 8192 ] || die "body is larger than 8 KiB; it is refused, not truncated"
  lb_has_host_path "$(cat "$bodyfile")" \
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
  command -v gh-axi >/dev/null 2>&1 || die "gh-axi is required to reach the channel"
  command -v gh >/dev/null 2>&1 || die "gh is required to read the channel"
  [ -f "$FM_ROOT/bin/fm-letterbox-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-letterbox-poll.sh" ] \
    || die "bin/fm-letterbox-poll.sh is unavailable"
  ensure_dirs
  write_shim "$STATE/letterbox.check.sh" || die "cannot write state/letterbox.check.sh"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" letterbox \
    || die "cannot register state/letterbox.check.sh"
  printf 'letterbox armed: %s <-> %s over %s in %s\n' "$LB_SELF" "$LB_PEER" "$LB_TRANSPORT" "$LB_REPO"
}

cmd_retire() {
  local removed=0
  if [ -e "$STATE/letterbox.check.sh" ] || [ -L "$STATE/letterbox.check.sh" ]; then
    rm -f -- "$STATE/letterbox.check.sh" && removed=1
  fi
  if [ -e "$STATE/letterbox.check-trust" ] || [ -L "$STATE/letterbox.check-trust" ]; then
    rm -f -- "$STATE/letterbox.check-trust" && removed=1
  fi
  if [ "$removed" -eq 1 ]; then
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
  local id claim reason owed=0 sent_open=0 unsent=0 resend=0 unanswerable=0
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
    [ "$(lb_claim_field "$STATE" "$id" class)" != reply ] || continue
    if ! lb_id_valid "$id"; then
      unanswerable=$((unanswerable + 1))
      printf '  UNANSWERABLE: %s %s (no usable card id, so nothing can reply to it; resolve it with a notice naming that key)\n' \
        "$id" "$(lb_claim_field "$STATE" "$id" refusal)"
      continue
    fi
    if [ "$(lb_claim_field "$STATE" "$id" from)" = "$LB_SELF" ]; then
      [ -e "$(lb_dir "$STATE" sent)/$id.receipt" ] || continue
      if [ "$(lb_claim_field "$STATE" "$id" resend_required)" = true ] \
        && [ -z "$(lb_claim_field "$STATE" "$id" resent_as)" ]; then
        resend=$((resend + 1))
        printf '  RESEND REQUIRED: %s notice (the peer refused it; send a corrected notice under a new id)\n' "$id"
      fi
      [ -z "$(lb_claim_field "$STATE" "$id" consumed)" ] || continue
      sent_open=$((sent_open + 1))
    else
      [ -z "$(lb_claim_field "$STATE" "$id" replied)" ] || continue
      owed=$((owed + 1))
      printf '  OWED: %s %s%s\n' "$id" "$(lb_claim_field "$STATE" "$id" class)" \
        "$( [ -n "$(lb_claim_field "$STATE" "$id" task)" ] && printf ' -> task %s' "$(lb_claim_field "$STATE" "$id" task)" )"
    fi
  done
  printf '  %s letter(s) awaiting a reply from this estate, %s sent and awaiting a reply from the peer, %s unsent, %s requiring resend, %s unanswerable\n' \
    "$owed" "$sent_open" "$unsent" "$resend" "$unanswerable"
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
  local id class title number url out reason resends
  for id in $(unsent_ids); do
    class=$(jq -r '.class // ""' "$(lb_dir "$STATE" outbox)/$id.json" 2>/dev/null)
    if ! lb_class_allowed "$class"; then
      printf 'UNSENDABLE: %s (invalid class); the outbox record is kept and skipped\n' "$id" >&2
      continue
    fi
    resends=$(jq -r '.resends // ""' "$(lb_dir "$STATE" outbox)/$id.json" 2>/dev/null)
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
  lb_claim_create "$STATE" "$id" "$class" "$LB_SELF" "$number" >/dev/null 2>&1
  rc=$?
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
  printf '%s\n%s\n%s\n' "$number" "$url" "$(date -u +%s)" \
    | fmx_private_artifact_publish_stdin "$(lb_dir "$STATE" sent)" "$id.receipt" 600 \
    || die "cannot record the receipt for $id"
}

# The notice a corrected notice replaces must be one this estate sent, must be
# a notice, and must actually carry the resend obligation, so --resends can
# never silently clear something else.
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
  local class='' subject='' file='' expires='' resends='' id title out number url body
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
  [ -z "$resends" ] || require_resend_target "$resends" "$class"
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

  id=$(lb_id_new) || die "cannot generate a letter id"
  title=$(lb_issue_title "$class" "$id")
  lb_card_request_write "$WORK/card.md" "$id" "$class" "$subject" "$(lb_now_iso)" "$expires" "$body"
  # The whole assembled card is validated as the receiver would, immediately
  # before it is recorded or transmitted, and scanned BEFORE the outbox write
  # and before the transport call: a server-side rejection would already be too
  # late, and so would a local record.
  require_card_sendable "$WORK/card.md" request "$id" "$class"
  require_clean "$WORK/card.md"

  # The id and the exact bytes are recorded BEFORE the transport call, which is
  # what makes the retry above an adoption instead of a second letter.
  # shellcheck disable=SC2016 # A jq filter, expanded by jq.
  lb_json_publish "$(lb_dir "$STATE" outbox)" "$id.json" \
    --arg id "$id" --arg class "$class" --arg subject "$subject" \
    --arg expires "$expires" --arg resends "$resends" --arg card "$(cat "$WORK/card.md")" \
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
  shift 2>/dev/null || true
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

cmd_reply() {
  local id=${1-} status='' file='' number reply_id class sender stash body
  shift 2>/dev/null || true
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
    sender=$(lb_claim_field "$STATE" "$id" from)
    class=$(lb_claim_field "$STATE" "$id" class)
    number=$(lb_claim_field "$STATE" "$id" issue)
  elif [ -f "$stash" ] && [ ! -L "$stash" ]; then
    sender=$(jq -r '.from // ""' "$stash" 2>/dev/null)
    class=$(jq -r '.class // ""' "$stash" 2>/dev/null)
    number=$(jq -r '.issue // ""' "$stash" 2>/dev/null)
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
  workdir
  # Read once, validate the snapshot, serialise from the snapshot: the same
  # discipline as send, for the same reason.
  body="$WORK/body"
  cat -- "$file" > "$body" 2>/dev/null || die "cannot read --file"
  require_sendable "reply to $id" "$body"
  ensure_dirs

  reply_id=$(lb_id_new) || die "cannot generate a reply id"
  lb_card_reply_write "$WORK/reply.md" "$reply_id" "$id" "$status" "$(lb_now_iso)" "$body"
  require_card_sendable "$WORK/reply.md" reply "$reply_id" "$status" "$id"
  require_clean "$WORK/reply.md"
  require_private_channel
  transport_write comment "$number" --body-file "$WORK/reply.md" >/dev/null \
    || die "the transport refused the reply"
  # The responder NEVER closes: the requester closes when it consumes this.
  if lb_status_terminal "$status" "$class"; then
    # One rewrite: replied is what stops the stale backstop raising this letter,
    # so it must never be recorded without the reply id that explains it.
    lb_claim_set_many "$STATE" "$id" replied "$status" reply_id "$reply_id" || true
    printf 'replied %s to %s; the requester closes the letter when it consumes this\n' "$status" "$id"
  else
    printf 'acknowledged %s (non-terminal); a terminal reply is still owed\n' "$id"
  fi
}

cmd_close() {
  local id=${1-} number reply file winner winner_status class resend replies='' found=0
  local -a reply_list=()
  require_active
  lb_id_valid "$id" || die "not a letter id: ${id:-<none>}"
  lb_claim_exists "$STATE" "$id" || die "no claimed letter $id in this home"
  [ "$(lb_claim_field "$STATE" "$id" from)" = "$LB_SELF" ] \
    || die "$id was received, not sent, by this estate; the requester closes a letter, never the responder"
  number=$(lb_claim_field "$STATE" "$id" issue)
  class=$(lb_claim_field "$STATE" "$id" class)
  case "$number" in ''|*[!0-9]*) die "the claim for $id records no issue" ;; esac

  # FIRST TERMINAL REPLY WINS. The winner is derived from the reply claim that
  # names this letter (lb_first_reply), with the sent claim's first_reply field
  # as its cache, so close consumes exactly that one even when the poll died
  # before writing the cache; any later reply is ignored rather than folded in
  # as a second answer.
  winner=$(lb_first_reply "$STATE" "$id") || winner=
  winner_status=${winner#* }
  winner=${winner%% *}
  [ "$winner_status" != "$winner" ] || winner_status=
  if [ -n "$winner" ]; then
    if [ -z "$winner_status" ] && [ -f "$(lb_dir "$STATE" inbox)/$winner.json" ] \
      && [ ! -L "$(lb_dir "$STATE" inbox)/$winner.json" ]; then
      winner_status=$(jq -r '.status // ""' "$(lb_dir "$STATE" inbox)/$winner.json" 2>/dev/null)
    fi
    found=1
    lb_claim_consumed "$STATE" "$id" "$winner" || replies=" $winner"
  else
    for file in "$(lb_dir "$STATE" inbox)"/*.json; do
      [ -e "$file" ] || continue
      reply=$(jq -r --arg id "$id" \
        'select(.kind == "reply" and ."in-reply-to" == $id) | .id' "$file" 2>/dev/null)
      [ -n "$reply" ] || continue
      winner_status=$(jq -r '.status // ""' "$file" 2>/dev/null)
      found=1
      lb_claim_consumed "$STATE" "$id" "$reply" && continue
      replies="$replies $reply"
      break
    done
  fi
  [ "$found" -eq 1 ] \
    || die "no terminal reply to $id has been received; an open letter means somebody still owes something"

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
  resend=
  if [ "$class" = notice ] && [ "$winner_status" = unable ]; then resend=true; fi
  for reply in $replies; do
    reply_list+=("$reply")
  done
  lb_claim_close_record "$STATE" "$id" "$resend" "${reply_list[@]+"${reply_list[@]}"}" \
    || die "cannot record the close of $id; the letter is still reported as awaiting a reply, so run close again"
  printf 'closed %s (issue %s)\n' "$id" "$number"
}

CMD=${1-}
shift 2>/dev/null || true
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

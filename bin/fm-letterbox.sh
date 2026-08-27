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
#       unanswered letters, letters this estate sent that are still open, and any
#       outbox record whose transport call never completed. Makes no API call.
#   fm-letterbox.sh list
#       Local-only listing of every stashed letter and reply with its state.
#   fm-letterbox.sh read <id>
#       Print one stashed card from the inbox.
#   fm-letterbox.sh send --class <c> --subject <s> --file <f> [--expires <iso>]
#       Send one letter. The id is chosen and recorded in the outbox BEFORE the
#       transport call, so a retry adopts the existing issue by title-matched id
#       instead of creating a second one.
#   fm-letterbox.sh reply <id> --status <s> --file <f>
#       Reply to a received letter. The responder NEVER closes the issue.
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
# poll raises it even if this turn is lost. Every write also runs
# bin/fm-secret-scan.sh over the assembled card first and refuses on anything but
# a clean result; it refuses, it never redacts.
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
  sed -n '2,44p' "$0" | sed -e 's/^# \{0,1\}//'
  exit "${1:-0}"
}

workdir() {
  [ -n "$WORK" ] && return 0
  WORK=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-letterbox.XXXXXX") || die "cannot create a work directory"
}

require_active() {
  lb_load_config
  [ -n "$LB_REPO$LB_SELF$LB_PEER$LB_TRANSPORT" ] \
    || die "the letterbox is not configured in this home (see docs/letterbox.md)"
  [ -z "$LB_CONFIG_ERROR" ] || die "$LB_CONFIG_ERROR"
  command -v jq >/dev/null 2>&1 || die "jq is required"
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
# on the next cycle. Cleared by the next write that actually lands.
record_write_error() {
  printf '%s\n' "$1" \
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
  local reason
  if reason=$(lb_transport require-private 2>/dev/null); then
    return 0
  fi
  [ -n "$reason" ] || reason="cannot confirm $LB_REPO is private"
  record_write_error "letterbox write refused: $reason"
  die "refusing to write: $reason"
}

# Refuses on anything but a clean scan, including the scanner failing to run.
require_clean() {
  if lb_scan_refuses "$1"; then
    die "refusing to send: credential-shaped content ($LB_SCAN_REASON); nothing was written or transmitted"
  fi
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

# Every outbox record with no matching receipt is a transport call that never
# completed. It is reported rather than hidden, and the next send reconciles it.
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
  if [ -z "$LB_REPO$LB_SELF$LB_PEER$LB_TRANSPORT" ]; then
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
  local id claim owed=0 sent_open=0 unsent=0
  for id in $(unsent_ids); do
    unsent=$((unsent + 1))
    printf '  UNSENT: %s (transport call never completed; the next send reconciles it)\n' "$id"
  done
  for claim in "$(lb_claim_dir "$STATE")"/*.json; do
    [ -e "$claim" ] || continue
    id=$(basename "$claim" .json)
    [ "$(lb_claim_field "$STATE" "$id" class)" != reply ] || continue
    if [ "$(lb_claim_field "$STATE" "$id" from)" = "$LB_SELF" ]; then
      [ -e "$(lb_dir "$STATE" sent)/$id.receipt" ] || continue
      sent_open=$((sent_open + 1))
    else
      [ -z "$(lb_claim_field "$STATE" "$id" replied)" ] || continue
      owed=$((owed + 1))
      printf '  OWED: %s %s%s\n' "$id" "$(lb_claim_field "$STATE" "$id" class)" \
        "$( [ -n "$(lb_claim_field "$STATE" "$id" task)" ] && printf ' -> task %s' "$(lb_claim_field "$STATE" "$id" task)" )"
    fi
  done
  printf '  %s letter(s) awaiting a reply from this estate, %s sent, %s unsent\n' "$owed" "$sent_open" "$unsent"
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
reconcile_unsent() {
  local id class title number url out
  for id in $(unsent_ids); do
    class=$(jq -r '.class // ""' "$(lb_dir "$STATE" outbox)/$id.json" 2>/dev/null)
    lb_class_allowed "$class" || continue
    title=$(lb_issue_title "$class" "$id")
    # Both create and find-title answer "<number> <url>", so this script never
    # has to know what a forge URL looks like.
    out=$(lb_transport find-title "$title" 2>/dev/null) || out=
    number=${out%% *}
    url=${out#* }
    case "$number" in ''|*[!0-9]*) number=''; url='' ;; esac
    if [ -n "$number" ]; then
      printf 'adopted existing letter %s as issue %s\n' "$id" "$number"
    else
      workdir
      jq -r '.card' "$(lb_dir "$STATE" outbox)/$id.json" > "$WORK/resend.md" 2>/dev/null || continue
      require_private_channel
      out=$(lb_transport create --title "$title" --body-file "$WORK/resend.md" \
        --label "to:${LB_PEER%%.*}") || die "the transport refused the retried letter $id"
      number=${out%% *}
      url=${out#* }
      printf 'retried letter %s as issue %s\n' "$id" "$number"
    fi
    record_receipt "$id" "$number" "$url" "$class"
  done
}

record_receipt() {
  local id=$1 number=$2 url=$3 class=$4
  printf '%s\n%s\n%s\n' "$number" "$url" "$(date -u +%s)" \
    | fmx_private_artifact_publish_stdin "$(lb_dir "$STATE" sent)" "$id.receipt" 600 \
    || die "cannot record the receipt for $id"
  lb_claim_create "$STATE" "$id" "$class" "$LB_SELF" "$number" >/dev/null 2>&1 || true
  clear_write_error
}

cmd_send() {
  local class='' subject='' file='' expires='' id title out number url
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --class) class=${2-}; shift 2 ;;
      --subject) subject=${2-}; shift 2 ;;
      --file) file=${2-}; shift 2 ;;
      --expires) expires=${2-}; shift 2 ;;
      *) die "unknown send flag $1" ;;
    esac
  done
  require_active
  lb_class_allowed "$class" \
    || die "class ${class:-<none>} is not in the v1 allowlist (ping, notice, fact-lookup, capability-query, work-proposal)"
  [ -n "$subject" ] || die "send needs --subject"
  [ -n "$file" ] && [ -f "$file" ] && [ ! -L "$file" ] || die "send needs a readable --file"
  if [ -n "$expires" ]; then
    lb_iso_valid "$expires" || die "--expires must be an ISO 8601 UTC stamp such as 2026-08-31T14:03:11Z"
  fi
  if [ "$class" = ping ] && [ -s "$file" ]; then
    die "a ping carries no content"
  fi
  require_sendable "$subject" "$file"
  ensure_dirs
  workdir
  reconcile_unsent

  id=$(lb_id_new) || die "cannot generate a letter id"
  title=$(lb_issue_title "$class" "$id")
  lb_card_request_write "$WORK/card.md" "$id" "$class" "$subject" "$(lb_now_iso)" "$expires" "$file"
  # Scan BEFORE the outbox write and before the transport call: a server-side
  # rejection would already be too late, and so would a local record.
  require_clean "$WORK/card.md"

  # The id and the exact bytes are recorded BEFORE the transport call, which is
  # what makes the retry above an adoption instead of a second letter.
  jq -n --arg id "$id" --arg class "$class" --arg subject "$subject" \
    --arg expires "$expires" --arg card "$(cat "$WORK/card.md")" \
    --argjson issued "$(date -u +%s)" \
    '{id:$id,class:$class,subject:$subject,expires:$expires,issued:$issued,card:$card}' 2>/dev/null \
    | fmx_private_artifact_publish_stdin "$(lb_dir "$STATE" outbox)" "$id.json" 600 \
    || die "cannot record the outbox entry for $id"

  require_private_channel
  out=$(lb_transport create --title "$title" --body-file "$WORK/card.md" \
    --label "to:${LB_PEER%%.*}") || die "the transport refused the letter; the outbox record is kept for retry"
  number=${out%% *}
  url=${out#* }
  case "$number" in ''|*[!0-9]*) die "the transport returned no issue number; the outbox record is kept for retry" ;; esac
  record_receipt "$id" "$number" "$url" "$class"
  printf 'sent %s (%s) as %s\n' "$id" "$class" "$url"
}

cmd_reply() {
  local id=${1-} status='' file='' number reply_id class sender stash
  shift 2>/dev/null || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --status) status=${2-}; shift 2 ;;
      --file) file=${2-}; shift 2 ;;
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
  case "$number" in ''|*[!0-9]*) die "the record for $id names no issue" ;; esac
  lb_claim_exists "$STATE" "$id" \
    || lb_claim_create "$STATE" "$id" "$class" "$sender" "$number" >/dev/null 2>&1 \
    || die "cannot record a claim for $id"
  require_sendable "reply to $id" "$file"
  ensure_dirs
  workdir

  reply_id=$(lb_id_new) || die "cannot generate a reply id"
  lb_card_reply_write "$WORK/reply.md" "$reply_id" "$id" "$status" "$(lb_now_iso)" "$file"
  require_clean "$WORK/reply.md"
  require_private_channel
  lb_transport comment "$number" --body-file "$WORK/reply.md" \
    || die "the transport refused the reply"
  clear_write_error
  # The responder NEVER closes: the requester closes when it consumes this.
  if lb_status_terminal "$status" "$class"; then
    lb_claim_set "$STATE" "$id" replied "$status" || true
    lb_claim_set "$STATE" "$id" reply_id "$reply_id" || true
    printf 'replied %s to %s; the requester closes the letter when it consumes this\n' "$status" "$id"
  else
    printf 'acknowledged %s (non-terminal); a terminal reply is still owed\n' "$id"
  fi
}

cmd_close() {
  local id=${1-} number reply file replies='' found=0
  require_active
  lb_id_valid "$id" || die "not a letter id: ${id:-<none>}"
  lb_claim_exists "$STATE" "$id" || die "no claimed letter $id in this home"
  [ "$(lb_claim_field "$STATE" "$id" from)" = "$LB_SELF" ] \
    || die "$id was received, not sent, by this estate; the requester closes a letter, never the responder"
  number=$(lb_claim_field "$STATE" "$id" issue)
  case "$number" in ''|*[!0-9]*) die "the claim for $id records no issue" ;; esac

  for file in "$(lb_dir "$STATE" inbox)"/*.json; do
    [ -e "$file" ] || continue
    reply=$(jq -r --arg id "$id" \
      'select(.kind == "reply" and ."in-reply-to" == $id) | .id' "$file" 2>/dev/null)
    [ -n "$reply" ] || continue
    found=1
    lb_claim_consumed "$STATE" "$id" "$reply" && continue
    replies="$replies $reply"
  done
  [ "$found" -eq 1 ] \
    || die "no terminal reply to $id has been received; an open letter means somebody still owes something"

  # ORDER: close the issue FIRST, then record what was consumed. Closing is
  # idempotent, so a crash between the two simply re-closes harmlessly on the
  # next run and then completes the record. The reverse order would leave the
  # issue open with the reply already marked consumed, which would break the
  # channel's one invariant - an open issue means somebody still owes something -
  # with nothing left to re-close it.
  require_private_channel
  lb_transport close "$number" || die "the transport refused the close"
  clear_write_error
  for reply in $replies; do
    lb_claim_consume "$STATE" "$id" "$reply" || die "cannot record the consumed reply $reply"
  done
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
  close) cmd_close "$@" ;;
  -h|--help|help) usage 0 ;;
  '') usage 2 ;;
  *) printf 'error: unknown command %s\n' "$CMD" >&2; usage 2 ;;
esac

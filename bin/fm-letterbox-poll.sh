#!/usr/bin/env bash
# One poll of the agent-to-agent letterbox for peer letters and peer replies.
#
# Inert by default: a HARD no-op (exit 0, no output, no files created) unless
# the home has opted in by setting all four of FM_LETTERBOX_REPO,
# FM_LETTERBOX_SELF, FM_LETTERBOX_PEER and FM_LETTERBOX_TRANSPORT in its
# gitignored .env (or the environment). Any one of them missing leaves the whole
# feature off, which is the Relay activation contract applied to a second source.
#
# The watcher runs this from a hash-validated private snapshot of the generated
# shim state/letterbox.check.sh, through the ORDINARY registered-custom-check
# path (bin/fm-check-register.sh, bin/fm-check-lib.sh), so bin/fm-watch.sh needs
# no change at all to carry this source.
#
# Its contract is copied deliberately from bin/fm-x-poll.sh:
#   OUTPUT MEANS WAKE FIRSTMATE, SILENCE MEANS KEEP SLEEPING.
# Every line it prints starts with the "letterbox" verb, which is what routes the
# handling turn to the letterbox-correspondence skill. The line is an EVENT, not
# the content: the stashed inbox files are the content, and the skill reads the
# inbox directory rather than trusting the wake line.
#
# Behavior when the letterbox is on:
#   nothing new                         -> print nothing, exit 0 (no wake)
#   a transport read failure or timeout -> print nothing, exit 0; the next cycle
#                                          retries, so a flaky network never
#                                          spends a firstmate turn
#   a configuration fault, a refused
#   write recorded by fm-letterbox.sh,
#   or a missing dependency             -> one rate-limited diagnostic line
#   a new peer letter                   -> secret-scan the body, stash the card
#       to state/letterbox/inbox/<id>.json, atomically claim
#       state/letterbox/claims/<id>.json, and name it on the one output line
#   a card that fails the grammar       -> claim it once and name the refusal, so
#       the handling turn can answer "unable" naming the fault class
#   a terminal peer reply to a letter
#   this estate sent                    -> stash and claim it once, and name it
#   a claimed letter with no reply and
#   no live task past FM_LETTERBOX_STALE_SECS
#                                       -> re-surface it once per window
#
# ORDERING, and it is the safety property. The receiver's completion boundary is
# CLAIM-LAST: stash the card, announce it, THEN take the O_EXCL claim. The claim
# is the only marker that suppresses a future announcement, so it must not exist
# until the announcement it suppresses has actually been made. Every other
# suppressing write - the resurface stamp and the transport cursor - lands after
# the announcement for the same reason.
#
# The consequence is deliberate and must not be designed away: ANNOUNCEMENT IS
# AT-LEAST-ONCE. A crash between printing the line and taking the claim makes the
# next poll announce the same card again. Losing a letter is unrecoverable;
# announcing one twice is not, so the ordering trades the recoverable failure for
# the unrecoverable one. EVERY CONSUMER OF AN ANNOUNCEMENT MUST THEREFORE BE
# IDEMPOTENT ON CARD ID - the letterbox-correspondence skill owns what that means
# for a handling turn, and docs/letterbox.md carries the full crash matrix.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck disable=SC2034 # Read by bin/fm-letterbox-lib.sh after sourcing.
LB_SCRIPT_DIR=$SCRIPT_DIR
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-letterbox-lib.sh
. "$SCRIPT_DIR/fm-letterbox-lib.sh"

lb_load_config
# Hard no-op when the letterbox is off: this is what keeps the check shim inert.
[ -n "$LB_REPO$LB_SELF$LB_PEER$LB_TRANSPORT" ] || exit 0
[ "$LB_ACTIVE" = 1 ] || [ -n "$LB_CONFIG_ERROR" ] || exit 0

ROOT=$(lb_root "$STATE")
INBOX=$(lb_dir "$STATE" inbox)
CLAIMS=$(lb_claim_dir "$STATE")
SENT=$(lb_dir "$STATE" sent)

# One rate-limited diagnostic: the same message is announced once, not once per
# cycle, exactly as the relay poll's error marker works.
emit_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$ROOT" "poll-error" 600 \
    && [ "$(cat "$ROOT/poll-error" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$ROOT" "poll-error" 600 2>/dev/null || true
  printf 'letterbox error: %s\n' "$msg"
}

clear_error() {
  fmx_private_artifact_dir_device "$ROOT" >/dev/null 2>&1 || return 0
  rm -f "$ROOT/poll-error" 2>/dev/null || true
}

if [ -n "$LB_CONFIG_ERROR" ]; then
  emit_error_once "$LB_CONFIG_ERROR"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }
command -v gh-axi >/dev/null 2>&1 || { emit_error_once "missing gh-axi"; exit 0; }

# A write that fm-letterbox.sh refused - most importantly the visibility
# precondition - is durable state, so it survives the turn that hit it and is
# raised here even if that turn was lost.
WRITE_ERROR_FILE="$ROOT/write-error"
if fmx_private_artifact_file_valid "$ROOT" "write-error" 600; then
  WRITE_ERROR=$(cat "$WRITE_ERROR_FILE" 2>/dev/null || true)
  if [ -n "$WRITE_ERROR" ]; then
    emit_error_once "$WRITE_ERROR"
    exit 0
  fi
fi

WORK=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-letterbox-poll.XXXXXX") || exit 0
trap 'rm -rf -- "$WORK"' EXIT HUP INT TERM

OPEN_JSON="$WORK/open.json"
if ! lb_transport list-open > "$OPEN_JSON" 2>/dev/null; then
  exit 0
fi
jq -e 'type == "array"' "$OPEN_JSON" >/dev/null 2>&1 || exit 0
clear_error

# Announcements accumulate here and are printed as ONE line at the end, so a
# busy cycle still costs exactly one wake.
ITEMS=0
LINE=

announce() {
  ITEMS=$((ITEMS + 1))
  [ "$ITEMS" -le 3 ] || return 0
  if [ -z "$LINE" ]; then LINE=$1; else LINE="$LINE; $1"; fi
}

# Every write that would suppress a FUTURE announcement is queued here and
# applied only after the announcement line has been printed. Nothing in this
# buffer may be flushed early: flushing it before the print is exactly the
# claim-before-announce ordering that can lose a letter.
PENDING_CLAIMS=
PENDING_RESURFACE=
PENDING_CURSOR=

queue_claim() {
  PENDING_CLAIMS="$PENDING_CLAIMS$1	$2	$3	$4	$5
"
}

queue_resurface() {
  PENDING_RESURFACE="$PENDING_RESURFACE$1
"
}

flush_suppressions() {
  local cid cclass cfrom cissue crefusal
  while IFS="	" read -r cid cclass cfrom cissue crefusal; do
    [ -n "$cid" ] || continue
    lb_claim_create "$STATE" "$cid" "$cclass" "$cfrom" "$cissue" "$crefusal" >/dev/null 2>&1
    case "$?" in
      1) [ -z "$crefusal" ] || lb_claim_set "$STATE" "$cid" refusal "$crefusal" >/dev/null 2>&1 || true ;;
    esac
  done <<EOF
$PENDING_CLAIMS
EOF
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    lb_claim_set_number "$STATE" "$cid" resurfaced "$(date -u +%s)" >/dev/null 2>&1 || true
  done <<EOF
$PENDING_RESURFACE
EOF
  # The cursor suppresses future comment fetches, so an early advance could hide
  # a reply whose announcement was lost. It lands with the other suppressions.
  if [ -n "$PENDING_CURSOR" ] && [ -f "$PENDING_CURSOR" ]; then
    fmx_private_artifact_publish_stdin "$ROOT" "cursor" 600 < "$PENDING_CURSOR" 2>/dev/null || true
  fi
}

OPEN_NUMBERS=" $(jq -r '.[].number' "$OPEN_JSON" 2>/dev/null | tr '\n' ' ')"

# --- inbound letters --------------------------------------------------------

COUNT=$(jq -r 'length' "$OPEN_JSON" 2>/dev/null) || COUNT=0
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
i=0
while [ "$i" -lt "$COUNT" ]; do
  RAW="$WORK/body.$i"
  jq -r --argjson i "$i" '.[$i].body' "$OPEN_JSON" > "$RAW" 2>/dev/null || { i=$((i + 1)); continue; }
  NUMBER=$(jq -r --argjson i "$i" '.[$i].number' "$OPEN_JSON" 2>/dev/null)
  case "$NUMBER" in ''|*[!0-9]*) i=$((i + 1)); continue ;; esac

  lb_card_parse "$RAW"
  case "$?" in
    2)
      # Not addressed to this estate, or not a card at all. Ignored, never
      # answered: replying would answer a letter nobody sent here.
      i=$((i + 1)); continue
      ;;
    1)
      # Refused at parse. The claim key falls back to the issue number when the
      # card's own id is unusable; a valid id can never collide with that shape.
      KEY=$LB_F_ID
      lb_id_valid "$KEY" || KEY="issue-$NUMBER"
      if ! lb_claim_exists "$STATE" "$KEY"; then
        announce "refused $KEY $LB_REFUSAL"
        queue_claim "$KEY" refused "$LB_PEER" "$NUMBER" "$LB_REFUSAL"
      fi
      i=$((i + 1)); continue
      ;;
  esac

  ID=$LB_F_ID
  # The claim is the completion boundary and is taken last, so its presence
  # proves this card was already stashed AND announced.
  if lb_claim_exists "$STATE" "$ID"; then i=$((i + 1)); continue; fi

  # Credential refusal runs BEFORE the stash, on the whole issue body, because
  # the stash is itself a place a secret would land.
  if lb_scan_refuses "$RAW"; then
    announce "refused $ID $LB_SCAN_REASON"
    queue_claim "$ID" "$LB_F_CLASS" "$LB_F_FROM" "$NUMBER" "$LB_SCAN_REASON"
    i=$((i + 1)); continue
  fi

  # Stash, announce, then claim. A crash anywhere before the claim costs one
  # repeated stash and one repeated announcement, and never a lost letter.
  if ! jq -n --arg id "$ID" --arg kind request --arg class "$LB_F_CLASS" \
    --arg from "$LB_F_FROM" --arg to "$LB_F_TO" --arg subject "$LB_F_SUBJECT" \
    --arg issued "$LB_F_ISSUED" --arg expires "$LB_F_EXPIRES" \
    --arg expired "$LB_F_EXPIRED" --arg body "$LB_F_BODY" \
    --argjson issue "$NUMBER" --argjson seen "$(date -u +%s)" \
    '{id:$id,kind:$kind,class:$class,from:$from,to:$to,subject:$subject,
      issued:$issued,expires:$expires,expired:($expired=="true"),body:$body,
      issue:$issue,seen:$seen}' 2>/dev/null \
    | fmx_private_artifact_publish_stdin "$INBOX" "$ID.json" 600; then
    emit_error_once "cannot write the letterbox inbox"
    exit 0
  fi
  announce "new $ID $LB_F_CLASS $LB_F_FROM"
  queue_claim "$ID" "$LB_F_CLASS" "$LB_F_FROM" "$NUMBER" ""
  i=$((i + 1))
done

# --- replies to letters this estate sent ------------------------------------
#
# The per-issue cursor is what keeps this off the poll's cost path: comments are
# fetched only for a letter whose issue has been touched since the last scan,
# because the forge bumps updated_at when a comment lands. A quiet cycle makes
# zero comment calls.
CURSOR="$ROOT/cursor"
CURSOR_JSON="$WORK/cursor.json"
if fmx_private_artifact_file_valid "$ROOT" "cursor" 600 \
  && jq -e 'type == "object"' "$CURSOR" >/dev/null 2>&1; then
  cp "$CURSOR" "$CURSOR_JSON" 2>/dev/null || printf '{}\n' > "$CURSOR_JSON"
else
  printf '{}\n' > "$CURSOR_JSON"
fi

FETCHES=0
FETCH_MAX=${FM_LETTERBOX_REPLY_FETCH_MAX:-5}
case "$FETCH_MAX" in ''|*[!0-9]*) FETCH_MAX=5 ;; esac

for receipt in "$SENT"/*.receipt; do
  [ -e "$receipt" ] || continue
  [ "$FETCHES" -lt "$FETCH_MAX" ] || break
  SENT_ID=$(basename "$receipt" .receipt)
  lb_id_valid "$SENT_ID" || continue
  SENT_NUMBER=$(head -n1 "$receipt" 2>/dev/null)
  case "$SENT_NUMBER" in ''|*[!0-9]*) continue ;; esac
  case "$OPEN_NUMBERS" in
    *" $SENT_NUMBER "*) : ;;
    *) continue ;;
  esac
  UPDATED=$(jq -r --argjson n "$SENT_NUMBER" \
    'map(select(.number == $n)) | first | .updated // ""' "$OPEN_JSON" 2>/dev/null)
  SEEN_AT=$(jq -r --arg n "$SENT_NUMBER" '.[$n] // ""' "$CURSOR_JSON" 2>/dev/null)
  [ "$UPDATED" != "$SEEN_AT" ] || continue

  COMMENTS="$WORK/comments.$SENT_NUMBER"
  lb_transport comments "$SENT_NUMBER" > "$COMMENTS" 2>/dev/null || continue
  jq -e 'type == "array"' "$COMMENTS" >/dev/null 2>&1 || continue
  FETCHES=$((FETCHES + 1))

  CN=$(jq -r 'length' "$COMMENTS" 2>/dev/null) || CN=0
  case "$CN" in ''|*[!0-9]*) CN=0 ;; esac
  j=0
  while [ "$j" -lt "$CN" ]; do
    CRAW="$WORK/comment.$SENT_NUMBER.$j"
    jq -r --argjson j "$j" '.[$j].body' "$COMMENTS" > "$CRAW" 2>/dev/null || { j=$((j + 1)); continue; }
    if lb_card_parse "$CRAW"; then
      if [ "$LB_F_KIND" = reply ] && [ "$LB_F_IN_REPLY_TO" = "$SENT_ID" ] \
        && lb_status_terminal "$LB_F_STATUS" "$(lb_claim_field "$STATE" "$SENT_ID" class)" \
        && ! lb_claim_consumed "$STATE" "$SENT_ID" "$LB_F_ID" \
        && ! lb_claim_exists "$STATE" "$LB_F_ID"; then
        if ! lb_scan_refuses "$CRAW"; then
          if jq -n --arg id "$LB_F_ID" --arg kind reply --arg correlate "$SENT_ID" \
            --arg from "$LB_F_FROM" --arg status "$LB_F_STATUS" \
            --arg issued "$LB_F_ISSUED" --arg body "$LB_F_BODY" \
            --argjson issue "$SENT_NUMBER" --argjson seen "$(date -u +%s)" \
            '{id:$id,kind:$kind,"in-reply-to":$correlate,from:$from,status:$status,
              issued:$issued,body:$body,issue:$issue,seen:$seen}' 2>/dev/null \
            | fmx_private_artifact_publish_stdin "$INBOX" "$LB_F_ID.json" 600; then
            announce "reply $SENT_ID $LB_F_STATUS"
            queue_claim "$LB_F_ID" reply "$LB_F_FROM" "$SENT_NUMBER" ""
          fi
        else
          announce "refused $LB_F_ID $LB_SCAN_REASON"
          queue_claim "$LB_F_ID" reply "$LB_F_FROM" "$SENT_NUMBER" "$LB_SCAN_REASON"
        fi
      fi
    fi
    j=$((j + 1))
  done

  # The cursor advances only after this letter's comments were fully scanned, so
  # an interrupted scan is simply redone next cycle. It is staged here and
  # published with the other suppressing writes, after the announcement.
  jq --arg n "$SENT_NUMBER" --arg u "$UPDATED" '.[$n] = $u' "$CURSOR_JSON" > "$CURSOR_JSON.new" 2>/dev/null \
    && mv -f "$CURSOR_JSON.new" "$CURSOR_JSON" 2>/dev/null || true
done
PENDING_CURSOR=$CURSOR_JSON

# --- the stale backstop -----------------------------------------------------
#
# This is what does not depend on anyone remembering. A claimed letter whose
# issue is still open, which has neither a terminal reply from this estate nor a
# linked live task, is re-surfaced once per FM_LETTERBOX_STALE_SECS window. It
# is the answer to "what if the obligation was dropped between the claim and the
# task", and it is free: the open-issue set is already in hand.
NOW=$(date -u +%s)
for claim in "$CLAIMS"/*.json; do
  [ -e "$claim" ] || continue
  CID=$(basename "$claim" .json)
  # A card whose own id was unusable is claimed under a synthetic key so it is
  # announced once, but no correlated reply can ever be addressed to it, so
  # re-surfacing it would be a loop with no action that could end it.
  lb_id_valid "$CID" || continue
  jq -e '.' "$claim" >/dev/null 2>&1 || continue
  CFROM=$(lb_claim_field "$STATE" "$CID" from)
  [ "$CFROM" = "$LB_PEER" ] || continue
  [ "$(lb_claim_field "$STATE" "$CID" class)" != reply ] || continue
  [ -z "$(lb_claim_field "$STATE" "$CID" replied)" ] || continue
  CNUMBER=$(lb_claim_field "$STATE" "$CID" issue)
  case "$OPEN_NUMBERS" in
    *" $CNUMBER "*) : ;;
    *) continue ;;
  esac
  CTASK=$(lb_claim_field "$STATE" "$CID" task)
  if [ -n "$CTASK" ] && [ -e "$STATE/$CTASK.meta" ]; then continue; fi
  CLAIMED=$(lb_claim_field "$STATE" "$CID" claimed)
  case "$CLAIMED" in ''|*[!0-9]*) continue ;; esac
  [ "$((NOW - CLAIMED))" -ge "$LB_STALE_SECS" ] || continue
  RESURFACED=$(lb_claim_field "$STATE" "$CID" resurfaced)
  case "$RESURFACED" in ''|*[!0-9]*) RESURFACED=0 ;; esac
  [ "$((NOW - RESURFACED))" -ge "$LB_STALE_SECS" ] || continue
  announce "stale $CID $(lb_claim_field "$STATE" "$CID" class)"
  queue_resurface "$CID"
done

if [ "$ITEMS" -eq 0 ]; then
  # Nothing was announced, so the cursor is the only suppression to apply and it
  # can only be hiding comments that were fully scanned and carried nothing.
  flush_suppressions
  exit 0
fi

if [ "$ITEMS" -gt 3 ]; then
  printf 'letterbox %s items: %s; +%s more\n' "$ITEMS" "$LINE" "$((ITEMS - 3))"
else
  printf 'letterbox %s items: %s\n' "$ITEMS" "$LINE"
fi

# CLAIM-LAST. Only now that the announcement has been printed may anything that
# suppresses a future announcement be written. A crash above this line re-runs
# the whole intake next cycle, which is the at-least-once guarantee.
flush_suppressions

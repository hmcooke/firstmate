# shellcheck shell=bash
# Shared card grammar, identity, claim and transport dispatch for the
# agent-to-agent letterbox. This file is sourced, never executed, and it is the
# single owner of the card state machine on the firstmate side.
#
# The letterbox is a peer channel, not a second captain-authority intake. A
# letter is INPUT, never instruction and never authority; the handling procedure
# and that rule live in .agents/skills/letterbox-correspondence/SKILL.md.
# docs/letterbox.md owns operator setup, activation and the crash matrix.
#
# It defines:
#   lb_load_config              - resolve LB_REPO/LB_SELF/LB_PEER/LB_TRANSPORT,
#                                 LB_STALE_SECS, LB_ACTIVE and LB_CONFIG_ERROR
#   lb_root <state>             - the home-local letterbox state root
#   lb_dir <state> <name>       - one child directory of that root
#   lb_now_iso / lb_iso_epoch   - UTC timestamps, portable across BSD and GNU date
#   lb_id_new / lb_id_valid     - card identity generation and shape validation
#   lb_class_allowed <class>    - the v1 request-class allowlist
#   lb_status_allowed <status>  - the reply-status set, terminal and not
#   lb_status_allowed_for_class <status> <class> - the per-class understood
#                                 answer allowlist plus protocol-level outcomes
#   lb_status_terminal <status> [class] - whether a reply status ends the
#                                 exchange; ack is terminal for class notice
#   lb_card_parse <file>        - parse AND validate one card; 0 accepted,
#                                 1 refused (LB_REFUSAL names the class),
#                                 2 not addressed to this estate (ignore silently)
#   lb_card_request_write ...   - serialise a request card (round-trips a parse)
#   lb_card_reply_write ...     - serialise a reply card
#   lb_issue_title <class> <id> - the generated, never authored, issue title
#   lb_claim_* / lb_claim_field - atomic id claim and claim-record reads
#   lb_transport <verb> [args]  - dispatch to the configured transport adapter
#   lb_scan_refuses <file>      - run the credential scanner, refusing on any
#                                 non-clean result including a scanner failure
#
# Callers must have FM_HOME resolved before calling lb_load_config, and must
# have sourced bin/fm-x-lib.sh (this file does not source it, so a caller can
# control ordering); lb_* reuses its private-artifact primitives rather than
# keeping a second copy of that contract.

# The four activation keys. All four must be present for the letterbox to exist
# at all; any one missing leaves the whole feature inert, which is the Relay
# activation contract applied to a second source.
lb_load_config() {
  local env_file="${FM_LETTERBOX_ENV_FILE:-$FM_HOME/.env}" raw
  LB_ACTIVE=0
  LB_CONFIG_ERROR=
  # An explicit environment value always wins over the .env file, including an
  # explicitly empty one, which is the Relay resolution rule. Each key is read
  # by name rather than through indirection, matching fmx_load_config.
  if [ -n "${FM_LETTERBOX_REPO+x}" ]; then LB_REPO=${FM_LETTERBOX_REPO-}
  else LB_REPO=$(fmx_env_get FM_LETTERBOX_REPO "$env_file"); fi
  if [ -n "${FM_LETTERBOX_SELF+x}" ]; then LB_SELF=${FM_LETTERBOX_SELF-}
  else LB_SELF=$(fmx_env_get FM_LETTERBOX_SELF "$env_file"); fi
  if [ -n "${FM_LETTERBOX_PEER+x}" ]; then LB_PEER=${FM_LETTERBOX_PEER-}
  else LB_PEER=$(fmx_env_get FM_LETTERBOX_PEER "$env_file"); fi
  if [ -n "${FM_LETTERBOX_TRANSPORT+x}" ]; then LB_TRANSPORT=${FM_LETTERBOX_TRANSPORT-}
  else LB_TRANSPORT=$(fmx_env_get FM_LETTERBOX_TRANSPORT "$env_file"); fi
  if [ -z "$LB_REPO" ] || [ -z "$LB_SELF" ] || [ -z "$LB_PEER" ] || [ -z "$LB_TRANSPORT" ]; then
    return 0
  fi
  # Present but invalid is a configuration fault, not inertness: it is surfaced
  # rather than silently ignored, because the home already opted in.
  case "$LB_REPO" in
    */*/*|/*|*/) LB_CONFIG_ERROR="FM_LETTERBOX_REPO is not owner/name" ;;
    */*) : ;;
    *) LB_CONFIG_ERROR="FM_LETTERBOX_REPO is not owner/name" ;;
  esac
  if [ -z "$LB_CONFIG_ERROR" ]; then
    case "${LB_REPO%%/*}" in ''|*[!A-Za-z0-9._-]*) LB_CONFIG_ERROR="FM_LETTERBOX_REPO is not owner/name" ;; esac
    case "${LB_REPO#*/}" in ''|*[!A-Za-z0-9._-]*) LB_CONFIG_ERROR="FM_LETTERBOX_REPO is not owner/name" ;; esac
  fi
  if [ -z "$LB_CONFIG_ERROR" ]; then
    lb_estate_valid "$LB_SELF" || LB_CONFIG_ERROR="FM_LETTERBOX_SELF is not an estate identity"
  fi
  if [ -z "$LB_CONFIG_ERROR" ]; then
    lb_estate_valid "$LB_PEER" || LB_CONFIG_ERROR="FM_LETTERBOX_PEER is not an estate identity"
  fi
  if [ -z "$LB_CONFIG_ERROR" ] && [ "$LB_SELF" = "$LB_PEER" ]; then
    LB_CONFIG_ERROR="FM_LETTERBOX_SELF and FM_LETTERBOX_PEER are the same estate"
  fi
  if [ -z "$LB_CONFIG_ERROR" ]; then
    case "$LB_TRANSPORT" in
      github) : ;;
      *) LB_CONFIG_ERROR="unsupported transport $LB_TRANSPORT" ;;
    esac
  fi
  if [ -n "${FM_LETTERBOX_STALE_SECS+x}" ]; then raw=${FM_LETTERBOX_STALE_SECS-}
  else raw=$(fmx_env_get FM_LETTERBOX_STALE_SECS "$env_file"); fi
  case "$raw" in
    ''|*[!0-9]*) LB_STALE_SECS=21600 ;;
    *) LB_STALE_SECS=$raw ;;
  esac
  [ "$LB_STALE_SECS" -ge 300 ] 2>/dev/null || LB_STALE_SECS=300
  # shellcheck disable=SC2034 # Read by callers (fm-letterbox.sh, fm-letterbox-poll.sh) after sourcing.
  [ -n "$LB_CONFIG_ERROR" ] || LB_ACTIVE=1
  return 0
}

lb_estate_valid() {
  local id=${1-}
  [ "${#id}" -le 64 ] || return 1
  case "$id" in
    ''|.*|*..*|*.) return 1 ;;
    *[!a-z0-9.-]*) return 1 ;;
  esac
  case "$id" in
    [a-z]*) return 0 ;;
    *) return 1 ;;
  esac
}

lb_root() {
  printf '%s\n' "$1/letterbox"
}

lb_dir() {
  printf '%s\n' "$1/letterbox/$2"
}

lb_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# BSD date first, GNU second, matching bin/fm-fleet-snapshot.sh. Prints nothing
# and fails when neither can read the stamp, so callers refuse rather than
# silently treating an unparseable time as now.
lb_iso_epoch() {
  local iso=$1 out
  out=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null \
    || date -u -d "$iso" +%s 2>/dev/null) || return 1
  case "$out" in
    ''|*[!0-9-]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# <sender-prefix>-<UTC compact timestamp>-<8 hex>. The sender prefix is this
# estate's first identity segment, so "firstmate.shipyard" issues
# firstmate-20260824T140311Z-9f2c1ab4. The id is chosen BEFORE the transport
# call and is immutable thereafter, which is what makes re-delivery a no-op.
lb_id_prefix() {
  local seg=${LB_SELF%%.*}
  printf '%s' "${seg:0:12}"
}

lb_id_new() {
  local hex
  hex=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  case "$hex" in
    ????????) : ;;
    *) return 1 ;;
  esac
  printf '%s-%s-%s\n' "$(lb_id_prefix)" "$(date -u +%Y%m%dT%H%M%SZ)" "$hex"
}

lb_id_valid() {
  local id=${1-}
  case "$id" in
    ''|.*|*/*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  printf '%s' "$id" \
    | grep -qE '^[a-z][a-z0-9]{0,11}-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'
}

lb_class_allowed() {
  case "${1-}" in
    ping|notice|fact-lookup|capability-query|work-proposal) return 0 ;;
  esac
  return 1
}

lb_status_allowed() {
  case "${1-}" in
    ack|answered|declined|unable|accepted-for-review|expired) return 0 ;;
  esac
  return 1
}

# The per-class reply-status allowlist from the v1 grammar. The union above is
# not sufficient on its own: it would let a notice be "answered" or a ping be
# "declined", both of which the protocol forbids, and it would make the
# notice-ack correction merely one terminal choice among several instead of the
# required one. Both the sender and the requester validate through this.
#
# ack is the universal non-terminal "received, working" status, except on notice
# where it is the single understood - and terminal - answer. expired is a
# lifecycle outcome rather than an answer, so any class may end that way.
# unable is a protocol-level refusal rather than an answer, so it is legal for
# every class, including the synthetic refused class used when parsing failed.
# An unable notice is terminal but is not the required acknowledgement: the
# sender closes it and sends a corrected notice under a new id.
lb_status_allowed_for_class() {
  local status=${1-} class=${2-}
  lb_status_allowed "$status" || return 1
  case "$status" in expired|unable) return 0 ;; esac
  case "$class" in
    notice) [ "$status" = ack ] ;;
    ping) case "$status" in ack|answered) return 0 ;; esac; return 1 ;;
    fact-lookup|capability-query)
      case "$status" in ack|answered|declined) return 0 ;; esac; return 1 ;;
    work-proposal)
      case "$status" in ack|accepted-for-review|declined) return 0 ;; esac; return 1 ;;
    # An unknown or unrecorded class cannot be validated against the table, so
    # only the universal statuses are accepted rather than the whole union.
    *) case "$status" in ack) return 0 ;; esac; return 1 ;;
  esac
}

# Terminality is class-dependent, because "notice" is one-way: its ack IS the
# terminal reply and it is required, not optional, so the requester has something
# to consume and can close the issue. For every other class ack means "received,
# working" and the exchange is still open. That keeps the one channel-wide
# invariant true: an open issue means somebody still owes something.
lb_status_terminal() {
  local status=${1-} class=${2-}
  case "$status" in
    answered|declined|unable|accepted-for-review|expired) return 0 ;;
    ack) [ "$class" = notice ] && return 0 ;;
  esac
  return 1
}

# The issue title is GENERATED, never authored, and is exactly
# "[letterbox] <class> <id>". The card's subject is a human-legibility field
# inside the card only and never reaches the title, so a title match is an exact
# id lookup and the sender-side idempotent create needs no search API.
lb_issue_title() {
  printf '[letterbox] %s %s\n' "$1" "$2"
}

# --- the card ---------------------------------------------------------------
#
# One fenced block per document, info string letterbox/v1, at column 0.
# Everything outside the fence is prose for a human reader and is never parsed.
# Inside it: "key: value" lines, one key per line, with exactly one multi-line
# field (body) written as a block scalar and required to come last.
#
# Every body line is indented by exactly two spaces, which is what stops body
# content from reaching column 0 and closing the fence it lives in. A single
# trailing carriage return per line is line-ending normalisation and nothing
# more: a CRLF body authored through a forge's web editor parses to exactly the
# fields its LF twin does, and every refusal still fires on it. The block
# scalar clips a single trailing newline, exactly as YAML "|" does, so a body
# round-trips through serialise-then-parse unchanged apart from that clip.
#
# lb_card_parse REFUSES rather than sanitising, and every refusal is a named
# class the caller can put in an "unable" reply and in a wake line. It never
# echoes the offending value, so a refusal can be reported safely.

LB_CARD_FENCE='```letterbox/v1'

lb_card_reset() {
  # shellcheck disable=SC2034 # Every LB_F_*/LB_REFUSAL var is read by callers after sourcing.
  LB_REFUSAL=
  LB_F_KIND=; LB_F_V=; LB_F_ID=; LB_F_FROM=; LB_F_TO=; LB_F_CLASS=
  LB_F_ISSUED=; LB_F_EXPIRES=; LB_F_SUBJECT=; LB_F_BODY=
  LB_F_STATUS=; LB_F_IN_REPLY_TO=; LB_F_EXPIRED=false
  LB_F_SEEN=' '
}

lb_refuse() {
  # shellcheck disable=SC2034 # Read by callers after sourcing, to name the refusal class.
  LB_REFUSAL=$1
  return 1
}

lb_card_seen() {
  case "$LB_F_SEEN" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# An absolute host path must never cross the channel: it is how one estate's
# filesystem shape leaks into the other's records, and on the peer estate a bare
# path in prose can itself be a delivery instruction. Cards refer to files by
# role.
#
# The rule is "a slash that begins a path", which is deliberately wider than
# "two components separated by whitespace". It catches a root-level path (/etc),
# a file URI (file:///home/x), and a label-prefixed path (path:/Users/x), all of
# which an earlier narrower detector accepted and transmitted.
#
# http and https URLs are removed BEFORE the test rather than exempted inside it.
# A network URL is not a host path and stays legal, but its own path component
# would otherwise look exactly like one. Every other scheme, file: included, is
# left in place and therefore refused, which is correct: a file URI IS an
# absolute host path wearing a scheme.
#
# A relative path stays legal because the slash must not follow an alphanumeric:
# docs/letterbox, and/or and 24/7 are all accepted.
lb_has_host_path() {
  printf '%s' "$1" \
    | sed -E 's#[Hh][Tt][Tt][Pp][Ss]?://[^[:space:]]*# #g' \
    | grep -qE '(^|[^A-Za-z0-9._~+-])/[A-Za-z0-9._-]'
}

lb_iso_valid() {
  printf '%s' "${1-}" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

# lb_card_parse <file> [now-epoch]
#   0  accepted; LB_F_* hold the validated card
#   1  refused; LB_REFUSAL names the class
#   2  not addressed to this estate, or carries no readable card at all - the
#      caller ignores it silently and owes no reply
lb_card_parse() {
  local file=$1 now=${2-} line key val content fences
  lb_card_reset
  [ -f "$file" ] && [ ! -L "$file" ] || return 2
  # grep -c prints 0 and EXITS 1 when there is no match, so a "|| printf 0"
  # fallback appends a SECOND count and makes a card-free document look like
  # several cards. Ordinary prose on a letterbox issue must be ignored, not
  # refused: keep grep's own count and discard only its exit status.
  fences=$(grep -c "^$LB_CARD_FENCE$(printf '\r')\{0,1\}\$" -- "$file" 2>/dev/null || true)
  case "$fences" in ''|*[!0-9]*) fences=0 ;; esac
  case "$fences" in
    0) return 2 ;;
    1) : ;;
    *) lb_refuse multiple-cards; return 1 ;;
  esac

  local in_block=0 in_body=0 body_started=0 body=''
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "$in_block" -eq 0 ]; then
      [ "$line" = "$LB_CARD_FENCE" ] && in_block=1
      continue
    fi
    if [ "$line" = '```' ]; then in_block=2; break; fi
    if [ "$in_body" -eq 1 ]; then
      case "$line" in
        '  '*) content=${line#  } ;;
        '') content= ;;
        *) lb_refuse malformed-body; return 1 ;;
      esac
      if [ "$body_started" -eq 1 ]; then
        body="$body
$content"
      else
        body=$content
        body_started=1
      fi
      continue
    fi
    [ -n "$line" ] || continue
    case "$line" in
      [a-z]*': '*) key=${line%%: *}; val=${line#*: } ;;
      [a-z]*':') key=${line%:}; val= ;;
      *) lb_refuse malformed-card; return 1 ;;
    esac
    case "$key" in
      *[!a-z0-9-]*) lb_refuse malformed-card; return 1 ;;
    esac
    if lb_card_seen "$key"; then lb_refuse duplicate-field; return 1; fi
    LB_F_SEEN="$LB_F_SEEN$key "
    case "$key" in
      decision-key|decision|answer-key|resolve-key|approved-by|approval|authority|captain|on-behalf-of|attribution)
        lb_refuse forbidden-authority-field; return 1 ;;
      kind) LB_F_KIND=$val ;;
      v) LB_F_V=$val ;;
      id) LB_F_ID=$val ;;
      from) LB_F_FROM=$val ;;
      to) LB_F_TO=$val ;;
      class) LB_F_CLASS=$val ;;
      issued) LB_F_ISSUED=$val ;;
      expires) LB_F_EXPIRES=$val ;;
      subject) LB_F_SUBJECT=$val ;;
      status) LB_F_STATUS=$val ;;
      in-reply-to) LB_F_IN_REPLY_TO=$val ;;
      body)
        [ "$val" = '|' ] || { lb_refuse malformed-body; return 1; }
        in_body=1
        ;;
      *) lb_refuse unknown-field; return 1 ;;
    esac
  done < "$file"
  [ "$in_block" -eq 2 ] || { lb_refuse unterminated-card; return 1; }
  LB_F_BODY=$body

  lb_card_validate "$now"
}

lb_card_validate() {
  local now=${1-} issued_epoch expires_epoch skew field

  # Addressing is decided first and on the raw value, because a card that is not
  # ours is ignored rather than refused, and refusing it would answer a letter
  # that was never sent to this estate.
  # A fence was recognised, so this document IS a card and an unreadable kind is
  # a fault to name, never something to ignore. Ignore code 2 is reserved for no
  # card at all and for a well-formed card addressed to another estate; using it
  # here left a malformed card with no refusal, no wake and no backstop state.
  case "$LB_F_KIND" in
    request)
      [ "$LB_F_TO" = "$LB_SELF" ] || return 2
      ;;
    reply)
      [ "$LB_F_FROM" = "$LB_PEER" ] || return 2
      ;;
    *) lb_refuse bad-kind; return 1 ;;
  esac

  # A higher v is refused by name and never silently downgraded, because a v2
  # card may mean something this parser would misread.
  case "$LB_F_V" in
    1) : ;;
    ''|*[!0-9]*) lb_refuse bad-version; return 1 ;;
    *) lb_refuse unsupported-version; return 1 ;;
  esac
  lb_id_valid "$LB_F_ID" || { lb_refuse bad-id; return 1; }

  if [ "$LB_F_KIND" = request ]; then
    [ "$LB_F_FROM" = "$LB_PEER" ] || { lb_refuse unknown-sender; return 1; }
    lb_class_allowed "$LB_F_CLASS" || { lb_refuse unknown-class; return 1; }
    [ -n "$LB_F_SUBJECT" ] || { lb_refuse missing-subject; return 1; }
    [ "${#LB_F_SUBJECT}" -le 120 ] || { lb_refuse subject-too-long; return 1; }
    if lb_card_seen status || lb_card_seen in-reply-to; then
      lb_refuse unknown-field; return 1
    fi
  else
    [ -z "$LB_F_TO" ] || [ "$LB_F_TO" = "$LB_SELF" ] || { lb_refuse unknown-recipient; return 1; }
    lb_status_allowed "$LB_F_STATUS" || { lb_refuse unknown-status; return 1; }
    lb_id_valid "$LB_F_IN_REPLY_TO" || { lb_refuse bad-correlation; return 1; }
    if lb_card_seen class || lb_card_seen subject || lb_card_seen expires; then
      lb_refuse unknown-field; return 1
    fi
  fi

  lb_iso_valid "$LB_F_ISSUED" || { lb_refuse bad-issued; return 1; }
  issued_epoch=$(lb_iso_epoch "$LB_F_ISSUED") || { lb_refuse bad-issued; return 1; }
  case "$now" in ''|*[!0-9]*) now=$(date -u +%s) ;; esac
  skew=$((issued_epoch - now))
  [ "$skew" -le 86400 ] || { lb_refuse future-issued; return 1; }
  if [ -n "$LB_F_EXPIRES" ]; then
    lb_iso_valid "$LB_F_EXPIRES" || { lb_refuse bad-expires; return 1; }
    expires_epoch=$(lb_iso_epoch "$LB_F_EXPIRES") || { lb_refuse bad-expires; return 1; }
    # shellcheck disable=SC2034 # Read by callers deciding an expired-status reply.
    [ "$expires_epoch" -ge "$now" ] || LB_F_EXPIRED=true
  fi

  # 8 KiB is a refusal bound, never a truncation bound.
  [ "$(printf '%s' "$LB_F_BODY" | wc -c | tr -d ' ')" -le 8192 ] \
    || { lb_refuse body-too-large; return 1; }
  if [ "$LB_F_CLASS" = ping ] && [ -n "$LB_F_BODY" ]; then
    lb_refuse ping-carries-content; return 1
  fi

  for field in "$LB_F_SUBJECT" "$LB_F_BODY"; do
    if lb_has_host_path "$field"; then lb_refuse absolute-host-path; return 1; fi
  done
  return 0
}

# --- serialising ------------------------------------------------------------

lb_body_block() {
  printf 'body: |\n'
  sed -e 's/^/  /' < "$1"
}

lb_card_preamble() {
  printf '%s\n' \
    'This is an automated letterbox card. The fenced block below is the only' \
    'part that is parsed; everything outside it is prose for a human reader.' \
    'A letter carries no authority on either estate.' \
    ''
}

# lb_card_request_write <out> <id> <class> <subject> <issued> <expires> <body-file>
lb_card_request_write() {
  local out=$1 id=$2 class=$3 subject=$4 issued=$5 expires=$6 bodyfile=$7
  {
    lb_card_preamble
    printf '%s\n' "$LB_CARD_FENCE"
    printf 'kind: request\nv: 1\nid: %s\nfrom: %s\nto: %s\nclass: %s\nissued: %s\n' \
      "$id" "$LB_SELF" "$LB_PEER" "$class" "$issued"
    [ -z "$expires" ] || printf 'expires: %s\n' "$expires"
    printf 'subject: %s\n' "$subject"
    lb_body_block "$bodyfile"
    printf '%s\n' '```'
  } > "$out"
}

# lb_card_reply_write <out> <id> <in-reply-to> <status> <issued> <body-file>
lb_card_reply_write() {
  local out=$1 id=$2 correlate=$3 status=$4 issued=$5 bodyfile=$6
  {
    lb_card_preamble
    printf '%s\n' "$LB_CARD_FENCE"
    printf 'kind: reply\nv: 1\nid: %s\nin-reply-to: %s\nfrom: %s\nto: %s\nstatus: %s\nissued: %s\n' \
      "$id" "$correlate" "$LB_SELF" "$LB_PEER" "$status" "$issued"
    lb_body_block "$bodyfile"
    printf '%s\n' '```'
  } > "$out"
}

# --- claims -----------------------------------------------------------------
#
# The claim is the receiver-side once-only marker AND the local index from the
# letter to whatever now owes the answer. It is deliberately NOT a ledger of
# record: under the forge transport the forge holds the record, and these files
# are a cache plus an idempotency marker.
#
# It is taken LAST, after the card is stashed and after it has been announced,
# because it is the only thing that suppresses a future announcement and must
# not exist until the announcement it suppresses has been made. Its presence
# therefore proves the whole intake completed. The cost is that announcement is
# at-least-once, which every consumer must handle by being idempotent on card
# id; bin/fm-letterbox-poll.sh's header owns that contract.
#
# Fields:
#   id class from issue claimed   written at claim time
#   refusal                       set when the card was refused at parse
#   task                          the ordinary firstmate task id that now owns
#                                 the obligation, recorded once work is created
#   replied reply_id              our terminal reply, recorded when posted
#   consumed                      reply ids already consumed (requester side),
#                                 which is what makes a replayed reply a no-op
#   first_reply first_reply_status the first terminal peer reply and its status
#   resend_required resent_as     an unable notice still needs a corrected
#                                 notice under a new id, and the id that did so
#   resurfaced                    epoch of the last stale re-announcement

lb_claim_dir() {
  lb_dir "$1" claims
}

lb_claim_path() {
  printf '%s\n' "$(lb_claim_dir "$1")/$2.json"
}

lb_claim_exists() {
  fmx_private_artifact_file_valid "$(lb_claim_dir "$1")" "$2.json" 600
}


# lb_claim_create <state> <id> <class> <from> <issue> [refusal]
# 0 = this caller claimed it, 1 = already claimed, 2 = could not claim.
lb_claim_create() {
  local state=$1 id=$2 class=$3 from=$4 issue=$5 refusal=${6-} tmp rc
  tmp=$(lb_claim_tmp) || return 2
  if ! jq -n --arg id "$id" --arg class "$class" --arg from "$from" \
    --argjson issue "$issue" --argjson claimed "$(date -u +%s)" \
    --arg refusal "$refusal" \
    '{id:$id,class:$class,from:$from,issue:$issue,claimed:$claimed,
      refusal:$refusal,task:"",replied:"",reply_id:"",first_reply:"",
      first_reply_status:"",resend_required:"",resent_as:"",resurfaced:0,consumed:[]}' \
    > "$tmp" 2>/dev/null || ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    return 2
  fi
  fmx_private_artifact_publish_stdin_once "$(lb_claim_dir "$state")" "$id.json" 600 < "$tmp"
  rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# The rewrite helpers never pipe jq straight into the publisher: jq's output is
# written to a private temp file and published only once jq succeeded and
# produced an object, so a claim that jq cannot read is left exactly as it was
# and the caller sees the failure instead of an empty file over a good claim.
lb_claim_tmp() {
  (umask 077; mktemp "${TMPDIR:-/tmp}/fm-letterbox-claim.XXXXXX")
}

# lb_claim_rewrite <state> <id> <jq-filter> [jq args...]
lb_claim_rewrite() {
  local state=$1 id=$2 filter=$3 path tmp rc
  shift 3
  path=$(lb_claim_path "$state" "$id")
  [ -f "$path" ] || return 1
  tmp=$(lb_claim_tmp) || return 1
  if ! jq "$@" "$filter" "$path" > "$tmp" 2>/dev/null \
    || ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    return 1
  fi
  fmx_private_artifact_publish_stdin "$(lb_claim_dir "$state")" "$id.json" 600 < "$tmp"
  rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

lb_claim_field() {
  local state=$1 id=$2 field=$3
  jq -r --arg f "$field" '.[$f] // "" | if type=="array" then join(" ") else tostring end' \
    "$(lb_claim_path "$state" "$id")" 2>/dev/null
}

# lb_claim_set <state> <id> <field> <value>: rewrite one claim field in place.
# The claim already exists here, so this is a replace rather than a claim.
lb_claim_set() {
  local state=$1 id=$2 field=$3 value=$4
  # shellcheck disable=SC2016 # A jq filter, expanded by jq.
  lb_claim_rewrite "$state" "$id" '.[$f] = $v' --arg f "$field" --arg v "$value"
}

lb_claim_set_number() {
  local state=$1 id=$2 field=$3 value=$4
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  # shellcheck disable=SC2016 # A jq filter, expanded by jq.
  lb_claim_rewrite "$state" "$id" '.[$f] = $v' --arg f "$field" --argjson v "$value"
}

# Terminal-reply dedupe: a reply id is recorded in the claim BEFORE the issue is
# closed, so a replayed reply with an already-recorded id is dropped.
lb_claim_consumed() {
  local state=$1 id=$2 reply=$3 path
  path=$(lb_claim_path "$state" "$id")
  [ -f "$path" ] || return 1
  jq -e --arg r "$reply" '(.consumed // []) | index($r) != null' "$path" >/dev/null 2>&1
}

lb_claim_consume() {
  local state=$1 id=$2 reply=$3
  # shellcheck disable=SC2016 # A jq filter, expanded by jq.
  lb_claim_rewrite "$state" "$id" '.consumed = ((.consumed // []) + [$r] | unique)' --arg r "$reply"
}

# --- credential refusal -----------------------------------------------------
#
# One contract, one owner. The scan runs BEFORE the transport call, BEFORE the
# local outbox write on the send path, and BEFORE the inbox stash on the receive
# path. Anything other than a clean exit 0 - including the scanner itself
# failing - is a refusal, because nothing was proven clean.
# LB_SCAN_REASON names the class and never the value.
lb_scan_refuses() {
  local file=$1 out rc
  out=$("${LB_SCRIPT_DIR:?}/fm-secret-scan.sh" "$file" 2>/dev/null); rc=$?
  case "$rc" in
    0) LB_SCAN_REASON=; return 1 ;;
    1) LB_SCAN_REASON=${out#refused: } ;;
    *) LB_SCAN_REASON=scanner-unavailable ;;
  esac
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  LB_SCAN_REASON=${LB_SCAN_REASON:-credential-shaped-content}
  return 0
}

# --- transport dispatch -----------------------------------------------------
#
# Exactly one adapter file knows any forge. Every verb below is part of the
# adapter contract; a second transport implements the same verbs and nothing
# else in the letterbox changes. docs/letterbox.md names the contract, and each
# adapter's own header owns its exact API calls.
lb_transport() {
  local adapter="${LB_SCRIPT_DIR:?}/fm-letterbox-transport-$LB_TRANSPORT.sh"
  [ -f "$adapter" ] && [ ! -L "$adapter" ] || return 1
  FM_LETTERBOX_REPO="$LB_REPO" bash "$adapter" "$@"
}

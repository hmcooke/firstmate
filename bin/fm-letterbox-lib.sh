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
#                                 LB_STALE_SECS, LB_REPLY_FETCH_MAX, LB_ACTIVE
#                                 and LB_CONFIG_ERROR
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
#   lb_claim_set_many <state> <id> <field> <value>... - set several fields in ONE
#                                 rewrite, so a crash cannot leave halves that disagree
#   lb_claim_close_record <state> <id> <resend> [reply...] - the requester's close
#                                 transition as one rewrite (see its header)
#   lb_text_publish <dir> <base> <mode> <line>... - stage and publish text
#   lb_transport_dependencies    - ask the adapter to report its own dependencies
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
  # Read through the same home configuration path as every other setting, so
  # the documented .env tuning reaches the watcher-run poll, whose generated
  # shim exports only FM_HOME.
  if [ -n "${FM_LETTERBOX_REPLY_FETCH_MAX+x}" ]; then raw=${FM_LETTERBOX_REPLY_FETCH_MAX-}
  else raw=$(fmx_env_get FM_LETTERBOX_REPLY_FETCH_MAX "$env_file"); fi
  # shellcheck disable=SC2034 # Read by bin/fm-letterbox-poll.sh after sourcing.
  case "$raw" in
    ''|*[!0-9]*|0) LB_REPLY_FETCH_MAX=5 ;;
    *) LB_REPLY_FETCH_MAX=$raw ;;
  esac
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
# estate's first identity segment NORMALISED to the id alphabet: every character
# outside [a-z0-9] is dropped and the result is cut to 12 characters, so
# "firstmate.shipyard" issues firstmate-20260824T140311Z-9f2c1ab4 and the
# equally valid identity "first-mate.shipyard" issues the same prefix rather
# than an id its own validator would refuse. The id is chosen BEFORE the
# transport call and is immutable thereafter, which is what makes re-delivery a
# no-op.
lb_id_prefix() {
  local seg
  seg=$(tr -cd 'a-z0-9' <<< "${LB_SELF%%.*}") || return 1
  printf '%s' "${seg:0:12}"
}

lb_id_new() {
  local hex
  hex=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null) || return 1
  hex=$(tr -d ' \n' <<< "$hex") || return 1
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
  grep -qE '^[a-z][a-z0-9]{0,11}-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' <<< "$id"
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
# Everything outside the fence is prose for a human reader and is never
# interpreted as card fields, though the whole document is credential-scanned.
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

# An absolute host path should not cross the channel: it is how one estate's
# filesystem shape leaks into the other's records, and on the peer estate a bare
# path in prose can itself be a delivery instruction. "Cards refer to files by
# role" is a PROTOCOL CONVENTION the peer is expected to follow; this guard
# exists to catch an accident, not to hold against an adversary.
#
# HONESTY, in the same register as bin/fm-secret-scan.sh:
#   - This is DEFENCE IN DEPTH, NOT A BOUNDARY. A regex asked to decide "is this
#     a filesystem path" in free text will not recognise every way a path can
#     be written, and no other safety property may rest on it. The bodies it
#     guards are separately credential-scanned.
#   - Its stated limit is measured, not assumed: a Windows-style path such as
#     C:\Users\captain\secret has no forward slash and is NOT recognised.
#     tests/fm-letterbox-grammar.test.sh pins that as the current outcome, so
#     strengthening the rule means revisiting this header, docs/letterbox.md and
#     the letterbox-correspondence skill together.
#
# The rule is a conservative "path start": after http and https URLs are
# stripped, a "~/" or a "/" that is immediately followed by a non-whitespace,
# non-slash character, where a "/" start is not itself preceded by an
# alphanumeric. It catches /etc, see /etc/passwd, (/home/x/y), file:///home/x,
# path:/Users/x, /$HOME/secret, /+cache/file, ~/.ssh/id_rsa and see ~/notes.
# It leaves relative paths and ordinary prose alone: docs/letterbox, and/or,
# 24/7, n/a, 2026/08/28, "read / write" and "50 / 2" are all accepted, because
# a slash inside a word or standing alone between spaces is not a path start.
#
# http and https URLs are removed BEFORE the test rather than exempted inside it.
# A network URL is not a host path and stays legal, but its own path component
# would otherwise look exactly like one. Every other scheme, file: included, is
# left in place and therefore refused: a file URI IS a host path wearing a scheme.
lb_has_host_path() {
  local stripped rc
  stripped=$(sed -E 's#[Hh][Tt][Tt][Pp][Ss]?://[^[:space:]]*# #g' <<< "$1") || return 0
  grep -qE '(^|[^A-Za-z0-9])~?/[^[:space:]/]' <<< "$stripped"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 0 ;;
  esac
}

lb_iso_valid() {
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<< "${1-}"
}

# lb_card_parse <file> [now-epoch]
#   0  accepted; LB_F_* hold the validated card
#   1  refused; LB_REFUSAL names the class
#   2  not addressed to this estate, or carries no readable card at all - the
#      caller ignores it silently and owes no reply
lb_card_parse() {
  local file=$1 now=${2-} line key val content fences rc
  lb_card_reset
  [ -f "$file" ] && [ ! -L "$file" ] || return 2
  # grep -c prints 0 and EXITS 1 when there is no match, so a "|| printf 0"
  # fallback appends a SECOND count and makes a card-free document look like
  # several cards. Ordinary prose on a letterbox issue must be ignored, not
  # refused: keep grep's own count and discard only its exit status.
  fences=$(grep -c "^$LB_CARD_FENCE$(printf '\r')\{0,1\}\$" -- "$file" 2>/dev/null)
  rc=$?
  case "$rc" in
    0|1) : ;;
    *) lb_refuse parser-unavailable; return 1 ;;
  esac
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
    case "$LB_F_SUBJECT" in
      *[[:cntrl:]]*) lb_refuse subject-control-character; return 1 ;;
    esac
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
  local body_size
  body_size=$(wc -c <<< "$LB_F_BODY") || { lb_refuse body-size-unavailable; return 1; }
  body_size=${body_size//[[:space:]]/}
  case "$body_size" in ''|*[!0-9]*) lb_refuse body-size-unavailable; return 1 ;; esac
  body_size=$((body_size - 1))
  [ "$body_size" -le 8192 ] || { lb_refuse body-too-large; return 1; }
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
#   in_reply_to status            on a reply claim, the sent letter it answers
#                                 and the status it carried, written at claim
#                                 time so the winner is recoverable from the
#                                 claim alone (see lb_first_reply)
#   first_reply first_reply_status the first terminal peer reply and its status,
#                                 a cache of what lb_first_reply derives
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


# lb_claim_create <state> <id> <class> <from> <issue> [refusal] [in-reply-to] [status]
# 0 = this caller claimed it, 1 = already claimed, 2 = could not claim.
# A reply claim records the sent letter it answers and its status in the same
# O_EXCL write that makes it a claim, so there is exactly one durable step and
# nothing about the winner can be half-written.
lb_claim_create() {
  local state=$1 id=$2 class=$3 from=$4 issue=$5 refusal=${6-} correlate=${7-} status=${8-} tmp rc
  tmp=$(lb_claim_tmp) || return 2
  if ! jq -n --arg id "$id" --arg class "$class" --arg from "$from" \
    --argjson issue "$issue" --argjson claimed "$(date -u +%s)" \
    --arg refusal "$refusal" --arg correlate "$correlate" --arg status "$status" \
    '{id:$id,class:$class,from:$from,issue:$issue,claimed:$claimed,
      refusal:$refusal,in_reply_to:$correlate,status:$status,
      task:"",replied:"",reply_id:"",first_reply:"",
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

# No JSON is ever piped straight from jq into the publisher, anywhere in the
# letterbox: without pipefail a failing jq would publish an empty file and the
# pipeline would still report success. jq's output goes to a private temp file
# and is published only once jq succeeded AND produced an object, so a record
# jq could not build is never written and the caller sees the failure.
lb_claim_tmp() {
  (umask 077; mktemp "${TMPDIR:-/tmp}/fm-letterbox-claim.XXXXXX")
}

# lb_json_publish <dir> <base> [jq args...] <filter>: build one JSON object with
# jq -n and publish it as a private artifact, replacing any existing one.
lb_json_publish() {
  local dir=$1 base=$2 tmp rc
  shift 2
  tmp=$(lb_claim_tmp) || return 1
  if ! jq -n "$@" > "$tmp" 2>/dev/null \
    || ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    return 1
  fi
  fmx_private_artifact_publish_stdin "$dir" "$base" 600 < "$tmp"
  rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

lb_text_publish() {
  local dir=$1 base=$2 mode=$3 tmp rc
  shift 3
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-letterbox-text.XXXXXX") || return 1
  if ! printf '%s\n' "$@" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  fmx_private_artifact_publish_stdin "$dir" "$base" "$mode" < "$tmp"
  rc=$?
  rm -f -- "$tmp"
  return "$rc"
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

# FIRST TERMINAL REPLY WINS, recovered from ONE boundary. The winner is the
# reply claim that records the sent letter as its in_reply_to (a clean reply
# claim, never a refusal), and that claim is created in one O_EXCL write. The
# sent claim's first_reply field is a cache of the same fact: when the poll died
# between creating the reply claim and writing the cache, the winner is derived
# here from the reply claim, so a later terminal reply can never overtake it.
# Prints "<reply-id> <status>" or nothing.
lb_first_reply() {
  local state=$1 sent=$2 winner status dir claim
  winner=$(lb_claim_field "$state" "$sent" first_reply)
  if [ -n "$winner" ]; then
    status=$(lb_claim_field "$state" "$sent" first_reply_status)
    [ -n "$status" ] || status=$(lb_claim_field "$state" "$winner" status)
    printf '%s %s\n' "$winner" "$status"
    return 0
  fi
  dir=$(lb_claim_dir "$state")
  for claim in "$dir"/*.json; do
    [ -e "$claim" ] || continue
    winner=$(jq -r --arg s "$sent" \
      'select(.class == "reply" and .in_reply_to == $s and (.refusal // "") == "")
       | "\(.id) \(.status // "")"' "$claim" 2>/dev/null)
    [ -n "$winner" ] || continue
    printf '%s\n' "$winner"
    return 0
  done
  return 1
}

# Terminal-reply dedupe reads reply ids already recorded after an earlier
# successful close, so a replayed reply with an already-recorded id is dropped.
# bin/fm-letterbox.sh owns the close-first, consumed-record-second transition.
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

# Set several fields in ONE rewrite. Two consecutive lb_claim_set calls are two
# publications, and a crash or a failure between them leaves a half-written
# record whose two halves disagree - which is how an obligation goes invisible.
# Anything that must be true together is written together.
# Usage: lb_claim_set_many <state> <id> <field> <value> [<field> <value> ...]
lb_claim_set_many() {
  local state=$1 id=$2 filter='.' i=0
  local -a args=()
  shift 2
  [ "$#" -ge 2 ] || return 1
  [ $(( $# % 2 )) -eq 0 ] || return 1
  while [ "$#" -ge 2 ]; do
    i=$((i + 1))
    filter="$filter | .[\$f$i] = \$v$i"
    args+=(--arg "f$i" "$1" --arg "v$i" "$2")
    shift 2
  done
  lb_claim_rewrite "$state" "$id" "$filter" "${args[@]+"${args[@]}"}"
}

# The requester's close transition, published as ONE rewrite.
#
# close closes the forge issue first, because closing is idempotent and a crash
# before the local record simply re-closes and retries. What must NOT happen is
# a half-written local record: consuming the reply while failing to record that
# a refused notice still needs re-sending leaves a closed issue, a consumed
# reply and no visible obligation - status suppresses a consumed sent claim and
# the stale backstop needs an open issue, so nothing asks for the retry.
#
# Publishing both facts in one rewrite makes every crash state visible: either
# the whole record lands, or none of it does and the reply stays unconsumed, so
# the letter is still reported as awaiting a reply and close can simply be run
# again.
lb_claim_close_record() {
  local state=$1 id=$2 resend=$3 list
  shift 3
  list=$(jq -cn --args '$ARGS.positional' "$@") || return 1
  # shellcheck disable=SC2016 # A jq filter, expanded by jq.
  lb_claim_rewrite "$state" "$id" \
    '.consumed = (((.consumed // []) + $r) | unique)
     | if $resend == "true" then .resend_required = "true" else . end' \
    --argjson r "$list" --arg resend "$resend"
}

# --- credential refusal -----------------------------------------------------
#
# One contract, one owner. The scan runs BEFORE each transport call that carries
# card bytes, BEFORE the local outbox write on the send path, and BEFORE the
# inbox stash on the receive path. Anything other than a clean exit 0 - including
# the scanner itself failing - is a refusal, because nothing was proven clean.
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
# adapter contract; a second transport implements the same verbs and adds its
# name to lb_load_config's allowlist, while no other letterbox path changes.
# The dependencies verb reports only adapter-owned tools. jq is owned and
# checked by the letterbox core because the core itself uses it.
# docs/letterbox.md names the contract, and each adapter's own header owns its
# exact API calls.
lb_transport_adapter_path() {
  printf '%s\n' "${LB_SCRIPT_DIR:?}/fm-letterbox-transport-$LB_TRANSPORT.sh"
}

lb_transport_dependencies() {
  local adapter out rc line missing=''
  adapter=$(lb_transport_adapter_path)
  if [ ! -f "$adapter" ] || [ -L "$adapter" ] || [ ! -r "$adapter" ]; then
    LB_TRANSPORT_DIAGNOSTIC="transport adapter $LB_TRANSPORT is missing or unreadable"
    return 1
  fi
  out=$(FM_LETTERBOX_REPO="$LB_REPO" bash "$adapter" dependencies 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    LB_TRANSPORT_DIAGNOSTIC=
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      missing\ ?*) missing="$missing${missing:+, }${line#missing }" ;;
    esac
  done <<< "$out"
  if [ -n "$missing" ]; then
    LB_TRANSPORT_DIAGNOSTIC="missing transport dependency: $missing"
  else
    LB_TRANSPORT_DIAGNOSTIC="transport dependency check failed for $LB_TRANSPORT"
  fi
  return 1
}

lb_transport() {
  local adapter
  adapter=$(lb_transport_adapter_path)
  [ -f "$adapter" ] && [ ! -L "$adapter" ] && [ -r "$adapter" ] || return 1
  FM_LETTERBOX_REPO="$LB_REPO" bash "$adapter" "$@"
}

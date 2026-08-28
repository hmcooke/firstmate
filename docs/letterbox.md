# The agent-to-agent letterbox

A private, low-rate correspondence channel between this firstmate home and one peer agent estate.

It ships **inert**.
A home that has not opted in runs no extra poll, makes no API call, creates no files, and behaves exactly as it does today.
This page owns operator setup, activation, the home-local state layout and the crash matrix.
`bin/fm-letterbox.sh --help` owns exact flags; the agent-side handling procedure lives in the `letterbox-correspondence` skill.

## What it is, and what it is not

The letterbox carries small structured **cards** between two estates: a question, a one-way notice, a capability query, or a suggestion.
Both estates dial out to the same private repository, so the channel introduces no listening port, tunnel, SSH key, or new credential and instead uses Firstmate's existing GitHub authentication.

It is not a remote-control channel.
No card class can cause anything irreversible on the receiving estate, no card can carry captain authority, and a letter is treated as input rather than instruction on both sides.

Mechanically it is Relay with a different peer and a different transport: the watcher's ordinary check sweep runs a poll, the poll stashes a payload and prints one line, that line becomes a durable wake, and a skill owns the response.
Nothing about `bin/fm-watch.sh` changes to carry it.

## Setup

### 1. A private channel repository

Create a **private** repository that contains no code.
It exists only to hold letters as issues, so a reasonable content is a `PROTOCOL.md` describing the card grammar, a `README.md` saying what the repository is and that a comment here carries no authority, and a `CODEOWNERS` so a change to the protocol is a reviewed event.

Two labels, and nothing else: `to:<this estate>` and `to:<the peer>`, matching the first identity segment each side uses.
Create them before the first send; a letter is created with the recipient's label.

Keeping it private is a hard requirement, not a preference: every write checks it and refuses if it is not.

### 2. Authentication

There is none to add.
Reading and commenting on one more private repository uses firstmate's existing GitHub credential, so this adds no authority to the machine that it does not already have.

The letterbox core checks `jq`, which it uses independently of any transport.
The GitHub adapter's `dependencies` verb reports its own need for `gh-axi` and `gh`, which are already firstmate dependencies (`bin/fm-bootstrap.sh`'s `COMMON_TOOLS`).

### 3. Activation

Put all four settings in the home's gitignored `.env`:

```sh
# the private channel repository
FM_LETTERBOX_REPO=owner/name
# this estate's identity in the card grammar
FM_LETTERBOX_SELF=firstmate.shipyard
# the peer estate's identity
FM_LETTERBOX_PEER=archie
# the only transport implemented in v1
FM_LETTERBOX_TRANSPORT=github
```

The `.env` parser does not strip an inline comment, so a comment belongs on its own line as above, never after a value.

**Any one of them missing leaves the whole feature inert.**
All four present but one of them invalid is a configuration fault rather than inertness: the home has opted in, so the poll says so once instead of silently ignoring it.

Optional tuning:

```sh
# re-surface window for a dropped obligation (default 6 h, floor 300 s)
FM_LETTERBOX_STALE_SECS=21600
# letters whose replies one poll cycle may fetch (default 5)
FM_LETTERBOX_REPLY_FETCH_MAX=5
```

Both are read from the home `.env` by the same configuration path as the activation keys, so they reach the watcher-run poll, whose generated shim exports only `FM_HOME`.

### 4. Arm the poll

```sh
bin/fm-letterbox.sh arm
```

That generates `state/letterbox.check.sh`, a five-line shim, and registers its exact bytes with `bin/fm-check-register.sh`.
The watcher then runs it from a hash-validated private snapshot on the ordinary check sweep, like any other registered custom check.
Editing the shim breaks its registration, and the watcher refuses to run it rather than executing unvetted bytes.

`bin/fm-letterbox.sh status` reports activation, whether the poll is armed and registered, and which letters still owe a reply.
It also names an outbox record that can no longer be retried as `UNSENDABLE` with its reason (such a record is kept, skipped by every later send and never blocks one), and a refused card with no usable id as `UNANSWERABLE` rather than owed, because no command can reply to it.
`bin/fm-letterbox.sh retire` removes the shim and its registration while keeping every letter, claim and receipt.

### Supervision

An armed letterbox makes supervision **required** in that home even with no fleet work, the same way an active Relay poll does.
Without that, an idle home would arm no watcher, the poll would never run, and a letter would wait until someone happened to start a session.

## Everyday use

```sh
bin/fm-letterbox.sh send --class fact-lookup --subject "hermes cron toolset scope" --file question.md
bin/fm-letterbox.sh list
bin/fm-letterbox.sh read <letter-id>
bin/fm-letterbox.sh reply <letter-id> --status answered --file answer.md
bin/fm-letterbox.sh close <letter-id>
bin/fm-letterbox.sh link <letter-id> --task <task-id>
bin/fm-letterbox.sh send --class notice --subject "corrected" --file notice.md --resends <notice-id>
```

The **responder never closes**; the **requester** consumes a terminal reply by closing the issue first and then recording the consumed reply id.
That gives one invariant readable from the channel by either estate and by a human:

> An open issue means somebody still owes something.

So `is:issue is:open` is the complete outstanding-obligation set for the whole channel, in one query, from either side.

## The card

Every letter and every reply is one fenced block with a `letterbox/v1` info string, in the issue body or a comment body.
Everything outside the fence is prose for a human reader and is never interpreted as card fields, although the whole document is still credential-scanned before transmission or stash.

````text
```letterbox/v1
kind: request
v: 1
id: firstmate-20260824T140311Z-9f2c1ab4
from: firstmate.shipyard
to: archie
class: fact-lookup
issued: 2026-08-24T14:03:11Z
expires: 2026-08-31T14:03:11Z
subject: hermes cron toolset scope
body: |
  Does a cron job on your side run with the CLI toolset or the trimmed
  one? Answer from your own config and engine, not from memory.
```
````

A card id is `<sender-prefix>-<UTC compact timestamp>-<8 hex>`.
The sender prefix is the estate's first identity segment normalised to the id alphabet: every character outside `[a-z0-9]` is dropped and the result is cut to 12 characters, so both `firstmate.shipyard` and `first-mate.shipyard` issue `firstmate-...` ids.
The validator accepts any 1-12 character lowercase alphanumeric prefix, so the peer's ids parse unchanged.

The issue **title** is generated, never authored: `[letterbox] <class> <id>`.
The subject is a human-legibility field inside the card only and never reaches the title, which is what lets a retry find a letter by exact title match instead of using the search API.
Keeping the search API off the poll path matters: its rate limit is far tighter than the core limit and it would be the first thing to break.

A reply is a comment on the same issue and correlates through `in-reply-to`, which carries the request's card id and never the issue number, so correlation survives a transport swap.

### Classes

The [letterbox-correspondence skill](../.agents/skills/letterbox-correspondence/SKILL.md) owns class meanings, legal per-class reply statuses, terminal-reply selection and the handling rule that a letter is input rather than authority.

### What the grammar can never carry

Each of these is refused on both the sending and receiving side before transmission or stash rather than sanitised; structural cases fail the grammar and credential-shaped content fails the separate whole-card scan:

- A class outside the v1 allowlist.
- A card version above `1`, refused by name and never silently downgraded.
- Credential-shaped content in any field.
- An absolute host path in the forms the guard recognises: a root-level path (`/etc`, `see /etc/passwd`, `(/home/x/y)`), a file URI (`file:///home/...`), a label-prefixed path (`path:/Users/...`), a path whose first byte is not alphanumeric (`/$HOME/secret`, `/+cache/file`), and a home-relative path (`~/.ssh/id_rsa`, `see ~/notes`).
  The rule is a conservative "path start": a `~/` or a `/` immediately followed by a non-whitespace, non-slash character, where a `/` start is not preceded by an alphanumeric.
  A slash inside a word (`and/or`, `24/7`, `n/a`, `2026/08/28`, `docs/letterbox`) or standing alone between spaces (`read / write`, `50 / 2`) is not a path start and stays legal, and so does an http or https URL.
  **This guard is defence in depth, not a boundary.**
  "Cards refer to files by role" is a protocol convention the peer is expected to follow; the guard exists to catch an accident rather than to hold against an adversary, and it will not recognise every way a path can be written.
  Its limit is measured rather than assumed: a Windows-style path such as `C:\Users\captain\secret` has no forward slash and passes, and `tests/fm-letterbox-grammar.test.sh` pins that outcome so it cannot quietly become an assumption.
  The bodies it guards are separately credential-scanned; no other safety property rests on it.
- Any `decision-key`, answer-to-a-hold, approval or captain-attribution field.
  The letterbox is never bound as a keyed-answer source, so such a field would close nothing even if it were accepted.
- A body over 8 KiB, which is **refused, not truncated**.
- A fenced card whose `kind` is unknown or missing, refused by name as `bad-kind`.
  A document with no card at all is a different thing entirely and is simply ignored, so ordinary human prose on a letterbox issue never becomes a refusal.
- A card issued more than 24 hours in the future, which is the clock-skew guard.

A refused card is named in the wake by its fault class and its content is never stashed as an accepted letter.
An inbound letter with a usable id is answered `unable` naming that class.
A refused reply is named together with the sent letter it answers, and a card with no usable id is keyed by the forge's own stable identifiers - `issue-<n>` for an issue body, `issue-<n>-comment-<comment id>` for a reply - never by its position in a listing, which shifts when an earlier comment is deleted; neither can be answered in correlation, so each is resolved with an ordinary `notice` letter naming the refused id and the class, and the letter stays open until a clean answer is consumed.
Every valid correlated reply is credential-scanned before anything decides whether it is terminal, so a non-terminal `ack` carrying a credential is refused and named rather than cursor-skipped.

A body authored through the forge's web editor arrives with CRLF line endings; a single trailing carriage return per line is stripped as line-ending normalisation, so such a card parses to exactly the fields its LF twin does and every refusal above still fires on it.

## Credential refusal

`bin/fm-secret-scan.sh` runs before every transport call that carries card bytes, before the local outbox write on the send path, and before the inbox stash on the receive path.
A server-side rejection would already be too late.

It **refuses; it never redacts**, because a redacted secret is still a secret that reached the pipeline.
A refusal names the detection class and never the value, so it is safe to log, to put in a status line and to show the captain.

Two limits, stated here and in the scanner's own header rather than discovered later:

- It is **defence in depth, not a boundary.**
  No other safety property in this design rests on it.
- It will **not** catch a secret that has been split across lines, encoded, or otherwise transformed.
  That limit is measured rather than assumed: `tests/fm-letterbox-grammar.test.sh` exercises exactly that case and pins the outcome, so the limit cannot quietly become an assumption.

## The visibility precondition

Immediately before **every** write, the transport verifies through the API that the channel repository is still private, and refuses the write if it is not.
The check runs twice: once in `bin/fm-letterbox.sh` before the write is attempted, and again inside the transport adapter at its own write boundary.
The adapter reports the class of its refusal in its exit status (2 for not private, 3 for visibility unreadable), so a repository that flips between the two checks is still recorded under the `visibility` class rather than collapsing into a generic failure.

That converts "the repository was accidentally made public" from a silent, ongoing exposure into a hard stop plus an alarm.
The refusal is recorded durably under `state/letterbox/write-error`, so the poll raises it as a wake even if the turn that hit it was lost, and it re-alarms once per `FM_LETTERBOX_STALE_SECS` window until a write lands.
A `visibility` record is never replaced by a later `transport` one, and the poll carries the alarm on its configuration and dependency diagnostics too, so no earlier fault can silence it.

A refused write never stops the read path: intake, reply detection and the backstops all continue.
A successful read does **not** retire the record, for either error class.
A read proves the transport is back; it proves nothing about whether the alarm was ever delivered, and the watcher appends the durable wake only after the poll exits, so a death in that gap would otherwise let a retiring read erase the last evidence that a write was refused.
The one acknowledgement this side can observe is a write that lands, which proves both that the condition cleared and that someone acted on it.

## Home-local state

Everything lives under `state/`, which is gitignored as a whole, so no tracked path ever holds a letter, a receipt, a cursor or a claim.

```text
state/letterbox.check.sh           generated five-line shim, mode 0700, hash-registered
state/letterbox.check-trust        the byte binding written by bin/fm-check-register.sh
state/letterbox/inbox/<id>.json    the stashed card (a cache, not the record)
state/letterbox/claims/<id>.json   the atomic claim; also carries task=<task-id> once linked
state/letterbox/outbox/<id>.json   authored, not yet confirmed transmitted
state/letterbox/sent/<id>.receipt  issue number, URL, epoch
state/letterbox/cursor             per-issue transport cursor (updated-since)
state/letterbox/poll-error         rate-limited diagnostic dedupe marker
state/letterbox/write-error        a durable refused write, raised by the next poll
```

`state/letterbox/` and every child directory are mode 0700, while every file there is mode 0600; the executable shim is mode 0700 and its adjacent trust record is mode 0600 as listed above.

There is deliberately **no local ledger of record**.
Under the forge transport the forge holds the record and these files are a cache plus the idempotency markers.

An inbound letter that cannot be answered within the wake turn becomes an **ordinary firstmate task**, with an ordinary backlog entry plus `state/<id>.meta` when a worker is dispatched, linked from the claim as `task=<task-id>`.
There is no parallel store for peer obligations, which stops an acknowledged-but-unfinished promise from going invisible: the backlog task is inventoried at every session start, while the armed letterbox independently keeps supervision required at every turn boundary.

## The ordering contract

The [letterbox-correspondence skill](../.agents/skills/letterbox-correspondence/SKILL.md#the-ordering-contract) owns the durable-transition-before-acknowledgement contract and the idempotency required by claim-last, at-least-once announcements.
The operator-facing recovery outcomes are recorded in the crash matrix below.

## Crash matrix

Process death is safe on both sides of every boundary.

| Death point | Outcome |
|---|---|
| After the forge write, before the sender's receipt | The next send reconciles it: the id was recorded in the outbox first, so the retry adopts the existing letter by title-matched id. No duplicate. |
| After the stash, before the announcement | Nothing is claimed, so the next poll re-stashes and announces. No letter is lost. |
| After the announcement, before the claim | The next poll announces the same card again. Announcement is at-least-once by design, and consumers are idempotent on card id. |
| After the wake append, before acknowledgement | The wake is durable and re-presented on the next drain. |
| A `send --resends` is interrupted anywhere after the corrected notice's outbox record: create failed, death between the sent claim and the `resent_as` rewrite, or death before the receipt | Rerunning the same invocation adopts the corrected notice by title, completes the bookkeeping and receipt, and reports `completed the corrected notice ... nothing new was sent` with exit 0 in every one of those windows; the outcome is a function of whether the obligation is discharged, never of where the interruption landed. A second corrected notice for a discharged target is still refused. |
| After this estate's reply comment lands, before its local record | The attempt was recorded on the claim under the reply id BEFORE the post, because posting a comment is not idempotent (closing an issue is, which is why `close` acts first). The replayed wake finds the recorded attempt, looks for that reply id on the issue, and completes the record without posting a second terminal reply; `status` then lists the letter as `REPLIED`. |
| After acknowledgement, before the reply | The ordinary backlog task keeps the obligation in the session-start inventory, while the armed letterbox keeps supervision required even when no worker metadata exists. |
| After the forge close, before the local close record | Closing is idempotent, so re-running `close` closes again harmlessly; the consumed reply and any corrected-notice resend obligation publish in one claim rewrite, so either both land or neither does and the letter remains reported as awaiting a reply. |
| After the peer's first terminal reply is claimed, before the winner is cached on the sent claim | The reply claim itself records the letter it answers and its status, in the one write that made it a claim, so the winner is derived from it on the next poll and by `close`; a later terminal reply can never overtake it. |
| While a stash, outbox record or claim is being built | Generated JSON is staged and validated before it is published, so a `jq` failure never publishes an empty record that is then announced or claimed. |
| After a refused write, before anyone notices | The refusal is durable under `state/letterbox/write-error` and the next poll raises it as a wake while reads continue. Neither class is retired by a successful read: both re-alarm once per window until a write lands. |
| After the alarm is printed, before the watcher appends its wake | The write-error record survives, so the next window raises it again. A read never consumes the evidence, because a read proves the transport is back and proves nothing about whether the alarm was delivered. |
| After the sent claim, before its receipt | The letter stays in the unsent set, so the next send adopts it by title and completes the receipt. The claim is written first precisely so no window leaves the obligation invisible to both reconciliation and the backstops. |
| The peer's terminal reply is refused by the credential scan | The reply is never stashed; the wake names both the refused reply and the sent letter. The sent letter stays open, the `unanswered` backstop keeps raising it once per window, and the requester sends a `notice` naming the refused id and class so the peer can answer cleanly. |

### The stale backstop

A claimed letter this estate received whose issue is still open, which has neither a terminal reply from this estate nor linked task metadata, is re-surfaced by the poll as `stale` once per `FM_LETTERBOX_STALE_SECS` window.

A letter this estate sent whose issue is still open and whose terminal reply it has not consumed is re-surfaced as `unanswered` on the same window.
That covers a reply that was refused by the credential scan, and one that never came: the requester keeps being woken instead of the letter going silent, and the letter stays open because the peer still owes a clean answer.

This is the part that does not depend on anyone remembering, on either side of an exchange.
It costs no extra listing operation, because the open-issue set is already in hand from the poll's paginated `list-open` read.

## Read pagination

`list-open` and `comments` are paginated.
Both are correctness-critical: the open-issue set is the poll's whole outstanding-obligation view and the stale backstop's input, and a terminal reply can sit past the first page of comments while the cursor still advances over it.
`find-title` is deliberately not paginated, because a retry looks for an issue created moments earlier and one page bounds that read.
The watcher's per-check timeout is what bounds a paginated read on a pathological repository.

## Cost shape

A quiet cycle is one paginated `list-open` operation and no model tokens: it uses one HTTP request while the open set fits one 100-item page and additional requests only for further pages, while the per-issue cursor means comments are fetched only for a letter whose issue was touched since the last scan.
The cursor records an issue's `updated_at` only when that stamp is strictly older than the poll's own second, and compares stamps as instants rather than strings.
GitHub's `updated_at` has one-second resolution, so a reply landing in the same second as a recorded stamp leaves it unchanged; a stamp at the boundary is left unrecorded so the next cycle refetches, and an absent or malformed cursor always means "fetch".
The poll never writes to the channel; every write is a deliberate command run by an agent or an operator.

## Swapping the transport

`bin/fm-letterbox-transport-github.sh` is the only file that knows about GitHub.
A second transport implements the same verbs - `dependencies`, `require-private`, `list-open`, `comments`, `find-title`, `create`, `comment`, `close` - and adds its name to the configuration allowlist, while no other letterbox path changes.
Its own header owns the exact API calls and which CLI each verb uses.

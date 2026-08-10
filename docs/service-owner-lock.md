# Service-owner session locks

Each firstmate home has one session lock at `state/.lock`, and only its holder may mutate that home's fleet state.
An interactive session is discovered rather than declared: [`bin/fm-lock.sh`](../bin/fm-lock.sh) walks process ancestry for a verified harness process and records that pid.
A long-running service process that drives these scripts against its own `FM_HOME` - for example a backend hosting agent sessions - has no harness ancestry to walk, so ancestry discovery can never find it and a live non-harness pid would otherwise read as a stale lock.

Service-owner mode is the supported way for such a process to be a home's one live primary.
It is additive: the harness path is unchanged, and a home that never uses service mode behaves exactly as before.

## Taking, holding, and releasing the lock

```sh
bin/fm-lock.sh service-acquire <name> [pid]   # take the lock for this service
bin/fm-lock.sh service-verify  <name> [pid]   # exit 0 only while it still holds it
bin/fm-lock.sh service-release <name> [pid]   # give it back
bin/fm-lock.sh status                         # who holds it, and is that owner live
```

`FM_HOME` selects the home, exactly as for every other script.
`<name>` is the service's declared identity, 1-64 characters of alphanumerics, dot, underscore, or dash, starting alphanumeric; it appears in status output and in the refusal another session receives.
`[pid]` is the process that owns the lock for its lifetime.
It defaults to the caller's parent, which is the service itself when the service runs the script directly, so a service that spawns the script through a shell wrapper should pass its own pid explicitly rather than rely on the default.

Acquisition is idempotent only for the same declared name, pid, and process incarnation, so a service may re-assert its own lock at any point in its lifetime.
Release is bound to the recorded owner: a different name or pid is refused, and releasing an already free lock is a clean no-op, which makes it safe to call from an exit path that may run twice.
Verification is read-only and changes nothing, so a health check may call it as often as it likes.

## What the lock looks like on disk

`state/.lock` keeps its exact shape - one line holding the owning pid - so every reader that only wants that pid is unaffected by this mode.
The declaration lives beside it in `state/.lock.owner`:

```
kind=service
pid=<pid recorded in state/.lock>
name=<declared owner identity>
start=<start-time token of that pid>
```

Both files are internal to [`bin/fm-session-lock-lib.sh`](../bin/fm-session-lock-lib.sh), which owns the rules that read them; a service should call the script rather than write either file itself.
The reader accepts only these four keys, each exactly once, with no other content.
The record is published before the lock names its pid, so an interrupted acquisition leaves a record no reader honors rather than a lock nobody can attribute.

## What the mode guarantees

Ownership is a declaration bound to one live process incarnation.
The record counts only while it names the pid `state/.lock` records and that pid still carries the recorded start time, so a process that merely looks like the service cannot claim ownership and a recycled pid cannot inherit it.
There is no process-name matching anywhere in this path.

A live service owner is never displaced.
A harness session opening in the same home refuses into read-only and names the service owner in its own error, an ordinary firstmate session then reports the loud read-only banner and skips every mutating step, and the Claude Stop auto-arm stays inert instead of reclaiming the lock.
A second service owner is refused on the same terms.

A dead or replaced service owner is reclaimable on exactly the same terms as a dead harness owner: the next session that acquires the lock takes it and clears the stale record.
A malformed record or one that names a different lock pid returns to the ordinary harness rules, so no partial or corrupt state grants service ownership.

## Limits

The lock is cooperative and local, the same as it has always been: it coordinates processes on one host that agree to consult it, and it is not an access control on the home's files.
`start` comes from `ps -o lstart=` under `LC_ALL=C` and `TZ=UTC`, so its text is independent of the caller's locale and timezone.
A host whose `ps` cannot report a process start time refuses service acquisition with a named error rather than falling back to trusting a bare pid.
If the canonical start token later cannot be read for a still-live recorded pid, the owner's identity is unverifiable and takeover is refused until it can be resolved.
That token has one-second granularity, which is the residual limit of the pid binding.
One lock covers one home; a service driving several homes takes each home's lock separately under its own `FM_HOME`.

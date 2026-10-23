# Changelog

The ledger starts at `0.1.0`. crew reached this file with tags never cut and
every PR merged without a changelog fragment, so there is no accurate section
to reconstruct — an invented history is worse than an honest starting line.
History before `0.1.0` lives in git; this file starts there, and the first
assembled section is the one the `0.1.0` release stamps from the fragments in
[`changelog.d/`](changelog.d/README.md).

This decision is the recorded one heavy-duty/crew#84 asks for: **start the
ledger at 0.1.0**, do not backfill.

<!-- Release sections land below this line, newest first, each stamped by the
release PR from the fragments in changelog.d/. -->

## 0.1.3 — 2026-10-23

### Added

- The rehearsal now asserts the registry bound on the phase-2 attention tick,
  per demand that census recorded: the engine's suppressed report names it, no
  attention session is launched outside the sandbox, and no demand draws a new
  pickup comment. A miss `FAIL`s and stops the round (#714).
- `crew up` and the installer report a below-floor box or rig, in the same
  words, naming crew's version and both platform versions found and wanted.
  It reports and never refuses: each call site keeps its own consequence,
  decided by the capability rather than the version (#679).
- The rig half reads only the boxes in the roster. A box on this host that
  crew was never asked about is left alone — as `crew up` and
  `crew upgrade --all` already leave it — so it is neither opened nor named
  in a finding (#679).
- The host schedule carries no weekly `crew reset --all` line, deliberately
  rather than by omission: the restore it performs takes `duty.log` with it and
  clears the resume breaker with no push, so it is deferred to `0.1.4` behind
  #328 (#678).
- `crew reset` itself is unchanged and available on demand — the verb, its
  version interlock, its refusals, the host lock and the job log all ship as
  they were, and only the schedule is affected (#678).
- `shared/host-crontab.example` argues the deferral where a reader who came to
  add a second line will look, and does not leave the line commented out: a
  commented job line is reinstatable by uncommenting, in the one file nobody
  diffs (#678).
- `shared/docs/host-maintenance.md` keeps the price and period reasoning the
  deferral is reversed from, and names what the deferral costs on disk until
  `0.1.4` with the reading an operator should take (#678, #606).
- Kimi sessions resume once after eligible timeouts and report only resumed-turn usage (#674).
- Box vitals flag low disk or memory headroom from operator-overridable limits. (#613).
- The fleet floor shows each box's current/max memory and disk headroom. (#613).
- Session history rows open their available transcript tails in the floor overlay. (#612).
- `duty.log` now records that the box restarted, on the first tick after a
  reboot, so a session that vanished with the box has a stated cause on the
  line above it instead of an unbroken run of ticks. A box that has never
  ticked says so rather than claiming a restart it did not take (#609).
- `shared/host-crontab.example` schedules the fleet host's maintenance: `crew restart --all` daily, one line per job, with no `flock` and no redirect in the line (#590).
- `crew restart` and `crew reset` take one non-blocking host maintenance lock between them, so the two verbs can never overlap; the later run names the holder, touches no box, and exits 4 (#590).
- `crew restart` and `crew reset` write every run to a host job log, boundary lines and per-box outcomes alike, so a run that did nothing still says so and silence at a boundary means cron is dead (#590).
- `CREW_HOST_STATE_DIR` moves the host maintenance lock and job log together (#590).
- `shared/docs/host-maintenance.md` is the runbook for the host jobs: what a skipped box means, what a refused reset means, and the rule that after any `crew upgrade` you re-cut before the next reset (#590).
- `crew reset --cut` snapshots each box as `armed` after proving it is logged in — GitHub and the agent profile's vendor CLI — and hired, reclaiming with an on-demand reaper run before it measures the disk and refusing a box still over the ceiling by naming what is large (#589).
- `crew reset` restores each box to its `armed` checkpoint and starts it, refusing a box with no such label rather than falling back to another one (#589).
- `crew reset` refuses a checkpoint whose recorded engine version is missing, unreadable or not a version, and `--cut` refuses a box whose engine stamp it cannot parse (#589).
- `--force-after` forces the restore path only; a `--cut` is skipped on a held duty lock however old (#589).
- `crew restart` drains and cycles selected boxes, skips live sessions, and reclaims stale duty snapshots (#588).
- Operators can price captured token records from an editable per-model rate card without stamping mutable costs into session history. (#572).
- `kimi` sessions record their token usage and credential pool on `SESSION END` (#571).
- A multi-step kimi session's totals cover every step rather than a single one (#571).
- A kimi session records uncached input, output, cache reads and cache creation, and no cost (#571).
- A kimi session's usage names its model `unknown` (#571).
- A kimi session whose usage is unavailable or unreadable records none, and its result is unchanged (#571).
- Codex sessions now record uncached input, cache, output, session identity and honest unknown-model usage while preserving final prose and omitting unavailable cost. (#570).
- Codex session logs preserve intermediate messages, command output and completion status when structured usage capture is active. (#570).
- `SESSION START` and `SESSION END` carry `sid=`, the session id the engine mints and pins on the CLI, so a session's transcript is addressable from `duty.log` (#538).
- A session killed at its wall is continued once rather than restarted, where its head has not moved, its log is non-empty and nothing of it survived (#538).
- Review sessions can park on bounded detached checks and resume once with recorded results instead of restarting long verification on every tick. (#533).
- `SESSION END` records log bytes and surviving session processes (#529).
- A release candidate carries its own drill record, `drills/X.Y.Z-rcN.md`, and
  `drills/README.md` states the ladder the release doors already implement
  (#506).
- A release guard refuses a final tree whose diff over its last candidate's tag
  touches anything but `VERSION`, `CHANGELOG.md`, `changelog.d/` and `drills/`
  (#506).
- Deleting a candidate's drill record cannot lower the anchor a final is
  measured against: the rc-ladder guard reads the published candidate tags as
  well as the shipped tree's records (#506).
- The rc-ladder guard requires every reachable published candidate's own record,
  spelled exactly as its tag, so renaming a record under another spelling of its
  number is refused as the deletion it is (#506).
- A zero-padded candidate `X.Y.Z-rc0N` is measured as rung N rather than
  reported as a tag that cannot be resolved: the ladder is ordered by the number
  and named by the spelling (#506).
- Only the release doors' own spelling is a candidate — `X.Y.Z-rcN` in ASCII
  digits — so a version or tag the doors would never classify never anchors, and
  never gates, a release (#506).
- A stray space inside `VERSION` cannot hide a release window from the rc-ladder
  guard: the version is consumed the way the release doors consume it, with all
  whitespace deleted rather than only the ends trimmed (#506).
- The rc-ladder guard reports a shallow clone as a could-not-look, including
  when ancestry is what it cannot decide, and names the `fetch-depth: 0` fix
  (#506).
- Fork PR authors can flag an evidenced red check for privileged rerun servicing. (#505).
- Triage sessions carry the board's round count for every issue, with the
  distribution those counts form and the round cap they are read against, as
  sizing evidence at the mint (#503).
- The builder engine records every open authored pull request's round count
  against the issue its body names, not only the ones that have reached the cap
  (#503).
- The builder engine counts a PR's review rounds and names the round cap to the
  session when the fifth round closes without a full approval standing at the
  current head (#502).
- CI refuses a tracked path that no `scope:*` row in `.github/labeler.yml` matches, naming each one; a path deliberately left unmapped is declared with its reason in `.github/scope-coverage.allow` (#500).
- Writing a `scope:*` label twice in `.github/labeler.yml` is refused, naming both lines: the scope job keeps only the last block, so the earlier one's globs derive nothing (#500).
- The release records the installer's size and payload file count, on the build's output and in the workflow run summary (#499).
- The rehearsal runbook documents every leg of the drill round — what each one
  needs, what it produces, and what its failure means — and names the blockers
  that stop a leg running on a bare host (#497).
- CI diffs the runbook's documented leg set against the harness's own
  declaration in both directions, so a leg added to the round cannot go
  undocumented (#497).
- The teardown fixtures drive the notifier union leg's second sandbox per role
  through the delete set, the ownership refusal and prefix-is-not-membership
  (#496).
- The fleet floor edits both watch registries — the fleet-wide `repos.txt` and
  `notify-repos.txt`, and a per-box selection reached from that box's own
  console (#488).
- A box's registry selection is `repos.d/<box>.txt` beside the fleet-wide list,
  and `crew hire` and `crew upgrade` transport it in place of the fleet-wide
  one (#488).
- A box selects from the fleet-wide registry and can never reach outside it: an
  entry the fleet does not watch is refused at the edit, and one retired
  fleet-wide leaves every box that had selected it (#488).
- A registry edit naming a malformed entry, or a repository the fleet cannot
  reach, is refused at the edit with the reason (#488).
- Every registry write is appended to `.registry-journal.log` in the fleet
  definition, naming the operator, the file, the state that write applied and
  the entries that moved, so one line describes the registry it produced
  without reference to any other (#488).
- Registry writes are serialised per registry and written through a temporary
  file of their own, so two edits in flight leave the file at one of the
  submitted states and one accurate record each (#488).
- A registry write that cannot be recorded is refused before anything moves,
  one the filesystem will not accept is refused with the reason, and one whose
  record fails after the file changed says the edit landed unrecorded rather
  than reporting a refusal (#488).
- `crew` reads every registry file through one reader, so a hand-indented entry
  is the entry it names and the console and the transport resolve one file
  alike (#488).
- A fleet-wide registry the definition does not have is shown as served from
  the shipped `examples/` file the transport stages, and saving it writes the
  definition's own copy (#488).
- Force stop as its own floor action, killing a guest that cannot schedule
  its own shutdown (#486).
- `crew status` and the fleet floor show bounded per-box tick health from existing duty records (#484).
- Every tick emits a box vitals record — cores and load, memory total/available/shared, swap configured and active, disk total/used/percent, platform and OS release (#483).
- A vitals reading that disagrees with the role profile's `BOX_CPU`, `BOX_MEMORY` or `BOX_DISK` is marked on the record as a finding, naming both the declared and the measured figure — over the declared figure as well as under it (#483).
- Swap configured and swap active are recorded as separate fields, so a swapfile present while `swapon --show` is empty reads as a finding rather than as free disk (#483).
- `crew status <box>` and the fleet floor both render the box vitals record, from the same logged line and in the same words, so the two consoles cannot describe one box differently (#483).
- The record's disk history is backfilled from `boot-check.log`, so the series starts where the box did rather than at the first tick after the probe shipped (#483).
- The duty engine declares its operating limits and reports near-limit and crossed-limit measurements with their affected repository and pull request (#482).
- The floor relays operating-limit events from boxes through its configured operator alert channel (#482).
- The fleet floor can send one configured alert when a roster box becomes unreachable and another when it recovers (#481).
- Builder resume suppression now appears with its age and reason in `crew status` and on the fleet floor (#480).
- Session-end records can include Claude token usage, actual-model attribution, conditional cost, session ID, and an operator-declared credential pool without changing prose logs. (#475).
- A session now runs under a memory ceiling: `SESSION_MEM_MAX_PCT` in
  `fleet.defaults.conf`, a percentage of the box's `MemTotal`, with a per-role
  override beside it. A session whose measured peak crosses it is terminated
  and its `SESSION END` carries `outcome=MEMORY` (#474).
- The termination covers the session's own process group as well as its pid
  tree, so a descendant that handles `TERM` by forking a replacement and
  exiting cannot outlive the session that was ended (#474).
- The ceiling ships at 0 on every row, which is off: with nothing configured
  the engine starts no watchdog and a session behaves exactly as it did (#474).
- `SESSION END` now carries `peak_rss=`, the largest `VmHWM` in the session's
  process tree in KiB, so a session that grew until the kernel killed something
  is visible in the engine's own record of it rather than only in the silence
  that followed (#473).
- The fleet floor renders that figure for the newest session per box, and shows
  a dash for a session it has no figure for — including every line written
  before this (#473).
- The field is omitted entirely where the engine got no reading: a platform
  that reports no `VmHWM`, or a session shorter than one measurement interval.
  An absent field is not a zero, and nothing an aggregate reads can confuse the
  two (#473).
- A session that died with its box gets `peak_rss=-` on the terminal the orphan
  reconciler writes for it, beside the `rc=-` and `dur=-` it already carried: a
  measurement owed and lost, not one never taken (#473).
- Fast triage ticks now wake when a declared predecessor changes state and name the dependency edge that needs a prose re-read. (#471).
- A duty may now name its own model tier: `MODEL_<KIND>` beside that kind's
  timeout in `conf/roles/*.conf`, and `run_session` invokes it instead of the
  agent profile's default, so a mention and an issue mint need no longer be
  bought at the same price (#469).
- The agent profile owns the translation into its own flag, and a profile that
  cannot express a tier leaves the duty on the default and warns, naming the
  profile and the kind, rather than ignoring the setting silently (#469).
- `SESSION END` now carries `tier=`, naming the resolved tier or `default`, so
  an aggregate can tell a duty that got cheaper from one that got rarer. The
  field is appended to every line, unconfigured sessions included (#469).
- Per-duty tiers ship unset everywhere: an engine that is upgraded and not
  configured invokes exactly what it invoked before, and every session behaves
  as it did. The `tier=default` field above is the one deliberate change to
  what a `SESSION END` line looks like (#469).
- The duty engine now enforces a session budget: a per-kind ceiling on both
  sessions and session-minutes over a rolling window, checked in `run_session`
  before any vendor call (#464).
- A lane at its ceiling logs `SESSION SKIP … reason=budget` and stops
  dispatching until the window rolls, leaving every other kind untouched
  (#464).
- The operator is told at 80% of a ceiling as well as at it, once per crossing
  per kind, on the channel the session breaker already uses (#464).
- Session budgets are configured per role and per kind in `conf/roles/*.conf`
  and ship OFF, so an engine that is upgraded and not configured behaves
  exactly as before (#464).
- `crew status <box>` reports each configured lane's balance — spent, ceiling
  and when the window next frees capacity — from the moment a ceiling is set
  rather than from that lane's first dispatch, and omits the section when no
  lane is configured (#464).
- An unreadable or unwritable budget counter refuses to dispatch and alerts,
  rather than dispatching on a balance the engine cannot read (#464).
- Triage prompts can route vendored-doctrine gaps to a configured, fleet-listed upstream repository (#463).
- A builder that judges a `ready` issue unbuildable now declines it on the
  board: a comment on that issue naming one of four reasons and @-mentioning
  triage, instead of a decision that died with the box (#462).
- `post-once.sh` takes an optional marker line and dedups on it, so a comment
  whose identity is narrower than its text posts once (#462).
- A daily reaper on every role reclaims what this engine's own sessions
  leave on a box: CLI transcripts older than the retention age, and cache
  entries nothing has read inside it. Each class logs its byte figure, and
  logs one when it reclaims nothing (#457).
- The reaper holds rather than deletes whenever it cannot establish a fact:
  while any session is live, on a filesystem whose access times do not
  advance, and over anything it could not finish reading (#457).

### Changed

- A builder box reads its identity's authored pull requests only in `repos.txt`
  repositories, never across the whole account (#728).
- The mint sequence has one writer that `crew new` and the drill both call,
  instead of two copies a human kept agreeing (#679).
- crew declares the platform it is built and tested against — box 0.10.0 and
  rig 0.4.0 — in one place, and the two call sites that hardcoded a version
  read it from there (#679).
- Codex duties resume one eligible timed-out thread instead of restarting from zero (#673).
- The `crew status` STUCK note names the ceiling that was exceeded, or says
  no session was in flight, matching the floor's wording (#624).
- Root can install one system crew tree that each host operator runs with their own identity and fleet configuration (#615).
- The STUCK note and panel name the ceiling that was exceeded, not only how
  long the lock has been held (#610).
- A freshly minted `reviewer` box is 4 CPU, 8GiB, 60GiB — the builder's size
  (#607).
- `reviewer.conf`'s comment above the figures names what a review run does, and
  no longer calls the role lean or its worktrees throwaway (#607).
- A box cloned from a gold snapshot — `crew new --from`, or a roster line with a
  fourth column — is sized at the role's cpu and memory where the host's box
  supports it, instead of inheriting the snapshot's (#607).
- `--disk` is never passed on a clone, so a cloned box keeps the snapshot's disk
  (#607, box#171).
- Every clone ends in one line giving cpu, memory and disk each `applied`, `NOT
  applied` or `unverified`, beside the size the box carries, the size the role
  profile asks for, and the commands to resize all three (#607).
- `drill/rehearsal.sh` mints each drill box at its role's size (#607).
- The ceremony pin moves from `0.7.6` to `0.7.7` across all ten anchored
  `uses:` references — the six release guards, both label callers, the release
  door and the privileged rerun service — so a fresh taxonomy bootstrap no
  longer stops at the `operator` label's over-long description (#603).
- Reviewer duty coverage now runs in its own entrypoint-driven test suite. (#601).
- `crew restart` and `crew reset` exit 4 when nothing was attempted, distinguishing it from a run in which everything attempted worked (#590).
- `crew hire`, `crew up` and `crew upgrade` mark the box's `armed` checkpoint stale before installing an engine, and refuse to install when that mark cannot be written (#589).
- `crew reset` refuses a box whose `armed` checkpoint is marked stale, naming both versions and the re-cut (#589).
- `crew hire` and `crew upgrade` both name the stale mark they left when the install that followed it failed (#589).
- `crew new --from` refuses an `armed` checkpoint as a clone source (#589).
- `crew down` waits for duty locks, reports partial failures, and requires an explicit supported `--force` to stop wedged boxes (#588).
- Reviewer prompts now show same-head CI conclusions and qualify how that evidence should be used (#532).
- `fleet-floor/server/floor.py` is split into a `floor` package on the banners it already drew — `ping`, `roster`, `units`, `fleet`, `actions`, `alerts`, `server`. Both doors are unchanged: `floor.py` still starts it, `import floor` still answers with the whole collector (#508).
- `fleet-floor/test/` mirrors the collector's modules: `cases.sh` becomes one suite per module under `test/floor/` (#508).
- `shared/lib/common.sh` is now an entry point over seven subject modules under `shared/lib/common/`; callers source the same path and get the same functions (#507).
- Fixtures for those modules run as seven suites under `shared/test/common/`, one per module at the mirrored path (#507).
- Agent doctrine and release machinery now use ceremony 0.7.6. (#505).
- PR Round logs now keep bounded review facts and reply links instead of copying whole-round replies into the body (#504).
- The engine holds its panel request on a PR at the round cap, so the successor
  is the only PR the panel is asked for (#502).
- A fifth round that closes with the panel's unanimous approval, where those
  approvals still stand at the current head, converges and hands off as usual
  and is never named for the cut. Where the head has since moved the approvals
  are spent and the PR is at the cap again (#502).
- The published installer carries only what an install needs, instead of the whole tracked tree: `crew-<version>.sh` is 531 KB where it was 51 MB (#499).
- Restart force-stops an unreachable box before starting it; a box that still
  answers restarts gracefully (#486).
- Lifecycle action replies name which step each per-box row came from, and the
  status line says when an action force-stopped a box (#486).
- The fleet payload serves the collector's reachability verdict as
  `ping.wedged`, so the console reads one rule rather than re-deriving it from
  the miss count against a threshold of its own (#486).
- A restart carries the mode its confirmation named, and the floor refuses it —
  changing nothing — if the box crossed the reachability boundary in between,
  so a graceful confirmation can never authorise a force stop (#486).
- `SESSION START` carries `holder=<pid>.<boot>`, the duty process that
  dispatched the session, so a session still running is told from one that
  died by asking its holder rather than its age (#478).
- Shared duty-engine fixtures run as five standalone subject suites behind the aggregate entrypoint (#470).
- Fast-tick triage sessions now receive only the named issues and discussions that woke them; hourly hygiene retains the whole-board sweep (#468).
- The hourly hygiene sweep now launches a session only for repositories whose board changed since the last one, and sweeps a never-changing board anyway once every `HYGIENE_FLOOR` (#465).
- A hygiene gate that cannot read the board or its ledger sweeps anyway and warns by repository, a `HYGIENE_FLOOR` that is not a whole number of seconds falls back to the shipped default with a warning rather than disarming the floor, and every withheld repository is logged each interval (#465).
- The hygiene prompt no longer asks for the blocked-to-ready flip or the stale-claim reclaim, which the issueflow reconciler already owns (#465).
- `no build duty` names why the ready work is held —
  `2 ready declined: unbuildable (1), needs-ruling (1)` — where it named only
  the ledger holding it (#462).
- Builder-specific panel rows now enroll both live builder identities without changing required reviewers (#458, heavy-duty/ceremony#424).

### Fixed

- Kimi timeout resumes now use durable tool calls from `wire.jsonl` instead of kill-truncated stdout (#746).
- GitHub authentication failures now record a matched API reason without also appending the exit-code fallback. (#736).
- The drill now mints its board fixtures and matches its label assertions under the box's own effective `LABEL_*` names, so a fleet whose `fleet.conf` renames one still drills (#735).
- The drill's installed queue-label set now reads `fleet.conf` over the defaults, so the stray-ruling assertion grades against the names the engine uses (#735).
- The drill compares an effective label name as data, never as a regular expression or a jq filter, so a name carrying `.`, `|` or `"` is matched exactly rather than accepting a near-match or failing to compile (#735).
- The drill terminates `grep`'s option list before the effective queue-label set, so a name beginning with `-` is compared as data rather than parsed as options (#735).
- The drill's box reads now strip only the line-ending carriage return the transport adds, so a name carrying one anywhere else is refused rather than silently repaired (#735).
- Phase 2 now refuses builder and reviewer drills when the box and host use the same GitHub identity. (#729).
- Builder drill rounds now create, resolve, and tear down the box identity's sandbox fork. (#727).
- A tick refused by the lock names its holder: a previous run still going, with
  its duration, or a lock left standing on a descriptor that run's children
  inherited (#726).
- A tick whose `.duty.lock.since` is corrupt now writes its evidence line
  (#726).
- The `resume` drill leg grades the pull request it drives: a resume session
  bought by another claim in the same sandbox no longer reads as a pending head
  resumed, or as a lane that failed to stop (#725).
- A failing `resume` row prints the tick's resume roll-call, so the round's
  record names the lane that dispatched (#725).
- The terminal-breaker drill leg grades the lane fixture's state instead of the
  label request's exit status: a fixture an earlier leg closed is reopened
  before any tick fires, and the arming row reds — naming the state and labels
  it read — when the re-read does not hold (#724).
- The leg grades a tick only once it has confirmed the tick ran, against
  `tick.sh`'s own evidence contract. A lock-skipped tick is re-fired within a
  bound; one that wrote nothing, logged FAILED or left the log unreadable is
  INCOMPLETE with the reason, never a FAIL (#724).
- The lane is armed, cleared and disarmed with the box's own effective
  `LABEL_ATTENTION`, resolved through `load_fleet_conf`, so a box whose
  operator moved that name is drilled against the label its engine fetches
  (#724).
- Timed-out Claude sessions with transcript tool use now retain their one resume even when the final reply is absent. (#723).
- The rehearsal's phase 2 no longer refuses an identity that carries an
  `attention` demand in another repository: it records those demands as a
  census row and runs, so the operator's own account is a supported drill
  identity and a round needs no throwaway one (#714).
- The census's window is the wake's own — the single unpaginated
  `per_page=100` page of the assigned-issues endpoint `duty_attention` reads —
  and it is taken after the sandbox demand is minted, since minting changes
  which demands that page carries (#714).
- The census asks for the box's own effective `attention` label rather than the
  literal name, so an operator rename no longer leaves it reading an empty set
  off a board that is full (#714).
- The phase-2 evidence is read across a `duty.log` rotation: the census records
  which generation it counted, so a round whose log moved reads the rotated
  tail and the new file instead of nothing, and one whose generation is gone
  stops rather than grading an absence (#714).
- A `duty.log` the box cannot read now stops the round instead of passing for
  an empty one: the reads that bound the phase-2 evidence carry their own
  failures, so "nothing was written outside the sandbox" can no longer be
  reported off a file nobody read (#714).
- Installer rehearsals return borrowed boxes disarmed with their original repository registry restored (#712).
- The real-fleet browser walk accepts prerelease engine stamps and skips fixture-only restart assertions. (#711).
- A creds-free box's first tick now logs `cannot resolve own login` again
  (#708).
- The `auth: gh rejected us` and `auth: gh is working again` lines now reach
  `duty.log` on the tick that produces them, instead of the value the tick
  resolves its own login from (#708).
- The repair `crew hire` and `crew status` print for an unconverged box now opens `box root` rather than `box shell` plus `sudo` (#700).
- That repair now installs rig at the declared pin when the guest has none (#700).
- `crew help reset` now describes the daily restart schedule and on-demand resets without advertising a removed weekly job (#688).
- `crew status` reads the newest vitals record even when an older log segment contains binary data (#688).
- Reviewer sizing guidance now accounts for clean worktree reclamation while retaining dirty-worktree capacity (#688).
- `crew new` mints a box again on the box version crew's own floor requires:
  a blank mint plus a `rig bootstrap <agent>-box`, replacing the
  `--template <agent>-box` spelling box 0.10.0 retires (#679).
- The guest tenant keeps the agent's own name — `claude`, `codex`, `grok`,
  `kimi` — rather than silently becoming the blank seed's `dev` (#679).
- `drill/rehearsal.sh` no longer dies at box creation on a current box host,
  so the rehearsal can reach its assertions (#679).
- `crew help`, `crew new`'s success response, `examples/fleet.roster` and
  `shared/docs/single-role.md` described a retired `<agent>-box` box
  template; all four now describe the blank mint and rig's `<agent>-box`
  role (#679).
- `crew new`'s response no longer says the vendor CLI is converging when rig
  has already finished, and makes no rig claim at all on the clone path,
  where no bootstrap ran (#679).
- The platform report no longer reads `box: not found found`, and says the
  guests could not be read rather than reporting an empty fleet when `jq`
  is absent (#679).
- Verdict submissions keep their byte-identical retry copy on the duty volume, so a full volatile temporary filesystem cannot discard a completed review (#672).
- Reviewer sessions retry missing exact-head verdicts up to three times instead of suppressing live requests after a successful model turn (#671).
- Builder checkouts now validate and cache their writable fork, repair stale remotes, and refuse dispatch when no unique head repository exists (#635).
- Floor-only pull requests now run the shell suite, including its repo-wide
  and cross-reader guards (#625).
- `crew status` no longer reports a healthy box STUCK for spending time it
  was dispatched to spend: the lock age is measured against the ceiling the
  in-flight session declares, so the CLI and the floor grade one box alike
  (#624).
- The fleet god-view now flags usage-limited lanes with their cause and lane, and distinguishes terminal sessions from ordinary failures (#611).
- Unit consoles now show collected operating-limit events and retention losses even when no alert channel is configured (#611).
- The floor no longer reports a healthy box STUCK for spending time it was
  dispatched to spend: the lock age is measured against the ceiling the
  in-flight session declares, so a `build` entitled to 3600s is not alarmed
  at minute 10 (#610).
- Fleet probes read tick age and vitals past NUL bytes in `duty.log`, avoiding false SILENT boxes (#608).
- Reviewer ticks reclaim finished review scratch while preserving dirty work and verdict records (#606).
- Reviewer ticks reclaim finished review scratch without reading the PR's state (#606, #597).
- A dirty review worktree is preserved by moving it to `kept-<name>-<head>` rather than left on the path the next review needs (#606).
- Reviewer repo-wide checks now run from the detached PR checkout, excluding sibling worktrees and mutation fixtures. (#605).
- Session records now distinguish kernel OOM kills from wall-clock timeouts (#600).
- Productive memory-killed sessions resume with cause-aware guidance, while error-only logs start fresh (#600).
- Reviewers cap local ShellCheck memory, never retry kernel-killed checks, and rely on same-head CI for repo-wide lint. (#598).
- Review ticks reclaim detached worktrees left by ended sessions before dispatch, while preserving branch-holding builder worktrees (#597).
- Fleet-floor test call logs now keep each concurrent box invocation in one atomic record (#563).
- Reconstructed orphan session records now retain every observed field, using unknown markers when the original value cannot be recovered (#553).
- A terminal the vendor did not cause is no longer cleared by a vendor probe
  succeeding, so a box that kills its own sessions is stopped rather than
  throttled to three dispatches every four ticks (#551).
- A lane held by such a terminal clears on an observed session end instead —
  a session that ran to its own `SESSION END`, whatever its outcome, which is
  the evidence that the box survived it (#551).
- A held lane is retried on a widening interval bounded by
  `SESSION_TERMINAL_HOLD_MAX_TICKS`, so it is never tried every tick and never
  left permanently dark (#551).
- The breaker's trip alert fires on the transition alone, so a held lane's
  trial dispatches no longer raise an alert pair per cycle (#551).
- Operator-launched sessions now inherit the layered fleet and role configuration and use the longest applicable session timeout unless explicitly overridden (#537).
- Reviewer sessions now use bounded PID or sentinel waits instead of self-matching process polls (#530).
- Fleet-wide mention batches stay visible without becoming links to a repository named `fleet` (#528).
- `crew upgrade` from an installed tree no longer ships `__pycache__/` directories into the payload (#517).
- Duty logs name missing session-classifier hooks once per agent profile per boot (#501).
- Claude quota-reset sessions now reach the terminal breaker (#501).
- A pull request touching only `postmortems/`, `.box/README.md`, `shared/crontab.example`, `.github/workflows/labels-sweep.yml` or the release artifact hook now carries a scope label (#500).
- Installer payloads now exclude ignored dependency trees and reject known-excluded paths before installation (#498).
- The runbook's Phase 3 report step describes the target the round derives from
  the ref it drilled, instead of routing findings to a long-merged pull
  request (#497).
- Drill records now enumerate every declared leg and explain each leg that did not execute. (#495).
- Drill rounds distinguish disarmed-only agreement from a measured armed, ticking, clock-skewed comparison and run both without extra boxes (#494).
- Drill rounds without an armed roster stay incomplete and retain their boxes for inspection (#494).
- Rehearsal reuse now refuses dirty sandboxes, while every role removes only the exact fixtures its current run created, on both success and failure (#493).
- The drill's exit footers name the pull request derived from the ref actually
  drilled, instead of a hard-coded long-merged one (#492).
- A drill round whose source names no pull request — a branch, a tag, a commit,
  a local `--tree` — prints no report instruction rather than a stale one (#492).
- Rehearsal rounds continue independent sections after a phase failure and report every section as passed, failed, or skipped-by in the summary (#491).
- Role rehearsals now resolve a candidate ref once and drill the same commit in every box (#490).
- The fleet-floor browser walk now checks byline overlap against one settled viewport frame at a time. (#489).
- `crew hire` reads a box with a narrowed registry as narrowed, rather than as
  a box about to be armed against the production registry (#488).
- `crew hire` compares the registry a box carries against the fleet's through
  the same reader on both sides, so a trailing space or a CRLF in either file
  no longer reads as a narrowing and lets an off-roster box be armed against
  the production registry (#51, #488).
- A floor restart reads its own stop result before starting: a stop that failed
  is reported as a failed restart and the start is not attempted, rather than a
  box being started by a lever that never stopped it. A box that was already
  stopped is started, not reported as a failed stop (#487).
- `wake-silent` no longer sends its wake into a box whose `box exec` is wedged.
  That box is named for a restart instead of costing the action a full timeout
  to report a wake it could not deliver (#487).
- Resume detection no longer loses a pull request whose comment thread grows
  past 131,072 bytes: the thread reaches `jq` down a pipe rather than as one
  argument, so the bound that applies is the one that scales (#479).
- Every failure on that path now warns (#479).
- A structural failure there — one that will not clear on its own, unlike a
  transient `gh` error, which is still retried next tick — now reaches the
  operator once per head instead of skipping the pull request forever (#479).
- That escalation also leaves a comment on the pull request naming the head, so
  the record survives an alert that was never delivered (#479).
- A session killed with its box no longer leaves a `SESSION START` nothing
  answers: the next tick emits the missing terminal with `outcome=ORPHANED`,
  and with `rc=-` and `dur=-` rather than a figure it cannot know (#478).
- A reconstructed terminal counts toward its kind's session breaker, on the
  same counter an observed one feeds: three in a row trip that lane and it is
  refused for the rest of the tick that trips it, until the next tick's CLI
  probe succeeds and clears the breaker (#478).
- Doctrine checkout warnings now report each frozen state once, include its age, and announce recovery without modifying session-owned Git state (#477).
- Credential failures now report rejected GitHub credentials and API responses instead of blaming configured git authors (#476).
- Git identity failures now name configured authors and the GitHub login in use (#476).
- The session subshell is raised in the kernel's OOM victim scoring before the
  CLI starts, so a box out of memory loses the session that is growing rather
  than `cron`, `sshd` or the engine itself (#474).
- The fleet floor's box probe lists `*.log` from the log directory rather than
  everything in it, so a poll landing while a session runs no longer spends one
  of its forty slots on that session's scratch file (#473).
- `acted=` in `duty.log` reports `yes`, `no` or `unknown` on claude and grok boxes, where it was always `unknown` (#467).
- Triage batches fresh mention threads from every repository into one capped session per tick (#466).
- Builder signals exclude ready issues marked as operator-owned work. (#461).
- Claims now stop before editing repositories where the `claimed` label is unavailable (#459).
- Failed issue claims now preserve the ready queue state and report repair or withdrawal failures (#459).
- The breaker drill reports profiles without `bot_session_terminal` as named INCOMPLETE skips instead of failures (#454).
- A maintainer's `CHANGES_REQUESTED` now wakes the builder to a fix round,
  once per block rather than forever (#452).
- The handoff no longer refires under a standing human change request, so a
  handed-off pull request stops bouncing back at the human with a fresh
  review request and a fresh notification (#452).
- A round answered with argument at an unchanged head still converges, so the
  argument reaches the human (#452).

### Removed

- The `authored PR(s) outside repos.txt` warning (#728).

## 0.1.2 — 2026-08-10

### Added

- The rehearsal drills the triage hygiene slot's board audit: it reports
  `attention` on a pull request and on an unassigned issue, naming both with
  their class (#441).
- The rehearsal drills that the board audit never repairs — both flags stay
  set, the unassigned issue stays unassigned, and neither fixture draws a
  comment (#441).
- The rehearsal drills the audit's alert transitions by count: silent on a
  clean board, one `🚨` when the malformed set appears, none while it is
  unchanged, one `✅` when it clears (#441).
- `drill/rehearsal-all.sh` takes `--no-attention-audit-drill` and records the
  leg's outcome in the round summary (#441).
- The rehearsal drills what the builder attention wake does after its ack: a
  claim with no open PR and no build branch is dispatched to the normal duty
  tick, leaving no PR and no `build/<issue>-*` branch behind (#440).
- The rehearsal drills the timed-out pickup report — one `⏱️` comment naming a
  stable log link, that link resolving to a readable file, and the operator
  alert naming the immutable run log (#440).
- `drill/rehearsal-all.sh` takes `--no-attention-drill` and records the leg's
  outcome in the round summary (#440).
- The drill asserts the boot check's `cli probe` verdict is `ok` and that the
  boot block carries no `WARN`, for the agent the round was given (#427, #240).
- Release drills now trip, suppress, alert once, and recover a staged terminal session lane for the drilled agent (#424).
- The drill asserts the operator watch set is `repos.txt` ∪ `notify-repos.txt`,
  both halves reaching the operator on one notify tick (#423, #316).
- `drill/rehearsal-all.sh --no-notify-drill` opts out of the notifier-union
  leg (#423).
- The real-host rehearsal now proves dirty merged-branch worktrees are preserved remotely before removal and retained when preservation fails (#422).
- The install rehearsal now measures the installed tree on a real host: the first install, the upgrade and the offline artifact each carry none of the installer's excluded roots, by path, and stay within the shipped size bound (#365, #421).
- The drill record now carries each installed tree's measured size rather than a bare pass, and reads both the excluded roots and the bound from their shipped sources instead of spelling them (#365, #421).
- The app rehearsal now reads the floor surfaces this release shipped: the serving host's own version, and each engine's integrity verdict taken from the box's own answer (#420).
- The app rehearsal now asserts the roster boxes counted but not drawn, the repair verb a floor with nothing hired names, and the split between deliberately disarmed and genuinely silent boxes (#420).
- The app rehearsal now asserts `crew up --dry-run` changes nothing, that an unanswered engine probe reads `unknown` rather than never-hired, and that `no build duty` names a cause and a count (#420).
- The release rehearsal now proves the check-conclusion resume wake, malformed-signal warning and zero-action stop on consecutive real ticks. (#419).
- The builder drill now exercises draft return and the settled-head panel-request gate through a live fix round (#418).
- `.ceremony/RELEASES.md` joins the vendored doctrine mirror (#350).
- The fleet-floor header shows the serving host's exact crew version (#347).
- The triage hygiene slot reports `attention` flags on pull requests or unassigned issues without repairing them. (#303).
- `drill/teardown.sh` removes what a drill round created — its boxes and its
  public sandbox repositories — naming each with its creation date and asking
  once, and doing nothing on an already-clean host (#217).
- Teardown deletes only names that are exactly the drill's own and that no
  roster on the host claims; a fleet member is refused even where its name
  matches the drill pattern, and one bad name in a run deletes nothing (#217).
- A sandbox repository is deletable only when its owner is the host's own gh
  identity as well as its name being a drill name, so a drill-shaped
  repository under another account is refused (#217).
- Teardown tells "found nothing" from "could not look": what it cannot
  inspect — no gh identity, no box CLI, an unreadable `box list`, or a single
  repository lookup that fails for anything but a measured 404 — exits 2
  INCOMPLETE, naming it, instead of reporting a clean host (#217).
- Naming the same box or sandbox twice in one teardown deletes it once,
  instead of a second removal failing and reporting a box that *was* removed
  as a failure (#217).
- Each release publishes `crew-<version>.sh.sha256` beside the installer, which
  `sha256sum -c` verifies (#210).
- The floor's unit tile renders the engine's integrity verdict beside its
  version: `current`, `MODIFIED` or `unverified` (#159, #190).

### Changed

- The drill's boot-check failures quote the line they read and name the agent,
  instead of reporting only that the log was non-empty (#427).
- Release initialization now audits every window fragment against the real-host drill before the round runs (#425).
- The drill re-asserts `repos.txt` after writing `notify-repos.txt` and aborts
  the round if the work set widened (#423).
- `drill/teardown.sh` removes the per-role `crew-drill-<role>-notify` sandbox
  (#423).
- Builder sessions declare complete rounds without waiting for checks; the engine gates panel requests until the head settles (#402).
- Adopt ceremony `0.6.2`: every pin moves off `0.6.0`, across `release.yml`, `release-guards.yml`, `labels.yml` and `labels-sweep.yml` (#398).
- The vendored doctrine carries ceremony `0.6.1` and `0.6.2`: a round is declared answered as soon as its fixes are pushed, the pending-check wait belonging to whatever mediates the request (#398).
- `.ceremony/RELEASES.md` now says how a release window advances past a member that lands `post-merge` — triage splits the remainder, and the original's close is the release edge (#398).
- Every install channel ships only what an installed tree runs:
  `fleet-floor/dev/`, the page sources, the test suites, the drill and the
  repository's own furniture are no longer installed, leaving the tree under 2M
  whether it came from a checkout, the scp-able artifact, `gh` or `curl`
  (#365).
- Adopt ceremony `0.6.0`: every pin moves off `0.5.0`, across `release.yml`, `release-guards.yml`, `labels.yml` and `labels-sweep.yml` (#350).
- A changelog fragment entry must now end with its issue citation — one parenthesised group, then the final `.` — and the `changelog-armed` guard refuses anything else (ceremony#262, #350).
- The issue sweep now comments on undeclared collision edges, on an unblocked non-member during a standing release window, and on a `post-merge` item starved of wake evidence for 7 days (#350).
- The builder's `no build duty` line now names its cause: an empty board, a seen-ledger suppression with its count, or the slot held by an open PR — named, with the board's live ready count beside it (#345).
- `drill/rehearsal-all.sh` tears the round down when every leg passed; `--keep`
  retains it, and a round that failed or never reached phase 2 keeps its boxes
  and prints the teardown command (#217).
- A teardown that could not inspect part of the round gets its own
  `INCOMPLETE` row in the rehearsal summary and reds the round, rather than
  reporting `ok teardown (boxes and sandbox repos removed)` (#217).
- A rehearsal whose target box already exists refuses, naming the box, its
  creation date, and the two ways forward. `--reuse` keeps it and records that
  the pre-auth checks skip and why (#116, #217).
- The fleet floor draws a console only for boxes that are deployed: one never
  created or never hired is counted but not drawn, a stopped or unreachable one
  keeps its console, and a floor with none of them names `crew hire` (#204).
- The hygiene sweep pushes a dirty merged-branch worktree's uncommitted work —
  untracked files included — to a `wip/<branch>` ref before removing it, and
  removes it only once that push has landed (#168).
- The preservation is also recorded upstream, as a comment on the PR the
  worktree belonged to naming the remote, the ref and what it holds: the ref
  lives on a fork, which an org-level action can take away, and the comment
  cannot (#168).
- A push or a record that fails leaves the worktree and its work untouched,
  reported once as before (#168).
- The removal log names the ref, the remote and the `git fetch` that gets the
  work back (#168).
- The counts in that record list every preserved file, including files under a
  directory nobody had committed yet, and a worktree whose state cannot be read
  at all is kept rather than described as empty (#168).
- Staged content is preserved too: where the index holds a different version of
  a file than the working tree, it is kept as the commit below the `wip/` ref's
  tip, named in the record and reachable with `git checkout FETCH_HEAD^` (#168).
- A worktree whose only uncommitted work was staged and then reverted in the
  tree is now preserved and released, instead of being refused on every sweep
  forever (#168).
- Fix rounds return to draft when the panel closes a round without full approval (#139).

### Fixed

- The `pipefail`/`grep -q` guard now reads `cli/crew`, `install.sh`, `shared/install.sh`, `dist/*.sh` and `shared/lib/version-skew.sh`, so a regression in them can no longer pass with the suite green (#449).
- Remote-shell payloads are exempt from that guard by their shape rather than by filename (#449).
- Duty predicates now match completed producer output without `pipefail` race failures. (#447).
- Predicate checks no longer intermittently misread successful output under `pipefail` when `grep -q` exits early (#443).
- The rehearsal summary now reports the resume leg's own verdict instead of inferring it from the builder role's exit code (#435).
- The drill exits non-zero when teardown could not restore `repos.txt` or
  `notify-repos.txt`, including when the box stopped answering (#423).
- The drill's teardown reds when the pre-drill `repos.txt` backup the round
  made is gone, instead of reading a measured loss as "nothing was backed up"
  and vouching for a registry nobody compared (#423).
- The drill's notifier leg refuses to choose its second sandbox when the
  host's pre-drill work registry cannot be read, instead of checking the
  candidate against a watch set silently short of that half (#423).
- The drill's notifier leg tracks a handoff fixture from the moment its PR is
  created, and retries a close that failed, so neither a labelling failure nor
  a failed close leaves an open handoff PR occupying a later builder slot
  (#423).
- The drill skips the notifier leg when the configured operator chat is
  unreachable, instead of grading a valid bot token with an unusable chat as a
  leg failure (#423).
- The rehearsal round removes both the notifier leg's and the worktree-hygiene
  leg's per-round temporary files (#423, #422).
- The triage drill now proves post-merge issues remain untouched and launch no session (#417).
- Membership predicates no longer misread existing boxes, roster entries, drill sandboxes, or cron daemons under load (#411).
- Make reused-box install drills require a tick written after console removal (#408).
- Phase 0 stages the tracked source tree required by the repository fixture suite while excluding the unused fleet-floor development assets (#407).
- Guard every attributed builder-doctrine quotation in prompts against drift in either file (#406).
- Playwright dependencies installed at any repository depth are ignored, and the documented setup no longer creates package manifests (#405).
- Near-miss and post-threshold stranded resume lanes stop dispatching repeatedly after three zero-action attempts at one head (#403).
- Terminal agent failures stop their session lane after three attempts, alert the operator once, and resume automatically after recovery. (#388).
- Kimi sessions distinguish quota termination from transient failures and report whether they used tools. (#388).
- A builder session parked on a running check is now woken by that check finishing: the head's newest check conclusion joins the resume fingerprint (#384).
- A ready PR at a green head with no round-answered signal naming it is resumed on the next tick instead of the twelfth; pending and red heads still wait the full twelve (#384).
- A draft carrying a valid current-head signal at a green head with no panel requested is resumed rather than suppressed. The engine buys the session; the flip stays the builder's (#384).
- The resume prompt quotes ceremony `0.6.0`'s parked-resume sentence again, so it no longer attributes wording to `.ceremony/BUILDER.md` that the vendored doctrine does not contain (#363).
- `resume-prompt-quotes-the-doctrine` compares whitespace-normalised text, so a re-vendor that only rewraps the vendored prose can no longer red `main` while every word still agrees (#363).
- `shared-ci` runs on `.ceremony/**`, so a doctrine re-vendor is checked in its own PR instead of surfacing against the next unrelated merge (#363).
- Triage duty records post-session board state and suppresses unchanged unblockable leads instead of waking itself again. (#359).
- The triage engine's board scan counts `post-merge` as a queue label, so an
  issue in that state is no longer reported as a stray on every tick (#358).
- `blocker:unrequested` is no longer written while the head's checks are pending or failing, so a builder waiting out a run is not flagged for not requesting (#350).
- `blocker:unrequested` now waits for the head and the round's newest verdict to stand still, so a round still in motion is not flagged (#350).
- `drill/install-drill.sh` step 9 no longer reds on a box hired minutes
  earlier: with no tick history to diff, it waits one cron boundary plus grace
  for a tick to land after the console removal (#341).
- Step 9's failure names which of engine, cron or tick went missing and what
  was read for it, instead of printing the removal's transcript (#341).
- `fleet-floor/test/cli.sh` no longer reds on a release tree: the `crew up`
  post-skip assertion accepts the already-hired skip as well as the re-bake
  (#323).
- The same case's failure message now names the box that was expected past the
  skip, instead of claiming the roster loop stopped (#323).
- A round-answered signal posted with its marker slot unrendered is now detected:
  the engine warns naming the comment, and the PR becomes due for resume on the
  next tick instead of the twelfth (#319).
- Resume reads each ready PR's comments again, so a PR that signalled correctly
  is no longer counted as unsignalled (#314, #319).
- Operator notifications now cover every repository the fleet works in (#316).
- `notify-repos.txt` now adds cross-repo handoff targets instead of replacing the work registry (#316).
- Fleet Floor state filters now separate deliberately disarmed boxes from genuinely silent ones. (#312).
- `crew status <box>` now reports an unanswered engine probe as unknown instead of inferring that the box was never hired (#308).
- Builder attention wakes dispatch new builds to the normal duty tick and report timed-out pickups on the issue and operator channel (#301).
- Kimi boot checks now use the guarded non-interactive command and resolved credential home used by duty sessions (#240).
- `crew up --dry-run` now reports hires for new boxes and summarizes every planned fleet action. (#218).
- Every release publishes the scp-able installer `crew-<version>.sh` as an
  asset, whichever door cut it (#98, #210).
- The browser walk's `gh ✓` check runs only over armed, ticking boxes, and
  reports that it did not run where there are none (#190).

## 0.1.1 — 2026-08-03

### Added

- `shared/docs/rehearsal.md` names `--remote` / `CREW_DRILL_REMOTE` as the way to rehearse against a fork (#302).
- The duty engine converges git identity before the first duty of every tick, and runs no session on a box whose commits would name another droid (#294).

### Changed

- Fleet Floor: grok's anatomy rebuilt under the blind-verifier loop protocol — predator arms with articulated talons, one committed key light, hard-point optics, grounded digitigrade feet — plus a `FLOORDEV.renderSolo` dev hook for droid-only studio renders (#289).
- CONTRIBUTING: a changelog fragment carries one entry per distinct user-visible change, with the reader test that decides it (#268).
- CONTRIBUTING: names which changelog rules block a review and which ride an approval as a nit — bullet count is editorial (#268).
- Adopt ceremony 0.4.1 (crew#259): a new `labels-sweep.yml` caller carries the
  reconcile sweep, with the hourly cron and the bootstrap dispatch relocated
  out of `labels.yml`, which gains `actions: write` for its trigger dispatch
  (ceremony#209).
- Sweeps now run detached from PRs: a queue-displaced sweep can no longer land
  a cancelled `reconcile` check on a PR, or set `blocker:ci-red` off its own
  displaced run (ceremony#208).
- `crew new`, `create-all`, `hire`, `hire-all`, `up`, `down`, `upgrade` and `gold` refuse under the shipped example fleet definition, naming `crew init` (#216).
- `crew status`, `crew profiles` and `crew up --dry-run` still work there, and say they are reading the shipped examples (#216).
- `examples/repos.txt` ships empty, so `crew init` seeds a fleet aimed at nothing until the operator names a repo (#216).
- The `fleet.conf` / `repos.txt` completeness check runs on the shipped examples too, not only on operator definitions (#216).
- Fleet Floor: the fleet view is a conference call — a vertically scrolling grid of webcam tiles, one per box, each unit front-on in close-up over a static blurred role-colour backdrop (#209).
- Fleet Floor: each tile carries AR telemetry — uptime, idle over the last 24h, queue, signal, a heartbeat trace that flatlines with the box, the open session's timer, and a live caption naming the work item (#209).
- Note: both `#209` entries above describe work that shipped in `0.1.0`. Their fragment went unconsumed because `0.1.0`'s release PR merged twelve commits stale (#212), so this is the first section that could carry them; the published `0.1.0` section is left as it stands (#162).
- Fleet Floor: grok's unit is rebuilt as a grounded stalker — digitigrade stance with hard deck contacts, a built-in predator-mask face, and a slicked-back cable mane with state language (#206).
- Fleet Floor: grok keeps a purple spine-slit readout and a flight-lineage service record; the jetpack hover and its thruster wash are gone (#206).
- Note: both `#206` entries above describe work that shipped in `0.1.0`. Their fragment went unconsumed because `0.1.0`'s release PR merged twelve commits stale (#212), so this is the first section that could carry them; the published `0.1.0` section is left as it stands (#162).

### Fixed

- Resume dispatches only when a draft's head, a foreign comment or review, or its referenced issue has moved since the last resume — a parked draft no longer wakes a session every tick forever. The builder's own comments and reviews are excluded (#314).
- `shared/prompts/resume.txt` posts the resume marker only when the session is going to act on the draft (#314).
- A resume that makes no commit at one head three times running is suppressed until the head moves, with one WARN in `duty.log` naming the PR, the head and the count (#314).
- `shared/docs/rehearsal.md` clones `heavy-duty/crew` at `main`, the drill's own default, not a personal fork and its merged branch (#302).
- Author-specific review panels now keep each builder's paired reviewer identity out of crew's required roster. (#298)
- A box's git identity is derived from its gh credential, so commits are bylined by the account that pushed them instead of the account the box carried before an identity change (#294).
- `crew hire` and `crew upgrade` write the box's git identity when it is authenticated, and say plainly when there is no credential to copy yet (#294).
- The shipped `examples/notify-repos.txt` names the builder accounts' forks, so a `state:needs-human` PR pushed to one is swept instead of waiting for somebody to notice it (#294).
- A reviewer who requested changes is no longer re-requested forever at an unchanged head: one round-answered signal opens one round, and the verdicts answering it spend it (#286).
- A round-answered signal posted while a review round is still open now takes effect once that round closes, rather than requesting a reviewer mid-round (#286).
- Review requests and convergence use a repository's per-author panel when configured. (#285)
- `crew upgrade` now leaves operator-paused boxes paused. (#283)
- A hired box that has never ticked reports `waiting` for its `gh` and vendor
  credentials instead of `stale`, in `crew status` and on the fleet floor (#265)
- Builder ticks keep ready issues claimable after choosing one and repair ledgers that previously buried the queue. (#264)
- Session history distinguishes successful no-op runs and shows their final reply. (#256)
- Fleet-floor messages now carry the duty environment contract. (#255)
- Codex sessions use medium reasoning effort. (#255)
- A board signal created during a triage box's mention session wakes triage in the same tick, instead of waiting a full tick (#253).
- A mention session that clears the last board signal no longer launches a triage session on the pre-session reading (#253).
- Test suites ignore ambient crew and duty configuration. (#252)
- Round logs retain verdicts on their original head after GitHub re-points reviews during a base merge. (#249)
- `crew floor` refuses under the shipped example fleet definition, in the CLI and in `floor.py` alike: a console over a definition nobody wrote could arm cron, power-cycle boxes and start model sessions (#244).
- `floor.py`'s fleet-definition completeness check runs whoever owns the directory, matching the CLI (#244).
- Resume stranded unsignalled PRs and retry CI-red heads after their checks settle. (#243)
- Warn once when a PR waits for its round-answered signal. (#243)
- CI-red and attention fix rounds now receive the complete round protocol and finish with the answered-head signal. (#242)
- The kimi profile launches its CLI non-interactively (#240).
- The kimi profile resolves its credential home across `~/.kimi` and `~/.kimi-code` (#240).
- Scope labels now cover the full install channel and the engine's test gate. (#238)
- `crew status` prints the whole roster when a hired box has no duty log yet, instead of stopping at the first one (#224).
- That box's row reads `no ticks yet` (#224).
- Fleet overlap checks now skip and report unreadable GitHub event payloads without stopping crew commands. (#223)
- Installer completion messages now report the recorded source provenance. (#222)
- `crew status <box>` reads `no ticks yet` on a box hired minutes ago — the
  same words its table and the floor already use for that box — naming the duty
  log it waits for and the tick that writes it, instead of `(unreachable)`
  (#221).
- The same view on an un-hired box names the absent engine rather than the
  missing log (#221).
- `crew status`: an un-hired box whose tenant role never converged reads `INCOMPLETE` and its note names the bootstrap recovery instead of `crew hire` (#220).
- `crew hire`: refuses a box rig never converged, naming what is missing; `--force` overrides (#220).
- `crew hire-all` and `crew up`: skip such a box, name it in the summary, and exit non-zero, while still hiring every healthy box in the same run (#220).
- `crew status <box>`: reports the rig role marker and which rig converged the box (#220).
- `crew create-all` continues after box failures and reports created, existing, and failed boxes (#219).
- The fleet floor's page names a paused box PAUSED and a disarmed one DISARMED
  in the headline, the CRON vital, the big card, the status line, the
  alert-coloured `silent` counter and the stage counts, so SILENT is reserved
  for a box that should be ticking and is not (#203).
- Fleet Floor now measures box liveness and session recency without mixing host and guest clocks. (#181)
- The engine reports a dirty worktree it left behind once per worktree and dirt state, not on every tick (#167).
- That report names the branch the worktree holds and the `git worktree add` failure it will cause (#167).

## 0.1.0 — 2026-07-31

### Added

- A `curl | bash` install channel, `dist/curl-install.sh` — the latest release by default, `CREW_REF` for a tag or the tip, and a refusal rather than a silent fallback when no release resolves. Temporary: it goes when crew moves off GitHub (#171).
- `crew status` reports engine integrity — `current`, `modified` or `unverified` — from a content hash of the installed engine tree, and names the files that differ (#159)
- `crew upgrade` and `crew hire` refuse to overwrite a modified engine, naming what differs; `--force` overwrites it (#159)
- installing converges the engine tree to what the version ships: anything the incoming tree does not carry — a file, a symlink, any entry that is not a directory — is moved to `~/duty/legacy/`, named on the way, rather than left behind and recorded as shipped (#159)
- the engine's own directories count as shipped content too: `~/duty/bin`, `lib`, `prompts` or `conf` redirected through a symlink now reads `modified` (#159)
- installing replaces such a redirect with a real directory holding what was behind it, and parks the link in `~/duty/legacy/` as evidence of where it pointed (#159)
- `fleet-floor/dev/whiteboard.html` — every robot, room and state as one asset map, built from `src/` and rendered by the app's own engine (#142)
- The engine sets `state:addressing` when a review round closes without full approval — the reviewer that lands the last verdict writes it, without waiting for the scheduled reconciler (#130).
- `drill/rehearsal-all.sh` drives the installer drill’s offline harnesses and five real-box observations into Section A record output (#117)
- Self-contained, offline, scp-able installer per version — `dist/make-installer.sh` builds `crew-<version>.sh`, a stub that verifies its payload checksum before unpacking and installs with no network, `curl` or `gh` (#98).
- `crew --version` prints the version and the install root it ran from — the root is how you settle which `crew` you ran when two are on PATH (#97)
- `crew help <command>` for every verb, rendered from the same table that dispatches it, so the help cannot describe a command the code does not have (#97)
- A typo'd command now suggests the nearest verb instead of only failing (#97)
- `crew versions`, `crew use`, and `crew uninstall` manage side-by-side host installs while reporting engine skew and protecting unattended fleets (#96)
- `install.sh` installs `crew` into a versioned layout (`versions/<v>`, a `current` symlink, `crew` on `PATH`), per-user with root refused — re-runs converge, a new version flips the default and reports engine skew (#95)
- `cli/crew` resolves its root through the `current` symlink so it runs the same from a checkout or an install (#95)
- crew adopts heavy-duty/ceremony's release and labels flow: tagged releases through both doors, a managed label taxonomy with per-scope `scope:*` labels, a `VERSION` a second fleet can pin, and the `.ceremony/` doctrine mirror verified on every PR (#84)

### Changed

- `fleet-floor` — the deck station in front of each unit belongs to its room now, instead of one undesigned plank drawn three times (#174)
- `fleet-floor` — a welding bench with a vise and a drawer chest, an inspection bench with a lens and a specimen, and a plotting table on a pedestal with a top tilted towards the camera (#174)
- `fleet-floor` — five polish passes over those stations: silhouette and value, construction, material and wear, light, and state (#174)

- `fleet-floor` — the deck station moved into the near plane, in front of the unit instead of beside it at the same depth, and is drawn in the top face's own perspective (#174)

- `fleet-floor` — ten loops on the near plane: a waist-height worktop that occludes the light behind it, the faces cut for the full height, an overhung apron, and per-room top materials (#174)
- `fleet-floor` — the near plane grows company and state: a companion prop per room (`LAYOUT.nearSide`), the unit's vendor colour on the back arris, the beacon's pulse on the offline station, motion while working, and a god-view crop that keeps the toe in frame (#174)
- `fleet-floor` — five loops on the residents: codex stands tall enough to use the bench, offline kimi sags to parking altitude instead of vanishing behind it and catches the beacon, and the near plane gains a left side and its wiring (#174)
- `fleet-floor` — five loops on the light, each crossing every room and robot: the unit shades the bench, the room's lamp lands on the unit, the worktop reflects who stands at it, shadows take the floor's colour, and near dust drifts in front of the subject (#174)
- `fleet-floor` — the god-view cell renders the real room instead of a second copy of one, so a room fix reaches the console, the grid and the map at once; the fleet view drops from ~92ms/frame to vsync as a side effect (#142)
- Vendor ceremony 0.4.0 doctrine, templates, workflows, and release guards. (#140)
- `shared-ci` does not run while a PR is a draft, and runs at the head the moment the PR is marked ready for review — the gate reads the event payload's draft bit, never a label (#136)
- The engine requests and re-requests the review panel, keyed off the session's round-answered signal rather than a builder session performing the request; `state:bots-reviewing` is set in the same act, and the reconciler stays authoritative (#133).
- The session no longer requests reviewers: it answers the round and posts the round-answered signal, and keeps only the argued-exception request under a red head genuinely outside the PR (#133).
- The labels board sweep runs hourly and ignores issue label and assignment churn while retaining immediate queue transitions (#131)
- The `state:addressing` write is optimistic and best-effort; the reconciler stays authoritative and corrects any write it would refuse (#130).
- Hosts ship crew engines directly to boxes, removing box-side crew repository access from hire and upgrade (#99)
- A bad invocation exits **2**; a real failure still exits **1**. Both used to be `1`, so a caller could not tell "you typo'd" from "the fleet is broken" — the boundary is the invocation versus the world, with the roster and profiles counting as configuration and boxes as state (#97)
- `crew status <box>` fails with exit 1 when the named box does not exist, rather than printing `(unreachable)` and succeeding. A box that exists but is merely stopped is unchanged (#97)
- A value-taking flag with no value (`crew new --agent`, `crew floor --port`, …) exits 2 instead of dying through Bash's own unbound-variable handler at 1 (#97)
- `crew up` and `crew hire-all` refuse an unrecognised flag instead of silently ignoring it — `crew hire-all --dry-run` used to hire the whole fleet while reading like a rehearsal (#97)
- An argument beyond a verb's synopsis is refused instead of silently ignored — `crew help hire unexpected` used to print hire's help and exit 0 (#97)
- A malformed `--ref` exits 2 and is refused at parse time rather than per box, so `crew hire-all --ref -bad` can no longer exit 0 against an empty roster (#97)
- handoff no longer spends an agent session or a repository clone: the engine requests the human's review, sets `state:needs-human`, and posts a factual handoff comment (approvals at the current head, the head SHA, and a pointer to the PR body's Round log) itself (#91)
- the closing prose it used to reconstruct at the end now lives in the PR body's `## Round log`, mirrored there mechanically from each whole-round reply — so no model is spent at handoff (#91)

### Fixed

- fleet-floor: the browser walk asserts the engine version by **shape** on a real fleet — some box renders a semver, and none renders a raw `crew@…` stamp or an unparseable `unknown` (#202).
- fleet-floor: the walk's exact-value engine check moved under the fixture gate. Pinned to the stub's `crew@0.4.1 (deadbee)` but gated on `LIVE` alone, it failed by construction on every real-host drill and read as an app defect (#202).
- fleet-floor: a box whose crontab holds no live `tick.sh` line now reads **disarmed** instead of `SILENT`. SILENT is an alarm meaning "this box should be ticking and is not", and spending it on a box nobody armed is how the drill's floor-vs-CLI agreement check skipped five consecutive runs (#189).
- `crew status` can answer "is this box armed?" at all, from the same crontab patterns `probe.sh` uses, so the CLI and the console stop holding private truths about it. A paused box is told to resume; an unarmed one is told to hire (#189).
- fleet-floor: `wake-silent` no longer sends a resume to boxes that have no commented crontab line to restore, which reported a failed row for every unarmed box in the fleet (#189).
- `pause` and `resume` no longer report a zero crontab count as a refused command; a box with no armed `tick.sh` line answers `nothing to pause` (#188).
- The drill exercises the console's control verbs against a tick line it arms itself, and leaves the box disarmed on every exit path (#188).
- The operator-config rehearsal now completes against boxes without a crew checkout. (#187)
- The installer drill hires its box as the agent and roles that box already carries, instead of a hard-coded `claude reviewer` that re-roled the box the later drill phases share (#180).
- A review re-request at an unchanged head is serviced instead of silently skipped: the reviewer now also asks whether the request postdates its own verdict, the same test `rereq_decision` makes before waking it (#178).
- An approval is of a tree, not only of a commit — an issue amendment or a ruling can change the right verdict while the head stands still (#178).
- The release drill installs through `crew hire` rather than calling `install.sh` directly, so it exercises the staging the fleet actually performs instead of a path no operator takes (#177).
- `crew hire` no longer exits silently on a box that has never been hired: `box_registry` and `production_registry` pipe into an assignment under `set -euo pipefail`, so an absent or all-comment registry killed crew with no message — including on a second operator's first `crew up` (#176).
- Builder handoff queries respect GitHub's page limit and reject GraphQL error bodies before acting (#155)
- Builder duty reserves its active slot for any open authored PR and makes issue claims race-safe. (#152)
- A re-request over a standing block wakes a real re-review even where `AUTO_APPROVE_REREQUEST=0`; the flag now governs only the approval (#151)
- Builder wakes preserve current-head change requests after later review comments. (#147)
- Duty check state now uses the latest run of each check name, ignoring superseded same-head cancellations (#146).
- `fleet-floor` — the offline alert lands on the unit for all four vendors, in both views: it was pinned to the sprite's bounding box in the grid and to the visor in the room, and neither is the head of a spider or a drone (#142)
- `fleet-floor` — a powered-down kimi is no longer cut in half by the bench it settled behind (#142)
- `fleet-floor` — the builder's conveyor no longer runs ten pixels through the workbench top (#142)
- The review duty no longer auto-approves over a standing request-changes — a re-request queues a real review round and admits that round's verdict, while a bare re-post is still refused (#114)
- Engine stamps use the crew version across installed and checkout-based trees, with an optional Git SHA retained only as provenance (#94)
- a fleet-wide `start-all`/`stop-all` no longer fails the whole fleet over a roster box `crew up` has not created yet — an absent row is inventory drift, and 500 is reserved for a box that was there and refused (#77)

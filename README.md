# CodexReset

This is [ryoma-oss's fork](https://github.com/ryoma-oss/codex-reset) of
[boyso/codex-reset](https://github.com/boyso/codex-reset). Original MIT license and attribution are retained.

## Desktop delivery verification

GUI sends use **Enter**. Codex must be configured to send messages with Enter.
Before typing, the app reads the target chat's last user-message ordinal from
local history. It reports success only after a new user message ending with the configured command appears in
that same chat within 15 seconds. This confirms delivery, not execution or Goal
activation. Delayed history writes may cause an unconfirmed result even when the
message was sent; inspect the chat before retrying. There is no automatic retry; a failed chat does not stop the remaining selected chats.
The handled-chat set resets when quota transitions from limited to available,
so a previous manual test does not suppress a later recovery cycle. Overlapping
manual and automatic batches are blocked. Target and editor focus are checked before input; missing or ambiguous accessibility controls stop the operation.

Delivery regression checks:

```bash
swiftc -lsqlite3 Sources/CodexReset/DeliveryReceipt.swift Tests/DeliveryReceipt/main.swift -o /tmp/codexreset-delivery-test
/tmp/codexreset-delivery-test
```

Goal-state regression checks (no live UI input):

```bash
swiftc -parse-as-library -lsqlite3 Sources/CodexReset/GoalState.swift Sources/CodexReset/BoundedTreeScan.swift Sources/CodexReset/ResumeAttempts.swift Sources/CodexReset/DesktopGoalAutomation.swift Sources/CodexReset/SQLiteReader.swift Tests/GoalAndMessage/Test.swift -o /tmp/codexreset-goal-test
/tmp/codexreset-goal-test
```

## Activity log archive

Logs are written locally to `~/Library/Logs/CodexReset/activity-YYYY-MM-DD.jsonl`
(UTC file names, ISO 8601 timestamps, Chinese and English messages). On startup
and each log write, entries older than seven days are removed. If the app is
not running, cleanup happens at the next launch. The Log tab shows the most
recent 1,000 entries, restores them after restart, and provides an **Open log
folder** button. The files retain all entries within seven days without the UI
entry limit. Run the archive regression checks with:

```bash
swiftc Sources/CodexReset/ActivityLogStore.swift Tests/ActivityLogArchive/main.swift -o /tmp/codexreset-log-test
/tmp/codexreset-log-test
```

Archive errors appear in the Log tab. Existing in-memory logs from
older builds cannot be recovered automatically. Logs may contain local paths,
chat names, configured commands and error details; they stay on this Mac.

## Changes in this fork

- Remove broad startup `pkill`; clean up only the server process owned by this instance when connection fails.
- Desktop continuation sends a message through the GUI instead of starting a turn through an app-server, to avoid acquiring a conversation writer lock.
- Prefer actual conversation names over initial messages in the chat picker.
- Fix unreadable settings colors.
- Show five-hour **remaining** percentage and ring in the menu bar; the panel still shows usage. Reset countdown is in the menu-bar tooltip.

**Goal resume + message:** **Try Goal resume + send command** is enabled by default in Settings. The app makes two independent attempts, first Goal resume and then command delivery. It verifies the target chat through an exact window title or selected accessibility item. The Goal path clicks one uniquely labeled resume button for a `paused`/`usage_limited` Goal and waits up to 15 seconds for the same Goal to become `active`. Its failure never blocks the command path: a Goal DB error, missing button, or unconfirmed activation is recorded and the app still tries to send the command. Already-active/no-Goal/other Goal states skip the button. Each path reports its own result; one confirmed path counts as partial success. Failed chats do not stop the remaining selected chats. Goal databases are read-only; no app-server thread writer is acquired. Transient SQLite busy/locked/schema/protocol/read-only failures are retried up to three times by reopening the connection; detailed SQLite errors and retries are logged. Persistent Goal read failures are logged; the independent command attempt still proceeds.

This feature requires Accessibility permission and depends on Codex's accessibility tree. Japanese `目標を再開`, English `Resume goal`, and Chinese labels are supported. Missing/ambiguous Goal controls or unconfirmed activation fail the Goal path only. Each path independently verifies the target chat and focus before its own input. Goal buttons and the composer are reacquired while waiting for UI readiness. Accessibility scans process queued nodes even when the admission limit is reached, deduplicate cycles, and expand from 6,000 to 20,000 nodes if needed, with per-scan time limits. Logs include visited/pending counts, limit/timeout flags, child-read error codes, frontmost app, active/hidden state, permission state, and raw/usable composer counts. Input values and full page contents are not logged. Unmatched resume-related labels and enabled state are logged. Composer identification requires one enabled multiline editor. At the user’s explicit request, the app keeps the existing draft, moves to the end of the verified composer, appends the configured command, and presses Enter. It does not check whether the composer is empty. Delivery confirmation accepts a new user message ending with the command, including a combined draft-plus-command message. The developer's computer-use tool cannot control Codex itself: **the new UI path has not yet been validated end to end**. Initial testing must be performed by the user with one selected chat. Some upstream notifications remain Chinese with English selected.

<img width="1280" height="258" alt="image" src="https://github.com/user-attachments/assets/766c58f1-5264-469b-b641-bfe8787caefa" />

**An app that keeps Codex on the job.**

A tiny macOS menu-bar companion for the **Codex** desktop app. It watches your
5-hour / 1-week usage windows, detects conversations that were paused because
you hit your usage limit, and **automatically resumes them with “继续” (or any
command) the moment your usage is back** — so you never have to babysit the
"upgrade / try again at HH:MM" wall again.

> Not an official OpenAI product. CodexReset is an independent, open-source
> utility that only talks to the local Codex app on your own machine.

---


<img width="2048" height="1218" alt="image" src="https://github.com/user-attachments/assets/c4ddef65-c347-40ff-8487-13db60605e76" />




## Why

When a Codex session hits its usage cap, Codex pauses the active conversation
and says something like:

> You've reached your usage limit. Upgrade your plan or top up to continue, or
> try again at 13:18.

Usage resets on a rolling **5-hour window**, and every paused conversation has
to be manually continued by switching to it and typing "继续". If you run
several agents/projects at once, that's a lot of babysitting.

**CodexReset does it for you.**

## Features

- **Menu-bar status** — live 5h / 1w usage bars, next-reset countdown, plan
  type and credit balance at a glance.
- **Auto-resume** — when the 5h window resets, CodexReset automatically sends
  "继续" to the conversations you've checked. Nothing is pre-selected: tick the
  paused conversations you care about (or hit "select all"), or add any other
  conversation from the full list.
- **Browse all conversations** — every project and its conversations are listed
  (grouped by project, archived and sub-agent threads filtered out). Check any
  conversation, even one that isn't paused yet, to have it resumed too.
- **Double-click to jump** — opens the conversation in Codex via its deep link.
- **Usage history timeline** — each 5h window reset is recorded automatically,
  so you can see the exact time usage recovers every day.
- **Detects pauses for you** — conversations stopped by
  `usageLimitExceeded` are found automatically, with their recovery time shown.
- **CLI mode** — `--query` prints usage, `--continue <thread_id>` resumes one
  thread from the terminal.

### How auto-resume works

The menu-bar app reads quota information through a local app-server. For
continuation it deep-links into Codex, focuses the composer, pastes the configured
message, and sends **Enter**. Accessibility permission is required. It does not
use the app-server to start turns. The optional upstream `--continue` CLI mode
still uses its original app-server-first behavior.

## Requirements

- macOS 14+
- The [Codex desktop app](https://openai.com/codex/) (this is a companion, it
  doesn't bundle Codex itself)
- Xcode command line tools for building (`xcode-select --install`)

## Install & run

### Build

```bash
git clone https://github.com/ryoma-oss/codex-reset.git
cd codex-reset
swift build -c release
```

### Use as a menu-bar app (recommended)

```bash
./make_app.sh              # builds & installs /Applications/CodexReset.app
./install_launchagent.sh   # (optional) auto-start at login via LaunchAgent
```

Then click the menu-bar icon to open the panel. Optionally:

- Give **CodexReset** Accessibility permission (System Settings →
  Privacy & Security → Accessibility) so the GUI fallback channel can type into
  Codex. The panel shows a live "Accessibility" status so you know when it's
  granted.
- **remote_control** can be used for local quota queries. Desktop continuation
  still requires Accessibility permission. Rebuilding with an ad-hoc signature
  can require granting that permission again.

### CLI only

```bash
.build/release/CodexReset --query                    # usage + paused threads
.build/release/CodexReset --continue <thread_id>     # resume one thread now
```

## Configuration

| Setting | Where |
|---|---|
| Auto-resume on/off | panel toggle `用量恢复后自动继续` |
| Command sent | panel `指令` field (default `继续`) |
| Which conversations | checkbox list in the panel |
| `remote_control` | panel toggle (writes `config.toml`) |
| `CODEX_HOME` | env var overrides `~/.codex` (advanced) |

## Privacy

- CodexReset reads only **local** files (`~/.codex` state and history
  databases, read-only) and talks to Codex's local app-server over a local
  socket.
- No data leaves your machine. No account, no telemetry.

## Building the .app icon

`Resources/generate_icon.py` turns a transparent-background/irregular
`logo.png` into a proper `AppIcon.icns` (center-padded to a square canvas,
LANCZOS scaling). Replace `logo.png` and re-run `./make_app.sh`.

## Contributing / disclaimer

PRs and issues are welcome. This project was reverse-engineered from local
behavior and may break when Codex updates — please open an issue with the
error and version. Use at your own risk; automated "继续" will consume usage in
the normal way within your plan.

## License

[MIT](LICENSE) © 2026 BOYSO

# Remote workspaces — design

Date: 2026-11-27. Status: APPROVED 2026-11-27 (builder check done). Target: the release after 0.1.0. It is not part of 0.1.0.

## Intent

The user runs a Mac mini as a server and wants to use Alloy on a laptop while the work happens on the mini. Later the same should work against a cloud dev box such as a Linux VPS. The project's files, git, terminals, language servers and agents all live on the server. The laptop is the window: editor, chat, panels.

Agents and terminals keep running on the server when the laptop sleeps, loses Wi-Fi or quits. Reconnecting puts you back where you were, with chat caught up, terminal output intact, and tabs and open files as you left them.

## Decided by the user

- **Approach A (below):** split at the edges. The laptop keeps the UI and editor buffers, and everything that touches the machine goes over one connection to a server program.
- **Targets:** the Mac mini first, then a Linux VPS.
- **Persistence:** agents and terminals keep running on the server across disconnects, so you can reconnect and carry on.
- **Disconnected:** the window stays up, read-only, with a "reconnecting…" banner. There's no offline editing or merging.
- **Timing:** this ships in the release after 0.1.0.
- **More than one laptop:** plan for several Macs attaching to the same server project over time, though in practice it will mostly be one laptop. Shared project state lives on the server, and each Mac keeps only its own window layout.
- **Mini after a reboot:** someone unlocking the mini at its screen (FileVault) before remote sessions can use Claude's Keychain sign-in is fine.

## Goals

1. Open a project on a remote host from the laptop and edit, save, browse, search, use git, run terminals and chat with agents. It should feel like a local project, except that requests make network round trips.
2. Typing, scrolling and drawing perform exactly as they do locally, because buffers and rendering stay on the laptop.
3. Agent sessions (Claude and ACP), terminals and the work they do survive disconnects and laptop quits. Reconnecting replays what you missed.
4. No manual server setup beyond SSH access. Alloy installs and updates its own server program over SSH.
5. Local projects behave and perform exactly as they do today.

## Non-goals

- Offline editing, or merging edits made while disconnected.
- Several laptops attached to the same project at once. In v1, a second connection takes over from the first.
- Windows as the server.
- Collaboration between users.
- Forwarding ports, for example opening a dev server running on the mini in the laptop's browser. That's a likely follow-up.
- Running Alloy plugins on the server. Plugins stay on the laptop and reach project files through the connection.

## Anti-goals (failures even if it "works")

- Local projects get slower, heavier or more complex at runtime. The local path must stay direct calls, with no extra hop.
- Alloy stores any key, password or token in a file or in plaintext. SSH handles sign-in through ssh-agent, the Keychain or Tailscale SSH. Alloy keeps only host names.
- The server program opens a network port. It is reachable only through SSH and a user-only Unix socket.
- A missed code path quietly reads or writes the **laptop's** disk for a remote project. This is the worst one, because the same path, for example `~/Developer/Alloy`, often exists on both machines.
- The server program uses noticeable CPU or memory while idle.

## Approaches considered

- **A. Split at the edges (picked).**
  - The laptop runs today's app.
  - Every place that touches the project's machine goes through a `Host` seam, with two implementations:
    - `LocalHost` is today's direct code, moved behind the seam.
    - `RemoteHost` talks to `alloy-host` on the server.
  - Long-running work (agents, terminals, language servers) lives on the server and streams to the laptop with replay.
  - This is how VS Code Remote and Zed remote work. Typing stays instant because buffers stay on the laptop.
  - The cost is a wide but mechanical refactor of about 110 file sites and 10 process sites.
- **B. Run the workspace model on the server and mirror it.**
  - Reconnecting comes naturally, but Alloy's views bind directly to the `@MainActor` `Workspace` and `Session` objects. Mirroring them means rebuilding how almost every view gets its data.
  - Typing would also lag, or need a local buffer anyway, which brings you back to A.
  - Rejected as a much bigger rewrite for the same result.
- **C. macOS Screen Sharing to an Alloy running on the mini.**
  - Works today with nothing to build, but it is laggy and blurry, and impossible on a Linux box with no screen.
  - Not a design, but usable in the meantime.

## Architecture

```
 Laptop: Alloy.app                                   Server: alloy-host (daemon, per user)
 ┌───────────────────────────────┐                   ┌──────────────────────────────────────┐
 │ UI, editor buffers, Workspace │                   │ project files, watcher, index, search │
 │   ↓ Host seam                 │   ssh <host>      │ git                                   │
 │ RemoteHost ── mux connection ─┼── alloy-host ─────┼─ unix socket (0700) ─┐                │
 │   (reconnects, resumes)       │     bridge        │                      ↓                │
 └───────────────────────────────┘                   │ agents (Claude, ACP) + replay rings   │
                                                      │ terminals (pty) + byte rings          │
                                                      │ language servers                      │
                                                      └──────────────────────────────────────┘
```

### 1. The Host seam (laptop side)

There is one `Host` per workspace, injected into `Workspace.init` next to the existing factories. It groups these capabilities:

- **`HostFileSystem`:**
  - stat, and read with stamp (`readForEditing`);
  - write atomically with an expected stamp and kept mode (`write` / `replaceAtomically`);
  - list directory, exists, remove, rename, create directory;
  - `realpath`, and the home directory.
  - Every project-file site goes through it (inventory below).
- **`HostProcesses`:**
  - run-to-completion (`GitProcess.run` becomes an instance call);
  - locate an executable, using the server's own login PATH and the server's layout;
  - spawn with pipes, for `ServerLauncher` (LSP).
- **`HostIndex` and `HostSearch`:** `FileIndex` and `SearchEngine` run where the files are. Remotely they stream batches.
- **The seams that already exist are reused as they are:**
  - `FileChangeSource` for the watcher;
  - `PtySpawner` / `PtyHandle` for terminals;
  - `SessionTransport` / `ACPTransportFactory` for agents;
  - `ServerLauncher` / `RPCByteChannel` for LSP.

`LocalHost` is a thin wrapper over today's code, so local behaviour and performance are unchanged. This is verified in phase 0 by the full test suite and the existing frame and perf guards, with numbers appended to `Bench/results/perf-history.jsonl`.

App-local state stays on the laptop and never goes through the Host seam: settings, themes, plugins and their installer, the knowledge pool (SQLite), frame timing, the project picker.

**Per-project store (user decision: plan for several Macs).** Today it lives at `<appSupport>/Alloy/Projects/<sha256(root)>/`. For a remote project it splits in two:
- **Shared, on the server**, at `~/.alloy/host/projects/<sha256(server root)>/`: `sessions.json`, the ledger, claims, overlap and told files, notes, the read index and generations, plus `acp-history/`.
  - `Workspace` still writes these files, but through `HostFileSystem`, so any Mac that attaches sees the same sessions, edit history and notes.
  - Only one client is attached at a time, so there's one writer. The daemon's own while-away write log is a separate file, which the attaching client merges into the ledger.
- **Per Mac, on the laptop**, keyed by `remote:<host-alias>:<server path>`: `ui-state.json` (tabs, panes, folds, layout). Each Mac reopens to its own layout.

**Path identity.**
- A remote project's root is the server's absolute path, held as a `file://` URL whose meaning belongs to the Host.
- All path normalisation goes through the Host: `resolvingSymlinksInPath`, `realpath` and the `/private` quirks.
- Watcher batches arrive already in the root form the consumers expect.

**Disk tripwire.** This is the guard for the worst anti-goal. Remote-mode tests use a root path that does not exist on the test machine, for example `/alloy-remote-test/<uuid>/proj`, served by an in-process fake host. If any code path touches the local disk for a project path, the test fails because the path is missing. The test suite runs the main workspace flows in this mode: open, save, tree, search, git and agent file writes.

### 2. `alloy-host` (server side)

- **What it is:** a new headless executable target. It depends on the lower layers only: AlloyCore's non-UI parts, AlloyRPC, AlloyACP and AlloyTerminal. It does not pull in MetalUI, AppKit, `Workspace` or AlloyHighlight. The existing `AlloyFake*` executables show the target pattern.
- **One daemon per user per installed version.**
  - It listens on `~/.alloy/host/<version>/host.sock`, with the folder at 0700 and the socket owned by the user.
  - `ssh <host> ~/.alloy/host/<version>/alloy-host bridge` starts the daemon if it isn't running, then pipes the SSH session's stdin/stdout to the socket.
  - Losing SSH drops only the bridge. The daemon and everything it runs carry on.
- **What it serves:**
  - the file system calls;
  - a watcher: FSEvents on macOS, inotify on Linux, with dropped events reported as a root rescan as today;
  - the index, search and git;
  - processes;
  - terminals;
  - agent sessions;
  - language servers.
- **How it starts on macOS:** as a launchd agent in the user's desktop (GUI) session (`launchctl bootstrap gui/<uid>`). That lets `claude` read its login Keychain item, which a plain SSH-spawned process often can't.
  - If no one is logged in at the desktop, for example after a reboot with FileVault, the connection explains "Log in at <host> once to enable agents". Files, git and terminals still work, started as an SSH-session daemon.
  - On Linux it runs as a `systemd --user` service (see Lifetime).
- **Lifetime (user decision): persistent.** The daemon never shuts itself down. It stops only when you tell it to: Alloy's "Stop Server" command for that host, or `alloy-host stop` on the server.
  - On macOS the launchd agent is `KeepAlive`, so it comes back after a crash and after your next login following a reboot.
  - On Linux it is a `systemd --user` service. Surviving logout needs `loginctl enable-linger`, which Alloy offers to run with one explanation and does not run silently.
  - "Stop Server Sessions" ends running agents and terminals but leaves the daemon up. "Stop Server" ends both.
- **Idle, low-memory state (user decision).** When no client is attached and nothing is running, the daemon goes idle:
  - It drops every per-project cache: file index, search state, git caches, closed-stream replay rings, and the watchers. Watchers restart, and the project rescans, on the next attach.
  - It asks the allocator to hand freed memory back (`malloc_zone_pressure_relief` on macOS, `malloc_trim` on Linux).
  - It runs no timers and does no polling. It only waits on its socket.
  - Target: under 15 MB resident and 0% CPU, measured and recorded in perf-history.
- **Idle with work running and no client:** it keeps only what that work needs (its processes, bounded replay rings and pending prompts) and drops everything else, the same as above.
- **Versions (builder-check call):**
  - The wire protocol carries a major version, separate from the app version. A newer laptop app attaches to an older daemon whenever the protocol major matches, so a Sparkle update never strands running sessions.
  - The daemon binary is replaced only when it has nothing running. On connect, the laptop says "server update ready, applies when sessions finish". At the next idle moment the daemon re-execs into the new binary, so it stays persistent across updates.
  - A protocol-major bump is rare and deliberate. When it happens with sessions still running, Alloy shows "N sessions are still running on the old server: open them with the old protocol, or stop them", and the old daemon stays reachable until they end.
  - Pending permission prompts count as running, so they're never lost.

### 3. Connection and protocol

- **Transport:** the system `/usr/bin/ssh` as a child process, with the bridge on its stdio. That gives the user's `~/.ssh/config`, ssh-agent, Keychain, ProxyJump and Tailscale SSH at no cost. Alloy never sees credentials.
  - For the mini, the user picks the host by its `~/.ssh/config` alias or Tailscale name.
  - **Sign-in methods (builder-check call):** v1 supports key-based sign-in only (ssh-agent, Keychain-stored keys, and Tailscale SSH). Alloy always runs `ssh -o BatchMode=yes`, so it never hangs on a hidden prompt.
    - A host that wants a password or 2FA fails fast with a dialog explaining how to set up a key.
    - An unknown or changed host key fails fast with a dialog showing the fingerprint. The first-time trust is done by running `ssh <host>` once in Terminal, and Alloy offers to open it.
    - Password/2FA (`SSH_ASKPASS` with ControlMaster) is a follow-up.
- **Framing:** one multiplexed stream of length-prefixed frames. Each frame has a channel id, a kind (JSON or binary) and a payload.
  - Control calls are JSON-RPC, reusing `JSONRPCConnection` over an `RPCByteChannel` that is one channel of the mux.
  - File contents and pty bytes go as binary frames, not base64.
  - Large reads are chunked so a big file never blocks terminal or chat traffic. Each channel gets fair, credit-based flow.
- **Resumable streams:**
  - Every long-lived stream (agent events, terminal output, watcher batches, LSP) carries a per-stream sequence number.
  - The server keeps a replay ring per stream:
    - **Agent sessions:** everything since the client's last acknowledged sequence. Agent output is small, so it's capped at 32 MB per session; beyond that the client reloads from the transcript files.
    - **Terminals:** a byte ring sized from the scrollback setting, capped at 8 MB per pane.
    - **Watcher:** anything older than the ring collapses into "rescan root".
  - On reconnect, the client sends `resume {stream: lastSeq}` for each stream and receives the gap.
- **Reconnect:** automatic, with backoff from 1 s to 30 s, plus an immediate attempt on wake and on network change. The banner shows "Reconnecting to <host>…" and a "Retry now" button.
- **Install and update:**
  - On connect, Alloy runs `uname -sm` and checks for `~/.alloy/host/<version>/alloy-host`.
  - If the binary is missing, Alloy uploads the matching binary bundled in Alloy.app over the same SSH connection (`cat > tmp && chmod && mv`). It then verifies a SHA-256 and runs `--version`.
  - The bundle ships macOS arm64 first, and Linux x86_64 and arm64 in phase 4.

### 4. Agents on the server

The agent protocol layer moves to the server so agents can work while the laptop is away:

- **Where the transports run:**
  - `ACPTransport` (an actor in AlloyACP, depending only on AlloyCore) runs inside `alloy-host`.
  - `ClaudeProcess` and its locator run there too, with the server's own `claude` and the server's own login.
  - The laptop's `SessionTransport` for a remote session is a client of that server-side transport. It sends `OutboundMessage`s and receives `ProcessEvent`s with sequence numbers.
  - `ProcessEvent` is already the single event model the UI uses for both backends.
- **Agent file access (`ACPFileHandling`):**
  - *While attached:* the server forwards `fs/read_text_file` and `fs/write_text_file` to the laptop, which keeps today's behaviour (buffer-aware reads, protected-path approval, overlap and claims checks, ledger records), with the disk part going back through the Host.
  - *While detached:* the server serves them straight from disk inside the same path policy (`ACPPathPolicy`, which runs on the server). It also logs each write as a "while you were away" entry. On reconnect those entries go into the laptop's ledger, and open buffers reload through the existing outside-edit flow.
  - Writes to protected paths while detached wait for approval, like permission prompts.
- **Permission prompts:**
  - Permission prompts raised while detached stay pending on the server. The agent waits, and the prompt appears when you reconnect.
  - A push notification is a later follow-up.
- **Alloy's MCP tools and hooks (`LocalServer`) (builder-check call, strict):**
  - Today these are an HTTP listener on the laptop's loopback. Claude's PreToolUse/PostToolUse hooks call it too (`Coordination/Hooks.swift`).
  - For remote sessions **no TCP port is opened on the server**, not even loopback, because other users on a shared VPS could reach it.
  - Instead the session's MCP config points at a stdio MCP server, `alloy-host mcp --session <id>`, and the hooks become command hooks, `alloy-host hook --session <id>`. Both talk to the daemon over the 0700 Unix socket, and the daemon tunnels each call over the connection to the laptop's `LocalServer` handlers.
  - While detached, tool calls return a clear "Alloy is disconnected" error, and the agent carries on with its own tools.
  - The session launch files (`mcp.json`, `settings.json` with the token) are written on the server, 0600 in a 0700 folder under `~/.alloy/host/`. The CLI that reads them runs there, and they are deleted when the session ends.
  - The token is a short-lived per-session random value, not a credential, but treat it as one: never logged, and kept out of any file other than that one launch file.
- **Credentials:** remote agents use the server's own logins (Claude signed in on the mini, the ACP agent's own config there). Alloy does not forward secrets from the laptop's Keychain.
- **Transcripts:**
  - Claude's live in `~/.claude/projects/...` on the server, and history is read through the Host.
  - ACP history (`acp-history/<session>.jsonl`) is written by the server-side transport into the server project store.
  - The session list (`sessions.json`) is in the server project store too. The daemon also keeps an in-memory registry of live sessions by id, so any attaching Mac can reattach.

### 5. Terminals

- **On the server:** `LivePtySpawner` runs inside `alloy-host`. The laptop's `PtyHandle` is remote: writes and resizes go out, and bytes come back.
- **On the laptop:** the emulator (MetalUITerminal) stays on the laptop.
- **On reconnect:** the ring's bytes are fed into a fresh emulator, so the screen and scrollback come back as far as the ring reaches.
- **Behind the Host:** `TerminalManager.spawn`'s local `isExecutable` and `isDirectory` checks, and `LinkDetector`'s `fileExists`.

### 6. Language servers

- They run on the server through `HostProcesses`. `ServerLauncher` gets an `RPCByteChannel` that is one mux channel. `ServerLocator` resolves on the server, which on Linux means no `xcrun`.
- **The call:** a language server restarts on reconnect rather than surviving it. LSP sessions are tied to the client's open-document state and can't be re-initialised in place. The expensive part, the server's index cache, stays on the server's disk, so a restart is warm.
- This narrows the earlier description, which said language servers keep running.

### 7. The window

- **File menu:**
  - "Connect to Server…" lists `~/.ssh/config` hosts and recent hosts. You can also type `user@host` or a Tailscale name.
  - Then a remote folder browser, served by `HostFileSystem.list`, opens the project.
- Remote projects appear in recents as `<host>: <path>`.
- **Window marking:** the window title and chrome badge show the host name, and the island chrome uses a small host marker. Local windows look unchanged.
- **While disconnected:**
  - The banner shows; editors, tree actions, git actions and terminals turn read-only.
  - The chat composer stays usable for drafting, but Send is disabled.
  - Autosave pauses. Unsaved edits made before the drop stay in memory and save on reconnect, with the existing outside-edit conflict flow if the disk changed.
- **Closing:** closing a remote window detaches, and everything keeps running. Quitting Alloy also detaches. "Stop server sessions" ends them on purpose.
- **Plugins:** they run on the laptop. Their project reads and writes (`PluginCoordinator+Project`, `PluginWriteRefusal`) go through the Host.

## Phases (each one ships green on its own)

0. **Host seam, local only.**
   - Introduce `Host` and `LocalHost`, and move every project-file and process site behind them. Add the fake host and the disk-tripwire test mode.
   - There is no user-visible change. The pass bar is the full suite green, frame and perf guards unchanged, and perf-history entries before and after.
1. **Connect, files, tree, watcher, index, search and git** against the Mac mini.
   - Includes `alloy-host` for macOS, the mux protocol, SSH bridge, install and update, reconnect, and the read-only offline mode.
   - At this point you can edit a remote project, without terminals or agents.
2. **Terminals and agents on the server,** with persistence and replay.
   - Includes the server-side ACP and Claude transports, `ACPFileHandling` forwarding and the detached mode, the MCP tunnel and pending permissions.
3. **Language servers on the server.**
4. **Linux server:**
   - inotify, a POSIX-socket listener instead of `Network`, swift-crypto (or a small SHA-256) instead of CryptoKit, and the Darwin calls guarded;
   - `ServerLocator` without `xcrun`;
   - static Linux binaries cross-compiled from macOS with the Swift static Linux SDK, which means no Docker;
   - testing against a real VPS or a local Linux VM.

The release after 0.1.0 ships phases 0–2 on macOS at least. Phases 3–4 can follow in point releases if needed.

## Inventory the refactor covers

The research map from 2026-11-27 lists:

- **Project file sites** (about 50 files):
  - document open and save (`Workspace.readForEditing`, `write`, `replaceAtomically`, revert, edit apply, save-as and rename);
  - the file tree and `FileIndex` (`git ls-files` plus `lstat`, with an enumerator fallback);
  - search (`SearchEngine` mmap reads);
  - git reads (`GitBaseline`, `GitStatus`, the lock removal);
  - ACP files and `ACPPathPolicy`, `ACPTranslator`'s before/after reads;
  - LSP `References` and `ConfigProbe`, rename and code actions;
  - plugin project access, composer attachments, terminal link checks;
  - transcript reads.
- **Process sites:** `GitProcess`, `FileIndex`, `ClaudeProcess` and `ClaudeLocator`, `ACPProcess` and `AgentDetector`, `ServerProcess` and `ServerLocator` (LSP), and `LivePtySpawner` and `TerminalLaunchPlanner`.
- **App-local, unchanged:** settings, themes, plugins, the knowledge pool, session launch files for local sessions, frame timing and `main.swift`'s NSWorkspace calls. NSWorkspace "open" calls on a remote file are disabled in v1, or download to a temp file first; the builder's call.

## Performance and resource targets

- Local projects: no regression on any existing guard or perf-history metric.
- Remote typing and drawing: identical to local, since nothing on that path crosses the network.
- Over a LAN or Tailscale direct path, opening a file under 1 MB takes the round trip plus under 20 ms. Search results start streaming within one round trip plus engine time.
- `alloy-host` idle with nothing running: 0% CPU and under 15 MB resident after it drops into the idle state. These are measured and recorded in perf-history.
- Replay rings are bounded as listed above. There's no unbounded buffering anywhere on either side.

## Review focus (failure modes most likely to bite)

1. A missed direct disk call reads the laptop's copy of a same-named path. The disk tripwire covers this.
2. The connection drops in the middle of a save. The atomic write is server-side, so either the old or the new file is there and never a partial one. The laptop must not mark the document saved until the server confirms.
3. While the laptop was away, an agent edited a file that has unsaved edits on the laptop. On reconnect this shows the existing outside-edit conflict choice, never a silent overwrite.
4. The laptop sleeps for hours and the replay ring overflowed. The client gets "gap too large" and reloads that session from its transcript, or the terminal from what the ring has, with a visible "earlier output trimmed" note.
5. A second Mac attaches while the first is asleep. Takeover must cleanly end the first client's writer role before the second one writes the shared store. The first Mac, on waking, sees "This project is open on <other Mac>" and goes read-only rather than writing stale state.
6. The SSH host key changed or sign-in is needed. Alloy shows a clear dialog and never hangs on a hidden prompt.

## Left to the builder

- Exact Swift shapes of `Host` and its sub-protocols, and how they are injected.
- Frame layout details and channel credit numbers.
- launchd plist and systemd unit details, within the persistent and idle rules above.
- Ring sizes within the stated caps.
- The remote folder browser's look, within Alloy's existing palette style.
- How NSWorkspace "open in default app" handles remote files in v1.

## Calls I made (for review)

- Agents on the server use the server's own logins, and Laptop Keychain secrets aren't forwarded.
- Language servers restart on reconnect instead of surviving it.
- While detached, Alloy's MCP tools answer "disconnected" and agents keep going.
- One client at a time; a second connection takes over. Shared state is on the server, so the second Mac sees the same sessions, edits and notes.
- Window layout is per Mac.
- Protocol major version: a newer app attaches to an older daemon, and the daemon only updates when idle.
- SSH sign-in is key-based only in v1, with fail-fast dialogs.
- No TCP port on the server, not even loopback: stdio MCP and command hooks over the Unix socket.
- On macOS the daemon is a launchd GUI-session agent so Claude's Keychain sign-in works.
- Closing or quitting Alloy detaches. "Stop Server Sessions" and "Stop Server" are the explicit commands.
- (Superseded by the user: the daemon is persistent and idles at low memory instead of exiting.)
- The Linux build is cross-compiled with the Swift static Linux SDK, with no Docker.

# PittMultiplayer: final design (MP1)

Status: **final design, approved for implementation**. Supersedes `proposal-lean.md`,
`proposal-physics-first.md` and `proposal-risk-first.md` (kept for history). Owner requirements in
`docs/MULTIPLAYER-UI-SPEC.md` are authoritative; where this document and the spec disagree, the spec wins
and this document is a bug.

Game: Project P.I.T.T. v1.0.8 (Steam 4026250), Godot 4.7.2, PittAPI 1.0 -> 1.1. Line numbers refer to
`decomp/scripts/*.gd` (read-only, never committed).

---

## 0. Judging: scores and what was taken from each proposal

Each criterion is scored 1-5. Claims were spot-checked in `decomp/` during judging (section 0.2).

| Criterion | lean | physics-first | risk-first |
|---|---|---|---|
| 1. Correct against the real game code | 3.5 | 4 | 4 |
| 2. Delivers the owner's UI / lobby spec exactly | 5 | 3 | 5 |
| 3. MP1 shippable and testable on one PC | 4 | 5 | 5 |
| 4. Does not block MP2 physics sync | 3 | 5 | 4 |
| 5. Simplicity | 5 | 2 | 3 |
| **Total (25)** | **20.5** | **19** | **21** |

Why these scores:
- **lean**: the clearest, most buildable structure, and the closest to the spec's menu requirements (it
  reuses the game's own `MenuLoad` save picker, `save_slot_row.tscn` rows and the panel swap). Correctness
  gaps: the client `UnlockManager` keeps evaluating client-local stats, so clients can unlock milestones the
  host never unlocked. Godot RPCs on a custom `SceneMultiplayer` would have to be redone for MP2 binary
  state. The snapshot keeps `object_pools`, which hands every joiner a copy of the host's sellable objects
  (duplicated money). Phase 0 is left to a spike.
- **physics-first**: the best long-term transport: packet-level, a channel plan with MP2 lifecycle
  reserved, a shared state-stream codec, ownership/epochs, and a fakeable `GameAdapter` so a host and a
  client can run in one headless process. It is too big for MP1 (NTP clock, quantization, ownership table,
  conditioner). It feeds full dictionaries into `SaveManager._load_game_state` at 10 Hz, which it admits has
  unconditional side effects (`apply_remote_tier`, defaults). Its own slot selector departs from "match the
  game's UI exactly".
- **risk-first**: the most real-game traps found, all confirmed. `GameState.buy` does not check `enabled`
  (game_state.gd:1062). F5/F9 are read with `Input.is_action_just_pressed` in `_input`, so filtering events
  can't block them (player_controller.gd:139/150). Steam migrates lobby ownership. The decomp instance would
  share the real save folder. A host in phase 0 or in a phase transition must not serve joins. Crate
  escalation lives in a lambda-local table. Two choices hurt playability, and this design reverses both:
  reverting all client income turns clients into spectators, and stripping `workbenches` from the snapshot
  leaves late joiners without benches (benches are restored from that key, workbench_spawning.gd:299).

**Base: lean.** It has the simplest structure and the best fit to the UI spec. Grafted onto it:

| From | Taken |
|---|---|
| risk-first | Risk register as the test spine (section 13): `scope:"local"` builtins (R18). Host re-validation of purchases, including `enabled` / `enabled_levels` (R11). Rewire fails closed (R12). InputMap erase for F5/F9 (R16). Host serves joins only in `OPEN`, never phase 0, transitions queued, ending refused (R4/R7/R40). Lobby owner migration = host left (R8). Results and state on one ordered stream, with the host flushing state before the reply (R20). `session_id` on every message (R21). Payload caps and rate limits (R22). Abort during loading deferred to a safe point (R23). User-dir abort gate (R26). Duplicate Play without `DUPLICATE_SIGNALS` (R27). Sandbox blocked while picking (R41). Remote cheats refused (R19). Wall-clock timing (R5). Teardown order. "Presence" achievements policy. Liveness ping. `--pittapi-instance`. Crate steps as checked data. |
| physics-first | Packet-level `Transport` (no RPC) with 4 channels, channel 3 reserved for MP2 lifecycle. One `GameAdapter` file for every game global, faked in headless tests. Client `UnlockManager` detached; live unlocks via the public `UnlockManager.force_unlock` (unlock_manager.gd:2259). Hole override that forwards nutrition to the host's hole. Unpause on `physics_frame` (no lost tick). Ownership/epoch concept and the MP2 phasing (2a/2b/2c). Bandwidth budget. Contract entries per feature. The idea that the avatar stream is the MP2 body stream with one entity kind. |
| lean | Main-menu extension shape. Reuse of the game's own `MenuLoad` for host Start. Session state machine and leave/disconnect table. Snapshot from the game's own save collectors, loaded through the game's own load path (one path for Start and late join). Encrypted session file using the runtime `SaveManager.SAVE_PASSWORD`. State-based idempotent `econ` with a client prediction of unacked contributions. Purchase rewire with the game's own feedback helpers. Capsule + visor + Label3D puppets with a 100 ms interpolation buffer. Two-process ENet headless test. Manual Steam checklist. File layout. |

### 0.1 Owner decisions this design assumes (defaults; each is a config switch)

| # | Decision | Default | Switch |
|---|---|---|---|
| D1 | MP1 world model: **shared progression, private physics**. Each peer simulates its own floor; money, unlocks, item levels, phase and hole are one co-op state owned by the host. | yes | n/a |
| D2 | Client earnings from its own world are contributed to the shared wallet. Off = clients' positive income is reverted, fines are still charged. | on | `client_earnings` |
| D3 | Host Start opens the game's own save panel (Continue / New Game). Sandbox sessions are not supported in MP1. | yes | n/a |
| D4 | Achievements "presence": nothing is granted for progress loaded on join, only for thresholds crossed while connected. | presence | `achievements` = presence / none / all |
| D5 | A client who sees the ending gets the game's own `profile.cfg game_completed` write (they finished it together). | accept | n/a |
| D6 | Secret ending stays per-peer and local: whoever triggers it leaves the session when their world exits (if that is the host, the session ends for everyone). | local | n/a |
| D7 | Host leaving the world (pause > Main Menu, quit) ends the session **and** the lobby. Clients see "The host ended the session" on the main menu. | yes | n/a |

### 0.2 Spot-checks done while judging (decomp, v1.0.8)

- `main_menu.gd:127-139`: `_unhandled_input` swallows every `ui_cancel` and opens the quit dialog when
  `MenuButtons` is visible. `_on_load_pressed` (:219) / `_on_new_game` (:263) end in `_launch_game` (:678),
  which unpauses, resets `MenuManager.current_menu/game_paused` and goes through `LoadingScreen`.
- `pause_menu.tscn:14`: the `PauseMenu` root has `process_mode = 4` = `PROCESS_MODE_DISABLED`, and no
  script changes it. Its subtree therefore behaves **the same whether the tree is paused or not**, which
  makes the "never pause in a session" rule much less risky. Spike P1 still confirms it live.
- `menu_manager.gd:107-120`: `open_menu` pauses the tree for every menu except MainMenu.
  `player_controller._unhandled_input` (PROCESS_MODE_ALWAYS) owns Esc open/close.
- `game_state.gd:1062`: `buy()` checks neither `enabled` nor `enabled_levels`, and it calls
  `WorkbenchSpawning.auto_machine_purchased` **before** the affordability check. `add_money`/`spend` take
  plain ints and apply no multipliers (:840-873), so forwarding a client's realized deltas to them is exact.
- `hole.gd:167`: `_on_product_consumed(type, base_value, body_id=-1)` scales nutrition by the hole's own
  `current_phase`. `_check_phase_completion` (:228) / `_trigger_ending` (:251) are the only phase writers there.
- `unlock_manager.gd:1495/1500`: connections to `stat_changed` / `phase_changed`. `force_unlock` (:2259)
  guards unknown and duplicate ids, then `_trigger_milestone` (:1726).
- `workbench_spawning.gd:129` spawns manual benches from `phase_changed`; `:299` restores spawned auto and
  manual benches from save data. That is why the snapshot keeps `workbenches`.
- `save_manager.gd:456`: `_read_save_string` tries encrypted with `SAVE_PASSWORD`, then plaintext.
- `steamworks.gd:146`: `restartAppIfNecessary` is skipped under `OS.has_feature("editor")`. The GodotSteam
  addon ships `template_debug` DLLs too, so the decomp editor instance loads Steam.
- Loader: `Commands._dispatch` denies `authority_only` on non-authority peers and already refuses `internal`
  commands from remote senders. `save.isolate` only accepts paths under `user://pittapi/`.
  `test-headless.ps1` copies every `mods/*` and runs every `tests/headless/suites/test_*.gd`.

---

## 1. Architecture

```
mods/PittMultiplayer  (composition root: main.gd, NET stream)
 ├─ lobby/   LobbyService (Steam | Dev | Fake)  ── signals ──▶ ui/ panels (dumb views)      [STREAM UI]
 │                 ▲ lobby_entered / lobby_left / transport_target()
 │                 │ set_state()                     ▲ start_game() / leave() / signals
 ├─ net/     Session ── Transport (Steam | ENet | Loopback) ── proto/codec ── MpAuthority   [STREAM NET]
 ├─ game/    GameAdapter: the ONLY file touching game globals (faked headless)
 ├─ sync/    econ (host publish / client apply), contributions, purchases, progression, snapshot
 ├─ world/   avatars + puppets, pause/input/save guards
 ├─ policy/  achievements
 └─ extensions/  main_menu_ext (UI) · upgrade_ui_ext, hole_ext, pause_menu_ext (NET)
```

Rules:
1. Only `lobby/steam_lobby_service.gd` calls Steam lobby, friends, presence and overlay functions. Only
   `net/transport_steam.gd` touches `SteamMultiplayerPeer`. Both check `Engine.has_singleton("Steam")`,
   `Steamworks.is_steam_initialized` and `has_method` before each call. `Steam.run_callbacks` is pumped by
   the game's `Steamworks._process` only; we never add a second pump.
2. Only `game/game_adapter.gd` (NET) reads or writes game autoloads and world nodes for sync. The UI stream
   touches only main-menu nodes, through `ui/` and `extensions/main_menu_ext.gd`.
3. Every extension is **inert unless a session is live**. The first line of each override is the vanilla
   path: `if not _mp_live(): return super(...)`. Single-player behaviour with the mod installed is unchanged
   (test `H-SP1`).
4. Extensions contain no copied game code. They call `super` and game members by name only. Every member
   used is listed in a contract file (section 11).
5. Network nodes live under `/root/PittAPI/Mods/PittMultiplayer` with `PROCESS_MODE_ALWAYS` and survive
   scene changes.
6. All network timing uses `Time.get_ticks_msec()` (wall clock). Phase 3 changes `Engine.time_scale`.

---

## 2. Transport

### 2.1 Interface (`net/transport.gd`)

```gdscript
signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal packet(peer_id: int, channel: int, bytes: PackedByteArray)
signal opened()                         # host listening / client connected to host
signal closed(reason: String)           # local close, host gone, connect failure
func kind() -> String                   # "steam" | "enet" | "loopback"
func host(target: Dictionary) -> Error  # from LobbyService.transport_target()
func join(target: Dictionary) -> Error
func poll() -> void                     # called by Session._process (PROCESS_MODE_ALWAYS)
func send(peer_id: int, channel: int, bytes: PackedByteArray) -> Error   # 0 = all; mode from channel
func close(reason: String) -> void
func local_peer_id() -> int             # host = 1
func platform_id_of(peer_id: int) -> String   # steam id as string; "enet:<id>"; "loop:<id>"
```

- Implementations wrap a `MultiplayerPeer` and use the **raw packet API**: `set_target_peer`,
  `transfer_channel`, `transfer_mode`, `put_packet`, `get_packet`, `get_packet_peer`, `get_packet_channel`.
  The peer is **not** assigned to `get_tree().get_multiplayer()`, so the game's tree stays offline. There
  are no `@rpc`s and no `MultiplayerSynchronizer`s: game node paths are not deterministic, and every inbound
  byte must go through our validator. Fallback if spike S1 finds that `SteamMultiplayerPeer` needs a
  `SceneMultiplayer`: a standalone `SceneMultiplayer` (never set on the tree), polled by us, with
  `send_bytes` / `peer_packet`. The interface stays the same.
- `transport_steam.gd`: `SteamMultiplayerPeer.new()`, `host_with_lobby(lobby_id)` / `connect_to_lobby(lobby_id)`;
  fallback `create_host(0)` / `create_client(host_steam_id, 0)`. Exact signatures are pinned by spike S2
  (`ClassDB.class_get_method_list("SteamMultiplayerPeer")` in the decomp instance). `Steam.initRelayNetworkAccess()`
  is called once if present. `max_channels=4` is already set (project.godot:254).
- `transport_enet.gd`: `create_server(port, MAX_MEMBERS - 1, 4)` / `create_client(address, port, 4)`, bound
  to 127.0.0.1 by default. `set_timeout(5000, 30000, 60000)` on peers, because a joiner's LoadingScreen can
  stall its main thread.
- `transport_loopback.gd`: an in-process hub for headless tests with deterministic `latency_ms`, `jitter_ms`,
  `loss` (unreliable channel only), `duplicate`, `reorder` and `stall(peer, ms)`.
- Topology: **star**. Clients talk only to the host, and the host relays avatars. Peer ids, slots and names
  are facts the host assigns, never taken from payloads.

### 2.2 Channels

| Ch | Mode | Carries |
|---|---|---|
| 0 | reliable ordered | Control and **the one host-to-client ordered stream**: hello/welcome/reject/bye, roster, session, ping/pong, cmd (C→H), res, econ, phase, unlock, hole, toast (H→C). The host flushes pending state before every `res` (R20). |
| 1 | reliable ordered | Snapshot chunks (bulk), so a large snapshot never delays a purchase reply. |
| 2 | unreliable | Avatar frames (binary). MP2: body state. |
| 3 | reliable ordered | **Reserved for MP2** entity spawn, despawn and ownership. Unused in MP1. |

### 2.3 Framing (`net/proto.gd`, `net/codec.gd`)

Byte 0 is the frame kind: `0` JSON, `1` zstd(JSON) (used above 1 KB), `2` avatar binary, `3` snapshot
chunk binary.

JSON messages are JSON-safe Dictionaries: `{"k": kind, "sid": session_id, "q": seq?, ...body}`.
- `k` is whitelisted per channel and per session state. Anything else is dropped and counted.
- `sid` is a random 64-bit hex id made when the host opens the transport. A mismatch is dropped.
- `q` is a per-direction seq on channel 0. Duplicates or older values are dropped.
- Caps: client→host JSON ≤ 16 KB, host→client JSON ≤ 256 KB, snapshot chunk 32 KB.
- Rate limits per peer: commands 30/s (burst 60), avatar 40/s, control 20/s. Over the limit: drop and
  count. Over 3× for 5 s: kick with `protocol`.
- Every message is logged at DEBUG and the last 200 are kept in a ring buffer (`mp dump` console command).

Avatar frame (kind 2, 44 bytes, little endian): `u8 kind, u8 slot, u16 flags, u32 t_ms, f32 x, y, z,
f32 yaw, f32 pitch, f32 vx, vy, vz, u32 seq`. Flags: crouch, sprint, airborne, menu_open, torch, teleported.
The host **overwrites `slot`** with the sender's real slot before relaying. The MP2 body codec is a sibling
frame kind in the same codec file (section 12).

### 2.4 Messages

| `k` | Dir | Body |
|---|---|---|
| `hello` | C→H | `{proto, pitt_version, pittapi_version, mods_hash, name, platform_id}` |
| `welcome` | H→C | `{peer, slot, roster, host_state, rules:{client_earnings, achievements, cheats}}` |
| `reject` | H→C | `{reason: "version"\|"mods"\|"full"\|"ending"\|"protocol", detail}` |
| `bye` | both | `{reason: "left"\|"host_left"\|"kicked"\|"ending"\|"error", detail}` |
| `roster` | H→C | `{roster:[{peer, slot, name, platform_id, state, is_host}]}` |
| `session` | H→C | `{host_state: "lobby"\|"starting"\|"open"\|"transition"\|"ending"}` |
| `ping` / `pong` | both | `{t0}` / `{t0, host_ms}` at 2 Hz: liveness (15 s silence = drop), RTT, clock offset |
| `join_req` | C→H | `{}`: the client asks for a snapshot (sent automatically once host_state is `open`) |
| `snap_begin` / `snap_end` | H→C | `{xfer, bytes, chunks, sha256}` / `{xfer}`; chunks are frame kind 3 on ch1 |
| `ready` | C→H | `{xfer}`: world loaded and snapshot applied |
| `cmd` | C→H | a PittAPI command envelope `{v,id,name,args,mod,origin,t}`, unchanged |
| `res` | H→C | `{id, result:{ok, value, error, code}}` |
| `econ` | H→C | section 6.2 |
| `phase` | H→C | `{kind: "begin"\|"settled", phase}` |
| `unlock` | H→C | `{ids:[...]}` in host order |
| `hole` | H→C | `{target_radius, phase_nutrition_total}` at ≤ 4 Hz on change |
| `toast` | H→C | `{key, args}` (for example "X joined") |

---

## 3. PittAPI integration and loader changes

### 3.1 `MpAuthority` (`net/mp_authority.gd`)

It is duck-typed to the members `Commands` calls (`get_kind`, `is_authority`, `local_peer_id`, `get_peers`,
`is_multiplayer`, `submit`, `complete`, `commands`, `peers_changed`). `install_authority` validates them.
- Host: `is_authority()=true`. `submit()` dispatches locally, flushes econ, then completes (exactly the base
  behaviour plus the flush). A `cmd` from peer P is handled as follows:
  1. Validate the envelope shape.
  2. Refuse cheat commands unless `allow_remote_cheats`.
  3. Run `commands.dispatch_remote(env, P)`, with P taken from the transport.
  4. Flush econ.
  5. Send `res`.
- Client: `is_authority()=false`, `local_peer_id()` from `welcome`. `submit(env)`:
  - `describe(name).scope == "local"`: dispatch locally, then complete.
  - Anything else: send `cmd`, park the envelope in `pending[id]` with a 10 s deadline, and complete on `res`.
    A timeout, or the session ending, completes it with `ERR_UNAVAILABLE`.

### 3.2 Loader additions (NET stream; each small)

| # | File(s) | Change | Why it can't live in the mod |
|---|---|---|---|
| L1 | `core/commands.gd`, `core/builtin_commands.gd` | `register(..., {scope: "authority"\|"local"})`, default `authority`. `local` skips the `authority_only` denial, is refused from remote senders, and is exposed in `describe()`. These builtins become `local`: `save.isolate`, `perf.pin_physics`, `achievements.suppress`, `presence.suppress`, `player.teleport`, `player.impulse`. | Otherwise a client's `save.isolate` runs **on the host** (R18). |
| L2 | `api/net.gd`, `pittapi.gd`, `core/manifest.gd`, `schema/mod.schema.json` | Manifest `"provides": ["net"]`; only one active mod may provide it. That mod's `api.net` gets `install_authority(a) -> Error`, `uninstall_authority()` (restores LocalAuthority), `emit_session_started(info)`, `emit_session_ended(reason)`, `emit_peers_changed()`, `register_remote_player(node, peer) -> int`, `unregister_remote_player(peer)`. Everyone gets `get_players() -> Array[Dictionary]` and `get_peer_info(peer)`. The existing `session_started` / `session_ended` / `peers_changed` signals and `net.authority_changed` start firing. | `_set_authority` and `entities.register_player` are core-private, and mods must not get the raw core. |
| L3 | `api/net.gd`, `core/events.gd`, `core/game_bridge.gd` | `api.net.begin_apply(origin_peer)` / `end_apply()`: events emitted in between carry `origin=peer`, `source="net"`, and `money.changed.reason="net"`. | Client mods and our own forwarder must tell "host changed it" from "my world changed it". |
| L4 | `core/contract.gd`, `core/mod_context.gd` | `api.contract_check(entries: Array) -> {ok, missing:[...], features_off:[...]}` using the core checker and the same `"feature\|target\|kind\|member"` format. | The MP mod carries its own contract files and must fail closed with the core's checker. |
| L5 | `pittapi.gd`, `core/builtin_commands.gd` | Editor builds only: `--pittapi-instance=<name>` moves the PittAPI user root to `user://pittapi-<name>/`. The `save.isolate` prefix follows that root. | Two decomp dev instances share one custom user dir. |
| L6 | `core/entities.gd` | `register_remote_player` / `unregister_remote_player` backing L2 (slots 2..999). | Puppets get stable player ids, cleaned up on leave. |
| — | `loader/mod.json` | Version 1.1.0 (api ^1.1). | Mods declare `api_version ^1.1`. |

**No loader menu/UI API in MP1.** The menu work is one script extension and one injector, both owned by
the MP mod. `api.ui` becomes a loader feature when a second mod needs a menu button (recorded in API-DESIGN
"future"). This keeps the UI stream out of `loader/` entirely.

### 3.3 Entities and events

- Players are identified across the wire by **peer id / slot**, never by entity id. Puppets get
  per-machine player entity ids through L2/L6.
- MP1 replicates no pooled entities. Client-local pooled objects are untracked (`id_of == 0`), as PittAPI
  already does on non-authority peers. `entity.spawn` from a client mod is executed by the host, in the
  **host's** world (documented MP1 semantics; mods check `api.net.is_authority()`).
- Clients get normal `money.changed` / `phase.changed` / `unlock.milestone` / `item.level_changed` events
  from their own GameBridge when replicated state is applied, tagged `source:"net"` (L3).
- The mod emits `mod.PittMultiplayer.session {state, role}`, `.peer_joined`, `.peer_left` and `.ended {reason}`.

---

## 4. Session lifecycle and scene coordination (`net/session.gd`)

### 4.1 One path for Start and late join

The host loads first. Clients **always** enter through the late-join path as soon as the host's world is
`OPEN`. Pressing Start therefore puts everyone in the world, but there is one code path to test and no
lockstep loading.

### 4.2 Host

```
IDLE --lobby_entered(owner)--> LOBBY (transport.host ok; lobby state=waiting)
LOBBY --start_game()--> STARTING (lobby state=starting; clients see "Host is loading"; UI shows MenuLoad picker)
STARTING --cancel_start()--> LOBBY
STARTING --world.ready && (save.applied || new game) && phase>=1 && elevator_exited && !transition--> OPEN (lobby state=in_game)
OPEN --phase.begin 2..4--> TRANSITION --phase settled (phase_changed)--> OPEN
OPEN|TRANSITION --phase.begin 5--> ENDING (lobby state=ending, joinable=false)
any --leave()/world exited to menu/quit--> CLOSING: bye{host_left} to all, flush 250 ms, close transport, lobby.leave() --> IDLE
```

- In `OPEN`, queued `join_req`s are served one at a time (snapshot build cost). In `STARTING` and
  `TRANSITION` they wait (60 s deadline, then reject). In `ENDING` they are rejected.
- Phase 0 (elevator) is never served (R40). Joiners always load phase ≥ 1, which skips the elevator intro.

### 4.3 Client

```
IDLE --lobby_entered(member)--> LOBBY: CONNECTING -> HANDSHAKE (hello -> welcome | reject) -> WAITING
WAITING --host_state open--> join_req -> LOADING: snapshot rx (sha256) -> write + isolate -> _launch_game
LOADING --world.ready && save.applied--> IN_GAME (guards installed, `ready` sent; host sends full econ, roster)
any --leave / bye / transport closed / lobby_left(host_left) / timeout--> CLOSING -> IDLE
```

- Timeouts (wall clock): handshake 10 s, snapshot 60 s, world load 180 s, ping silence 15 s, command 10 s.
- If the host is lost during LOADING, the abort waits until a safe point (world ready, or the load failed)
  before the return to the menu (R23).
- A lobby owner change, or the owner leaving (`lobby_left("host_left")` from LobbyService), counts as the
  host leaving. There is no host migration (R8).

### 4.4 Leave and disconnect

| Event | Host | Client |
|---|---|---|
| Client Leave / pause > Main Menu / quit | `peer_disconnected`: roster update, puppet freed, `unregister_remote_player`, toast `MP_PEER_LEFT` | teardown (4.6). Lobby left. No dialog. |
| Host Leave / pause > Main Menu / quit | `bye{host_left}`, flush, teardown, lobby left | on `bye` / transport closed: teardown. If in a world: `PauseMenu._return_to_main_menu()` (pause_menu.gd:104, the game's full reset). Then the main menu shows the dialog `MP_END_HOST_LEFT`. |
| Network drop | as client leave | as host leave, reason `connection_lost` |
| Version / mods mismatch | `reject` | dialog with the detail. The Join list already shows such lobbies disabled. |
| Lobby full | Steam refuses the join | `lobby_left("join_failed")` → dialog `MP_ERR_FULL` |
| Ending (phase 5) | ENDING. The world exits through the game's ending → session ends, reason `ending` | each peer runs its own ending. Session ends silently when its world exits. |

The host's pause-menu "Main Menu" and "Quit" confirm bodies become `MP_CONFIRM_END_SESSION`
(`pause_menu_ext`).

### 4.5 Scene changes inside a session

There are only four:
- menu → world: per peer, async.
- world → black-hole ending: per peer, through the replicated `phase 5`.
- world → menu: leave.
- secret ending: per peer (D6).

`begin_load_reload` (in-game Load, F9) is blocked for everyone during a session (section 8.3).

### 4.6 Teardown (one idempotent function, also run from `_exit_tree` / `NOTIFICATION_WM_CLOSE_REQUEST`)

1. Mark the session not live, so extensions go inert.
2. Fail pending commands with `ERR_UNAVAILABLE`.
3. Send `bye` (best effort), then close the transport.
4. Restore `UnlockManager` connections and processing, the InputMap, the camera process mode and the
   movement lock.
5. `api.net.uninstall_authority()`, then `emit_session_ended(reason)`.
6. `save.isolate {enabled:false}`, then delete the session file.
7. `Engine.time_scale = 1.0`, `get_tree().paused = false`.
8. Free puppets.
9. `lobby.leave()`.
10. If in a world: `PauseMenu._return_to_main_menu()`. Record `last_end` so the UI can show the dialog.

---

## 5. Interface contract (UI ⇄ NET)

This section is normative. Both streams build against it simultaneously. A change needs both owners to
agree, and an edit here first.

### 5.1 Shared conventions

- Steam ids, lobby ids and member ids are **Strings** (64-bit values must survive JSON). Only
  `steam_lobby_service.gd` and `transport_steam.gd` convert to int.
- Every model is a plain JSON-safe `Dictionary`. Unknown keys are ignored by readers, and writers may add
  keys.
- All signals are emitted deferred-safe: a handler may call back into the emitter.
- Reason strings are fixed codes, never translated text. The UI maps a code to a key with
  `"MP_END_" + reason.to_upper()` or `"MP_LOBBY_" + reason.to_upper()`.
- Constants live in `lobby/lobby_model.gd` (UI-owned, NET may read): `MAX_MEMBERS := 10`,
  `APP_ID := 4026250`, `MP_PROTO := 1`, `LOBBY_STATES := ["waiting", "starting", "in_game", "ending"]`.

### 5.2 Models (`lobby/lobby_model.gd`, UI stream)

```
LobbyInfo  = {id: String, owner_id: String, host_name: String, members: int, max: int,
              state: "waiting"|"starting"|"in_game"|"ending",
              pitt_version: String, pittapi_version: String, mp_proto: int, mods_hash: String,
              joinable: bool, compatible: bool, reason: String,       # reason: "" or MP_ERR_* key
              is_owner: bool}                                          # meaningful in current() only
MemberInfo = {id: String, name: String, is_owner: bool, is_self: bool}
VersionInfo = {pitt_version: String, pittapi_version: String, mp_proto: int, mods_hash: String}
TransportTarget = {kind: "steam", role: "host"|"client", lobby_id: String, host_steam_id: String}
                | {kind: "enet",  role: "host"|"client", address: String, port: int}
```

### 5.3 LobbyService (UI stream implements; NET consumes the starred members)

`lobby/lobby_service.gd` is the base class (`extends Node`). `steam_lobby_service.gd`,
`dev_lobby_service.gd` and `fake_lobby_service.gd` extend it.

```gdscript
# --- signals ---
signal lobby_entered(info: Dictionary)          # * LobbyInfo; info.is_owner tells host vs member
signal lobby_left(reason: String)               # * "left"|"host_left"|"kicked"|"join_failed"|"error"
signal members_changed(members: Array)          #   [MemberInfo], lobby screen redraw
signal lobby_data_changed(info: Dictionary)     #   LobbyInfo of current lobby (state, members count)
signal friend_lobbies_changed(list: Array)      #   [LobbyInfo], join screen redraw
signal join_requested(lobby_id: String)         #   Steam invite / "Join Game" / +connect_lobby
signal error(code: String, detail: String)      #   non-fatal, UI shows the game's ConfirmDialog

# --- lifecycle (called by NET main.gd) ---
func setup(api: Object, version: Dictionary, config: Dictionary) -> void   # * VersionInfo from NET
func kind() -> String                           # * "steam" | "dev" | "fake"

# --- lobby ops (called by UI; NET never calls host/join) ---
func host(max_members: int = MAX_MEMBERS) -> void
func join(lobby_id: String) -> void
func leave() -> void                            # * idempotent; emits lobby_left("left") if it was in one
func invite_friends() -> void                   #   host: activateGameOverlayInviteDialog(lobby)
func refresh_friend_lobbies() -> void
func set_scan_active(on: bool) -> void          #   Join panel visible: events + 10 s fallback scan

# --- state (NET reads/writes) ---
func current() -> Dictionary                    # * LobbyInfo or {}
func is_in_lobby() -> bool                      # *
func is_owner() -> bool                         # *
func get_members() -> Array                     #   [MemberInfo]
func get_local_name() -> String                 # * persona name (Steam) or "Player <n>" (dev/fake)
func transport_target() -> Dictionary          # * TransportTarget for current lobby; {} if none
func set_state(state: String) -> void           # * host only: lobby data "state" + joinable rule
func set_external_members(members: Array) -> void  # * dev/fake: NET pushes roster as [MemberInfo];
                                                   #   steam: no-op (members come from Steam)
```

Behaviour guarantees the NET stream relies on:
- `lobby_entered` fires exactly once per lobby, **after** `transport_target()` is valid. NET opens the
  transport in its handler.
- `lobby_left("host_left")` fires when the owner leaves or ownership changes (`getLobbyOwner` differs from
  lobby data `host_steam_id`).
- After `leave()`, `current()` is `{}` and no further lobby signals fire for that lobby.
- `set_state("ending")` makes the lobby not joinable. `"in_game"` keeps it listed and joinable (late join).
- The host keeps lobby data `members` current. `host_name`, `host_steam_id`, `pitt_version`,
  `pittapi_version`, `mp_proto` and `mods_hash` are written from `setup(version)`. Rich presence `connect`
  = `+connect_lobby <id>` (plus `steam_player_group`) is re-asserted at 1 Hz while in a lobby and cleared
  on leave.
- Rows whose `pitt_version` / `pittapi_version` / `mp_proto` / `mods_hash` differ from `version` get
  `compatible=false` and `reason="MP_ERR_VERSION"` or `"MP_ERR_MODS"`. `members >= max` gives
  `joinable=false` and `"MP_ERR_FULL"`.
- Dev service: `host()` returns `{kind:"enet", role:"host", address:config.dev_address, port:config.dev_port}`
  from `transport_target()`. The Join list shows one row per `config.dev_targets` entry (default
  `127.0.0.1:27450`). Lobby id = `"dev:<address>:<port>"`. The member list comes from
  `set_external_members`.

Factory (UI stream), `lobby/lobby_factory.gd`:
```gdscript
static func make(kind: String) -> Node          # "steam" | "dev" | "fake" -> un-setup LobbyService
```

### 5.4 Session (NET stream implements; UI consumes)

`net/session.gd` (`extends Node`). It is passed to the UI by `main.gd`.

```gdscript
# --- signals ---
signal state_changed(state: String, info: Dictionary)
    # state: "idle"|"lobby"|"starting"|"loading"|"in_game"|"ending"|"closing"
    # info:  {role: "host"|"client"|"", sub: String, host_state: String}
    #        sub (client in "lobby"): "connecting"|"handshake"|"waiting"
signal roster_changed(players: Array)
    # [{peer:int, slot:int, name:String, platform_id:String,
    #   state:"connected"|"loading"|"in_game", is_host:bool}]
signal start_availability_changed(ok: bool, reason: String)   # reason: "" or MP_* key
signal ended(reason: String, detail: String)
    # reason: "left"|"host_left"|"connection_lost"|"version"|"mods"|"full"|"kicked"|
    #         "ending"|"timeout"|"protocol"|"error"
    # the UI shows a dialog for every reason except "left" and "ending"

# --- queries ---
func get_state() -> String
func get_role() -> String                       # "host"|"client"|""
func is_live() -> bool                          # transport session exists (lobby..ending)
func get_roster() -> Array
func can_start() -> Dictionary                  # {ok: bool, reason: String}; host && state=="lobby"
func consume_last_end() -> Dictionary           # {reason, detail} once, then {}; for the main-menu dialog

# --- commands from the UI ---
func start_game() -> Error                      # host pressed Start: state -> "starting", lobby
                                                #   state "starting". UI then opens the game's MenuLoad.
func cancel_start() -> void                     # host backed out of MenuLoad: -> "lobby", lobby "waiting"
func notify_host_launch(scene_path: String) -> void   # from main_menu_ext._launch_game while picking,
                                                      #   called BEFORE super(); NET waits for world.ready
func leave(reason: String = "left") -> void     # idempotent, any state; always ends with lobby.leave()
```

Behaviour guarantees the UI stream relies on:
- The UI calls `lobby.host()` / `lobby.join()` directly. The Session reacts to `lobby_entered` and moves
  to `"lobby"`. The UI **never** calls `lobby.leave()`; it calls `session.leave()`. Session then calls
  `lobby.leave()` and the UI pops its panels on `lobby_left` / `state_changed("idle")`.
- The client world launch is done by the Session through `GameAdapter` (the `MainMenu` group node's
  `_launch_game`). `main_menu_ext._launch_game` must call `super()` **unconditionally**, and it calls
  `notify_host_launch` only while the router is in host-picking mode.
- `ended` fires before the scene change back to the main menu. The menu is re-instanced afterwards, so the
  UI also calls `consume_last_end()` on every main-menu injection to show the dialog.
- While `get_state()` is `"loading"` or `"in_game"`, the UI does not swap main-menu panels or react to
  `join_requested`, apart from queueing it (section 7.5).

### 5.5 Composition (NET `main.gd` ⇄ UI `ui/mp_ui.gd`)

```gdscript
# ui/mp_ui.gd  (extends Node; UI stream)
func setup(api: Object, lobby: Node, session: Node) -> void   # connects signals; injects on every main menu
func is_host_picking() -> bool                               # used by main_menu_ext only (UI-internal)

# main.gd (NET stream), in order:
#   var version := {pitt_version, pittapi_version, mp_proto: 1, mods_hash}   # NET computes mods_hash:
#        sha256("id@version" of sorted client_required mods).substr(0, 16)
#   var lobby = load(api.path("lobby/lobby_factory.gd")).make(kind)   # kind: config transport steam->"steam", enet->"dev"
#   add_child(lobby); lobby.setup(api, version, config)
#   session = Session.new(api, lobby, adapter, config); add_child(session)
#   if lobby.kind() != "steam": session.roster_changed.connect(func(r): lobby.set_external_members(<roster as MemberInfo>))
#   var ui = load(api.path("ui/mp_ui.gd")).new(); add_child(ui); ui.setup(api, lobby, session)
#   load(api.path("ui/strings.gd")).register()        # registers every MP_* key (also in headless)
```

`ui/strings.gd` (UI stream): `static func register() -> void`. It must register these keys, which NET
uses in toasts, restrict messages and end reasons: `MP_PEER_JOINED` (`{name}`), `MP_PEER_LEFT` (`{name}`),
`MP_HOST_ONLY`, `MP_HOST_SAVES`, `MP_NOT_IN_MULTIPLAYER`, `MP_CONFIRM_END_SESSION`, `MP_SHOP_UNAVAILABLE`,
`MP_MP1_PRIVATE_WORLD`, `MP_SANDBOX_UNSUPPORTED`, and `MP_END_<REASON>` for every `ended` reason.

`mod.json` (NET-owned) lists all four extensions from day one: `extensions/main_menu_ext.gd` (UI),
`extensions/upgrade_ui_ext.gd`, `extensions/hole_ext.gd`, `extensions/pause_menu_ext.gd` (NET). Until a
stream delivers its file, the other stream's tests use a stub. A missing extension file is a quarantine
error, so each stream commits a pass-through stub of its own extensions on day one.

### 5.6 Test doubles (each stream owns the double of the *other* side it needs)

- NET: `tests/headless/fakes/mp_net/stub_lobby.gd`. It implements 5.3 and is driven by test code
  (`enter(info)`, `drop(reason)`).
- UI: `tests/headless/fakes/mp_ui/fake_session.gd`. It implements 5.4 and records calls.
- Conformance: `test_mp_ui_contract.gd` (UI) asserts that every LobbyService implementation, **and** NET's
  `stub_lobby.gd`, has every 5.3 member. `test_mp_net_contract.gd` (NET) asserts the same for `session.gd`
  **and** UI's `fake_session.gd` against 5.4. Drift fails both suites.

### 5.7 File ownership

**STREAM UI** (and nothing else):
```
mods/PittMultiplayer/lobby/lobby_model.gd          models + constants (5.2)
mods/PittMultiplayer/lobby/lobby_service.gd        base class (5.3)
mods/PittMultiplayer/lobby/steam_lobby_service.gd  the only Steam lobby/friends/presence/overlay caller
mods/PittMultiplayer/lobby/dev_lobby_service.gd    ENet dev lobby (static targets, external members)
mods/PittMultiplayer/lobby/fake_lobby_service.gd   scripted, for headless UI tests
mods/PittMultiplayer/lobby/launch_args.gd          +connect_lobby (OS.get_cmdline_args, Steam.getLaunchCommandLine)
mods/PittMultiplayer/lobby/steam_signals.gd        GodotSteam signal-arity adapters (defaulted-param lambdas)
mods/PittMultiplayer/lobby/lobby_factory.gd
mods/PittMultiplayer/ui/mp_ui.gd                   UI root: injection on each main menu, router ownership, dialogs
mods/PittMultiplayer/ui/menu_injector.gd           Play duplicate + sibling panels, idempotent
mods/PittMultiplayer/ui/mp_router.gd               panel stack, Esc = back, focus, host-picking mode
mods/PittMultiplayer/ui/host_join_panel.gd
mods/PittMultiplayer/ui/lobby_panel.gd
mods/PittMultiplayer/ui/join_panel.gd
mods/PittMultiplayer/ui/ui_style.gd                clone layout/buttons/rows from live menu nodes; res:// fonts
mods/PittMultiplayer/ui/dialogs.gd                 wraps res://scripts/confirm_dialog.gd
mods/PittMultiplayer/ui/strings.gd
mods/PittMultiplayer/ui/i18n/en.json  (+ fr, de, es, pl, ru, pt-br, cn, jp, ko where cheap)
mods/PittMultiplayer/ui/contract_ui.gd             UI's game contract entries (section 11)
mods/PittMultiplayer/extensions/main_menu_ext.gd
tests/headless/suites/test_mp_ui_*.gd              (menu, router, lobby, join, strings, contract)
tests/headless/fakes/mp_ui/**                      fake_session.gd, main-menu stub scene builder
```

**STREAM NET** (and nothing else):
```
mods/PittMultiplayer/mod.json, main.gd, README.md
mods/PittMultiplayer/net/{transport,transport_steam,transport_enet,transport_loopback,proto,codec,
                          session,mp_authority,roster,clock,contract_net}.gd
mods/PittMultiplayer/game/game_adapter.gd
mods/PittMultiplayer/sync/{econ_host,econ_client,contributions,purchases,progression,snapshot}.gd
mods/PittMultiplayer/world/{avatars,puppet,pause_guard,input_guard,save_guard}.gd
mods/PittMultiplayer/policy/achievements.gd
mods/PittMultiplayer/extensions/{upgrade_ui_ext,hole_ext,pause_menu_ext}.gd
mods/PittMPTests/**                                two-instance suites (mp_host, mp_client), armed by flag
loader/core/{commands,builtin_commands,authority,entities,events,game_bridge,manifest,contract,mod_context}.gd
loader/api/net.gd, loader/pittapi.gd, loader/schema/mod.schema.json, loader/mod.json
tests/headless/suites/test_mp_net_*.gd
tests/headless/fakes/mp_net/**                     stub_lobby.gd, fake_game_adapter.gd, stubs
tools/install.ps1 (-WithMP), tools/test-headless.ps1 (run contract_check on mod contracts),
tools/contract_check.py (several contract files), tools/mp-dev-setup.ps1, tools/test-mp-loopback.ps1
docs/mp/MANUAL-STEAM-TEST.md, TESTING.md, README.md (MP sections), .gitignore
```

---

## 6. Economy and progression (host-authoritative)

### 6.1 Classification

| Class | Fields | Host | Client |
|---|---|---|---|
| **Mirrored** (host truth, overwritten on clients) | `money`; item tables `upgrades/tools/toys/products/combos` (`level`, `enabled`, toy `buy_prices[0]`); `purchased_once`; `unlocked_milestones`; `phase`; hole `target_radius` + `phase_nutrition_total` | authoritative | apply only |
| **Contributed** (client deltas, merged on host) | money deltas (any sign); stat counters `products_consumed.*`, `total_products_consumed`, `products_crafted.*`, `products_autocrafted.*`, `total_bonus_earned`, `money_per_product.*`; maw nutrition | merges | forwards; keeps its own local counters (not mirrored after join) |
| **Local** (per world in MP1) | `bank`, `mining_bank`, `pickaxe_*`, `remote` channel states, `panel_stack`, buffs, puzzle/gate/keypad flags after join, play time | own | own |

`bank` is the gambling terminal's (gambling_terminal.gd:149), which is a per-world machine in MP1.
Deposits and cash-outs reach the shared wallet as money deltas.

### 6.2 Host → clients (`sync/econ_host.gd`)

- Dirty triggers: core events `money.changed`, `item.level_changed`, `unlock.milestone`, `phase.changed`,
  `command.executed(ok)`, plus a 4 Hz poll (the golden statue writes money directly; toy prices change
  silently).
- At most one `econ` per 100 ms when dirty. A **full** `econ` goes out every 2 s and on `ready`. That
  self-heals drift, and drift found by a full send is logged.
- ```json
  {"k":"econ","sid":"…","q":812,"full":false,"money":"123456789012345678901",
   "items":{"upgrades":{"sprint":{"level":1,"enabled":true}},"toys":{"bumper":{"buy_price0":500}}},
   "purchased_once":{"broom":true},"ack":{"2":41,"3":7}}
  ```
  `ack[peer]` = the last contribution seq from that peer merged into this state. Money is always an
  **absolute decimal string** (R9). Unlocks, phase and hole are separate messages (2.4) on the same
  ordered stream.

### 6.3 Client apply (`sync/econ_client.gd`, inside `api.net.begin_apply(1)`/`end_apply()`)

Idempotent, in this order:
1. **items**: write `level` / `enabled` / `buy_prices[0]` / `purchased_once` via GameAdapter, then the
   post-hooks that `GameState.buy` would have run in this world:
   - `remote_tier` level changed → `GameState.apply_remote_tier()`;
   - `products.<k>.auto_machine.level` 0→1 → `WorkbenchSpawning.auto_machine_purchased(k, 0)` (the auto
     bench appears in the client's world);
   - sprint+crouch → `slide.enabled` comes from host data;
   - then `UpgradeUI.update_ui()` and `update_credits()` if present.
2. **money**: `GameState.money = BigInt.from_string(add(auth, Σ unacked pending))`, then
   `money_updated.emit(money)` (load-path semantics, save_manager.gd:824; no stat side effects).
3. Drop pending contributions with `seq ≤ ack[me]`.

`sync/progression.gd` (client):
- `unlock {ids}`: for each id, `UnlockManager.force_unlock(id)` if the id is in `milestones` and not yet
  unlocked. This is the game's live path: actions, `milestone_unlocked`, the notification and UpgradeUI
  badges. Unknown ids are logged and skipped.
- `phase {begin, p}`: if `p > current_phase`, `GameProgression.change_phase(p)`. The client plays the real
  cinematic, music and `time_scale` locally. The client's checkpoint save hits the isolation lock. Phase
  never moves backwards. `p == 5` → state `ending`.
- `hole`: set `target_radius` and `phase_nutrition_total` on the `saveable_hole` node. Its `_process` lerps
  the radius.
- The client's `UnlockManager` is **detached** for the session: `stat_changed` / `phase_changed`
  disconnected (guarded by `is_connected`), `set_process(false)`. It is restored in teardown **before**
  `_return_to_main_menu` runs `UnlockManager.reset()`. Milestones are judged only on host state.

### 6.4 Client → host contributions (`sync/contributions.gd`)

The client keeps `auth` (the last host money) and `P` (pending deltas in seq order). Every 100 ms, and
synchronously right before applying any `econ`:
- **money**: `d = local_money − (auth + ΣP)` (BigInt, signed via `compare` + `sub_big`). This catches
  every writer in the private world (maw, combo payout hud.gd:670, statue direct writes, press, fines, bank
  cash-out) without per-sink hooks.
  - `client_earnings` on: append `d` to the batch and to `P`.
  - Off: a positive `d` is reverted at once; a negative `d` is still forwarded (fines are charged).
- **stats**: for whitelisted counters, `stat_changed` events while not applying, with the previous value
  kept per stat, so a throttle never loses increments.
- **nutrition**: `hole_ext._on_product_consumed(type, base_value, body_id)` on clients queues
  `{type, base_value}` and does **not** call `super`. `_check_phase_completion()` and `_trigger_ending()`
  are no-ops on clients.
- One command per batch: `PittMultiplayer.contribute {seq, money:"±digits", stats:{path:n}, feed:[{t, v}]}`.
- Host handler (authority scope, schema-validated, dedupe by `(peer, seq)`, caps per batch logged when
  clamped):
  - money `+` → `GameState.add_money(int)` (int64 chunks above `INT64_MAX`);
  - money `−` → `GameState.spend(min(|d|, money))`, the game's floor-at-0 semantics;
  - stats → counter `+= n` and `stat_changed.emit` (the host's UnlockManager and Steamworks react);
  - feed → the **host's** `hole._on_product_consumed(t, v, -1)`, with phase scaling from the host phase.
- Combos stay per peer. Their payout arrives as a money delta, so a double payout is impossible: the host
  never sees a client's `combo_ended`.

### 6.5 Purchases (`sync/purchases.gd` + `extensions/upgrade_ui_ext.gd`)

The extension overrides `_create_upgrade_row`, `_create_tool_buy_row` and `_create_toy_buy_row`. It keeps
the `is_mirror` early return and does not override `_ready`. On clients only:
```
var row = super(...); var button = row.get_meta("button")
for c in button.pressed.get_connections(): button.pressed.disconnect(c.callable)
if button.pressed.get_connections().size() != 0: _shop_unavailable(); return row   # fail closed (R12)
button.pressed.connect(_mp_on_row_pressed.bind(row))
```
`_mp_on_row_pressed` works as follows:
- `recall_mode` rows call the original callable (recall is local to the private world).
- Otherwise it sets a per-row pending flag and runs `execute_async` for one of:
  - `PittMultiplayer.buy_item {category, key, subkey}`
  - `PittMultiplayer.buy_tool {tool, level}`
  - `PittMultiplayer.buy_toy {toy}`
- On the reply it plays the game's own feedback (`_play_sound`, `_create_success_effect`, `_flash_label`,
  `_spawn_floating_text` with `UI_PURCHASED` / `UI_INSUFFICIENT_FUNDS` / ...).
- For tools and toys, on `ok`: `_spawn_tool_instance(tool, level)` / `_spawn_toy_instance(toy)` in the
  buyer's own world, then `Steamworks.check_consumerism()`.

Host handlers (authority scope) re-check everything against **host** state (R11):
- the item exists and is `enabled`;
- `enabled_levels[level]` where present;
- level < price count;
- pool headroom for tools;
- affordability.

Then:
- `buy_item`: affordability **first**, then `GameState.buy`. This avoids `auto_machine_purchased` running
  before the price check (game_state.gd:1083).
- `buy_tool`: `spend`, `purchased_once`, `check_consumerism`. No spawn on the host in MP1.
- `buy_toy`: the same, plus crate price escalation from a data table in the mod (wooden 1, metal 100,
  plush 10000, anomaly 1000000). Those values are local to the lambda at upgradeUI.gd:1546, so
  `tools/contract_check.py` greps them in decomp, and a game update that changes them fails the check.

The host's own terminal is untouched.

---

## 7. Lobby service and UI (STREAM UI)

### 7.1 SteamLobbyService

- Host: `Steam.createLobby(Steam.LOBBY_TYPE_FRIENDS_ONLY, MAX_MEMBERS)`. On `lobby_created(result, id)`:
  - write lobby data (5.3) and `setLobbyJoinable(true)`;
  - set rich presence `connect` and `steam_player_group`;
  - emit `lobby_entered`.

  `Steamworks._push_presence` only writes `money` and `steam_display`, so our keys survive. We re-assert
  them at 1 Hz anyway, because `clear_presence()` wipes everything.
- Members: after `lobby_joined` (response 1 = success, otherwise `lobby_left("join_failed")`), fill from
  `getNumLobbyMembers` + `getLobbyMemberByIndex` + `getFriendPersonaName`. Then:
  - `lobby_chat_update` → rebuild (the host also rewrites `members`);
  - `persona_state_change` → refresh names;
  - `lobby_data_update` → `lobby_data_changed`;
  - an owner check on each update (5.3).
- Join list: for each friend (`getFriendCount(FRIEND_FLAG_IMMEDIATE)` / `getFriendByIndex`), call
  `getFriendGamePlayed(f)`. If `id == APP_ID` and `lobby` is set, call `requestLobbyData(lobby)`; the row
  fills on `lobby_data_update`. A `persona_state_change(f)` re-checks that friend. A Refresh button, plus a
  10 s rescan only while `set_scan_active(true)`. Empty state: `MP_NO_FRIENDS_HOSTING`. Row text:
  `host_name`, `members / max`, `MP_STATE_WAITING` / `MP_STATE_IN_GAME`, and the disabled reason.
- `join_requested(lobby, friend)` and `+connect_lobby <id>` (read at mod init and on the first main menu)
  → `join_requested(String)`.
- Signal arities: every handler goes through `steam_signals.gd` lambdas with defaulted params. Spike S2
  pins the real arities with `ClassDB.class_get_signal_list("Steam")`.

### 7.2 Menu injection (`ui/menu_injector.gd`, `extensions/main_menu_ext.gd`)

Injection runs on `scene.changed(kind="main_menu")`, after `MainMenu._ready`, deferred one frame. It is
idempotent (it returns if `Background/MenuButtons/MPMultiplayer` exists) and re-runs on every main-menu
re-instance (returning from gameplay). Options and Credits only hide MainMenu, so our nodes survive them.

1. **Button**: `Play.duplicate(DUPLICATE_GROUPS | DUPLICATE_SCRIPTS | DUPLICATE_USE_INSTANTIATION)`. No
   `DUPLICATE_SIGNALS`, because Play's `.tscn` connection to `_on_play_pressed` must not be copied (R27).
   - `name = "MPMultiplayer"`, `text = "MP_MULTIPLAYER"`;
   - inserted at `Play.get_index() + 1`; font override (PublicPixel 104) carried by the duplicate;
   - `mouse_entered → menu._on_mouse_entered` (the game's hover sound);
   - `pressed` → router: honours `menu.ignore_input`, plays `menu._play_ui_sound(menu.click_sound)`, calls
     `menu._temporarily_ignore_input()`;
   - focus neighbours fixed;
   - disabled with a tooltip reason if the MP contract fails, or if Steam is uninitialised in Steam mode.
2. **Panels** `MPHostJoin`, `MPLobby`, `MPJoin`:
   - `VBoxContainer` siblings of `MenuLoad` under `Background`, so the `main_menu.tres` theme is inherited;
   - layout copied at runtime from the live `MenuLoad` node (anchors, offsets 49/-76/785/384, grow);
   - buttons cloned from `MenuLoad/New` (size 52);
   - titles in `GravityBold8.ttf` gold `Color(0.969, 0.729, 0.078)`, loaded from `res://`;
   - list rows are `res://scenes/save_slot_row.tscn` instances, tinted with the menu's `SLOT_COLOR_*`
     constants read from the live instance;
   - the lobby member list sits centred on screen (an extra centred container shown and hidden with the
     lobby panel).
3. **Swap**: `MenuButtons.visible = false; panel.visible = true` and back, then
   `_temporarily_ignore_input()`, then `grab_focus()` on the first enabled button when
   `InputManager.using_gamepad`. `MenuManager.apply_menu_scales()` runs after injection (idempotent).
4. **Esc**: the router lives under `Background`, so it receives `_unhandled_input` before `MainMenu`. It
   handles `ui_cancel` and marks it handled. The game's handler never sees it, so the quit dialog cannot
   open (main_menu.gd:127).
5. **Start**: the host presses Start → `session.start_game()`. If OK, the router hides `MPLobby`, calls
   `menu._on_play_pressed()` (the game's own save picker), and sets `picking = true`. `main_menu_ext`
   overrides while picking:
   - `_on_return_save_load` → `cancel_start()` and back to `MPLobby`;
   - `_on_sandbox_pressed` → toast `MP_SANDBOX_UNSUPPORTED`;
   - `_launch_game(p)` → `session.notify_host_launch(p)`, then `super(p)` (always super).

   `_focus_current_panel` focuses our visible panel, else `super`.
6. **Leave**: the Lobby panel's Leave button and Esc open the game's ConfirmDialog
   (`MP_CONFIRM_LEAVE_TITLE/BODY`), then `session.leave()`. Leaving any MP panel back to `MenuButtons`
   while in a lobby also calls `session.leave()` (no ghost lobbies).
7. Layout risk (spike S7): five 104 px buttons may push `MenuButtons` (grow both ways) into the title. If
   so, set `grow_vertical = GROW_DIRECTION_END` or lower `separation` on `MenuButtons`, measured and not
   guessed.

### 7.3 Lobby screen behaviour

- Member rows: the name, plus a gold `MP_HOST` tag on the owner. With a session roster, a status suffix
  (`MP_STATE_LOADING` / `MP_STATE_IN_GAME`).
- Host buttons: `MP_START` (enabled from `can_start()` / `start_availability_changed`), `MP_INVITE` and
  `MP_LEAVE`. Clients: `MP_LEAVE`, and the status line `MP_HOST_LOADING` while host_state is `starting`,
  or `MP_JOINING` while loading.

### 7.4 Strings and dialogs

All visible text is translation keys registered as `Translation` resources for the game's locales (en
fallback). Dialogs: `load("res://scripts/confirm_dialog.gd").new().setup(title, body, on_ok, ok_key,
cancel_key, menu.click_sound, menu.hover_sound, focus)`, added to the menu (as in `_on_delete_save_pressed`).

### 7.5 `join_requested` routing

- On the main menu, not in a session: `lobby.join(id)`, then the Lobby panel.
- In a session lobby: confirm "leave and join?".
- In a world (single-player or MP): `api.hud.toast(tr("MP_JOIN_FROM_MENU"))`. The id is kept, and a confirm
  is offered on the next main menu.

---

## 8. Players, pause, input and saves (STREAM NET)

### 8.1 Avatars (`world/avatars.gd`, `world/puppet.gd`)

- Send: 20 Hz wall clock, only on change plus a 1 Hz keepalive. Fields: local player position, yaw
  (`rotation.y`), camera pitch, velocity and flags. `teleported` is set on a jump of more than 4 m.
- Puppet: a `Node3D` named `PittMP_Avatar_<slot>` under `/root/World/PittMP_Avatars`:
  - a `CapsuleMesh` (r 0.35, h 1.8) with a per-slot tinted `StandardMaterial3D` from a 10-colour palette;
  - a box "visor" pitched with the camera;
  - a `Label3D` billboard in `PublicPixel-rv0pA.ttf` (gold for the host, white for others; max distance
    40 m).

  It has **no** physics body, **no** groups, and is never named `PlayerController`. All 18
  `get_first_node_in_group("player")` sites and 16 `is_in_group("player")` checks keep meaning "me" (R1).
- Interpolation: render at `host_now − 100 ms` using the ping/pong clock offset. Position is lerped, yaw
  and pitch use `lerp_angle`. Extrapolation up to 250 ms with velocity, then hold. Snap on `teleported` or
  a jump over 5 m. Hidden after 3 s without frames.
- Registered via `api.net.register_remote_player`. Toasts `MP_PEER_JOINED/LEFT`.

### 8.2 Pause = local only (`world/pause_guard.gd`, both roles, while `in_game`)

- The tree is never paused. On `get_tree().physics_frame` (emitted before physics dispatch, even while
  paused) and in `_process` as a backstop: if `paused` and not exempt, set `get_tree().paused = false`.
  Exempt: `GameProgression.ending_active`, session `ending`. `SaveManager.save_game` pauses synchronously
  inside one call, so it is unaffected.
- `MenuManager.game_paused` / `current_menu` stay as the game set them, so Esc open/close in
  `player_controller._unhandled_input` and `close_current_menu` keep working. The PauseMenu subtree is
  `PROCESS_MODE_DISABLED`, so it behaves the same paused or not.
- Local freeze while `MenuManager.current_menu != null` or `game_paused`:
  - `api.player.set_movement_locked(true)`;
  - `main_camera.release_held_object()`, then `MainCamera.process_mode = PROCESS_MODE_DISABLED`;
  - both restored when the menu closes. Mouse look is already skipped (player_controller.gd:195).
- The music pause filter won't engage (cosmetic, accepted).

### 8.3 Input and save guards

- `world/input_guard.gd`: while live, the InputMap events of `quick_load` are erased on all peers and
  `quick_save` on clients. `player_controller._input` polls `Input.is_action_just_pressed`, so event
  filtering can't work (R16). They are re-erased on `InputManager.bindings_changed` and restored with
  `InputManager.apply_bindings()`. `keybindings.cfg` is never written.
- `extensions/pause_menu_ext.gd`:
  - Load and Delete → `hud.show_restrict_message(tr("MP_HOST_ONLY"))` for everyone;
  - Save is blocked on clients (`MP_HOST_SAVES`);
  - Main Menu / Quit use `MP_CONFIRM_END_SESSION` on the host;
  - `_return_to_main_menu` calls `session.leave()` first, then `super`.
- `world/save_guard.gd` (client): `save.isolate` on
  `user://pittapi/mods/PittMultiplayer/session/<sid>.save`, from before the world loads until after it is
  left. It is re-asserted every frame (the elevator resets `save_locked`, elevator.gd:57).
  `set_active_slot` is never called. The file is deleted at session end, and orphans are deleted at boot.
- Host: saves its own slot normally (autosave, checkpoints, manual). The save holds the merged co-op
  progress and only the host's world and position.

### 8.4 Achievements (`policy/achievements.gd`)

- Host: single-player behaviour.
- Client, **presence** (default):
  1. Before launching the snapshot load, run `achievements.suppress` (local scope) and save `_granted`.
  2. On `save.applied`, compute the baseline of already-met achievements with the game's own helpers
     (`_meets(_get_stat(rule.stat), rule.threshold)`, phase ≥ p, gates and flags `evaluate_all` checks).
  3. Set `_granted = saved ∪ baseline` and resume.

  After that, only crossings fire: local stats, replicated `change_phase`, purchases.
- `none` keeps everything suppressed. `all` is single-player behaviour.
- Cheats: remote cheat commands are refused by default. If a cheat command succeeds on the host, the host
  broadcasts `rules.cheats=true`, and every peer runs `achievements.suppress` for the rest of the session.
  Lobby data `cheats=1` tags the Join row.
- Tests always suppress on every instance (one real Steam account).

---

## 9. Snapshot and late join (`sync/snapshot.gd`)

### 9.1 Host build

The host calls SaveManager's pure collectors into a **fresh** dictionary. It never touches
`SaveManager.save_data`, never writes a file, and never pauses:

| Key | Source | MP1 |
|---|---|---|
| `game_state` | `_save_game_state()` | keep (`bank`, `mining_bank` and `panel_stack` zeroed: local) |
| `game_statistics` | `_save_game_statistics()` | keep (the client's starting counters) |
| `unlocked_milestones` | `UnlockManager.get_save_data()` | keep |
| `phase` | `GameProgression.current_phase` | keep (always 1..4 because joins are served only in `OPEN`) |
| `hole` | `_save_hole()` | keep |
| `workbenches` | `WorkbenchSpawning.get_save_data()` | **keep** (benches are restored from it, workbench_spawning.gd:299) |
| `vertical_gates`, `cameras`, `minable_blocks`, `loop_puzzle` | collectors | keep as starting state (local afterwards) |
| `object_pools` | | **empty** (private physics; avoids handing out the host's sellable objects) |
| `press_spawned`, `trading_terminal_spawned`, `bowling_set_spawned`, `pickaxe` | | **false / {}** (bought items live in the buyer's world) |
| `player_position` | host `last_safe_position` + a 1.5 m per-slot ring offset; fallback `(0,6,18)` | computed (R39) |
| `music`, `seen_items` | | omitted (client-local defaults) |
| `version` | `application/config/version` | keep |
| `pitt_mp` | `{proto, sid, econ_q, xfer}` | added (unknown keys are ignored by the game) |

Encoding: `JSON.stringify` → zstd → sha256 → 32 KB chunks on channel 1. Several joins within 2 s share
one build. `mp dump snapshot` writes the last one as plain JSON to the mod data dir (debugging, manual only).

### 9.2 Client apply (one path for Start and late join)

1. `save.isolate {enabled:true, path:<session file>}` (local scope, L1).
2. Write the snapshot **encrypted** with `SaveManager.SAVE_PASSWORD`, read from the live autoload and never
   copied into the repo. The game's reader then takes its normal path. Plaintext is the fallback
   (save_manager.gd:456).
3. Achievements presence step 1. Detach UnlockManager (6.3).
4. Do what `_on_load_pressed` does, minus `set_active_slot`:
   - `GameProgression.reset_run_state()`;
   - `current_phase = snap.phase`;
   - `GameState.sandbox_mode = false`;
   - `SaveManager.should_load_on_ready = true`;
   - `menu._pending_new_game = false`;
   - `menu._launch_game("res://scenes/world.tscn")` on the `MainMenu` group node.
5. The game's LoadingScreen, pool init, `load_game()` and `apply_deferred_load()` apply money, items,
   unlock replay (`load_save_data` → `_execute_action`), phase, hole, gates and benches.
6. On `world.ready` + `save.applied`: install guards, avatars and the hole client mode, then send `ready`.
   The host answers with a full `econ`, the roster and avatar fan-out. Anything that changed during the
   load (including a phase change) is corrected by that full state.

---

## 10. Testing

### 10.1 Headless (`tools/test-headless.ps1`, every change)

The whole protocol runs host + 1-3 clients **in one process** over `transport_loopback`, each peer with its
own `FakeGameAdapter`. That is the only way to test several peers headless, because PittAPI and the game
autoloads are process singletons.

| Suite (owner) | Covers (risk ids) |
|---|---|
| `test_mp_net_scope` (NET) | L1 `scope:"local"`: builtins never reach the host (R18); remote local/internal refused; describe flags; L2 provider gate + install/uninstall restores LocalAuthority; L3 tagging; L4 check; L5 user root |
| `test_mp_net_codec` | frames, caps, unknown kind / stale `sid` / duplicate `q` dropped (R21, R22), chunk + zstd + sha256, avatar frame round trip |
| `test_mp_net_authority` | cmd → `dispatch_remote` with transport sender, forged origin ignored; res completes; timeout and session end → ERR_UNAVAILABLE (R42); remote cheat refused (R19); state flushed before res under jitter (R20) |
| `test_mp_net_session` | host/client machines: start, late join, join in phase 0 / STARTING waits (R40), TRANSITION deferred (R4, R7), ENDING refused, leave, host_left via bye / transport / `lobby_left("host_left")` (R8), abort during LOADING deferred (R23), teardown order and idempotence |
| `test_mp_net_econ` | apply idempotent; money > int64 as strings (R9); 1000 random interleavings of client contributions + host purchases converge with no double count or loss; `client_earnings` off reverts gains and charges fines (R10); full econ heals injected drift |
| `test_mp_net_progression` | `force_unlock` replay once per id, unknown id skipped; UnlockManager detach / restore; hole feed → host hole, client completion no-op; phase forward-only; phase 5 → ending |
| `test_mp_net_purchase` | rewire on a stub upgradeUI row; fail-closed rewire (R12); recall uses the original; host rejects locked / missing enabled_level / max / unaffordable / pool full (R11); crate escalation; double press sends once |
| `test_mp_net_snapshot` | keys equal the collectors' keys; strip table; client steps in order; isolation path never slot-like (R14) |
| `test_mp_net_guards` | pause guard unpauses in the same physics frame, freezes movement and camera, restores; InputMap erase / restore / re-erase on `bindings_changed` (R15, R16); puppets have no groups, body or `PlayerController` name (R1); interpolation under loss and `time_scale=0` (R5) |
| `test_mp_net_achievements` | progressed join grants nothing; a crossing after join grants once; `none`; cheat broadcast suppresses (R17) |
| `test_mp_net_two_process` | a second headless Godot via `OS.create_process` with `--pittapi-instance=peer2`, real **ENet localhost**: handshake, reject on mismatch, cmd round trip, econ between two fake adapters, avatar stream, host leave |
| `test_mp_net_contract` | 5.4 conformance of `session.gd` and UI's `fake_session.gd` |
| `test_mp_ui_menu` (UI) | stub MainMenu with the real node paths: button right after Play with Play's overrides and **no** `_on_play_pressed` connection (R27); idempotent re-injection; panel swap like the game; Esc handled before MainMenu (R28); gamepad focus; host-picking overrides incl. sandbox block (R41) |
| `test_mp_ui_lobby` | FakeLobbyService: member redraw; friend list via events; missed events recovered by Refresh / 10 s scan only while visible; mismatch and full rows disabled; empty state; `join_requested` on menu / in lobby / in world (R34); `session.leave()` on every exit path (R35) |
| `test_mp_ui_contract` | 5.3 conformance of all LobbyServices and NET's `stub_lobby.gd` |
| `test_mp_ui_strings` | every key used in `ui/` and every key in 5.5 is registered in `en` |
| `H-SP1` (existing suites) | all 102 existing tests pass with PittMultiplayer installed and no session (extensions inert) |

`test-headless.ps1` also runs `contract_check.py` on `ui/contract_ui.gd` and `net/contract_net.gd`.

### 10.2 Two-instance ENet loopback (`tools/test-mp-loopback.ps1`, NET)

Setup (`tools/mp-dev-setup.ps1`, once):
- `"<godot console>" --headless --path decomp --import` (minutes).
- Build `dist/mp-dev/mods/` (loader → `PittAPI/`, `PittMultiplayer/`, `PittMPTests/`).
- Write `decomp/override.cfg` (decomp is gitignored):
  ```ini
  [application]
  config/use_custom_user_dir=true
  config/custom_user_dir_name="PittMP-Dev"
  [autoload]
  PittAPI="*<repo>/dist/mp-dev/mods/PittAPI/pittapi.gd"
  ```

**T0 gate (R26).** A probe run prints `OS.get_user_data_dir()`. The script **aborts** unless it ends in
`PittMP-Dev`. The real `%APPDATA%\Godot\app_userdata\Project P.I.T.T` is SHA-256-hashed before and after
every run; any change fails the run.

Run (no game launch needed): two decomp editor instances (`Godot_v4.7.2-stable_win64.exe --path decomp`,
which skips `restartAppIfNecessary`), `--pittapi-instance=host` and `--pittapi-instance=client`, each armed
with `user://pittapi-<x>/mp_autotest.flag {role, port, run_id}`. Both run `achievements.suppress` and
`presence.suppress` first (same Steam account). Scenario:
1. Host: isolated new game, `phase.set 1`, dev lobby host on `127.0.0.1:27450`.
2. Client: join → snapshot → world → `in_game` within 180 s, with money and phase equal.
3. Avatars both ways within 1 s; a host teleport of 10 m arrives within 300 ms.
4. Host `money.add` reaches the client exactly. A client feeds its own maw → host money and
   `products_consumed` rise and the client converges with no double count.
5. A client buys an upgrade through the rewired button (pressed programmatically): host level +1, client
   +1. A client tool buy: host money − price, tool in the client's world only.
6. Host `phase.set 2`: the client plays the transition, both settle at 2. Host `unlock.force` → client
   notification.
7. Client pause menu open: the host's puppet on the client keeps moving, and the client tree is not paused.
8. Client leaves and rejoins at phase 2 (late join).
9. Host leaves: the client is on the main menu with `MP_END_HOST_LEFT`, isolation off, session file deleted.
10. A repeat of 3-4 with loopback conditioning (100 ms ± 30, 5 % loss).

Variant `-HostLive` (only stages allowed to launch the game): the host is the real game via
`steam://rungameid/4026250` with `-WithTests -WithMP`, the save hash guard and `save.isolate`; the client
is the decomp instance. This proves release-template behaviour (ENet present, `.gdc` vs decompiled `.gd`
differences). `projectpitt.exe` is killed after.

### 10.3 Manual Steam checklist (`docs/mp/MANUAL-STEAM-TEST.md`, owner)

Needs two PCs with two Steam accounts that are friends, the same install (`tools\install.ps1 -WithMP`),
and backups of both save folders. Steps:
1. Button placement, font, hover and click, controller focus, survives returning from a game.
2. Host lobby, centred list, Invite overlay.
3. Join list fills without Refresh; Refresh works; empty state.
4. Join via the row, the overlay invite (`join_requested`), and friends-list "Join Game" with the game
   closed (`+connect_lobby`).
5. Start → save panel → both in the world, smooth named puppets.
6. Shared money both ways; purchases never overspend; tool in the buyer's world only.
7. Unlock notification and phase-2 transition on both.
8. Pause and overlay on one peer: the other keeps playing, and the paused peer's own player is frozen.
9. Late join mid-game.
10. Client leave; host to main menu (dialog); host Alt-F4 ("connection lost" within about 15 s); no ghost
    lobby after 10 s.
11. Version mismatch row disabled.
12. Save hashes on B unchanged; A's slot holds the merged progress.
13. Achievements: nothing granted for progress loaded on join, a crossing fires once.
14. Network stats under 50 KB/s with 2 players.

### 10.4 Spikes (before the code that depends on them)

| Spike | Question | Blocks |
|---|---|---|
| S1 | Raw `ENetMultiplayerPeer` and `SteamMultiplayerPeer` work polled manually without a SceneMultiplayer (decomp instance; Steam: create + poll, no errors); else the standalone SceneMultiplayer fallback | NET transport |
| S2 | Dump `ClassDB.class_get_method_list("SteamMultiplayerPeer")` and `class_get_signal_list("Steam")` + method args for the 5.3 calls in the decomp instance; `getFriendGamePlayed` keys; channel count honours 4 | NET transport_steam, UI steam service |
| S3 / T0 | override.cfg custom user dir + PittAPI autoload in the decomp instance; Steam init in two processes on one account (or a clean degrade); `--pittapi-instance` | loopback harness |
| S4 | `ENetMultiplayerPeer` exists in the shipped release template | `-HostLive` only |
| S5 | Collectors have no side effects (headless + live diff); the encrypted session file loads via `load_game` under isolation; `profile.cfg` and slots untouched; a phase ≥ 1 load skips the elevator | snapshot |
| S6 | With the tree unpaused: pause menu, options, controls, upgrade terminal, Steam overlay and controller-loss auto-pause behave; `physics_frame` unpause loses no tick (P1) | pause guard |
| S7 | Five 104 px buttons fit at min and max menu scale (screenshot) | UI layout |
| S8 | Snapshot build time and size on a late-game save (< 100 ms, < 1 MB compressed) | snapshot |
| S9 | Master pitch and `time_scale` restored after leaving mid phase 3 (P2) | teardown |

---

## 11. Contracts (game members used)

Each stream keeps its own contract file in the core format (`const ENTRIES := ["feature|target|kind|member", ...]`):
- `ui/contract_ui.gd`, feature `mp.menu`: `main_menu._launch_game`, `_on_play_pressed`,
  `_on_return_save_load`, `_on_sandbox_pressed`, `_focus_current_panel`, `_on_mouse_entered`,
  `_play_ui_sound`, `_temporarily_ignore_input`, `ignore_input`, `click_sound`, `hover_sound`,
  `SLOT_COLOR_*`; `MenuManager.apply_menu_scales`; `InputManager.using_gamepad`,
  `input_device_changed`; `Steamworks.is_steam_initialized`.
- `net/contract_net.gd`, features `mp.snapshot`, `mp.econ`, `mp.progression`, `mp.purchase`, `mp.pause`,
  `mp.saves`, `mp.achievements`:
  - SaveManager collectors (`_save_game_state`, `_save_game_statistics`, `_save_hole`,
    `_save_vertical_gates`, `_save_cameras`, `_save_minable_blocks`, `_save_loop_puzzle`), `SAVE_PASSWORD`,
    `should_load_on_ready`, `peek_saved_phase`, `set_active_save_path`;
  - `WorkbenchSpawning.get_save_data`, `auto_machine_purchased`;
  - `UnlockManager._on_stat_changed`, `_on_phase_changed`, `force_unlock`, `milestones`,
    `unlocked_milestones`, `get_save_data`;
  - `GameProgression.change_phase`, `reset_run_state`, `current_phase`, `ending_active`, `elevator_exited`;
  - `GameState.apply_remote_tier`, `purchased_once`, `add_money`, `spend`, `buy`, `can_afford`;
  - hole `_on_product_consumed`, `_check_phase_completion`, `_trigger_ending`, `target_radius`,
    `phase_nutrition_total`;
  - upgradeUI `_create_upgrade_row`, `_create_tool_buy_row`, `_create_toy_buy_row`, `_spawn_tool_instance`,
    `_spawn_toy_instance`, `_play_sound`, `_create_success_effect`, `_spawn_floating_text`, `update_ui`,
    `update_credits`;
  - pause_menu `_on_save_pressed`, `_on_load_pressed`, `_on_delete_save_pressed`, `_on_main_menu_pressed`,
    `_return_to_main_menu`, `_on_quit_pressed`;
  - player_controller `last_safe_position`, `is_crouching`, `is_sprinting`;
  - `MenuManager.game_paused`, `current_menu`;
  - `InputManager.bindings_changed`, `apply_bindings`;
  - Steamworks `_granted`, `_probe_ids`, `_meets`, `_get_stat`, `evaluate_all`, `check_consumerism`.

Checked at boot with `api.contract_check` (L4). Any missing member disables **multiplayer as a whole**:
the button is disabled with `MP_ERR_INCOMPATIBLE_BUILD`. There is no partial MP mode.

---

## 12. MP2 plan: physics objects (designed, not built)

MP2 switches from private worlds to **one host-simulated world**. It is built without changing the
transport, the session, the lobby, the snapshot path, the econ mirror, purchases, avatars, pause or saves.

1. **MP2a, one-way world.** Clients drop their local objects. Host pooled bodies become client puppets:
   - spawned through `ObjectPoolManager.spawn(pool_id)` under the host entity id, giving correct visuals
     via `on_pool_spawn`;
   - `freeze = true`, `freeze_mode = KINEMATIC`, with collision kept for local player contact;
   - driven by a body frame (frame kind 4: eid varint, pos 1 mm, smallest-three quaternion, optional
     velocity, about 21-33 B) on channel 2, with the same interpolation buffer as avatars;
   - spawn, despawn and meta on channel 3 from the PittAPI `entity.spawned/despawned` events (ids are
     already authority-allocated). A state record for an unknown eid waits 500 ms for its spawn.

   Contributions (6.4) are deleted. The snapshot includes `object_pools`, applied as puppets.
2. **Host-only gameplay.** Thin `if not api.net.is_authority(): return` extensions at the sinks and force
   writers listed in production-objects H6/H7/H10 and world-physics §8: maw, press, crates, pinata,
   statue, gambling, ore processor, workbench completion, cauldron, fans, magnet, tractor, vacuum, cannon,
   spring pad, bumper, qa_arm, portals, `camera_pivot` breakage. The player-affecting branch keeps running
   on each client for its own player.
3. **MP2b, grab ownership.** Table `eid → {owner_peer, epoch}`, default owner = host.
   - A client grab predicts locally and sends `own_req`. The host grants first-come with `epoch+1`, or
     denies (consumed, in a cannon or vacuum bag).
   - The owner streams the held body at 30 Hz.
   - Release or throw sends the exact state back. The host restores the dynamic body and its metas.
   - Older epochs are ignored. Owner silence for 1.5 s, or a disconnect, releases the body. A paused owner
     releases (already enforced by the MP1 pause guard).
4. **MP2c, machines and tools.** Equipped tools are proxies on puppets; their effects are commands run on
   the host. Forces against remote players are sent as `player.impulse` (local scope) to the owning
   client. Host-only `AnimatableBody3D` ghost colliders for remote players. Interactions become
   `world.interact {eid, verb}`. Feed camera ids are host-assigned. `perf.pin_physics 60` on all peers.
5. **Budget.** A priority accumulator per client (distance to that client's avatar, velocity, recent
   interaction). Sleeping bodies send once. Default 48 KB/s per client, adaptive on RTT and loss. A lobby
   setting "physics detail" (low / normal / high).

---

## 13. Build order

1. Day 1, both streams: commit stubs for their own extensions and the test doubles (5.5, 5.6). NET:
   `mod.json` and a `main.gd` skeleton that tolerates missing UI files.
2. Spikes S1, S2, S3 (both streams read S2), then S5, S6, S7.
3. In parallel:
   - **UI:** models + base service → fake service → router and panels → injector + main_menu_ext → dev
     service → Steam service → strings → UI suites.
   - **NET:** loader L1-L6 + `test_mp_net_scope` → codec / transports / session / authority → snapshot +
     save guard → econ / contributions / progression / purchases → avatars / guards / achievements → NET
     suites → `mp-dev-setup` + `test-mp-loopback`.
4. Integration: both contract suites green; `test-mp-loopback.ps1` scenario 1-10; `-HostLive` in a launch
   stage; owner runs `MANUAL-STEAM-TEST.md`.

## 14. Known MP1 limitations (stated in the mod README and the join toast `MP_MP1_PRIVATE_WORLD`)

- Objects, machines and tools are per player until MP2. You see your friends walking, not their ducks.
- No host migration, chat, kick UI or sandbox sessions.
- Contributions trust friends (friends-only lobby, rate caps, sanity caps). MP2 removes them.

# Multiplayer architecture proposal: "physics-first"

Project P.I.T.T. v1.0.8 / Godot 4.7.2 / PittAPI 1.0. Milestone **MP1** (lobby, transport, session, avatars,
shared economy/progression, late join). Written by the "physics-first" architect. The angle is that the hardest
future problem is replicating a physics-heavy sandbox: hundreds of pooled RigidBody3D products, machines, held
objects, authority transfer on grab, snapshot interpolation, bandwidth on Steam relay. Every MP1 choice below is
checked against that problem, so MP1 does not block MP2.

Status: proposal. Nothing here is built. Line numbers refer to `decomp/scripts/*.gd` (read-only, never committed).

---

## 0. Decisions at a glance

| # | Decision | Why (physics-first) |
|---|---|---|
| D1 | **Packet-level transport over any `MultiplayerPeer`.** No Godot RPCs, no `MultiplayerSynchronizer`. One `Transport` interface: ENet (dev/tests), SteamMultiplayerPeer (real), in-process Loopback (headless), and a Conditioner decorator for latency, jitter and loss. | MP2 needs control over packet size, priority and budget per body. RPC and NodePath routing break on pooled nodes, whose names are not deterministic. |
| D2 | **Star topology, host-authoritative.** Clients only talk to the host. Host = peer 1 = PittAPI authority. | Physics is non-deterministic (Jolt, `randf` everywhere), so lockstep is impossible. |
| D3 | **4 channels:** 0 reliable control, 1 reliable bulk (snapshots), 2 unreliable state (avatars now, bodies in MP2), 3 reliable world-lifecycle (reserved for MP2 spawn/despawn/ownership). Matches the game's `steam/multiplayer_peer/max_channels=4`. | A multi-MB world snapshot must never stall commands, and lifecycle must never wait behind state. |
| D4 | **Reliable messages are JSON. High-rate state is quantized binary** (one codec family, `Quant`), shared by avatars (MP1) and bodies (MP2). | The avatar stream is the MP2 body stream with one entity kind. MP1 builds and proves the interpolation, clock and quantization code. |
| D5 | **Host time is the only clock.** `NetClock` does NTP-style ping/pong. Every state packet is stamped with host ticks. Physics is pinned at 60 Hz on every peer (`perf.pin_physics`). | Snapshot interpolation and authority hand-off need one time base. PerformanceMonitor changes tick rates per machine. |
| D6 | **MP1 world model: "parallel physics, shared economy".** Each peer runs its own copy of the physical floor. Nothing physical is replicated in MP1. Money, stats, items, unlocks, phase, hole growth and progression fixtures are host-authoritative and mirrored. Clients send their locally earned income to the host as **contribution deltas**, found by diffing the game's own serializer. No per-sink hooks are needed. | It gives playable co-op now without building half of MP2 in a hurry. MP2 turns the contribution path off and keeps everything else: the mirror, purchase commands, snapshot, avatars, clock, channels and pause. |
| D7 | **Late join = Start.** There is one code path. The host serializes a snapshot with the game's own `SaveManager` collectors. The client writes it as a plaintext `.save` under `user://pittapi/mp/`, isolates saves to it, and loads the world through the **vanilla load path** (`should_load_on_ready` → `load_game()` → `apply_deferred_load()`). | This is the game's own full-state applier, the same one used for saves. MP2 adds `object_pools`, applied as puppets. |
| D8 | **Pause = local "soft pause".** The tree is never paused while a session is running. The game's menus still open, and local input is frozen instead. | Pausing physics on the host freezes the shared world. In MP2 it would also freeze every body for every player. |
| D9 | **Remote players are lightweight puppets** (duck-mesh avatar + Label3D name). They are never in groups `player`/`main_camera`/`head`, so all 18 `get_first_node_in_group("player")` lookups keep their single-player meaning: "the local player". | The game's interaction code is local-player-centric by design. MP2 forwards player-affecting forces to the owning client and never simulates other players. |
| D10 | **Ownership is a first-class concept from day one.** Every replicated entity has `{eid, owner_peer, epoch}`. In MP1 only avatars use it (each peer owns its avatar). MP2 extends it to held bodies. | Authority transfer on grab is the core MP2 mechanic. The table, the epochs and the stale-packet rejection get built and tested in MP1. |
| D11 | **Steam lobby code stays out of gameplay code.** `LobbyService` (Steam, Dev/ENet, Fake) → signals → dumb panels. The Transport is separate from the LobbyService, because a lobby is not a connection. | The transport can be tested without Steam, and Steam lobby behaviour without a world. |

---

## 1. Facts this design relies on (verified in this pass)

| Fact | Evidence |
|---|---|
| The bundled GodotSteam DLL exposes `SteamMultiplayerPeer` with `create_host`, `create_client`, `host_with_lobby`, `connect_to_lobby`, `get_steam_id_for_peer_id`, `get_peer_id_for_steam_id`, `set_no_nagle`, `set_no_delay`, `set_server_relay`, and peer signals `peer_connected`/`peer_disconnected`. | `grep -a` of `<game>/libgodotsteam.windows.template_release.x86_64.dll` |
| Steam names used by the spec exist: `createLobby`, `joinLobby`, `leaveLobby`, `setLobbyData`, `getLobbyData`, `setLobbyJoinable`, `requestLobbyData`, `getLobbyOwner`, `getNumLobbyMembers`, `getLobbyMemberByIndex`, `getLobbyMemberLimit`, `setLobbyMemberData`, `getFriendCount`, `getFriendByIndex`, `getFriendGamePlayed`, `getFriendPersonaName`, `getPersonaName`, `getSteamID`, `activateGameOverlayInviteDialog`, `setRichPresence`, `getLaunchCommandLine`, `initRelayNetworkAccess`, `getPlayerAvatar`/`getMediumFriendAvatar`/`avatar_loaded`, signals `lobby_created`, `lobby_joined`, `lobby_chat_update`, `lobby_data_update`, `persona_state_change`, `join_requested`, `lobby_match_list`, `network_messages_session_request`. | same DLL grep. **Argument lists are from GodotSteam 4.x docs and memory, not verified.** Every handler is a lambda with defaulted parameters (`func(a=null,b=null,c=null,d=null)`), so a changed argument count does not break the connection, and every call is guarded with `has_method`. |
| `project.godot`: `steam/multiplayer_peer/max_channels=4`, `initialize_on_startup=true`, `embed_callbacks=false`. `Steamworks._process` is the only `run_callbacks` pump (PROCESS_MODE_ALWAYS). | save-boot-steam map §1, §4 |
| `Steamworks` skips `restartAppIfNecessary` when `OS.has_feature("editor")` (steamworks.gd:146), so the decomp project can run as a 2nd local instance. | orchestrator + map |
| Main menu: `Background` (ColorRect, `theme = res://assets/main_menu.tres`) holds the sibling panels `MenuButtons` / `MenuLoad` / `MenuSandbox` (VBoxContainer, anchors_preset 4, offsets 49/-76/785/384, `grow_vertical=2`). `Play` has a `PublicPixel` override at size 104; `MenuLoad/Load` uses 52. Signals are connected in the `.tscn` (persistent connections). | main_menu.tscn:399-589, 1609-1639 |
| `main_menu.gd`: `_unhandled_input` `ui_cancel` walks `MenuSandbox → MenuLoad → MenuButtons(→ Quit dialog)` and always calls `set_input_as_handled`. `_focus_current_panel` knows only its own 3 panels. `_process` touches only `MenuLoad`/`MenuSandbox` buttons. `ignore_input` + `_temporarily_ignore_input()` debounce 0.15 s. `_launch_game(path)` and `_on_resources_loaded` are the launch path. `_on_load_pressed` / `_on_new_game` use `_selected_slot`. | main_menu.gd:121-140, 76-84, 107-116, 652-714 |
| `MenuManager.open_menu` sets `get_tree().paused = true` for any menu except MainMenu. `request_auto_pause` does the same on overlay or controller loss. `PlayerController` (PROCESS_MODE_ALWAYS) and `MainCamera` return early from `_physics_process` when `get_tree().paused`. | menu_manager.gd:107-137, player_controller.gd:212, main_camera.gd:180/219 |
| `SaveManager.save_game` pauses and unpauses **synchronously inside one call** (save_manager.gd:248-256). | save_manager.gd |
| `_save_game_impl` builds the snapshot from pure collectors: `_save_game_state()`, `UnlockManager.get_save_data()`, `_save_game_statistics()`, `_save_object_pools()`, `_save_player_position()`, phase, `_save_cameras()`, `_save_hole()`, `_save_vertical_gates()`, fixture flags, `WorkbenchSpawning.get_save_data()`, music, `_save_minable_blocks()`, `_save_pickaxe()`, `_save_loop_puzzle()`, seen_items. `load_game()` reads `active_save_path`, accepts **plaintext** JSON (fallback), and replays milestones through `UnlockManager.load_save_data` → `_execute_action`. | save_manager.gd:273-301, 370-452, 456-474 |
| `_load_game_state` applies most keys only when present, but **some unconditionally with defaults** (`pickaxe_tier`, `uv_*`, `mining_bank`, `bank`, `keypad_revealed`, ...). It always re-applies `remote` (`apply_remote_tier`). So partial deltas must never be fed to it. Full mirrors are fine. | save_manager.gd:817-945 |
| `hole.gd`: `_on_product_consumed(type, base_value, body_id=-1)` → `_calculate_target_radius()` → `_check_phase_completion()` (line 201) → `change_phase`. `get_save_data()` / `apply_saved_state()` exist. | hole.gd:167-252, 361-395 |
| `UnlockManager` evaluates on `_on_stat_changed` / `_on_phase_changed` and in `_process` (floor checks). `force_unlock(id)` → `_trigger_milestone` is the live unlock path (notification + signal). | unlock_manager.gd:1509, 1612-1630, 2259 |
| Purchases are `button.pressed` lambdas built in `_create_upgrade_row` (`GameState.buy`), `_create_tool_buy_row` (`spend`, `purchased_once`, `check_consumerism`, `_spawn_tool_instance`) and `_create_toy_buy_row` (also crate price escalation). Each returns the row and keeps the button in `row.get_meta("button")`. | upgradeUI.gd:1176-1215, 1302-1382, 1509-1570 |
| `get_first_node_in_group("player")`: exactly **18** sites (cannon 1, elevator 1, fall_sequence 1, game_progression 3, golf_club 2, gravity_inverter 1, pause_menu 1, save_manager 3, security_room 3, test_black_hole 1, tractor_beam 1). `is_in_group("player")` body checks in 16 scripts. | grep |
| No humanoid mesh exists in the game. `res://scenes/duck.tscn` has a `Duck` MeshInstance3D (the mascot), already loaded at Play time by the pools. | duck.tscn:97 |
| PittAPI: `PittAPI._set_authority(a)`, `Commands.dispatch_remote(envelope, sender_peer)` (re-runs every gate, origin from the transport), `authority_only` defaults to **true** for every builtin. `Entities.can_allocate()` is false on non-authority peers. Players use slots 1..999. `state.snapshot()` exists. `save.isolate` exists and re-asserts locks every frame. | loader/core/*.gd |

---

## 2. Architecture overview

```
                      ┌──────────────── mods/PittMultiplayer (composition root: main.gd) ───────────────┐
 Steam ─ LobbyService ─┤ signals → MpMenuRouter → HostJoinPanel / LobbyPanel / JoinPanel  (dumb views)   │
 (Steam|Dev|Fake)      │                                                                                 │
                       │ Session (state machine) ── NetClock ── PeerRegistry (peer→slot, steam id, name) │
 MultiplayerPeer ─ Transport (MpPeerTransport | Loopback) [+ Conditioner]                                │
 (Steam|ENet)          │      │  Protocol (type byte, JSON / Quant codecs, chunker)                      │
                       │      ├─ ch0 control: HELLO/WELCOME/CMD/CMD_RESULT/ECON_*/PHASE/UNLOCK/SESSION    │
                       │      ├─ ch1 bulk:    SNAPSHOT_BEGIN/CHUNK/END                                    │
                       │      ├─ ch2 state:   AVATAR_STATE / AVATAR_BATCH   (MP2: BODY_STATE)            │
                       │      └─ ch3 world:   (MP2: SPAWN/DESPAWN/OWN_*/META)                            │
                       │                                                                                 │
                       │ NetAuthority (extends PittAPI authority.gd) ⇄ PittAPI Commands                  │
                       │ World services (only while in world):                                           │
                       │   AvatarSender / AvatarManager(puppets) / StateStream (interp buffer, shared)   │
                       │   EconReplicator (host) / EconMirror (client) / HoleSync / PhaseSync / UnlockSync│
                       │   PurchaseRouter (+upgrade_ui_ext) / FixtureSync / PauseGuard / SavePolicy      │
                       │   AchievementPolicy / SnapshotBuilder+Applier                                   │
                       │ GameAdapter: the ONLY code that touches game globals (fakeable)                 │
                       └─────────────────────────────────────────────────────────────────────────────────┘
```

Rules:
- **GameAdapter** wraps every game global and method this mod uses: GameState, SaveManager, UnlockManager, GameProgression, WorkbenchSpawning, MenuManager, Steamworks, `main_menu`, `hole`, `UpgradeUI`, player and camera. Headless tests run a host session and a client session **in one process**, each with its own `FakeGameAdapter`. This is the only way to test two peers headlessly, because PittAPI and the game autoloads are process singletons.
- Every service is a plain `RefCounted` or `Node` with injected dependencies (`adapter`, `transport`, `session`, `api`), and it has no `class_name`.
- Every new game member we touch is added to `loader/core/contract.gd`. A missing member disables the MP feature that needs it; nothing crashes.

---

## 3. Transport and abstraction

### 3.1 Interface (`transport/transport.gd`)

```
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int, reason: String)
signal packet(peer_id: int, channel: int, bytes: PackedByteArray)
signal opened()                        # host listening / client connected to host
signal failed(reason: String)
func host(opts: Dictionary) -> Error   # {port} | {steam: true}
func join(target: Dictionary) -> Error # {address, port} | {host_steam_id} | {lobby_id}
func close(reason := "") -> void
func send(peer_id: int, channel: int, bytes: PackedByteArray, reliable: bool) -> Error
func broadcast(channel: int, bytes: PackedByteArray, reliable: bool, except_peer := 0) -> void
func poll() -> void                    # called from Session._process (PROCESS_MODE_ALWAYS)
func local_peer_id() -> int; func is_host() -> bool; func peers() -> Array[int]
func stats(peer_id) -> Dictionary      # {rtt_ms, out_bps, in_bps, loss} best effort
func identity(peer_id) -> Dictionary   # {steam_id?, name?}
```

### 3.2 Implementations

- **`MpPeerTransport`** wraps any `MultiplayerPeer`, used **raw**: `poll()`, `get_available_packet_count()`, `get_packet()`, `get_packet_peer()`, `get_packet_channel()`, `set_target_peer`/`set_transfer_channel`/`set_transfer_mode` + `put_packet`. It is **not** assigned to `get_tree().get_multiplayer()`, so the game's tree stays single-player and nothing else sees the peer. Risk: SteamMultiplayerPeer may need a SceneMultiplayer to drive its handshake. Fallback: give it a private `SceneMultiplayer` set on our own subtree with `get_tree().set_multiplayer(mp, ^"/root/PittAPI/Mods/PittMultiplayer")` and use `send_bytes` / `peer_packet`. This is the first spike, S-MP1.
  - `EnetPeerFactory`: `ENetMultiplayerPeer.create_server(port, MAX_PLAYERS-1, 4)` / `create_client(addr, port, 4)`. Dev and tests only, bound to `127.0.0.1` by default.
  - `SteamPeerFactory`: `SteamMultiplayerPeer.new()`, `create_host(0)` / `create_client(host_steam_id, 0)`. If those signatures differ, `host_with_lobby(lobby_id)` / `connect_to_lobby(lobby_id)`. `set_no_nagle(true)` for the state channel. Call `Steam.initRelayNetworkAccess()` once at mod init. Peer→SteamID comes from `get_steam_id_for_peer_id`.
- **`LoopbackTransport`**: an in-process pair or star (`LoopbackHub.make(n)`) for headless tests, with no sockets.
- **`Conditioner`**: a decorator for any Transport that adds latency, jitter, loss, duplication, reordering and an outbound byte cap (token bucket). Used in headless tests, and optionally live (`mp_sim` config), to exercise interpolation and MP2 budgets on localhost.

### 3.3 Why not Steam NetworkingMessages directly

`sendMessageToUser` / `receiveMessagesOnChannel` exist and are a fallback. `SteamMultiplayerPeer` already maps Steam identities to Godot peer ids and gives the same API as ENet, which keeps one code path. `Transport` hides the choice either way.

### 3.4 Packet size rules (MP2-relevant from day one)

- Unreliable packets: **≤ 1100 bytes** (below the ENet MTU of about 1400 and Steam's unreliable fragmentation point of about 1200), each self-contained, with no dependency between packets.
- Reliable control messages: ≤ 16 KB. Anything bigger goes on ch1 as chunks.
- Snapshot chunks: 32 KB each, zstd-compressed (`PackedByteArray.compress(FileAccess.COMPRESSION_ZSTD)`), with a CRC32 of the whole payload checked at END.

---

## 4. Wire protocol

### 4.1 Frame

```
byte 0     type (u8)
byte 1     flags: bit0 compressed(zstd), bit1 chunk, bit2..7 reserved
bytes 2..  body: reliable → UTF-8 JSON object; unreliable state → Quant binary
```

Every JSON body carries `"v": PROTOCOL_VERSION`. The host rejects a mismatch in HELLO. A body that fails to parse, is too big, or exceeds the per-peer rate (control: 120 msg/s, state: 60 pkt/s) is dropped and counted. Past a threshold the peer is kicked with reason `protocol`.

### 4.2 Message types

| Type | Name | Ch | Dir | Body |
|---|---|---|---|---|
| 0x01 | HELLO | 0 | C→H | `{v, pitt_version, pittapi_version, mp_version, mods:[id@ver client_required], name, steam_id?}` |
| 0x02 | WELCOME | 0 | H→C | `{session_id, peer_id, slot, host_tick, tick_hz:60, peers:[{peer,slot,name,color}], state:"lobby"\|"in_game", rules:{achievements, cheats_for_clients}}` |
| 0x03 | REJECT | 0 | H→C | `{reason: "version"\|"full"\|"mods"\|"banned"\|"protocol", detail}` |
| 0x04 | BYE | 0 | both | `{reason: "leave"\|"host_left"\|"kicked"\|"session_end"\|"error", msg_key}` |
| 0x05/06 | PING/PONG | 0 | both | `{t0}` / `{t0, host_tick, host_ms}` (NetClock) |
| 0x07 | PEERS | 0 | H→C | full peer list on change |
| 0x10 | CMD | 0 | C→H | the PittAPI command envelope, unchanged (`{v,id,name,args,mod,origin,t}`) |
| 0x11 | CMD_RESULT | 0 | H→C | `{id, ok, value, error, code}` |
| 0x12 | MOD_EVENT | 0 | H→C | `{name: "mod.<id>.*", payload}` for mod events emitted with `replicate:true` |
| 0x20-22 | SNAPSHOT_BEGIN/CHUNK/END | 1 | H→C | BEGIN `{snap_id, tick, bytes, chunks, crc}`; CHUNK binary; END `{snap_id}` |
| 0x23 | CLIENT_READY | 0 | C→H | `{snap_id}` (world loaded and snapshot applied) |
| 0x30 | ECON_FULL | 0 | H→C | `{rev, tick, mirror:{game_state, game_statistics}, ack}` |
| 0x31 | ECON_DELTA | 0 | H→C | `{rev, tick, set:{path: value}, ack: contrib_seq_for_this_peer}` |
| 0x32 | ECON_CONTRIB | 0 | C→H | `{seq, add:{path: "+digits"\|int}, max:{path: n}, or:{path: true}}` |
| 0x33 | HOLE | 0 | H→C | `hole.get_save_data()` + `{tick}` (≤ 4 Hz, on change) |
| 0x34 | HOLE_FEED | 0 | C→H | `{type, base_value}` (client maw → host hole) |
| 0x35 | PHASE | 0 | H→C | `{phase, from, tick}` |
| 0x36 | UNLOCK | 0 | H→C | `{ids:[...]}` (new milestones, in order) |
| 0x37 | FIXTURE | 0 | H→C | `{kind:"auto_bench"\|"manual_bench"\|..., key, level}` |
| 0x40 | AVATAR_STATE | 2 | C→H | Quant (see 4.4) |
| 0x41 | AVATAR_BATCH | 2 | H→C | Quant: up to 9 avatar records + host's own |
| 0x42 | AVATAR_META | 0 | both | `{slot, held_pool?, equipped_pool?, torch, crouch}` (on change) |
| 0x50-5F | reserved MP2 | 3/2 | | SPAWN, DESPAWN, BODY_STATE, OWN_REQ, OWN_GRANT, OWN_DENY, OWN_RELEASE, META, INTERACT |
| 0x60 | SESSION | 0 | H→C | `{event: "start"\|"end"\|"ending"\|"reload", ...}` |

### 4.3 Channels

| Ch | Mode | Carries | Why separate |
|---|---|---|---|
| 0 | reliable, ordered | control, commands, econ, phase, unlocks | small, latency-sensitive, must stay in order relative to each other |
| 1 | reliable, ordered | snapshot chunks | a 2 MB snapshot (MP2) must not delay a purchase reply |
| 2 | unreliable | avatar state (MP1), body state (MP2) | latest-wins; loss must not stall anything |
| 3 | reliable, ordered | MP2 entity lifecycle and ownership | spawn must arrive before meaningful state for that eid, but must not queue behind ch0 traffic |

Ordering *between* channels is never assumed. A state packet for an unknown eid is buffered for 500 ms waiting for its SPAWN, then dropped. Each state record carries the eid's ownership `epoch`, and records with an older epoch are discarded.

### 4.4 Quant codec (`world/quantize.gd`) — shared by avatars and MP2 bodies

| Field | Encoding | Size |
|---|---|---|
| packet header | type u8, flags u8, host_tick u32 (sender's estimate for client→host), count u8 | 7 |
| record id | entity id varint (avatar = slot 1..10) | 1-5 |
| epoch | u8 (wraps; compared mod 256) | 1 |
| position | 3 × i24, 1/1024 m, ±8192 m (covers world plus fall zones) | 9 |
| rotation | avatar: yaw u16 + pitch i16. Bodies: smallest-three quaternion, 2+3×10 bits | 4 |
| velocity (opt, flag) | 3 × i16, 1/128 m/s, ±256 m/s | 6 |
| angular vel (opt, MP2) | 3 × i16, 1/256 rad/s | 6 |
| state bits | u8: crouch, sprint, airborne, torch, sleeping(MP2), held(MP2), teleported (no-interp) | 1 |

An avatar record is about 21 bytes, so 20 Hz is about 0.5 KB/s per avatar. A full 10-player AVATAR_BATCH is about 220 bytes. An MP2 body record is about 21-33 bytes.

### 4.5 Bandwidth budget (planning numbers)

| Stream | Rate | Per client (host upstream) | 10 players, host total |
|---|---|---|---|
| avatars | 20 Hz batch | 9 × 21 B × 20 = 3.8 KB/s | 34 KB/s |
| econ deltas | ≤ 10 Hz, change-driven | < 1 KB/s typical | < 10 KB/s |
| ping | 1 Hz | negligible | |
| **MP2 bodies** | 20 Hz, priority-budgeted | **cap 48 KB/s default** (`mp_body_budget_kbps`) | 430 KB/s (≈3.5 Mbit/s) |

MP1 total is about 40 KB/s, which is fine on Steam relay. For MP2 the host's uplink is the limit. The budget is configurable, and the host lowers it adaptively when `stats().rtt_ms` or loss climbs. A lobby setting "Physics detail: low/normal/high" maps to 24/48/96 KB/s.

---

## 5. Clock and ticks (`core/net_clock.gd`)

- The host keeps `host_tick` = physics frames since the session started, counted from `get_tree().physics_frame` while the session is running and never paused (see §12).
- Clients send PING `{t0}` once per second (4/s for the first 3 s). PONG returns `host_tick` and `host_ms`. The client keeps the 8 lowest-RTT samples and estimates `offset = host_ms + rtt/2 - local_ms`, slewed by at most 2 ms per second (never jumps unless the error is over 250 ms).
- `render_time = host_now_ms - interp_delay_ms`, with interp_delay = max(100 ms, 2 × send interval + jitter estimate). It is the same value for avatars and MP2 bodies.
- On session start every peer runs `perf.pin_physics {hz:60}` (it stops PerformanceMonitor from switching 60/40/30 Hz). The tick rate is restored at session end. Frame-count gameplay (portal `TELEPORT_LOCK_FRAMES`, piston `rider_claim_window`) then behaves the same on every peer, which matters for MP2.

---

## 6. Integration with PittAPI (Commands / Authority / Entities / Events)

### 6.1 NetAuthority (`core/net_authority.gd`, extends the loader's `core/authority.gd`)

- Host: `is_authority() = true`, `local_peer_id() = 1`, `get_peers()` from PeerRegistry, `is_multiplayer() = true`, `get_kind() = "steam"|"enet"|"loopback"`. `submit()` = local dispatch, exactly like the base class.
- Client: `is_authority() = false`, `local_peer_id()` from WELCOME. `submit(env)`:
  1. reads `commands.describe(env.name).scope`;
  2. `scope == "local"` → `commands.dispatch_envelope(env)` locally, then `complete`;
  3. otherwise sends CMD on ch0 and parks the envelope in `pending[id]` with a 10 s timeout (`ERR_UNAVAILABLE "host did not answer"`). On CMD_RESULT it calls `complete(env, result)`.
- Host receive: `CMD` from peer P → `commands.dispatch_remote(env, P)`. The origin comes from the transport and never from the envelope. Cheat commands from remote peers are refused unless the host's `mp_allow_client_cheats` is true. The reply goes back as CMD_RESULT.
- Installed on `session_started` through a new provider hook (6.4). On session end, `LocalAuthority` is restored. Any pending client results complete with `ERR_UNAVAILABLE "session ended"`.

### 6.2 Command scope (loader change, small)

The current `authority_only: bool` cannot express "runs on whoever issued it". Add `scope: "authority" | "local"`. `"owner"` is reserved for MP2 entity-owner commands. `authority_only` stays as a compatibility alias (`true` → `"authority"`, `false` → `"local"`). The dispatcher denies `scope=="authority"` on non-authority peers, as today, and denies `scope=="local"` from remote senders.

| Builtin | Scope | Reason |
|---|---|---|
| `money.*`, `bank.set`, `item.buy`, `phase.set`, `unlock.*`, `entity.*` | authority | shared state / host physics |
| `player.teleport`, `player.impulse` | **local** | every peer simulates its own player |
| `achievements.suppress`, `perf.pin_physics`, `save.isolate`, `presence.suppress` | **local** | per-machine policy |

New MP commands (namespaced `PittMultiplayer.*`), all with `scope: "authority"` unless noted:
`PittMultiplayer.buy_tool {tool, level}`, `PittMultiplayer.buy_toy {toy}`, `PittMultiplayer.kick {peer}` (host UI only), plus `internal` replay commands that run only on clients: `PittMultiplayer.apply_econ`, `PittMultiplayer.apply_phase`, `PittMultiplayer.apply_unlocks`. They go through `dispatch_envelope(env, is_replay=true)`, so the cheat gates and the cheated flag are skipped and `command.executed` is audited with `origin = 1`.

### 6.3 Events

- Clients do **not** receive replicated core events. Their own GameBridge sees mirrored state change and emits `money.changed`, `phase.changed`, `unlock.milestone`, `item.level_changed` from local observation, so mods behave the same on every peer.
- Loader addition: `events.push_origin(peer, source)` / `pop_origin()`. While the EconMirror or PhaseSync applies host state, events get `origin = 1, source = "net"`, so a mod can tell "the host did this" from "this happened here".
- `mod.<id>.*` events emitted on the host with `api.events.emit(name, payload, {replicate: true})` are forwarded as MOD_EVENT (host → all). Re-emission on the client goes through `emit_internal` with origin 1.
- `net.session_started`, `net.session_ended`, `net.peer_joined`, `net.peer_left` are added to the catalog and emitted by `api.net`.

### 6.4 Loader changes (complete list; each small)

| File | Change | Justification |
|---|---|---|
| `api/net.gd` + `pittapi.gd` | `api.net.install_provider(authority) -> Error` / `uninstall_provider()`, allowed only for a mod whose manifest declares `"provides": ["net"]` (one provider at a time). It calls `_set_authority`, emits `session_started`/`session_ended`/`peers_changed`, and adds `get_peer_info(peer) -> {slot,name,steam_id}` and `get_players() -> Array[int]` (player entity ids). | Mods cannot reach `PittAPI._set_authority` through `api`, and should not. |
| `schema/mod.schema.json`, `core/manifest.gd` | Optional `provides: [String]`. | Gate for the provider. |
| `core/commands.gd`, `core/builtin_commands.gd` | `scope` option (6.2). | Client-local commands. |
| `core/events.gd` | `push_origin`/`pop_origin`; `emit(..., {replicate})` flag recorded on the event. | Origin truthfulness. |
| `core/entities.gd` | (a) `set_local_namespace(true)`: on non-authority peers, game-side pooled spawns get **negative** local ids (−1, −2, …) instead of none, so PittAPI keeps working for MP1 client-local objects and can never collide with host ids. (b) Design-only hooks for MP2: `register_remote(eid, node, pool_id)`, `owner_of`/`set_owner(eid, peer, epoch)`. | MP1 parallel worlds; MP2 mirrors. |
| `api/ui.gd` (new facade) + `pittapi.gd` | `api.ui.on_main_menu(cb)` (fires each time a MainMenu node becomes ready, including re-entry), `api.ui.main_menu_button_after(anchor="Play", name, text_key, cb) -> Button` (duplicates the anchor **without** signals), `api.ui.add_menu_panel(id, control, like="MenuLoad")` (copies layout from the sibling), `api.ui.show_panel(id)`/`back()`, `api.ui.confirm(title_key, body_key, on_ok, ok_key, cancel_key, focus)` (wraps the game's `ConfirmDialog` with the menu's click/hover sounds), `api.ui.add_translations(locale, dict)`. Owned panels are removed on quarantine. | The spec asks for a menu injection API, and other mods can reuse it. |
| `pittapi.gd` | Editor-only env `PITTAPI_USER_SUBDIR` → `user://pittapi_<x>/`. | Two decomp instances share one user dir (§17.2). |
| `core/contract.gd` | New members: `main_menu._launch_game`, `_on_load_pressed`, `_on_new_game`, `_selected_slot`, `ignore_input`, `_temporarily_ignore_input`, `click_sound`, `hover_sound`; `SaveManager._save_game_state`, `_save_game_statistics`, `_save_object_pools`, `_save_cameras`, `_save_hole`, `_save_vertical_gates`, `_load_game_state`, `_load_game_statistics`; `UnlockManager._on_stat_changed`, `_on_phase_changed`, `force_unlock`; hole `_check_phase_completion`, `get_save_data`, `apply_saved_state`; upgradeUI `_create_upgrade_row`, `_create_tool_buy_row`, `_create_toy_buy_row`, `_spawn_tool_instance`, `_spawn_toy_instance`; `WorkbenchSpawning.spawn_auto_workbench`; PauseMenu `_return_to_main_menu`. Feature groups: `mp.menu`, `mp.snapshot`, `mp.econ`, `mp.purchase`, `mp.hole`. | Game-update resilience. |

Everything else lives in `mods/PittMultiplayer/`.

---

## 7. Session lifecycle and scene coordination

### 7.1 States

```
Host:   IDLE → LOBBY_HOSTING → STARTING (host world loading) → IN_GAME ─┬→ ENDING (phase 5) → LOBBY_HOSTING
                                                                       └→ (pause→Main Menu / quit) → IDLE (BYE host_left)
Client: IDLE → LOBBY_JOINED → CONNECTING → SYNCING (snapshot rx) → LOADING (world) → IN_GAME
                    ↑______________________ BYE / disconnect / host left ______________________|
```

The lobby (Steam) and the transport session are separate. A client is in the Steam lobby from Join onwards. It opens the transport when the lobby `state` is `in_game`, or when it receives `SESSION start`.

### 7.2 Start (host)

1. In the Lobby panel the host picks a **save slot** in a slot selector row built with the same style as `MenuLoad/ScrollContainer/SlotContainer`, filled from `api.saves.get_slot_infos()`, with the choices "Continue slot N" or "New game". Sandbox is excluded in MP1. *(Owner question Q1.)*
2. Start → `Session.host_start()`: `transport.host()` (ENet port or Steam listen socket), then `main_menu._selected_slot = n`, then `main_menu._on_load_pressed()` or `_on_new_game()`. This is the game's own launch path, unchanged, including slot selection, corrupt quarantine and starter crates.
3. On `world.ready` (PittAPI event) on the host: run `perf.pin_physics`, start the World services, set lobby data `state=in_game`, and broadcast `SESSION start {session_id}` to lobby members already connected.

### 7.3 Join / late join (client): one path

1. Lobby `state == in_game`, or `SESSION start` arrives → CONNECTING: `transport.join({host_steam_id: getLobbyOwner(lobby)})` (ENet: address/port from lobby data in the Dev service).
2. HELLO → host checks versions and mods → WELCOME, or REJECT (shown with the game's ConfirmDialog, then back to the Join panel).
3. The host builds a snapshot (§13) and streams it on ch1. The client verifies the CRC and writes `user://pittapi/mp/<session_id>.save` (plaintext JSON) through SafeFS.
4. LOADING. The client prepares the vanilla load the same way `_on_load_pressed` does:
   - `save.isolate {enabled:true, path: "user://pittapi/mp/<session_id>.save"}`. This sets save_locked, turns autosave off, re-asserts both every frame, and keeps the path away from slots and `profile.cfg`.
   - `GameProgression.reset_run_state()`; `GameProgression.current_phase = snapshot.phase`; `GameState.sandbox_mode = snapshot.sandbox`; `SaveManager.should_load_on_ready = true`; `main_menu._pending_new_game = false`;
   - `main_menu._launch_game("res://scenes/world.tscn")`. LoadingScreen → pool init → world → `player_controller._ready` → `SaveManager.load_game()` → `apply_deferred_load()` → `GameState.start_game()`.
5. On `world.ready` the client applies session-only patches: UnlockManager detached (§11.6), hole extension in client mode, avatars started. Then it sends CLIENT_READY.
6. The host sends ECON_FULL (whatever changed while the client loaded) and adds the client to the avatar fan-out. Its avatar appears for everyone.

The snapshot is **applied by the game, not by us**. That covers money, items, milestones (via `_execute_action` replay, exactly like a load), phase (with the music and `phase_changed` that `load_game` emits), hole radius, gates, cameras, workbenches, loop puzzle, keypad/escape code, minable blocks and seen badges.

### 7.4 Leave and disconnect

| Event | Detection | Effect |
|---|---|---|
| Client chooses Main Menu or Quit (pause menu) | pause_menu_ext / `scene.changed → main_menu` / `tree_exiting` | BYE `leave`, transport close. On Main Menu the client also `leaveLobby` (spec: no ghost lobbies), `save.isolate false`, and restores the UnlockManager links and the tick rate. |
| Client crashes or times out | transport `peer_left` (ENet timeout about 5 s; Steam connection closed or problem) | Host removes the avatar and frees the slot. Toast "X left". |
| **Host chooses Main Menu** | host `scene.changed → main_menu` while IN_GAME | Host broadcasts `BYE host_left` (msg key `MP_HOST_ENDED`), closes the transport, sets lobby `state=waiting`, and returns to the Lobby panel. Clients run the pause menu's `_return_to_main_menu()` (the game's own full singleton reset + scene change) and then show the ConfirmDialog "The host ended the session" on the main menu. The router opens the Lobby panel again, because they are still lobby members and can be started again. |
| Host quits the game or crashes | transport disconnect, **or** `lobby_chat_update` with the owner leaving, **or** `getLobbyOwner() != original_host` (Steam migrates lobby ownership) | Same client path with key `MP_HOST_LEFT`. The client also leaves the Steam lobby. **No host migration in MP1 or MP2.** |
| Host reloads (F9 / pause Load) | blocked in MP1 (§15) | — |
| Ending (phase 5) | PhaseSync receives `PHASE 5` | §11.5 |

The order of resets on a client: ConfirmDialog is shown only after the main menu scene is ready (`api.ui.on_main_menu`), so it is not destroyed by the scene change.

### 7.5 Scene coordination summary

The only scene changes in a session are: menu → world (per peer, async, no need to sync), world → black-hole ending (§11.5), and world → menu (§7.4). `begin_load_reload` (in-game reload) is blocked in a session. No peer ever waits on another peer's loading screen. The host simulates without pausing, and a late joiner simply arrives.

---

## 8. Lobby service and UI

### 8.1 LobbyService (`lobby/lobby_service.gd` base + model)

```
signal lobby_entered(info: LobbyInfo)          # we are in a lobby (host or member)
signal members_changed(members: Array)         # [MemberInfo{steam_id, name, is_host, slot?, avatar_tex?}]
signal lobby_data_changed(info: LobbyInfo)     # state/members/version from lobby data
signal lobby_left(reason: String)              # "left"|"host_left"|"kicked"|"error"
signal friend_lobbies_changed(list: Array)     # [LobbyInfo{lobby_id, host_name, members, max, state, joinable, reason}]
signal join_failed(reason: String)
signal join_requested(lobby_id: int)           # invite accepted / +connect_lobby
func host(max_members := 10) -> void
func join(lobby_id: int) -> void
func leave() -> void
func invite() -> void
func set_state(s: String) -> void              # "waiting"|"in_game"
func scan_friends() -> void                    # Refresh
func set_scanning(on: bool) -> void            # Join panel visible → 10 s fallback timer on/off
func current() -> LobbyInfo; func is_host() -> bool; func host_steam_id() -> int
```

- **SteamLobbyService** (all Steam calls live here):
  - Host: `createLobby(LOBBY_TYPE_FRIENDS_ONLY, MAX_MEMBERS=10)` → `lobby_created(connect, lobby_id)` → `setLobbyData` for `pitt_version`, `pittapi_version`, `mp_version`, `mods_hash`, `host_name`, `members`, `state=waiting`, `transport=steam`; `setLobbyJoinable(true)`; rich presence `connect = "+connect_lobby <id>"`, `steam_player_group = <id>`, `steam_player_group_size = n`.
  - Rich presence: `Steamworks._push_presence` writes only `money` and `steam_display` every 0.3 s, so our keys survive. `clear_presence()` (`clearRichPresence`) would wipe them, so we re-assert every 5 s while in a lobby.
  - Members: initial fill after `lobby_joined` via `getNumLobbyMembers`/`getLobbyMemberByIndex`/`getFriendPersonaName`. Rebuilt on `lobby_chat_update`. Names and avatars refresh on `persona_state_change`. The host updates `members` lobby data on every change, because non-members only see counts that way. Lobby state comes from `lobby_data_update`.
  - Join discovery: loop `getFriendCount(FRIEND_FLAG_IMMEDIATE)` / `getFriendByIndex`. If `getFriendGamePlayed(f).id == 4026250` and `lobby` is set → `requestLobbyData(lobby)` → the row fills on `lobby_data_update`. Then `persona_state_change(friend)` re-checks that friend. Refresh button; the 10 s fallback rescan runs only while the Join panel is visible.
  - Version gate in the row: `pitt_version`/`pittapi_version`/`mp_version`/`mods_hash` mismatch → row disabled with the reason. `members >= max` → "Full". `state == in_game` → "In game" (still joinable).
  - `join_requested(lobby_id, friend)` and `+connect_lobby <id>` (from `OS.get_cmdline_args()` and `Steam.getLaunchCommandLine()`, checked at mod init and on first main-menu ready) → `join_requested` signal. The router goes straight to the Lobby panel. If the player is in a world (single-player), it first asks with ConfirmDialog "Leave your game to join?" and uses the pause menu's return path.
  - `leave()` → `leaveLobby` + clear rich presence keys. It runs on every return to the main menu outside a session, and on `tree_exiting`.
- **DevLobbyService**: same signals over ENet for dev and tests. "Host" opens the ENet server immediately, and its member list = connected peers + names from HELLO. "Join" panel rows come from `mp_dev_targets` config (default `127.0.0.1:47777`). Lobby data is carried in WELCOME/PEERS.
- **FakeLobbyService**: scripted, for headless tests (friends with lobbies, member churn, lost events, mismatched versions).

### 8.2 Screens (dumb views)

`MpMenuRouter` holds a stack of panel ids (`mp_hostjoin`, `mp_lobby`, `mp_join`). Esc / `ui_cancel` = pop. Panels subscribe to LobbyService signals in `_enter_tree`, disconnect in `_exit_tree`, and redraw from `current()`.

| Panel | Contents (all text = translation keys) |
|---|---|
| HostJoin | `MP_HOST`, `MP_JOIN`, `MENU_BACK` (52 px, like MenuLoad buttons) |
| Lobby | Title `MP_LOBBY` (gold Gravity font like the menu titles), center member list (rows styled like save-slot rows: name, "HOST" tag, ping when in game), host-only: slot selector, `MP_START`, `MP_INVITE`; everyone: `MP_LEAVE` (ConfirmDialog `MP_CONFIRM_LEAVE`) |
| Join | List of friend lobbies (`host_name`, `members/10`, `MP_STATE_IN_GAME`/`MP_STATE_WAITING`, disabled reason), empty state `MP_NO_FRIENDS_HOSTING`, `MP_REFRESH`, `MENU_BACK` |

### 8.3 Injecting into `main_menu.tscn` without breaking the game's menu code

These come from reading `main_menu.gd`:

1. **Hook:** `api.ui.on_main_menu(cb)`. It fires on `scene.changed(kind=main_menu)` after `MainMenu._ready`, deferred one frame. It runs on every re-entry, because the main menu scene is re-instanced by `change_scene_to_file` / LoadingScreen. Options and Credits do not re-instance it: `MenuManager.open_menu` only hides MainMenu, and our nodes stay inside its tree.
2. **Multiplayer button:** `var b = play.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)`. **`DUPLICATE_SIGNALS` is excluded on purpose**: Play's `pressed → _on_play_pressed` is a persistent `.tscn` connection, and the default flags would copy it (pressing Multiplayer would open the save panel). Then `b.name = "Multiplayer"`, `b.text = "MP_MULTIPLAYER"`, `MenuButtons.add_child(b)`, `move_child(b, play.get_index() + 1)`. Connect `mouse_entered → main_menu._on_mouse_entered` (the game's own hover sound) and `pressed → router.open("mp_hostjoin")`. Our handler honors `main_menu.ignore_input`, calls `main_menu._play_ui_sound(main_menu.click_sound)` and `main_menu._temporarily_ignore_input()`, which is the same debounce the game uses. The font override (PublicPixel 104) comes along with the duplicate.
3. **Panels:** our VBoxContainers are added under `Background`, so they **inherit `main_menu.tres` from Background** and no theme load is needed. They copy `layout_mode`, anchors, offsets and `grow_*` from `Background/MenuLoad` at runtime, so a restyle of the game carries over. Buttons copy the font override from `MenuLoad/Load` (52). List rows reuse `res://scenes/save_slot_row.tscn` (instantiated as a `Button` with the same toggle/ButtonGroup/focus settings as `_populate_slots`), and we fill only its label text.
4. **Panel swap:** `MenuButtons.visible = false; panel.visible = true` and the reverse. This is the game's pattern exactly. We never touch MenuLoad or MenuSandbox.
5. **Esc / back:** the game's `_unhandled_input` swallows every `ui_cancel` (it always calls `set_input_as_handled`). Our panels are descendants of MainMenu, so they receive `_unhandled_input` **before** it does (reverse tree order). We handle `ui_cancel` and mark it handled. If ours were missed, the game's chain finds none of its panels visible and does nothing. It never opens the Quit dialog, because MenuButtons is hidden while our panel shows.
6. **Gamepad focus:** the game's `_focus_current_panel` ignores our panels. We connect `InputManager.input_device_changed` ourselves and `grab_focus()` the first enabled button (and focus it on each panel show when `InputManager.using_gamepad`), mirroring `_grab_first_button`.
7. **Layout risk (check live):** MenuButtons is 460 px tall with `grow_vertical = both`. A fifth 104 px button will make it grow by about 60 px up and down, possibly under the "P.I.T.T." title. A screenshot check is planned. If it overlaps, the mitigation is to reduce `theme_override_constants/separation` on MenuButtons only while our button exists, in a stage allowed to launch the game.
8. **Leaving:** returning from any MP panel to MenuButtons outside a session calls `lobby.leave()`.

### 8.4 Translations

`ui/i18n/en.json` (+ cheap locales). `api.ui.add_translations` builds a `Translation` per locale and calls `TranslationServer.add_translation`. Keys: `MP_MULTIPLAYER, MP_HOST, MP_JOIN, MP_LOBBY, MP_START, MP_INVITE, MP_LEAVE, MP_REFRESH, MP_NO_FRIENDS_HOSTING, MP_STATE_IN_GAME, MP_STATE_WAITING, MP_FULL, MP_VERSION_MISMATCH, MP_MODS_MISMATCH, MP_CONFIRM_LEAVE_TITLE/BODY, MP_HOST_ENDED, MP_HOST_LEFT, MP_CONNECTING, MP_SYNCING, MP_JOIN_FAILED, MP_SLOT_NEW, MP_SLOT_CONTINUE, MP_HOST_SAVES, MP_TOAST_JOINED, MP_TOAST_LEFT`.

---

## 9. The MP1 world model: "parallel physics, shared economy"

**Problem.** MP1 excludes physics replication. A client still needs something to do, and MP2 must still not be blocked.

| Option | Client experience in MP1 | MP2 impact | Verdict |
|---|---|---|---|
| A. Host world only, clients have no physics objects | Walk around and buy upgrades. Nothing to craft. | none | Not playable |
| B. One-way host object streaming in MP1 | See host objects, cannot touch them | This is MP2a, pulled forward | Out of scope (too big) |
| **C. Parallel physics, shared economy** | Each peer has its own floor (manual duck bench is baked into world.tscn; benches spawn from replicated progression; tools bought spawn for the buyer). Money, stats, unlocks, phase and hole are one shared co-op state. You see your friends walking. | MP2 deletes client-local objects and turns off the contribution path. Every other part stays. | **Chosen** |

How C works:
- **Host** runs the game unchanged. It is the authority for every shared field (§11.1).
- **Clients** play normally on their local floor. Their game code mutates GameState locally (maw income, combo payouts in hud.gd:670, press, bonuses, fines). No sink hooks are needed: `EconMirror` diffs the game's own serializers (`_save_game_state` + `_save_game_statistics`) against the last host mirror and sends the **difference as a contribution** (§11.3). The host merges it, which drives the host's milestones, achievements and phase. The host then mirrors the result back.
- The **hole** is the one progression sink outside GameState. On clients the hole extension forwards nutrition to the host (`HOLE_FEED`) instead of growing locally, and it applies the host's hole state.
- Entity ids: client-local objects get negative local ids (§6.4), so PittAPI events keep working for client mods and never collide with host ids.
- This is said honestly in the UI: a toast on joining, "Shared money & progress. Objects are per-player until a later update."

What carries over unchanged to MP2: the transport, protocol, clock, lobby, session, snapshot (plus `object_pools`), EconReplicator/Mirror (minus contributions), purchase routing, unlock/phase/hole sync, avatars, pause and save policy.

---

## 10. Player avatars and the 18 `player` lookups

### 10.1 Sending (`world/avatar_sender.gd`, local peer)

- Runs in `_physics_process` every 3rd tick (20 Hz). It reads `PlayerController.global_position`, yaw (`rotation.y`), camera pitch (`MainCamera.rotation.x`), `is_crouching`, `is_sprinting`, `is_on_floor()`, and `torch_mode`.
- A `teleported` bit is set when the position jumps more than 4 m in one tick (respawn, portal, maw), so receivers snap instead of interpolating.
- Clients send AVATAR_STATE to the host, ch2, unreliable. The host batches every avatar, including its own, into one AVATAR_BATCH per client per tick. A client's own record is excluded from the batch it receives.
- AVATAR_META (reliable, on change only) carries `held_pool` / `equipped_pool`, the pool id of what the player holds (`main_camera.picked_object.pool_id` / `equipped_item.pool_id`). MP1 shows a non-colliding ghost of that object at the puppet's hands. MP2 replaces the ghost with the real replicated body.

### 10.2 Puppet (`world/avatar_puppet.gd`)

- A plain `Node3D` under `/root/World/PittMPAvatars`, with no scripts from the game. It has groups `remote_player` and `pittmp_avatar`, and **never** `player`, `main_camera` or `head`.
- Visual: the mesh resource is taken from the `Duck` MeshInstance3D of `res://scenes/duck.tscn`. We read it from the PackedScene's `SceneState`, so no RigidBody, script or `product` group is ever instanced, and the maw can never eat it. It is scaled to about 1.7 m, with a per-slot tint (`StandardMaterial3D.albedo_color` override from a 10-colour palette). It tilts head and body by pitch.
- A `Label3D` name above it uses `res://assets/PublicPixel-rv0pA.ttf` (load(), never copied), billboard, outline, `no_depth_test = false`, and fixed size at a distance.
- There is no collision in MP1. Objects are per-peer, so a puppet pushing your local ducks would be meaningless and would jitter. MP2 adds an `AnimatableBody3D` capsule on a dedicated layer on the **host only**, so host-simulated bodies react to remote players.
- `physics_interpolation_mode = OFF`. The pose is driven in `_process` by `StateStream.sample(render_time)`: Hermite interpolation with velocity from neighbouring snapshots, extrapolation up to 200 ms, then hold. If the snapshot shows `teleported`, the puppet snaps.
- Registered with `entities.register_player(puppet, peer)`, so `api.net.get_players()` and `entities.describe(slot)` work.

### 10.3 The 18 lookups

The local player keeps being the only `player`-group node on each peer, so each lookup keeps its single-player meaning ("me"). For MP1 parallel worlds that is exactly right: every machine on my floor affects my player. The table is the MP2 to-do list.

| Site | MP1 | MP2 action |
|---|---|---|
| save_manager ×3 (position save/load, snapshotable) | correct: host saves host position. Clients never save. Snapshot position = host position + 1.5 m offset. | per-player positions in a sidecar (optional) |
| pause_menu (unstuck/respawn) | local, correct | same |
| game_progression ×3 (ending suction, respawn, light) | local cosmetic, correct | ending suction stays per-peer |
| security_room ×3, elevator (secret ending, escape ride) | the secret ending stays per-peer, see §11.5 | coordinated secret ending |
| fall_sequence (ending) | local, correct | same |
| cannon, gravity_inverter, tractor_beam (player pull) | local machines → local player, correct | host runs the machine. Its player-affecting force is sent as `player.impulse` (scope local, forwarded by the host to the owner) to remote owners, or the client runs a "player-only" sensor branch (preferred: no RTT) |
| golf_club ×2 (aim meta on player) | local, correct | owner-client authority while equipped |
| test_black_hole | debug scene | ignore |
| `is_in_group("player")` ×16 (fan, bumper, spring pads, magnet, press, maw, fail_safe, …) | local | the same split: the **body** branch runs on the host only, and the **player** branch runs on each client for its own player (the client sees puppet bodies that are kinematic, so local sensors still fire on proximity) |

---

## 11. Economy and progression replication (host-authoritative)

### 11.1 Field classification (`world/econ_fields.gd`, one table drives everything)

Source of truth = the dictionaries returned by `_save_game_state()` and `_save_game_statistics()`, plus `unlocked_milestones`, phase, hole and workbenches.

| Class | Fields | Host | Client |
|---|---|---|---|
| **SHARED-ADD** (counters) | `money`, `total_money_gained`, `total_money_spent`, `total_bonus_earned`, `combo_bonus_total`, `total_products`, `long_range_feeds`, `panel_ricochet_feeds`, stats `products_crafted.*`, `products_autocrafted.*`, `products_consumed.*`, `total_products_consumed`, `money_per_product.*`, `safety_violations` | authoritative, merges contributions | mirror; local changes → contribution deltas |
| **SHARED-MAX** | `max_combo`, `total_combos` (add), `max_simultaneous_toggle_tools`, `peak_production_rate` | max-merge | contribute when higher |
| **SHARED-OR** (one-way flags) | `torch_unlocked`, `uv_unlocked`, `uv_lamp_dispensed`, `keypad_revealed`, `elevator_hacked`, `secret_ending_seen`, `pickaxe_found` | OR-merge | contribute `true` |
| **HOST-SET** (only via commands or host logic) | `upgrades/tools/toys/products/combos` levels, enabled, toy `buy_prices`, `purchased_once`, `unlocked_milestones`, phase, hole, `escape_code`, `cauldron_min_purity`, workbench spawn state | authoritative | mirror only; local changes are overwritten (and logged as a bug) |
| **LOCAL (MP1)** | `bank`, `mining_bank`, `pickaxe_tier`, `remote` (channels/tier states), `panel_stack`, buffs, `is_game_started`, `game_start_time`, `total_play_time` | own | own; stripped from mirrors |

`bank`, mining, remote channels and the panel rack are tied to physical machines on each peer's own floor in MP1. They become HOST-SET in MP2.

### 11.2 Host → clients (`world/econ_replicator.gd`)

- Dirty triggers: PittAPI events `money.changed`, `stat.changed`, `item.level_changed`, `unlock.milestone`, `phase.changed`, `bank.changed`, `command.executed(ok)`, and a 0.5 s safety poll.
- At most 10 Hz, the host serializes `_save_game_state()` + `_save_game_statistics()` (pure collectors, cheap), drops the LOCAL fields, diffs them against the last sent version **per client**, and sends `ECON_DELTA {rev, set:{"game_state.upgrades.sprint.level": 2, "game_state.money": "123456…", …}, ack}`.
- The full mirror goes in the snapshot and in ECON_FULL at CLIENT_READY.
- `ack` = the highest contribution `seq` from that client already merged into this state.

### 11.3 Client contributions and reconciliation (`world/econ_mirror.gd`)

The client state is `M` (last host mirror), `P` (unacked contributions, in seq order), and the game's live `G`.

```
every 0.1 s and right before applying any host message:
    L  = local serialize (game_state + statistics, SHARED fields only)
    E  = M ⊕ ΣP              # what G should be if nothing happened locally
    d  = L − E               # per class: ADD → numeric difference (BigInt, can be negative),
                             #             MAX → L if L > E, OR → true if L and not E
    if d not empty: P.append({seq: ++seq, d}); send ECON_CONTRIB
on ECON_DELTA/FULL from host:
    flush (above); M = apply(set); drop P entries with seq ≤ ack
    target = M ⊕ ΣP          # host truth + my in-flight income
    write target into G via the game's own appliers (11.4)
```

- Money uses BigInt (`from_string`, `add_big`, `sub_big`, `compare`). The game's BigInt has no negatives, so the delta is a sign plus digits.
- The host merges a contribution by applying `GameState.add_money(amount, "")` or `spend` (or `money.add_big` for huge values) **once per contribution**, and adds stats by setting the counter and emitting `GameState.stat_changed(stat, value)`. The host's UnlockManager and Steamworks then react exactly as if the action had happened on the host.
- Sanity checks only (friends-only trust model): drop contributions with a non-shared path, or money above `mp_contrib_cap_per_s` (default: no cap, log only).
- **No double counting.** A contribution leaves P only when the host says it is included (`ack`), and G is always recomputed from host truth plus pending.
- **No lost income.** The flush happens synchronously right before every apply, in the same frame.
- Order of operations in one frame cannot interleave, because GDScript is single-threaded.

### 11.4 Writing mirrored state into the game (client)

- Build the **full** dictionaries `target.game_state` / `target.game_statistics`, with LOCAL fields replaced by the client's current local values. Then call `SaveManager._load_game_state(full)` / `_load_game_statistics(full)` inside `events.push_origin(1, "net")`. These appliers are idempotent on full dicts. They are never fed partial dicts, because of the unconditional defaults (§1).
- Then:
  - emit `GameState.stat_changed(k, v)` for each changed stat key (feeds Steamworks achievements and HUD);
  - call `UpgradeUI.update_ui()` + `update_credits()` if any item key changed;
  - call `Steamworks.check_consumerism()` if purchase counters changed;
  - emit `bank_updated` only for LOCAL bank changes.
- Item `enabled`/`enabled_levels` stay consistent, because unlocks replay through the real milestone path (§11.6) and levels come from host state.

### 11.5 Phase (`world/phase_sync.gd`)

- The host broadcasts `PHASE` when PittAPI `phase.changed` fires (poll-based, so it catches the immediate set for 2-4 and for 5).
- Client: `GameProgression.change_phase(p)` through the internal replay command. Each client then runs the real transition locally: cinematic, music, lights, `phase_changed` (late for 2-4) → WorkbenchSpawning spawns benches on its floor. `checkpoint_save` is blocked by the client save lock. The phase-3 `Engine.time_scale` slow-motion is per process and runs on every peer at about the same time.
- Phase only moves forward. One local exception: the elevator exit on a new game calls `change_phase(1)` on whichever peer leaves first. That is allowed on clients (0→1 only), and the host's own exit is a no-op afterwards.
- **Ending (PHASE_5):** the host's hole triggers it. Clients receive PHASE 5 and run their own `_trigger_ending_sequence`. The session is marked ENDING, PauseGuard stands down (end_of_game pauses the tree), and every peer goes through the game's ending → end_of_game → credits → main menu. On the main menu the host returns to the Lobby panel and the clients follow (`lobby state=waiting`).
  - Client side effects: the ending's forced `save_game(true)` writes only the isolated session file, but `mark_game_completed()` writes the **client's real `profile.cfg`** (`game_completed`, unlocks Sandbox) and END_MAIN fires. *Owner question Q2:* allow (default: yes, they finished the game together) or suppress (the client would extend `end_of_game`).
- **Secret ending** (keypad → elevator escape → security room) is a per-peer sequence with scene-level side effects. MP1: allowed on the host only. On clients the keypad's success path is suppressed by an `elevator.gd` extension guard, with a toast "Only the host can do this in multiplayer". *(Owner question Q3.)*

### 11.6 Unlocks (`world/unlock_sync.gd`)

- During a session the client **detaches its UnlockManager**: `GameState.stat_changed.disconnect(UnlockManager._on_stat_changed)`, `GameProgression.phase_changed.disconnect(UnlockManager._on_phase_changed)` (each guarded by `is_connected`), and `UnlockManager.set_process(false)` (floor checks). All three are restored at session end. Milestones are judged on host state only, including floor milestones, which use the host's floor.
- The host broadcasts `UNLOCK {ids}` from `unlock.milestone`. The client runs `UnlockManager.force_unlock(id)` for each one, the game's live `_trigger_milestone` path: same notification, `milestone_unlocked` signal, UpgradeUI "new" badges.
- The snapshot path uses `load_save_data` (the save replay). Both are vanilla code paths.

### 11.7 Purchases (`world/purchase_router.gd` + `extensions/upgrade_ui_ext.gd`)

- `upgrade_ui_ext.gd` extends `res://scripts/upgradeUI.gd` (world scene script, extendable, with the `is_mirror` early return kept). It overrides `_create_upgrade_row`, `_create_tool_buy_row` and `_create_toy_buy_row`: it calls `super`, takes `row.get_meta("button")`, and **on clients only** disconnects that button's `pressed` connections (`for c in button.pressed.get_connections(): button.pressed.disconnect(c.callable)`). It then connects a router handler that issues the command and plays **the game's own feedback helpers** with the result (`_play_sound`, `_create_success_effect`, `_create_error_effect`, `_flash_label`, `_enhanced_shake_node`, `_screen_shake`, `_spawn_floating_text`, `update_ui`, `update_credits`, `_refresh_*_row`).
- The host keeps the vanilla lambdas, so its purchases are game code. PittAPI's bridge still sees `item.level_changed`, and the EconReplicator mirrors it.
- Commands:
  - upgrades/products/combos → `item.buy {category,key,subkey}` (host: PittAPI's affordability-checked `GameState.buy`);
  - tools → `PittMultiplayer.buy_tool {tool, level}` (host: `can_afford` → `spend` → `purchased_once` → `check_consumerism`, **no spawn on the host**);
  - toys → `PittMultiplayer.buy_toy {toy}` (host: spend, purchased_once, crate price escalation copied from upgradeUI.gd:1546).
- On `ok` the client spawns the tool or toy **locally** through `_spawn_tool_instance` / `_spawn_toy_instance`, the game's own spawn with the press/terminal singletons and pool ids (MP1 parallel worlds). In MP2 the host spawns into the shared world instead (a one-line policy switch in the host handler).
- The recall-mode branch of the tool row is local and stays untouched: recalling your own tools.
- Concurrent purchases are serialized by the host. The loser gets `ok=false` and the game's "insufficient funds" feedback.

### 11.8 Progression fixtures (`world/fixture_sync.gd`)

- Phase-driven benches spawn on every peer from the local `phase_changed`.
- An auto-machine purchase spawns the auto bench on the host via `GameState.buy`. For clients, FixtureSync watches mirrored `products.<k>.auto_machine.level` going 0→1 and calls `WorkbenchSpawning.spawn_auto_workbench(type)` (type mapped through `PRODUCT_TO_WORKBENCH`).
- Snapshot workbench data covers late joiners.

### 11.9 Hole (`world/hole_sync.gd` + `extensions/hole_ext.gd`)

- Client: the `_on_product_consumed(type, base_value, body_id)` override sends `HOLE_FEED {type, base_value}` and does **not** call super. `_check_phase_completion()` becomes a no-op. On `HOLE` from the host it sets `target_radius` / `phase_nutrition_total` / `current_phase`, and the hole's own `_process` grows `current_radius` smoothly. `apply_saved_state` is used only at load, because it snaps the radius.
- Host: HOLE_FEED → `hole._on_product_consumed(type, base_value, -1)`. This is the real path, including the phase scaling `PRODUCT_NUTRITION_SCALE[key][phase]` applied with the **host's** phase. HOLE is broadcast at ≤ 4 Hz on change.

### 11.10 Combos

Combos are local per peer in MP1, because they are driven by local maw feeding. The payout (hud.gd:670, `add_bonus`) arrives at the host as a contribution through the money and `total_bonus_earned` deltas. ComboSystem events are never replicated, so double payout is impossible. MP2: combos become host-only. Clients' HUD `show_result` is gated by a `hud.gd` extension, and the combo bar is mirrored as a cosmetic.

---

## 12. Pause = local "soft pause" (`world/pause_guard.gd`)

The game pauses through `MenuManager.open_menu` (autoload, not extendable), `request_auto_pause` (overlay / controller loss), `SaveManager.save_game` (synchronous, harmless), `end_of_game`/`session_complete`.

1. **Keep the tree running.** PauseGuard (PROCESS_MODE_ALWAYS) connects `get_tree().physics_frame`. That signal is emitted every physics step, before `_physics_process` dispatch, even while paused. If `session.in_game and get_tree().paused and not exempt`, it sets `get_tree().paused = false` before any node's physics runs, so no tick is lost. It also checks in `_process` as a backstop. `player_controller_ext._unhandled_input` calls super and then unpauses at once, to cover the Esc path in the same frame. `exempt` = `GameProgression.ending_active` or `SaveManager._is_saving`.
2. **Keep the menus working.** `MenuManager.game_paused` / `current_menu` stay set by the game, so the pause menu, options and `close_current_menu` logic behave normally, and `player_controller._input` already ignores quick save/load/torch while a menu is open.
3. **Freeze local input while a menu is open** (`soft_paused = MenuManager.current_menu != null and MenuManager.game_paused`):
   - movement: player meta `golf_aim_mode = true` (the game's own "movement blocked" switch; gravity still applies), through PittAPI's movement-lock owner mechanism so it does not clash with golf;
   - grab/use: `main_camera_ext.handle_input()` returns early while soft-paused (it polls `Input` directly, so clicks on menu buttons would otherwise grab objects);
   - look: `player_controller_ext._unhandled_input` ignores `InputEventMouseMotion` while soft-paused (the pause UI normally consumes it anyway).
4. A held object is released on pause (`main_camera.release_held_object()`), so a carried body is not left gravity-less for minutes. In MP2 this is mandatory: a paused owner must give up authority.
5. Cosmetic: the MusicManager low-pass keyed on `get_tree().paused` won't engage. Optionally call `MusicManager.set_filter_cutoff` while soft-paused.
6. Outside a session PauseGuard does nothing, and single-player pause stays vanilla.

---

## 13. Late-join snapshot (`core/snapshot.gd`)

**Builder (host).** It mirrors `_save_game_impl` (save_manager.gd:280-301) into a **fresh** dictionary, calling the same collectors. It never touches `SaveManager.save_data` and never writes a file on the host.

```
{ "pittmp": {v, session_id, tick, host_ms, sandbox, cheated, rules},
  "version": <game version>, "timestamp", "game_state", "unlocked_milestones", "game_statistics",
  "object_pools": {}            # MP1: empty (parallel worlds). MP2: full _save_object_pools() → puppets
  "player_position": host pos + spawn offset,
  "phase", "demo_end_triggered", "cameras", "hole", "vertical_gates",
  "press_spawned": false, "trading_terminal_spawned": false, "bowling_set_spawned": false,   # MP1: per-peer purchases
  "workbenches", "music", "minable_blocks", "pickaxe": {} (MP1 local), "loop_puzzle", "seen_items" }
```

- The collectors are believed to be pure reads. A spike (S-MP4) checks each one for side effects with a headless and a live diff.
- Encoding: JSON → zstd → 32 KB chunks on ch1 → CRC. MP1 size is a few KB to tens of KB. MP2 with pools is about 1-3 MB of JSON, about 150-300 KB compressed, about 2-4 s at 100 KB/s.
- **Consistency:** the snapshot is stamped with `tick` and `econ rev`. Messages sent to that client after BEGIN and before CLIENT_READY are queued on the host. After READY the host sends a fresh ECON_FULL, plus (MP2) every SPAWN/DESPAWN with tick > snapshot tick, before resuming per-tick state. The client discards anything with `rev/tick ≤ snapshot`.
- **Apply (client):** the vanilla load (§7.3). The file lives in `user://pittapi/mp/` (SafeFS area, not slot-like, never under `user://` root, which Steam Auto-Cloud syncs). It is deleted on session end and at boot (orphans).

---

## 14. Steam achievements policy (`world/achievements_policy.gd`)

- **Default: "earned together."** Clients mirror authoritative stats and phases. Our appliers emit `stat_changed`, and the client's `phase_changed` fires on replayed transitions, so `Steamworks._on_stat_changed` / `_on_phase_changed_for_achievements` grant clients the same progress achievements as the host. Local actions (UV lamp INVISIBLE, keycard SECRET, loop LOOP, gate achievements) fire for the peer whose world it happened in.
- **Suppressed for everyone** (`achievements.suppress` on all peers, lobby data `ach=off`) when the host session is sandbox, when the host's sidecar is cheated or a cheat command ran this session, or when the host sets `mp_achievements=false`. A peer joining a suppressed session is told before joining (Join row tag).
- A client's own cheat commands are refused by default (§6.1), so they cannot taint the host.
- Tests always run `achievements.suppress` on every instance, because they use the one real Steam account.

---

## 15. Save policy (`world/save_policy.gd`)

- **Host only.** The host saves into its own slot as usual: autosave, checkpoints, F5, pause Save. The save contains merged co-op progress and the host's world.
- **Clients never save.** `save.isolate` points at the session file, with save_locked and autosave off, re-asserted every frame (the elevator's `_ready` unlocks saves; PittAPI already handles that). F5 → `player_controller_ext._input` shows `MP_HOST_SAVES` through `hud.show_restrict_message`. F9, and pause-menu Save/Load/Delete, are hidden or blocked by `pause_menu_ext`.
- **Host F9 / pause Load during a session is blocked** in MP1 (`begin_load_reload` swaps the whole world). MP2 option: "host reload" = `SESSION reload`, and every client re-syncs from a new snapshot.
- PittAPI never writes game save files. The only game-driven client write outside the session file is the ending's `profile.cfg` (§11.5, Q2).
- Live test guard: the existing SHA-256 save-hash check runs on **both** instances' user dirs.

---

## 16. MP2 plan: physics objects (design only)

### 16.1 Phasing

| Stage | Content |
|---|---|
| **MP2a** one-way world | Clients drop their local floor. Host pooled bodies become client **puppets**: spawned through `ObjectPoolManager.spawn` (correct visuals, `on_pool_spawn`) under the host eid, with `freeze=true`, `freeze_mode=KINEMATIC`, and collision kept for local player-vs-body contact. They are driven by BODY_STATE interpolation (same StateStream as avatars). Client interactions (workbench hold, toggles, terminal, press, scheduler, remote) become `world.interact {eid, verb, args}` commands. |
| **MP2b** grab authority | Held bodies are simulated by the holder (§16.3). Throws carry velocity. |
| **MP2c** machines and tools | Equipped tools on remote players, field tools (fan/magnet/vacuum/tractor/orbit), cannon queue, vacuum bags, portals, pistons with riders. |

### 16.2 Host-side gating (extensions on world/pooled scripts, `take_over_path`)

Clients early-return in the gameplay branch of every sink or force writer listed in the maps (production-objects H10, world-physics §8): bottom_maw `_on_body_entered`, press `process_crushed_items`, gambling terminal, golden statue, ore processor, minable blocks, crates `break_crate`, pinata `_burst`, cash register drain, candy expiry, workbench crafting completion, cauldron ritual, debris and fail_safe teleports, portal teleports, fan/magnet/gravity_inverter/tractor/vacuum/orbit `_physics_process` (body branch only), spring pad / bumper body branch, qa_arm, roomba, cannon `fire`, `camera_pivot._integrate_forces` breakage, hole growth (already in MP1).

Each extension checks `api.net.is_authority()` and keeps its player-affecting branch running on clients for the local player.

### 16.3 Ownership and authority transfer on grab

- Table: `eid → {owner_peer, epoch, since_tick}`. The default owner is the host.
- Grab, client side:
  - `main_camera_ext.pick_object()` predicts: it calls super (local `_begin_carry` on the puppet, unfreezing it locally as a dynamic body) and sends `OWN_REQ {eid, epoch_seen}`.
  - The host grants first-come (`OWN_GRANT {eid, peer, epoch+1}`) unless the body is already owned, consumed, in a cannon, or in a vacuum bag. It then freezes the body kinematic and follows the owner's BODY_STATE.
  - On `OWN_DENY` (within RTT) the client calls `drop_object(true)`, re-freezes the puppet, and resumes interpolation.
- While held: the owner streams BODY_STATE for that eid at 30 Hz with `held` set. The host relays it to the others, who render it attached near the owner's puppet hands. That is smoother than interpolation for a hand-held object.
- Release, drop or throw: `OWN_RELEASE {eid, epoch, pos, rot, lin_vel, ang_vel, thrown}`. The host restores the dynamic body with that exact state and the metas (`player_throw_time`/`position` set on the host from the release), and owner returns to the host with epoch+1.
- The client keeps simulating locally for at most 150 ms after release, then blends to the host stream, so a throw does not snap.
- Stale-packet rule: any BODY_STATE or RELEASE with an epoch older than the table's is ignored. Timeouts: a held body with no owner packet for 1.5 s is released by the host at its last state. On disconnect, every body the peer owns is released.
- Equipped tools: owner = holder. The tool is reparented under the remote puppet's hand as a visual on other peers. Its world effect runs on the host from `tool.use {eid, verb, cam_xform}` messages (vacuum ingest, tractor beam), or on the owner for self-effects (golf aim).

### 16.4 State streaming and bandwidth

- BODY_STATE records (§4.4): position, smallest-three rotation, optional velocity. The host sends only **awake, non-placed, visible** bodies. Placed tools (`freeze_mode=STATIC`) send one reliable META on change. Sleeping bodies send one "sleep" record (exact final pose), then nothing until they wake. A keyframe of each awake body goes out at least every 1 s (loss recovery).
- **Priority accumulator per client:** `prio += dt × w_type × w_dist(owner avatar) × (1 + |v|) × w_recent_interaction`. Each tick, records are sent in priority order until the per-tick byte budget (`budget_kbps / tick_rate`) is used up, packed into ≤ 1100 B self-contained packets. Sent bodies reset to 0.
- Interest: bodies more than 60 m from a client's avatar get a 0.25 weight. Bodies inside cannons or vacuum bags are hidden (META) and never streamed.
- Mass events: pinata bursts (up to many candy, pool max 10000) are batched as one reliable SPAWN_BATCH. Candy then streams by priority like anything else. The `candy`/`duck` pool caps bound the worst case.
- Client interpolation buffer as for avatars. An unknown eid waits for SPAWN on ch3 (500 ms). Teleports (portal, fail_safe) set the `teleported` bit.
- Snapshot includes `object_pools` (game schema: per-object pos, rot, velocities, `is_frozen`, placed/active, metas, bags, queues, piston data). The client applies it as puppets instead of through `_load_object_pools`.

### 16.5 Per-entity extra state (META, reliable ch3)

`value` (register drain, candy decay, anomaly grade), metas `gambled`, `tint_color`, `crude_source`, `starter_crate`, `consumed`, `pending_maw_recycle`, `bumper_bounce_count`, flat-duck `is_flattened`, pinata/crate damage, tool `is_active`, `placed`, piston `{offset, phase, timer}` (kinematic, derived from small state, so no transforms), scheduler mode/interval/duration, remote channels, feed camera ids (host-assigned, replacing `Time+randi` ids). All of these are already serialized by `_save_object_pools`, and MP2 reuses those per-type encoders.

---

## 17. Testing strategy

### 17.1 Headless (`tools/test-headless.ps1`, no game, every change)

New suites in `tests/headless/suites/test_mp_*.gd`, with fakes in `tests/headless/fakes/mp/` (`fake_game_adapter.gd`, `fake_main_menu.tscn` with the real node paths, `fake_upgrade_ui.gd`, `fake_hole.gd`):

| Suite | Covers |
|---|---|
| `test_mp_protocol` | frame flags, JSON bodies, Quant round trip within error bounds (pos ≤ 1 mm, yaw ≤ 0.01 rad, smallest-three ≤ 0.002), packet ≤ 1100 B, chunker + zstd + CRC, rejection of oversize or garbage |
| `test_mp_transport` | Loopback pair and star; the Conditioner (100 ms ± 30, 5 % loss, reorder): reliable order kept, unreliable latest-wins |
| `test_mp_clock` | offset convergence under jitter, slew limit, render_time monotonic |
| `test_mp_statestream` | interpolation and extrapolation, teleport snap, out-of-order and duplicate records, epoch rejection |
| `test_mp_authority` | client `execute("item.buy")` → host `dispatch_remote` → result; `scope=local` runs locally; remote cheat refused; host gone → pending fail |
| `test_mp_econ` | two FakeGameAdapters: client local income + host purchase at once → converge; ack drops pending; no double count across 1000 random interleavings (property test); BigInt above int64; LOCAL fields untouched |
| `test_mp_unlock_phase_hole` | UNLOCK → `force_unlock` replay; client UnlockManager detached and restored; HOLE_FEED → host hole; client completion no-op; phase forward-only rule |
| `test_mp_session` | state machines: start, late join, leave, host-left (transport and lobby-owner paths), ending, rejects |
| `test_mp_lobby` | FakeLobbyService: friend discovery via events, missed events recovered by Refresh/rescan, version and mods mismatch rows, `+connect_lobby` and `join_requested` routing, `leave()` on menu return |
| `test_mp_menu` | injection on a fake MainMenu: button after Play, **pressing it does not call `_on_play_pressed`**, panel swap, Esc handled by us, re-entry re-injects exactly once, gamepad focus |
| `test_mp_pause` | soft pause: tree unpaused within the same physics frame, movement lock set and cleared, exemptions |
| `test_mp_snapshot` | builder output keys equal the save keys; MP1 strips; the applier sets isolation + flags in the right order |

### 17.2 Two-instance ENet loopback (live, automated): `tools/test-mp-loopback.ps1`

Setup, once, by `tools/mp-dev-setup.ps1`:
- `"<godot> --headless --path decomp --import"` (may take minutes).
- Assemble `dist/mp-dev/mods/` (loader → `PittAPI/`, `PittMultiplayer/`, `PittMPTests/`) like the installer does.
- Write `decomp/override.cfg` (decomp is gitignored):

```ini
[application]
config/use_custom_user_dir=true
config/custom_user_dir_name="Project P.I.T.T (PittMP dev)"   ; never the real save folder
[autoload]
PittAPI="*<repo>/dist/mp-dev/mods/PittAPI/pittapi.gd"
```

The **custom user dir is critical**. Without it, the decomp project uses the same app name and therefore the real `%APPDATA%\Godot\app_userdata\Project P.I.T.T` saves.

Run:
- Instance H: `PITTAPI_MODS_DIR=dist/mp-dev/mods PITTAPI_USER_SUBDIR=host <godot> --path decomp`
- Instance C: the same with `PITTAPI_USER_SUBDIR=client`.

Both use the editor binary (`OS.has_feature("editor")`, no Steam relaunch). They can be windowed, or `--headless` if the world runs headless (spike S-MP3). Each gets a flag file `user://pittapi_<x>/mp_autotest.flag` `{role, port, run_id, suites}`. Both run `achievements.suppress` + `presence.suppress` first, because both log into the same Steam account. Fallback if a second Steam init fails: `[steam] initialization/initialize_on_startup=false` for instance C. The game tolerates `is_steam_initialized=false`; to verify.

Scenario (`PittMPTests` suites, report per instance, merged by the harness):
1. H: isolated new game (the existing gameplay suite recipe) + DevLobbyService host on `127.0.0.1:<port>`.
2. C: join → snapshot → world loads from the session file → `world.ready` with phase and money equal to H.
3. Avatars: each sees the other's puppet within 2 s. H teleports its player 10 m → C's puppet arrives within 300 ms.
4. Econ: H `money.add 1000` → C mirrors within 500 ms. C spawns a duck locally and pushes it into its maw (`entity.set_transform`) → H money and `products_consumed.duck` increase, and C converges with no double count.
5. Purchase: C `item.buy` of a cheap upgrade → H level +1 → C UI level +1. C tool buy → H money −price, C has the tool locally.
6. Progress: H `phase.set 2` (gameplay_phase recipe) → C phase 2 transition. H `unlock.force` → C notification.
7. Pause: C opens the pause menu → H physics frames keep advancing, and C's tree is not paused.
8. Late join: start C after H is IN_GAME (rerun 2-3).
9. Leave: C leaves → H removes the puppet. H goes to Main Menu → C gets `MP_HOST_ENDED` and is on the main menu.
10. Conditioner run (`mp_sim=100ms,5%`) repeating 3-4 with relaxed timing.
11. Save safety: hash the real user dir (must not be touched at all) and both dev subdirs (no `savegame*` writes on C).

Variant `-HostRealGame`: H is the real game via `steam://rungameid/4026250` with `-WithTests` and save.isolate, C is the decomp instance. Only in stages allowed to launch the game. It kills `projectpitt.exe` after.

### 17.3 Manual Steam checklist (owner, 2 accounts / 2 PCs, real relay)

1. Both: `tools\install.ps1`. Accounts are Steam friends. Both own the game.
2. A: Multiplayer appears directly under Play, same font, hover and click sounds. The button is still there after Options → back, and after returning from a game.
3. A: Host → lobby shows A in the center. Steam friends list shows A "in a joinable game". Invite opens the overlay.
4. B: Join lists A's lobby with `1/10` within a few seconds, with no Refresh needed. Refresh works.
5. B joins via (a) the Join list, (b) the overlay invite (`join_requested`), (c) friends list "Join Game" with B's game closed (`+connect_lobby` launch). Each path ends in the Lobby screen showing A and B. A's member count updates.
6. A: Start (slot selector) → both in the world. Names above heads, smooth movement at relay ping (check about 100-200 ms), no avatar for yourself.
7. Money: A earns → B sees it. B feeds its own maw → A sees money and hole growth. Purchases from both at once never overspend.
8. Unlock notification on both. Phase 2 transition on both.
9. Pause on B: A keeps playing and B is frozen locally. Steam overlay on A: B keeps playing.
10. Late join: C (third account, if available), or B leaves and rejoins mid-game.
11. A quits to the main menu → B sees "Host ended the session" and is back in the Lobby screen. A quits the game hard (Alt+F4) → B gets "Host left" within about 10 s and leaves the lobby.
12. Version mismatch: B with a different PittMultiplayer version → row disabled with the reason.
13. Saves: B's `savegame*` and `sandbox.save` unchanged (hash before and after). A's slot contains the merged progress.
14. Bandwidth: Steam overlay network stats (or `mp stats` console) under 50 KB/s in MP1 with 2 players.
15. Achievements: earned together (a cheap one, e.g. the first phase); none in sandbox or cheated sessions.

---

## 18. Concrete file list

```
mods/PittMultiplayer/
  mod.json                      id PittMultiplayer, multiplayer "client_required", provides ["net"],
                                extensions: upgrade_ui_ext, hole_ext, player_controller_ext, main_camera_ext,
                                pause_menu_ext, elevator_ext
  main.gd                       composition root; config (mp_transport, mp_dev_targets, mp_body_budget_kbps,
                                mp_allow_client_cheats, mp_achievements, mp_sim); console cmds `mp host|join|stats|kick`
  core/session.gd               host/client state machines, start/join/late-join/leave/end orchestration
  core/protocol.gd              type ids, frame encode/decode, JSON helpers, rate limits
  core/net_clock.gd             ping/pong, offset estimate, render_time, host_tick
  core/net_authority.gd         extends <PittAPI>/core/authority.gd (scope-aware submit, remote dispatch)
  core/peer_registry.gd         peer → {slot, steam_id, name, color, ready}
  core/snapshot.gd              builder (host), chunk tx/rx, file write, client load prep
  core/ownership.gd             eid → {owner, epoch} (avatars in MP1; bodies in MP2)
  transport/transport.gd        interface
  transport/mp_peer_transport.gd raw MultiplayerPeer wrapper
  transport/enet_factory.gd     ENetMultiplayerPeer host/client
  transport/steam_factory.gd    SteamMultiplayerPeer host/client (defensive signatures)
  transport/loopback.gd         in-process hub (tests)
  transport/conditioner.gd      latency/jitter/loss/bandwidth decorator
  lobby/lobby_models.gd         LobbyInfo, MemberInfo (plain data)
  lobby/lobby_service.gd        base signals/API
  lobby/steam_lobby_service.gd  all Steam lobby/friends/presence calls
  lobby/dev_lobby_service.gd    ENet "lobby"
  lobby/fake_lobby_service.gd   scripted (headless)
  lobby/launch_args.gd          +connect_lobby parsing (cmdline + getLaunchCommandLine)
  ui/menu_router.gd             panel stack, Esc, gamepad focus
  ui/host_join_panel.gd  ui/lobby_panel.gd  ui/join_panel.gd  ui/slot_selector.gd  ui/row_factory.gd
  ui/i18n/en.json (+ de, fr, es, ... where cheap)
  world/game_adapter.gd         every game global/method used (contract-checked)
  world/quantize.gd             Quant codec (avatars + MP2 bodies)
  world/state_stream.gd         snapshot buffer + Hermite interp + extrapolation (shared)
  world/avatar_sender.gd  world/avatar_manager.gd  world/avatar_puppet.gd
  world/econ_fields.gd          field classification table (§11.1)
  world/econ_replicator.gd      host: diff + ECON_DELTA, contribution merge
  world/econ_mirror.gd          client: contributions, reconciliation, appliers
  world/unlock_sync.gd  world/phase_sync.gd  world/hole_sync.gd  world/fixture_sync.gd
  world/purchase_router.gd      client purchase commands + host handlers (buy_tool, buy_toy)
  world/pause_guard.gd  world/save_policy.gd  world/achievements_policy.gd
  extensions/upgrade_ui_ext.gd  extensions/hole_ext.gd  extensions/player_controller_ext.gd
  extensions/main_camera_ext.gd extensions/pause_menu_ext.gd  extensions/elevator_ext.gd
mods/PittMPTests/               mod.json, main.gd (flag per user subdir), suites/suite_mp_host.gd, suite_mp_client.gd
loader/                         (changes in §6.4) api/net.gd, api/ui.gd (new), core/commands.gd,
                                core/builtin_commands.gd, core/events.gd, core/entities.gd, core/contract.gd,
                                core/manifest.gd, schema/mod.schema.json, pittapi.gd
tests/headless/suites/test_mp_*.gd, tests/headless/fakes/mp/*
tools/mp-dev-setup.ps1          import decomp, assemble dist/mp-dev, write decomp/override.cfg (custom user dir)
tools/test-mp-loopback.ps1      two-instance run, merged report, save-hash guard on all user dirs
tools/install.ps1               + PittMultiplayer (and PittMPTests with -WithTests)
docs/mp/                        this proposal; later MP-PROTOCOL.md (normative wire spec), MP-TESTING.md
```

---

## 19. Build order, spikes, risks, owner questions

### 19.1 Spikes first (each about 15-30 min)

- **S-MP1** Raw `SteamMultiplayerPeer` without SceneMultiplayer: put_packet/get_packet between two local processes is impossible on one account, so check `create_host` + `poll` + no errors, and verify method signatures via `ClassDB.class_get_method_list("SteamMultiplayerPeer")` in the decomp editor instance. Repeat for ENet raw between two decomp instances.
- **S-MP2** The decomp editor instance boots to the main menu with the override.cfg custom user dir. Steam initialises in parallel with the real game (or degrades cleanly).
- **S-MP3** `--headless` world load in the decomp instance (pools, LoadingScreen, world `_ready`).
- **S-MP4** Snapshot collectors are side-effect free. A plaintext session `.save` loads through `load_game()` with `save.isolate`.
- **S-MP5** `physics_frame` unpause keeps physics stepping (count physics frames on the host while a client-style menu is open).

### 19.2 Build order

1. Loader changes (§6.4) + headless tests.
2. Protocol, transports, clock, StateStream + headless.
3. Session + NetAuthority + snapshot + DevLobbyService.
4. Menu injection + panels (Fake/Dev lobby).
5. World services: pause → avatars → econ → unlock/phase/hole → purchases → fixtures.
6. SteamLobbyService + Steam transport.
7. Two-instance loopback harness.
8. Manual Steam checklist with the owner.

### 19.3 Risks

| Risk | Mitigation |
|---|---|
| GodotSteam signal arities differ | defaulted-param lambdas; `has_method`; S-MP1 method-list dump |
| SteamMultiplayerPeer needs SceneMultiplayer | private SceneMultiplayer on our subtree (§3.2) |
| 5th menu button overflows the title | live screenshot; separation tweak |
| Client `_load_game_state` full re-apply has side effects (remote tier, bank_updated) | LOCAL fields carry client values; per-apply diff test in S-MP4; apply ≤ 10 Hz and only on change |
| Parallel-world confusion for players | join toast; held-object ghosts on puppets; MP2a removes it |
| Phase transition coroutines on clients spawn debris locally (game_progression.gd:778/1122) | MP1: acceptable, debris is a local object. MP2: host-only spawn gate |
| Elevator first-exit race | forward-only phase rule (§11.5) |
| Same Steam account on both test instances (achievements, presence) | suppress on both; Steam-off fallback for instance C |
| Decomp project uses the real save folder | custom user dir in `decomp/override.cfg` (§17.2), checked by the harness before launch |

### 19.4 Owner questions

- **Q1** Host Start: choose a slot (Continue/New) in the lobby, as proposed? Sandbox sessions allowed?
- **Q2** Clients who see the ending: allow the game to mark *their* profile `game_completed` + END_MAIN (default yes)?
- **Q3** Secret ending in MP1: host only (proposed), or disabled in multiplayer?
- **Q4** MP1 parallel-world model (per-player objects, shared money/progress) is acceptable as a stepping stone to MP2a?
- **Q5** Max players stays 10 for MP2, given host upload (about 3.5 Mbit/s at normal physics detail)? Or should 6 be recommended for physics-heavy play?

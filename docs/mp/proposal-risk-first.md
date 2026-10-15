# Multiplayer architecture proposal: risk-first (MP1)

Author angle: adversarial. This proposal starts from every way the single-player game breaks when more
than one person is in it, and builds the design out of the guards. Where a feature conflicts with a guard,
the guard wins and the feature is cut or deferred. When something goes wrong, the session should end
cleanly with a message. It should never keep running in a quietly desynced state.

Inputs: `docs/MULTIPLAYER-UI-SPEC.md` (owner requirements, authoritative), `docs/API-DESIGN.md`,
`README.md`, `TESTING.md`, `docs/map/*.md`, `loader/**`. Every game symbol named below was re-checked
in `decomp/` (v1.0.8). Line numbers are for `decomp/scripts/*.gd`. Items marked **SPIKE** have not been
verified yet and must be checked before the code that relies on them is written.

---

## 0. The one decision that shapes everything: MP1 = shared progression, private physics

MP1 does not replicate physics objects (products, tools, machines). That is MP2. So in MP1 **every peer
simulates its own copy of the facility.** Only these are shared:

- the host's economy and progression (money, bank, item levels and enabled flags, toy prices,
  unlocked milestones, phase, stats, hole size);
- player avatars;
- the session lifecycle.

This has consequences that the other proposals may skip over. They have to be explicit product
decisions:

| Consequence | Decision (MP1) |
|---|---|
| A client's own maw, combos, golden statue and press would credit money locally | **Host-simulated economy only.** Money changes made by client-local game code are reverted to the authoritative value right away (MoneyGuard, section 8.4). Negative deltas (fines: maw fall `bottom_maw.gd:238/307`, camera break `camera_pivot.gd:102`, fail-safe `fail_safe.gd:66`) are forwarded to the host as `charge` requests. A setting `mp1_client_contributions` (off by default) can forward positive client sales. It is documented as inflationary (auto benches run on every peer). |
| A client's hole grows from its own feeding and would call `GameProgression.change_phase` itself (`hole.gd:233/238/243/252`) | `hole.gd` extension: `_check_phase_completion()` and `_trigger_ending()` return early on non-authority peers. Hole size is overwritten from host state at 2 Hz. |
| Client milestones would evaluate against client-local stats and unlock things the host has not unlocked | On clients, `UnlockManager`'s `stat_changed` and `phase_changed` connections are disconnected and `UnlockManager.set_process(false)` for the session (section 8.5). Unlocks come only from the host. |
| Tools and toys a client buys | The host validates and spends. The **buyer's own world** spawns the item through the game's `_spawn_tool_instance` / `_spawn_toy_instance`. The host's world does not get it until MP2. |
| Auto-machine purchases (`WorkbenchSpawning.auto_machine_purchased`, `game_state.gd:1083`) | Spawned only in the host world. Client worlds do not spawn benches in MP1. |
| World puzzles (gates, loop puzzle, keypad, secret ending, mining) | Per-peer and local in MP1. Their GameState flags are not replicated after join. |

The UI should say so (a one-time toast on clients: `MP_MP1_PRIVATE_WORLD`). Anything else would look like
a bug to players.

---

## 1. Risk register (what breaks, and the guard)

R = risk id, referenced throughout. "Test" points to section 13.

| R | What breaks in MP | Evidence | Guard | Test |
|---|---|---|---|---|
| R1 | Remote puppets picked up by `get_first_node_in_group("player")` (18 call sites in 11 scripts), `is_in_group("player")` body checks (16 scripts) and `body.name == "PlayerController"` checks (elevator, gate_weight_plate, loop_puzzle) | grep counts, section 9 | Puppets are **not** in groups `player`/`head`/`main_camera`/`HUD`, are never named `PlayerController`, and have **no physics body** in MP1 (MeshInstance3D + Label3D only), so no Area3D or maw sees them | H-AV1, H-AV2 |
| R2 | `get_tree().paused` from `MenuManager.open_menu` (`menu_manager.gd:115`), `end_of_game.gd:102`, `session_complete.gd:152` freezes the host world for everyone | grep `paused` | PauseGuard (section 9): un-pauses the tree every frame while a session is live and the peer is in world, and applies a local-only freeze (movement lock, camera disabled, held object released) | H-PA1..3 |
| R3 | `SaveManager.save_game` pauses the tree synchronously (`save_manager.gd:246-252`) and a big save can stall the host for a long frame | code | No frame passes during the pause, so the network is unaffected. Liveness timeouts are ≥ 15 s of real time | L-2 |
| R4 | Phase 2-4 transitions are long coroutines. `current_phase` is set first and `phase_changed` fires seconds later (`game_progression.gd:139-175`, `:250/404/643`) | code | Replicate `phase.begin` immediately. Clients run the cinematic locally by calling `change_phase(N)`. **Late join is deferred** until `phase.settled` (timeout 60 s) | H-PH1, H-LJ2 |
| R5 | Phase 3 changes `Engine.time_scale` (including 0.0 stutter, `:684-740`). Delta-based timers stall or skew | code | All network timing uses `Time.get_ticks_msec()`. SceneTreeTimers use `ignore_time_scale=true`. Interpolation uses wall clock. `Engine.time_scale = 1.0` is forced on session end and on world exit | H-AV3 |
| R6 | PHASE_5 changes scene (`game_progression.gd:1438`), sets `save_locked`, calls `mark_game_completed()` (writes **profile.cfg**), and calls `save_game(true)` from `_write_pre_ending_snapshot` | code | PHASE_5 is **session conclusion**: host broadcasts `phase.begin 5`, each peer plays its own ending, lobby state goes to `ending`, and joins are refused. On a client, `save_game(true)` writes only the isolated path. The client's `profile.cfg game_completed` write is accepted and documented: the client did co-op the ending | H-PH3, M-14 |
| R7 | Late join during a host transition, ending, reload or menu | | Host session state machine (section 6): joins are served only in `OPEN`. In `TRANSITION` they are queued. In `ENDING`, `STARTING` and `CLOSED` they are refused with a reason | H-LJ1..4 |
| R8 | No host migration. Steam **migrates lobby ownership automatically** when the owner leaves | Steam behaviour | Lobby data `host_steam_id` is set by the host. Clients treat an owner change or the host leaving as `host_left`, leave the lobby and end the session | H-SE3, M-11 |
| R9 | BigInt money drift (deltas, float conversion, int64 overflow) | `big_int.gd`, F15 | Money is replicated **only as absolute decimal strings** with a monotonic `seq`, and applied with load-path semantics (`money = BigInt.from_string(s); money_updated.emit(money)`, `save_manager.gd:824`). No deltas, no floats, no `add_money` on clients. Periodic full state plus a checksum | H-EC1..4 |
| R10 | Client-local economy writes (maw, combo payout `hud.gd:670`, golden statue direct write `golden_duck_statue.gd:209/388`, press) | maps | MoneyGuard reverts. Fines are forwarded as `charge`. See section 0 | H-EC5 |
| R11 | `GameState.buy()` does not check `enabled` (`game_state.gd:1062`); the UI does the gating | map | Host-side purchase commands re-check `enabled`, `enabled_levels[level]`, max level, price and pool headroom against **host** state | H-BUY1..4 |
| R12 | Purchases are inline lambdas in `upgradeUI.gd` (`:1184`, `:1320`, `:1521`) | code | Client-only `upgradeUI.gd` extension rewires each row button after `super` (section 8.3). It fails closed: if rewiring fails, the client's UpgradeUI shows `MP_SHOP_UNAVAILABLE` and buys nothing | H-BUY5 |
| R13 | Client clicks run through `GameState.buy` locally anyway (rewire missed) | | ItemGuard: on clients, an item level or enabled change not caused by replication is reverted from host state and logged as ERROR. The money delta in the same frame is **not** forwarded as a charge | H-BUY6 |
| R14 | Client saves overwrite real slots; autosave; F5; pause-menu Save; elevator `_ready` sets `save_locked=false` (`elevator.gd:57`) | code | Clients run under the existing `save.isolate` (re-asserted every frame, non-slot path) **from before the world loads until after it is left** | H-SV1, L-3 |
| R15 | Host F9 / pause-menu Load / Delete triggers `begin_load_reload` (`save_manager.gd:163`), a scene change with no LoadingScreen | code | During a session: `quick_save`/`quick_load` InputMap events are erased on clients, and `quick_load` is erased on the host (re-asserted on `InputManager.bindings_changed`). `pause_menu.gd` extension blocks Load/Delete for everyone and Save on clients | H-SV2 |
| R16 | `player_controller._input` reads `Input.is_action_just_pressed` (global), not the event, so per-event filtering cannot block F5/F9 | `player_controller.gd:136-160` | Erase the InputMap events instead of filtering events (R15) | H-SV2 |
| R17 | Achievements: a late joiner loads a progressed host state, and `Steamworks._on_save_loaded → evaluate_all()` (`steamworks.gd:381-437`) grants phase and money achievements for free | code | "Presence" policy (section 11): everything is suppressed during the join load, then a baseline of already-met achievements is marked granted for the session. Only thresholds crossed while present fire | H-ACH1..3 |
| R18 | PittAPI builtins `save.isolate`, `perf.pin_physics`, `achievements.suppress`, `presence.suppress`, `player.*` are `authority_only` (the default), so with a remote authority a **client's `save.isolate` would execute on the host** | `builtin_commands.gd:20-66`, `commands.gd:_dispatch` | Loader addition L1: a command `scope: "local"` that never leaves the issuing peer. The builtins above are marked local | H-CMD3 |
| R19 | Remote cheat commands (`money.set` etc.) run on the host when the host has `cheats_allowed=true` (the default) | `commands.gd:_admit` | The host refuses remote envelopes for `cheat` commands unless `mp_allow_remote_cheats=true` | H-CMD4 |
| R20 | A command result arrives before the state delta it caused, so the UI refreshes with old values | channel ordering | Results and state deltas share **one reliable ordered channel**. The host flushes the state diff before sending the reply | H-CMD2 |
| R21 | Stale packets from a previous session, or duplicated or reordered messages | | `session_id` (random 64-bit per session) on every message. `seq` on state messages. Duplicates and older seq values are dropped | H-NET2 |
| R22 | Malformed or hostile packets (friends-only does not mean bug-free) | | Size caps, type whitelist per state, JSON-safe check, per-peer rate limits. Peer ids, names and slots always come from the transport or the host, never from payloads (`dispatch_remote` already takes `sender_peer` from the transport) | H-NET3 |
| R23 | Host disconnects while a client is mid-LoadingScreen (threaded load, then `change_scene_to_packed`) | `loading_screen.gd:203-227` | Abort is **deferred** until the client reaches a safe point (world ready or load failed), then the client returns to the menu with a dialog | H-SE4 |
| R24 | Steam pumps callbacks only through `Steamworks._process → Steam.run_callbacks()` (`steamworks.gd:441`, `embed_callbacks=false`) | code | We never add a second pump. We connect to `Steam.*` signals and poll only the `MultiplayerPeer` | review |
| R25 | `restartAppIfNecessary` (`steamworks.gd:146`) and two instances under one Steam account | code | Dev and test transport is ENet on localhost. The second instance runs from `decomp/` in the editor binary (skips the restart check) | L-1 |
| R26 | **The decomp editor instance uses the real `user://`** (`%APPDATA%/Godot/app_userdata/Project P.I.T.T`: same project name) | Godot user-dir rules | `decomp/override.cfg` sets `application/config/use_custom_user_dir=true` + `custom_user_dir_name="PittMP-Dev"`. PittMultiplayer's dev bootstrap **refuses to start** in an editor build if `OS.get_user_data_dir()` ends with `Project P.I.T.T` (**SPIKE T0**) | L-0 |
| R27 | Main-menu injection: duplicating `Play` with default flags copies its `pressed → _on_play_pressed` connection (`main_menu.tscn:1613`) | tscn | `duplicate(DUPLICATE_GROUPS \| DUPLICATE_SCRIPTS \| DUPLICATE_USE_INSTANTIATION)` (no `DUPLICATE_SIGNALS`), then connect `mouse_entered → main_menu._on_mouse_entered` and `pressed → router` ourselves | H-UI1 |
| R28 | `main_menu._unhandled_input` (`main_menu.gd:118-131`) consumes `ui_cancel` whenever MenuButtons is hidden. `_focus_current_panel` knows nothing about our panels | code | Our panels sit deeper in the tree, so they get `_unhandled_input` first; the router handles Esc and marks it handled. `main_menu.gd` extension overrides `_focus_current_panel()`: our panel first, else `super` | H-UI2 |
| R29 | Adding a fifth 104 px button overflows MenuButtons (736×460, `grow_vertical=2`, so it grows both ways) and may overlap the `P.I.T.T.` title | tscn | After injection, measure `get_combined_minimum_size()`. If it is over the original height, set `grow_vertical = GROW_DIRECTION_END`. Screenshot check in manual test M-1 | M-1 |
| R30 | Version or mod mismatch causes silent desync | | Lobby data gate plus a transport `hello` gate: game version, `buildid`, PittAPI version, MP protocol, and the sorted `client_required` mod list `[id@version]` must match exactly | H-NET1 |
| R31 | `item.buy` / `entity.spawn` from client mods now go to the host world | `commands.gd` | Documented MP1 semantics: world commands are host-world. Mods must check `api.net.is_authority()`. ExampleMod's F8 spawn lands in the host world | doc |
| R32 | A remote player's tool can't be under two cameras; carry writes `linear_velocity` locally | player map section 9 | MP1: not replicated (private physics). MP2: ownership transfer (section 12) | n/a |
| R33 | `PerformanceMonitor` changes the physics tick rate per machine (`performance_monitor.gd:352`) | map | MP1: irrelevant (avatars use wall clock). MP2: `perf.pin_physics 60` on all peers | n/a |
| R34 | A Steam invite (`join_requested`) arrives while the player is in a single-player world | spec | Joins are accepted only from the main menu. In a world: toast `MP_JOIN_FROM_MENU`; the lobby id is kept and a confirm dialog is offered on the next main menu | H-LB4 |
| R35 | Ghost lobbies | spec | `leaveLobby` on every exit path: router Back/Leave, session end, `world.exited`, `scene.changed` to main menu while not in a lobby screen, `NOTIFICATION_WM_CLOSE_REQUEST`, `_exit_tree` | H-LB3, M-13 |
| R36 | The client's `Steamworks.clear_presence()` or `_push_presence` (`steamworks.gd:239-289`) and our `connect` key | code | `_push_presence` only sets `money` and `steam_display`. We re-assert `connect`/`steam_player_group` at 1 Hz while in a lobby. `presence.suppress` stays off | M-6 |
| R37 | `main_menu.tscn` connects `visibility_changed → _on_visibility_changed`, which does not exist in main_menu.gd (engine error on every menu load) | tscn:1609, grep | Pre-existing. The MP mod must not count it toward its own errors (ErrorGuard attributes it to no mod) | boot test |
| R38 | Decompiled `.gd` in the editor instance is not byte-identical to the shipped `.gdc`, and editor builds abort on VM errors while release builds do not (README S4) | | Loopback tests prove **our** protocol only. Release behaviour is proven by live tests (real game as host) and the manual 2-account checklist | L-*, M-* |
| R39 | Client spawns at a bad position (host mid-air, in the maw) | | Snapshot `player_position` = host `last_safe_position` plus a per-slot ring offset (1.5 m). Falls back to `RESPAWN_ANCHOR (0,6,18)` | L-4 |
| R40 | Host in PHASE_0 (elevator). A joiner would run its own elevator, and its exit calls `change_phase(1)` locally (`game_progression.gd:117`) | code | The session stays `STARTING` until the host's `current_phase >= 1` and `elevator_exited`. Joiners always load phase ≥ 1, so the elevator intro is skipped (`elevator.gd:63-69`) | H-LJ1 |
| R41 | Sandbox mode (`debug_apply_all`, `sandbox.save`) in a session | main_menu.gd:557+ | Not supported in MP1. The host's slot picker blocks Sandbox (override `_on_sandbox_pressed` → toast) | H-UI4 |
| R42 | Pending client commands when the session ends | | All pending results finish with `ERR_UNAVAILABLE "session ended"`. Command timeout is 10 s | H-CMD1 |

---

## 2. Components and boundaries

```
mods/PittMultiplayer/                     (new mod; "multiplayer": "client_required", provides: ["net"])
  main.gd                 entry: wires everything; owns the MpSession; exposes get_public_api()
  core/
    proto.gd              constants, message kinds, framing, size caps, validation
    codec.gd              JSON (+zstd above 1 KB) and the binary avatar frame; chunker for snapshots
    transport.gd          abstract Transport (signals + poll/send); no game or Steam code
    transport_enet.gd     ENetMultiplayerPeer on 127.0.0.1 (dev/tests)
    transport_steam.gd    SteamMultiplayerPeer host_with_lobby / connect_to_lobby
    transport_loopback.gd in-process pair with latency/loss/dup/reorder knobs (headless)
    session.gd            host + client state machines, timeouts, roster, liveness
    mp_authority.gd       duck-typed PittAuthority (submit/complete/is_authority/...)
    game_adapter.gd       THE ONLY file that reads or writes game globals (GameState, SaveManager,
                          UnlockManager, GameProgression, MenuManager, Steamworks, InputMap, scene nodes)
    replicator_econ.gd    host: diff + publish; client: apply (through game_adapter)
    snapshot.gd           host: build join snapshot from SaveManager collectors; client: write + launch
    guards.gd             MoneyGuard, ItemGuard, PauseGuard, InputGuard, SaveGuard, UnlockGuard
    achievements.gd       presence policy
    avatars.gd            send/relay/receive, interpolation, puppet nodes
    contract_mp.gd        list of every game member this mod touches (checked at boot)
  lobby/
    lobby_service.gd      abstract: signals + plain-data model (LobbyInfo, MemberInfo)
    lobby_service_steam.gd  all Steam lobby/friends/presence calls live here and only here
    lobby_service_local.gd  ENet dev "lobby" (fixed port, command-line join)
    lobby_service_fake.gd   headless
  ui/
    menu_injector.gd      finds MainMenu, duplicates Play, adds panels, idempotent
    mp_menu_router.gd     panel push/pop, Esc = back, focus
    screen_hostjoin.gd    Host / Join / Back
    screen_lobby.gd       member list (center) + Start / Invite / Leave
    screen_join.gd        friend lobbies list + Refresh + Back
    row_factory.gd        instances res://scenes/save_slot_row.tscn rows and tints them like main_menu
    strings.gd            MP_* translation keys -> TranslationServer (en + cheap locales)
    dialogs.gd            wraps res://scripts/confirm_dialog.gd
  extensions/
    main_menu_ext.gd      _focus_current_panel, _launch_game, _on_return_save_load, _on_sandbox_pressed
    upgrade_ui_ext.gd     _create_upgrade_row / _create_tool_buy_row / _create_toy_buy_row rewiring
    hole_ext.gd           _check_phase_completion / _trigger_ending gated on authority
    pause_menu_ext.gd     _on_save_pressed / _on_load_pressed / _on_delete_save_pressed /
                          _on_main_menu_pressed / _return_to_main_menu / _on_quit_pressed
```

Rules:

1. Only `game_adapter.gd` touches game globals. Headless tests swap in a `FakeGameAdapter`, so the
   **whole protocol runs host plus N clients in one process** without the game.
2. Only `lobby_service_steam.gd` and `transport_steam.gd` touch `Steam`. Both check `Engine.has_singleton("Steam")`,
   `Steamworks.is_steam_initialized` and `has_method` before each call (GodotSteam signatures, section 4).
3. Screens are dumb views. They subscribe to LobbyService and Session signals in `tree_entered` and
   disconnect in `tree_exiting`.
4. Every extension is **inert** unless `session.is_live()`: the first line of each override is
   `if not _mp_live(): return super.<same>(...)`. That proves single-player behaviour is unchanged
   (test H-SP1: the existing 102 headless tests plus the live boot/menu/gameplay suites with the mod installed).
5. Extensions contain no copied game code. They call `super` and game methods by name only. Redistribution
   rule: decomp is never copied.
6. Network nodes are `PROCESS_MODE_ALWAYS` and live under `/root/PittAPI/Mods/PittMultiplayer`, so they
   survive scene changes.

---

## 3. Minimal loader additions (each one justified)

| # | Addition | Why it can't live in the mod | Size |
|---|---|---|---|
| L1 | `commands.register(..., {scope: "local"})`: `execute()` dispatches locally even under a remote authority; `_dispatch` skips the `authority_only` denial for it; `dispatch_remote` refuses it. Mark `save.isolate`, `perf.pin_physics`, `achievements.suppress`, `presence.suppress`, `player.teleport`, `player.impulse` as local | R18: otherwise a client's save isolation runs **on the host** | ~20 lines + tests |
| L2 | Privileged net hook: manifest `"provides": ["net"]` (schema update). Only one active mod may provide it. Its context gets `api.net.install_authority(a)`, `api.net.uninstall_authority()`, `api.net.register_remote_player(node, peer) -> eid`, `api.net.unregister_remote_player(peer)`, and `api.net.emit_session(started\|ended, info)`, which drives the existing `session_started`/`session_ended`/`peers_changed` signals and `net.authority_changed` | `_set_authority` and `entities.register_player` are core-private, and mods must not get the raw core | ~60 lines |
| L3 | Replay tagging: `api.net.begin_apply(origin_peer) / end_apply()` sets GameBridge `money_reason = "net"` and event `origin`/`source = "net"` for events emitted while replicated state is applied | Mods on clients must be able to tell "host changed money" from "my game changed money" (MoneyGuard depends on it) | ~20 lines |
| L4 | `api.contract.check(members: Array) -> {ok, missing}` exposing the core Contract checker | The MP mod has its own contract (section 14). Failing closed needs the same checker the core uses | ~15 lines |
| L5 | `--pittapi-instance=<name>` command-line argument → `user://pittapi-<name>/` | Two dev instances share the throwaway `PittMP-Dev` user dir. Without this they fight over `pittapi.log`, `status.json` and config | ~10 lines |
| L6 | (nice to have) event `ui.main_menu_ready {path}` emitted after MainMenu `_ready` | The mod can do this through `scene.changed`. Only add it if a second mod needs menu injection | ~10 lines |

No other loader changes. In particular we do **not** wrap autoloads (`GameState` etc. are BLOCKED and S4 is unverified).

---

## 4. Transport and abstraction

### 4.1 Interface (`core/transport.gd`)

```gdscript
signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal packet(peer_id: int, channel: int, bytes: PackedByteArray)
signal closed(reason: String)            # local close, host gone, connect failure
func host(opts: Dictionary) -> Error
func join(target: Variant, opts: Dictionary) -> Error   # Steam: lobby_id; ENet: "127.0.0.1:port"
func poll() -> void                      # called from session._process (PROCESS_MODE_ALWAYS)
func send(peer_id: int, channel: int, reliable: bool, bytes: PackedByteArray) -> Error   # 0 = broadcast
func close(reason: String) -> void
func local_peer_id() -> int              # host = 1
func steam_id_of(peer_id: int) -> int    # 0 on ENet/loopback
func kind() -> String                    # "steam" | "enet" | "loopback"
```

Implementation notes:

- Both concrete transports wrap a Godot `MultiplayerPeer` and use the **raw packet API** (`set_target_peer`,
  `transfer_channel`, `transfer_mode`, `put_packet`, `get_packet`, `get_packet_peer`, `get_packet_channel`).
  We **do not** assign `get_tree().get_multiplayer().multiplayer_peer` and we use **no `@rpc` and no
  MultiplayerSynchronizer**, because:
  - RPC routing needs identical node paths, and the game's tree is not deterministic;
  - SceneMultiplayer would start consuming packets and auto-relaying;
  - every inbound byte must go through our validator.
  **SPIKE T1**: `SteamMultiplayerPeer` works when only polled manually, without being set on SceneMultiplayer.
  Fallback: set it on a private `SceneMultiplayer` instance assigned to our subtree only
  (`get_tree().set_multiplayer(mp, ^"/root/PittAPI/Mods/PittMultiplayer")`) and receive through
  `peer_packet` (`SceneMultiplayer.send_bytes`).
- `transport_steam.gd`: `SteamMultiplayerPeer.new()`, then `host_with_lobby(lobby_id)` on the host and
  `connect_to_lobby(lobby_id)` on clients. These names, plus `create_host`, `create_client`,
  `get_steam_id_for_peer_id`, `get_peer_id_for_steam_id`, `set_no_delay` and `refuse_new_connections`, were
  found in the bundled `libgodotsteam.windows.template_release.x86_64.dll`. Argument lists are not visible
  there: call through `has_method` and log the GodotSteam version string at boot (**SPIKE T2**: signatures
  and return codes). The project already sets `steam/multiplayer_peer/max_channels=4`.
- `transport_enet.gd`: `ENetMultiplayerPeer.create_server(port, 9, 4)` / `create_client("127.0.0.1", port, 4)`.
  Use generous `ENetPacketPeer.set_timeout(5000, 30000, 60000)` because a joiner's LoadingScreen can stall
  its main thread (R23).
- `transport_loopback.gd`: two endpoints in one process. A deterministic RNG drives `latency_ms`,
  `jitter_ms`, `loss` (unreliable only), `duplicate`, `reorder` (unreliable only) and `stall(peer, ms)`.
- Topology is a **star**. Clients only talk to the host, and the host relays avatars. No client-to-client
  traffic, so peer ids and slots are host-assigned facts.
- Liveness is our own `ping`/`pong` at 2 Hz on wall clock. A peer silent for 15 s is dropped. This works
  the same on ENet and Steam and does not depend on transport-specific timeouts.

### 4.2 Channels (4 = project max)

| Ch | Mode | Direction | Contents |
|---|---|---|---|
| 0 | reliable ordered | both | control: hello/welcome/reject, roster, session_state, join_request, snapshot chunks, join_ready/failed, ping/pong, bye, session_end |
| 1 | reliable ordered | client → host | command envelopes |
| 2 | reliable ordered | host → client | **one totally ordered stream**: command results, econ deltas/full, phase begin/settled, unlock deltas, toasts. A single `seq` counter (R20, R21) |
| 3 | unreliable (sequenced where the peer supports it) | both | avatar transforms (binary) |

### 4.3 Framing and message format

Byte 0 is the frame kind: `0` JSON, `1` zstd(JSON), `2` avatar binary, `3` snapshot chunk (binary).

JSON messages are JSON-safe Dictionaries. Every one carries:

```json
{"k": "econ", "sid": "9f2c...", "q": 1042, ...body}
```

- `k`: message kind (whitelisted per channel and per session state; anything else is dropped and counted).
- `sid`: session id (hex of 64 random bits, made at host Start). A mismatch is dropped (R21).
- `q`: seq on channel 2; optional elsewhere.

Caps: client → host JSON ≤ 16 KB; host → client JSON ≤ 256 KB. Snapshots are chunked in 16 KB binary
frames with `{xfer, i, n, sha256}` in a JSON header (`snapshot_begin`). Per-peer rate limits: commands
30/s burst 60, avatar 40/s, control 20/s. Over the limit: drop and count. Over 3× the limit for 5 s: kick
with `MP_ERR_PROTOCOL`.

Avatar frame (kind 2, 28 bytes, little endian): `u8 kind, u8 slot, u16 flags, u32 t_ms, f32 x, f32 y, f32 z,
f32 yaw, f32 pitch, u32 seq`. Flags: crouch, sprint, airborne, menu_open, torch. The host **overwrites `slot`** with
the sender's real slot before relaying (R22).

---

## 5. Plugging into PittAPI (Commands / Authority / Entities / Events)

### 5.1 MpAuthority (duck-typed; Commands only calls these members)

```
get_kind() -> "mp-host" | "mp-client"
is_authority() -> host: true, client: false
local_peer_id() -> transport id (host 1)
get_peers() -> roster peer ids
is_multiplayer() -> true
submit(envelope):
  host:   result = commands.dispatch_envelope(envelope); econ.flush_now(); complete(envelope, result)
  client: if registry says scope=local -> commands.dispatch_envelope locally (L1 already handles this before submit)
          else pending[id] = {envelope, deadline = now+10 s}; send ch1 {k:"cmd", env: envelope}
complete(envelope, result) -> commands.complete_envelope(envelope, result)
```

Host receive path for `cmd`:

1. Validate the frame. `env.name` must be a String, `env.args` a Dictionary, and `env.id` an int (it is the
   client's own id, echoed back).
2. If `describe(name).cheat` and not `mp_allow_remote_cheats`, reply `ERR_DENIED` (R19).
3. Run `commands.dispatch_remote(env, sender_peer_from_transport)`. All PittAPI gates re-run, and
   `ctx.is_remote` and `ctx.origin_peer` are set.
4. `econ.flush_now()`, so any state change caused by the command is sent first on ch2.
5. Send `{k:"res", id, result}` on ch2.

Client: when `res` arrives, `commands.complete_envelope(pending.envelope, result)`. When the session ends,
or a command passes its deadline, it is completed with `{ok:false, code:"ERR_UNAVAILABLE"}` (R42).

### 5.2 MP commands (registered by the mod; host-validated)

| Command | Scope | Host validation | Effect on host |
|---|---|---|---|
| `PittMultiplayer.buy_item {category, key, subkey}` | authority | category ∈ {upgrades, products, combos}; key and subkey exist; item `enabled` and, when present, `enabled_levels[level]`; level < prices.size(); can_afford | Same as core `item.buy` (affordability first, avoiding the auto-machine bug), i.e. `GameState.buy(...)` |
| `PittMultiplayer.buy_tool {tool, level}` | authority | tool exists and `enabled`, `enabled_levels[level]`, level < buy_prices.size(), pool headroom for the pool id `_spawn_tool_instance` would use, can_afford | `GameState.spend(cost)`, `purchased_once[tool]=true`, `Steamworks.check_consumerism()` on the host. Reply `{ok, spawn: true}`; the **client** spawns locally |
| `PittMultiplayer.buy_toy {toy}` | authority | enabled, buy_prices non-empty, can_afford | `spend`, `purchased_once`, crate price escalation using the same step table `upgradeUI.gd:1546-1555` uses (the values are read from the game at runtime: see the note below). Reply `{ok, spawn: true}` |
| `PittMultiplayer.charge {amount: "digits", reason}` | authority | amount ≤ 10^9 per call, ≤ 20 calls/min/peer | `GameState.spend(min(amount, money))`, i.e. the game's floor-at-0 semantics |
| `PittMultiplayer.contribute {amount, product_type}` | authority | only when `mp1_client_contributions`; rate caps | `GameState.add_money(amount, product_type)` |
| `PittMultiplayer.apply_*` | local, internal, replay | never remote | client-side appliers (section 8); they go through Commands only for the audit trail |

Crate step note: the step table (`upgradeUI.gd:1546-1555`) is a local dictionary inside the purchase lambda,
so it can't be read at runtime. **Decision**: the mod carries the 4 step values as data (wooden 1, metal 100,
plush 10000, anomaly 1000000), not code. A contract test checks them against the decomp text through
`tools/contract_check.py` (step 3 of the headless run), so a game update that changes them fails before release.
The escalated price reaches clients through the normal econ diff (`buy_price0`).

### 5.3 Entities

- Puppets: `api.net.register_remote_player(puppet, peer)` (L2) → slot id 2..999. `api.entities.describe` shows
  `kind: "player"`.
- MP1 clients allocate no dynamic ids (PittAPI already: non-authority allocates none). Client-local pooled
  objects are untracked in MP1 (`id_of == 0`). This is documented.
- The static fixture key hashes are already deterministic and stay unused in MP1. MP2 uses them.

### 5.4 Events

- Clients see normal events (`money.changed`, `phase.changed`, `unlock.milestone`, `item.level_changed`) produced
  by the GameBridge when replicated state is applied, tagged `reason: "net"` / `source: "net"` (L3).
- The mod emits `mod.PittMultiplayer.session` `{state, role, peers}`, `.peer_joined`, `.peer_left`, `.desync`
  `{kind}` and `.ended` `{reason}`.
- `api.net` signals: `session_started`, `session_ended`, `peers_changed` (L2).

---

## 6. Session lifecycle and scene coordination

### 6.1 One path for Start and for late join

**Every client enters the world through the late-join path.** Start does not do a lock-step "everyone loads
now". The host loads first, and clients join the running world as soon as it is open. That gives one code path
to test instead of two, and it makes R4, R7 and R40 the same problem.

### 6.2 Host state machine

```
IDLE --host()--> LOBBY  (createLobby ok + transport.host ok; lobby data state=waiting)
LOBBY --Start--> PICKING (game's MenuLoad panel shown in "MP host" mode; Return -> LOBBY)
PICKING --Load/New (main_menu_ext._launch_game)--> STARTING (lobby state=starting; clients: "Host is loading")
STARTING --world.ready && phase>=1 && elevator_exited && no transition--> OPEN (lobby state=in_game)
OPEN --phase.begin 2..4--> TRANSITION --phase.settled--> OPEN
OPEN|TRANSITION --phase.begin 5--> ENDING (lobby state=ending, joinable=false)
any --host leaves world / quits / Leave--> CLOSED: broadcast session_end{reason}, close transport, leaveLobby
```

- In `OPEN`, the host serves queued join requests one at a time (snapshot build cost, R3).
- In `TRANSITION`, joins are queued (deadline 60 s, then served as settled).
- In `ENDING`, `STARTING` and `PICKING`, a join is answered with `session_state` and the client waits
  (`PICKING`/`STARTING`) or is refused (`ENDING`).
- Host return to main menu: the `pause_menu_ext._on_main_menu_pressed` confirm dialog body becomes
  `MP_CONFIRM_END_SESSION`. `_return_to_main_menu` first runs `session.close("host_left")`, then `super`.

### 6.3 Client state machine

```
IDLE -> JOINING_LOBBY (joinLobby) -> CONNECTING (transport.join) -> HANDSHAKE (hello -> welcome|reject)
 -> LOBBY_WAIT (lobby screen; host PICKING/STARTING)
 -> SNAPSHOT_RX (host OPEN; join_request -> snapshot chunks, sha256 checked)
 -> LOADING_WORLD (save.isolate on; write snapshot; launch through main_menu._launch_game)
 -> SYNCING (world.ready + save.applied -> join_ready -> host sends econ full + roster)
 -> PLAYING
 -> LEAVING (Leave / host_left / error) -> IDLE
```

Error edges: any state → `ABORTING(reason)`. In LOADING_WORLD, ABORTING waits for a safe point (R23).
Then: tear down guards (section 9.6), `save.isolate {enabled:false}`, `Engine.time_scale = 1`,
`get_tree().paused = false`. If in world: `PauseMenu._return_to_main_menu()` (the game's own full reset,
`pause_menu.gd:104-149`). Then a ConfirmDialog on the main menu with the reason key.

Timeouts (wall clock): handshake 10 s, snapshot transfer 60 s, world load 180 s, ping silence 15 s,
command 10 s.

### 6.4 Join snapshot (host build)

The host builds it without touching the save file and without pausing, by calling SaveManager's **pure
collector functions** (verified read-only, `save_manager.gd:518-656`, `:1483`):

| Section | Source | MP1 |
|---|---|---|
| `game_state` | `_save_game_state()` | keep. Set `elevator_hacked=false` and `panel_stack=[]`; keep `remote` (MP2 replicates) |
| `game_statistics` | `_save_game_statistics()` | keep |
| `unlocked_milestones` | `UnlockManager.get_save_data()` | keep |
| `phase` | `GameProgression.current_phase` (clamped ≤ 4) | keep (always ≥ 1, R40) |
| `hole` | `_save_hole()` | keep |
| `vertical_gates`, `cameras`, `minable_blocks`, `loop_puzzle` | collectors | keep (cosmetic world state; local afterwards) |
| `object_pools`, `workbenches`, `pickaxe`, `press_spawned`, `trading_terminal_spawned`, `bowling_set_spawned` | | **strip / false** (private physics; avoids duplicated economy objects) |
| `player_position` | host `last_safe_position` + ring offset | computed (R39) |
| `music`, `seen_items` | | strip (client-local) |
| `version` | `application/config/version` | keep |
| `mp` (extra top-level key, ignored by the game) | `{sid, econ_seq, host_name}` | add |

The host serialises it with `JSON.stringify`, compresses it with zstd, takes its sha256, and sends it in chunks.

### 6.5 Join snapshot (client apply)

1. Run `save.isolate {enabled:true, path:"user://pittapi/mods/PittMultiplayer/session/join.save"}` (L1 makes it local).
2. Write the snapshot there as **plaintext JSON**. `_read_save_string` falls back to plaintext
   (`save_manager.gd:456-476`, verified).
3. Load the way `_on_load_pressed` does (`main_menu.gd:211-229`): `GameProgression.reset_run_state()`,
   `current_phase = snapshot.phase`, `SaveManager.should_load_on_ready = true`, `main_menu._pending_new_game = false`,
   then `main_menu._launch_game("res://scenes/world.tscn")`. The game's own LoadingScreen, pool init,
   `load_game()` and `apply_deferred_load()` run unchanged. `_write_slot_index()` is a no-op for non-slot
   paths (F11).
4. Achievements are suppressed for the duration (section 11).
5. On `save.applied`: install the guards, send `join_ready`, and receive econ full state, roster and avatars.

Late join mid-host-transition is impossible by construction (6.2). A host phase change *during* the client's load
is fixed by the full econ state in step 5: the client calls `change_phase(N)` and plays the cinematic.

### 6.6 Coordinated scene changes

| Host event | Clients |
|---|---|
| `phase.begin 1..4` | `GameProgression.change_phase(N)` locally (cinematic, music, `time_scale`). `checkpoint_save` hits the isolation lock |
| `phase.settled N` | idempotent; marks "settled" |
| `phase.begin 5` | `change_phase(5)` locally; session → ENDING; avatars stop; at the client's scene change away from world the client leaves the session silently (reason `ending`) |
| host leaves world | `session_end{host_left}` → ABORTING |
| host in-game reload | impossible (R15) |

---

## 7. Lobby service and UI

### 7.1 LobbyService (signals plus plain data)

```
signal lobby_entered(info: LobbyInfo)          # created (host) or joined (client)
signal lobby_left(reason: String)
signal members_changed(members: Array)         # [MemberInfo{steam_id, name, is_host, state}]
signal friend_lobbies_changed(list: Array)     # [LobbyInfo{lobby_id, host_name, members, max, state, compatible, reason}]
signal join_requested(lobby_id: int)           # invite / "Join Game" / +connect_lobby
signal error(key: String, detail: String)
func host(max_members := 10) ; func join(lobby_id) ; func leave() ; func invite_overlay()
func refresh_friend_lobbies() ; func set_state(state: String) ; func set_scan_active(bool)
```

Steam implementation (all names verified in the DLL; signatures **SPIKE T2**):

- Host: `createLobby(LOBBY_TYPE_FRIENDS_ONLY, MAX_MEMBERS=10)` → `lobby_created(connect, lobby_id)`. Then
  `setLobbyData` for `pitt_version` (`1.0.8`), `pitt_buildid`, `pittapi_version`, `mp_proto`, `mods_hash`,
  `host_name`, `host_steam_id`, `members`, `state`. Then `setRichPresence("connect", "+connect_lobby %d")`
  and `steam_player_group`, re-asserted at 1 Hz (R36).
- Members: after `lobby_joined`, `getNumLobbyMembers` + `getLobbyMemberByIndex` + `getFriendPersonaName`.
  Updates come from `lobby_chat_update` (rebuild), `persona_state_change` (names) and `lobby_data_update`
  (host state). The host rewrites `members` on every `lobby_chat_update`.
- Owner change or `host_steam_id` leaving (`getLobbyOwner` ≠ `host_steam_id`) → `lobby_left("host_left")` (R8).
- Join list: for each friend (`getFriendCount` + `getFriendByIndex`), `getFriendGamePlayed(friend)`. If its `id`
  is this app and `lobby` is non-zero, call `requestLobbyData(lobby)`; the row fills on `lobby_data_update`.
  `persona_state_change` re-checks that friend. A 10 s fallback rescan runs **only while the Join screen is
  visible** (`set_scan_active`), plus a Refresh button.
- Compatibility: `compatible` is false when any of `pitt_version`, `pitt_buildid`, `pittapi_version`,
  `mp_proto`, `mods_hash` differs. `reason` is a translation key (`MP_ERR_VERSION_GAME`, ...).
- `join_requested(lobby_id, friend_id)` and `+connect_lobby <id>` (from `OS.get_cmdline_args()`, falling back to
  `Steam.getLaunchCommandLine()`) → `join_requested`. Consumed only on the main menu (R34).
- When Steam is not initialised (`Steamworks.is_steam_initialized == false`), the Multiplayer screen shows
  `MP_ERR_NO_STEAM` and only the dev path (when enabled) works.

`lobby_service_local.gd` (dev): "host" opens ENet on `mp_dev_port` (default 27450). "Join" lists
`127.0.0.1:<port>` if a probe connect succeeds. `--pittmp-join=127.0.0.1:27450` auto-joins at boot.
`lobby_service_fake.gd` (headless): scripted members and lobbies; `emit_*` helpers.

### 7.2 Injection into `main_menu.tscn` without breaking its code

`menu_injector.gd` runs on `scene.changed(kind="main_menu")` (and on `node_added` of group `MainMenu` as a
backstop). It waits for `ready`, then:

1. If `Background/MenuButtons/MPMultiplayer` exists → return (idempotent; menu re-entry rebuilds the scene).
2. `play := Background/MenuButtons/Play`.
   `mp := play.duplicate(DUPLICATE_GROUPS | DUPLICATE_SCRIPTS | DUPLICATE_USE_INSTANTIATION)` (R27).
   Set `name = "MPMultiplayer"`, `text = "MP_MULTIPLAYER"` (auto-translated like `MENU_PLAY`).
   `add_sibling` → `move_child(mp, play.get_index() + 1)`.
   Connect `mouse_entered` to `main_menu._on_mouse_entered` (the game's hover sound) and `pressed` to
   `router.open("hostjoin")`. Fix the focus neighbours of Play/MP/Options.
3. Panels `MPHostJoin`, `MPLobby`, `MPJoin`: `VBoxContainer` siblings under `Background`. Layout values are
   **copied at runtime from the live `MenuLoad` node** (anchors_preset 4, anchors 0.5/0.5, offsets 49/-76/785/384,
   grow_vertical 2), not hard-coded, so a restyle carries over. Theme comes from `Background`
   (`main_menu.tres`). Buttons use `res://assets/PublicPixel-rv0pA.ttf`: 104 px top level, 52 px sub-panel.
   The lobby's centre member list is an extra centred container that the Lobby panel shows and hides
   together with itself.
4. Rows: `load("res://scenes/save_slot_row.tscn").instantiate()`. Fill the `Number`/`Name`/`Info` labels and tint
   them with main_menu's own colour constants (`SLOT_COLOR_NORMAL/EMPTY/SELECTED` read from the script instance)
   and the `"> %02d"` focus marker, like `_refresh_slot_ui`.
5. Sounds: `MenuManager.play_ui_sound(main_menu.click_sound | hover_sound)`. Input debounce: call
   `main_menu._temporarily_ignore_input()` and honour `main_menu.ignore_input`.
6. Router: `push(id)` hides the current panel (MenuButtons at the root) and shows `id`. `pop()` reverses it. Esc
   (`ui_cancel`) is handled in the router's `_unhandled_input`. Router nodes are children of `Background`, so
   they get the event before `MainMenu` and call `set_input_as_handled()` (R28).
   `main_menu_ext._focus_current_panel()` focuses our visible panel's first button, else `super`.
7. Host Start → `router.push_game_panel("MenuLoad")`: calls `main_menu._on_play_pressed()` (the game's own slot
   picker) with `picking_for_mp = true`. Overrides while that flag is set: `_on_return_save_load` returns to
   MPLobby, `_on_sandbox_pressed` shows a toast (R41), `_launch_game` informs the session (→ STARTING) and calls `super`.
8. Leaving any MP panel back to MenuButtons, or `scene.changed` away from the main menu while in a lobby
   without a live session, calls `leaveLobby` (R35).

Strings: `MP_MULTIPLAYER, MP_HOST, MP_JOIN, MP_BACK, MP_START, MP_INVITE, MP_LEAVE, MP_REFRESH,
MP_LOBBY_TITLE, MP_JOIN_TITLE, MP_NO_FRIENDS_HOSTING, MP_PLAYERS_FMT, MP_STATE_WAITING, MP_STATE_IN_GAME,
MP_STATE_STARTING, MP_HOST_LOADING, MP_CONFIRM_LEAVE_TITLE/BODY, MP_CONFIRM_END_SESSION, MP_HOST_LEFT,
MP_KICKED_PROTOCOL, MP_ERR_VERSION_*, MP_ERR_NO_STEAM, MP_ERR_FULL, MP_ERR_ENDING, MP_JOIN_FROM_MENU,
MP_SHOP_UNAVAILABLE, MP_HOST_ONLY, MP_MP1_PRIVATE_WORLD, MP_SANDBOX_UNSUPPORTED, MP_PEER_JOINED, MP_PEER_LEFT`.
They are registered as `Translation` resources for the game's own locale codes (`en, fr, cn, es, pl, ru, de, pt-br,
jp, ko`, `localization_manager.gd:4`), with English as the fallback. Dialogs use
`load("res://scripts/confirm_dialog.gd").new().setup(title_key, body_key, on_confirm, confirm_key, cancel_key,
click, hover, focus)`, loaded by path rather than through the `ConfirmDialog` global, to avoid depending on the
class cache.

---

## 8. Economy and progression replication

### 8.1 Host publisher (`replicator_econ.gd`)

- Triggers: PittAPI events `money.changed`, `bank.changed`, `item.level_changed`, `unlock.milestone`,
  `stat.changed`, `phase.changed`/`phase.settled`, plus a 4 Hz dirty poll (the golden statue writes money
  directly, and toy prices change silently).
- Coalescing: at most one `econ` delta per physics frame. Money-only deltas are throttled to 10 Hz (latest value wins).
- `econ` body: `{q, full: bool, h: sha256(canonical), money, total_money_gained, total_money_spent, bank, mining_bank,
  items: {cat: {key: {level, enabled, [sub: {level, enabled}], buy_price0?}}}, purchased_once, flags: {torch_unlocked,
  uv_unlocked, pickaxe_tier, pickaxe_found, uv_lamp_dispensed}, stats: {...game_statistics subset}, hole: {target_radius,
  phase_nutrition_total}}`. Deltas include only changed leaves. A full state goes out every 10 s and on demand.
- `unlock` body: `{q, ids: [..new ids in host order..]}`. `phase` body: `{q, kind: "begin"|"settled", phase}`.

### 8.2 Client applier (all through `game_adapter.gd`, inside `api.net.begin_apply(1)` / `end_apply()`)

- Seq: a message with `q ≤ last_q` is dropped. A gap triggers `{k:"resync"}` (should never happen on reliable ordered).
- Money: `GameState.money = BigInt.from_string(s)`; `money_updated.emit(GameState.money)`. Same for the totals
  (no emit). `bank`: set + `bank_updated.emit`.
- Unlock delta: for each id not yet in `unlocked_milestones`, in host order: append the id,
  `UnlockManager._execute_action(milestones[id].action)`, `milestone_unlocked.emit(id, m)`, and
  `_queue_notification(tr(m.notification))` if present. This mirrors `_trigger_milestone` (`unlock_manager.gd:1726`)
  by calling the game's own methods. Unknown ids (missing mod) → desync error (R30 should prevent it).
- Full resync: `UnlockManager.load_save_data(host_ids)` (resets `enabled_levels` and replays: the load path,
  `:2189`, no notifications), then item `level`/`enabled`/`buy_prices[0]`, then money.
- Item post-apply hooks: when `upgrades.remote_tier.level` changes, call `GameState.apply_remote_tier()`. When any
  item changes, call `UpgradeUI.update_ui()` + `update_credits()` (group `UpgradeUI`).
- Stats: written silently (no `stat_changed` emit). Then `Steamworks.evaluate_all()` is run at most every 2 s on
  clients so presence-policy achievements can fire (section 11).
- Hole: set `target_radius` and `phase_nutrition_total`. The client's `hole._process` lerps `current_radius`.
- Checksum: after applying a message that carries `h`, compute the same canonical hash. Two mismatches in a row
  → `resync` + a `mod.PittMultiplayer.desync` event. Three resyncs in 60 s → end the session with `MP_ERR_DESYNC`
  (fail closed).

Canonical hash input: `money|bank(%.6f)|phase|sorted(unlocked)|for cat,key sorted: level,enabled,subs|toy buy_price0`.
It is computed identically by both sides from GameState through the adapter.

### 8.3 Purchases from clients (`upgrade_ui_ext.gd`)

For each of `_create_upgrade_row`, `_create_tool_buy_row` and `_create_toy_buy_row`:

```
var row = super(...)
if not _mp_client(): return row
var button: Button = row.get_meta("button")
for c in button.pressed.get_connections(): button.pressed.disconnect(c.callable)
if button.pressed.get_connections().size() != 0: _shop_unavailable(); return row   # fail closed (R12)
button.pressed.connect(_mp_on_row_pressed.bind(row))
```

`_mp_on_row_pressed(row)`: honours the `recall_mode` meta (recall stays local: it moves objects in the
client's own world), calls `_acknowledge_row(row)`, sets a per-row pending flag (ignores presses while pending),
reads the row metas (`category/key/subkey`, `tool_name/level`, `toy_name`, verified at `upgradeUI.gd:1177-1179`,
`:1309-1310`, `:1516`), and runs the MP command with `execute_async`. On the result:

- ok: the game's success feedback (`_play_sound`, `_create_success_effect`/`_pulse_node`, `_screen_shake`,
  `_spawn_floating_text(button, tr("UI_UPGRADED"|"UI_PURCHASED"))`). For tools and toys, also
  `GameState.purchased_once[x] = true`, `Steamworks.check_consumerism()` and `_spawn_tool_instance(tool, level)` /
  `_spawn_toy_instance(toy)` locally. Then `update_ui()`.
- fail: the game's error feedback with `tr("UI_INSUFFICIENT_CREDITS"|"UI_INSUFFICIENT_FUNDS"|"UI_MAX_LEVEL")`,
  mapped from the result code.

The upgrade terminal mirror (`upgrade_terminal.gd:57-70`, meta `is_mirror`, PROCESS_MODE_DISABLED) is not
interactive. The extension does not override `_ready`.

### 8.4 MoneyGuard (client)

- Keeps `auth_money` (string) from the last applied host value.
- On `money.changed` with `reason != "net"`, on `stat_changed("money")`, and on a per-frame compare of
  `money.to_plain_string()` (cheap at MP1 rates; clients only): `delta = local - auth`.
  - delta < 0 and ItemGuard saw no unrouted item change this frame → send `charge {amount: -delta}`.
  - delta > 0 → if `mp1_client_contributions`, send `contribute`.
  - Always restore `money = BigInt.from_string(auth_money)` + `money_updated.emit` (tagged net).
- The HUD may flicker for one frame on fines. That is acceptable and documented.

### 8.5 UnlockGuard and phase guard (client)

- On session live: `GameState.stat_changed.disconnect(UnlockManager._on_stat_changed)`,
  `GameProgression.phase_changed.disconnect(UnlockManager._on_phase_changed)` (connections verified at
  `unlock_manager.gd:1493-1500`), `UnlockManager.set_process(false)` (stops floor checks; feed reminders are lost
  on clients, which is acceptable). Everything is restored on teardown, before `_return_to_main_menu` runs
  `UnlockManager.reset()`.
- `hole_ext.gd`: on non-authority, `_check_phase_completion()` and `_trigger_ending()` return without `super`.
- A per-frame phase watch (bridge `phase.changed` with source `poll`/`transition` not caused by our replay) →
  desync error. It should be unreachable. The watch exists to catch unknown `change_phase` callers.

---

## 9. Pause (local-only) and other guards

### 9.1 PauseGuard (both roles, only while live and in world)

`MenuManager.open_menu` pauses the tree (`menu_manager.gd:115`), and so do the overlay and controller-loss
auto-pause (`request_auto_pause`, `:123`). The game's menus must keep working while the world keeps running:

1. On `get_tree().process_frame` (and in our `_process`): if `get_tree().paused` and we are live and not ENDING,
   set `get_tree().paused = false`. `MenuManager.game_paused` stays true, so the game's menu logic (resume via Esc
   in `player_controller._unhandled_input` `:173-193`, `close_current_menu` restoring the mouse) is unchanged.
2. While `MenuManager.game_paused or MenuManager.current_menu != null`:
   - **local freeze**: `api.player.set_movement_locked(true)` (meta `golf_aim_mode`; gravity still applies,
     `player_controller.gd:232-243`);
   - `MainCamera.process_mode = PROCESS_MODE_DISABLED` (stops `_input`/`_physics_process` grabs and throws, which
     only check `get_tree().paused`, `main_camera.gd:180/219`), after `release_held_object()`;
   - restore both when the menu closes.
   The player node itself is **not** disabled: its `_unhandled_input` is the Esc-to-resume path.
3. `save_game`'s synchronous pause (`save_manager.gd:246-252`) is left alone. No frame passes.
4. Mouse look is already blocked by `MenuManager.current_menu != null` (`player_controller.gd:195`).
5. MusicManager's pause filter keys on `get_tree().paused` (`music_manager.gd:37-48`), so it won't engage. That is
   accepted as cosmetic.
6. **SPIKE P1**: `pause_menu.tscn` root has `process_mode = 4` (DISABLED in the 4.x enum). Confirm live that the pause
   menu's buttons and `_unhandled_input` behave identically with the tree unpaused. Our guard doesn't depend on
   the answer, but the test must prove the menu is still usable.

### 9.2 InputGuard

On live: erase the InputMap events of `quick_load` (all peers) and `quick_save` (clients). Re-erase on
`InputManager.bindings_changed`. Restore through `InputManager.apply_bindings()` on teardown. This never writes
`keybindings.cfg` (`save_bindings` is only called by the controls UI).

### 9.3 SaveGuard

- Client: `save.isolate` before LOADING_WORLD; off after leaving the world.
- `pause_menu_ext`: in a session, Load and Delete show `MP_HOST_ONLY` through `hud.show_restrict_message(tr(..))`
  for everyone. Save is blocked on clients and allowed on the host. "Main Menu" and "Quit" use the session-aware
  confirm text. `_save_then_exit` on clients is already a no-op (`save_before_exit` returns early when
  `save_locked`, F11).
- Host saves only its own slot, as in single player: autosave, checkpoints and manual saves continue.

### 9.4 ItemGuard (client)

Diffs item levels and enabled flags every frame against the last applied host state (cheap: about 70 items). Any
change outside the applier → revert + ERROR + suppress the charge for that frame (R13).

### 9.5 Time and Engine.time_scale

Network code never uses `delta` for timing. Teardown always sets `Engine.time_scale = 1.0`. The pitch-shift
effect on Master is left to `reset_run_state`, which runs inside `_return_to_main_menu`. **SPIKE P2**: confirm
the pitch restores after leaving mid phase-3.

### 9.6 Teardown order (single function, idempotent, also run from `_exit_tree`)

1. Session flag → not live, so extensions go inert.
2. Fail pending commands.
3. Close the transport (best-effort `bye`).
4. Restore UnlockManager connections/process, InputMap, camera process mode, movement lock.
5. Uninstall the authority (→ LocalAuthority).
6. Turn off save isolation.
7. `time_scale = 1`, tree unpaused.
8. Remove avatars.
9. `leaveLobby`.
10. Optionally `PauseMenu._return_to_main_menu()` + dialog.

---

## 10. Player avatars

- Send: local player `global_position`, body yaw (`rotation.y`), camera pitch (`MainCamera.rotation.x`), and flags
  (`is_crouching`, `is_sprinting`, `not is_on_floor()`, menu open, `torch_mode`) at **20 Hz of wall-clock time**,
  only when changed (or as a 1 Hz keepalive). Channel 3, unreliable.
- Host relays each client's frame to all other clients, overwriting `slot`.
- Puppet: `Node3D "PittMP_Avatar_<slot>"` under `/root/World/PittMP_Avatars` (rebuilt on `world.ready`, freed
  with World). Children:
  - `MeshInstance3D` with a built-in `CapsuleMesh` (radius 0.35, height 1.8; no game assets, no copying), a
    `StandardMaterial3D` per-slot colour from an 8-colour palette, plus a small box "visor" child aligned with the
    pitch so facing reads at a distance;
  - `Label3D` (billboard, `PublicPixel-rv0pA.ttf` loaded by path, gold `Color(0.969,0.729,0.078)` for the host, white
    for others, `no_depth_test=false`, `fixed_size` off, max distance 40 m).
  - No physics body, no groups and no script from the game (R1).
- Interpolation: a buffer of time-stamped frames rendered at `now - 100 ms` (wall clock), linear for position and
  shortest-arc for yaw. Extrapolation up to 250 ms, then hold. Hidden after 3 s without frames. A snap when a jump is
  over 5 m (teleports, respawn).
- Toasts for join and leave through `api.hud.toast` (our own CanvasLayer; works everywhere).
- Names: Steam persona of `transport.steam_id_of(peer)` resolved **on the host** and sent in `roster`. ENet: `Dev-<slot>`.

---

## 11. Steam achievements policy ("presence")

- Host: unchanged from single player.
- Client join: before step 3 of 6.5, copy `Steamworks._granted` to `saved` and prefill `_granted[id] = true` for
  every id in `Steamworks._probe_ids` (the existing `achievements.suppress` mechanism, now local scope, L1). On
  `save.applied`, compute the **baseline** with the game's own helpers (no copied logic):
  - `ACH_STAT`: `_meets(_get_stat(rule.stat), rule.threshold)`;
  - `ACH_PHASE`: `phase >= p`;
  - `ACH_GATE`: solved gates;
  - the flags `evaluate_all` checks (`uv_unlocked`, `keypad_revealed`, loop puzzle, destroyed cameras).
  Then set `_granted = saved ∪ baseline` and restore normal operation. From then on, crossings fire normally:
  local `stat_changed` (the client's own world), local `change_phase` from replication (`ACH_PHASE`), and the
  throttled `evaluate_all()` after silent stat writes.
- `mp_achievements` setting: `presence` (default) | `none` (keep everything suppressed while live) | `all`
  (single-player behaviour).
- Remote cheats are refused by default (R19). If the host enables them, the lobby data gets `cheats=1` and clients
  switch to `none` automatically.
- Accepted: a client completing the co-op ending gets END_MAIN and writes its own `profile.cfg game_completed` (R6).

---

## 12. MP2 plan: physics objects (designed, not built)

1. **Host is the only simulator of shared world objects.** Clients' copies of pooled bodies become kinematic puppets:
   `freeze=true, freeze_mode=KINEMATIC`, contact monitor off. They are spawned through the same `ObjectPoolManager.spawn(pool_id)`
   (identical POOL_CONFIG by version gate) and keyed by host entity ids (`entity.spawned{entity_id, pool_id}`,
   PittAPI ids already authority-allocated).
2. **Snapshot stream**: channel 3. Per entity: `eid u32, pos f32x3, rot quantised quat (smallest-three, 32 bit), linvel f16x3`,
   about 30 bytes. Sleeping bodies are sent once and then only on wake. Placed tools (`placed=true`, STATIC) only on placement.
   Priority by distance to each client's avatar plus a recency budget (e.g. 30 KB/s per client). Full per-entity extras
   reuse the `_save_object_pools` schema (`save_manager.gd:657-795`) on spawn and on change of `value`, metas, `is_active`.
3. **Gate host-only logic** with `take_over_path` extensions (all world/pooled scene scripts, so extendable): maw payout
   (`bottom_maw.gd`), combo payout (`hud.gd:670 show_result`), hole growth, workbench crafting, press
   `process_crushed_items`, cannon `fire`, fans/magnet/gravity inverter/tractor/vacuum/orbit `_physics_process`
   force writers, spring pad/bumper, qa_arm `_whack`, portal teleports, piston rider carrying. On clients each
   returns early. The visual-only parts (audio, particles) are replayed from host events.
4. **Interaction ownership**: grabs, carries and throws are client **requests**. The host grants a short-lived ownership
   lease (`eid → peer`, 2 s renewable). The owner simulates the body locally (`main_camera` carry writes `linear_velocity`)
   and streams it; the host accepts it within plausibility bounds and returns authority on release/throw/lease expiry.
   Equip: the real node stays in the host world, hidden. The puppet shows a proxy mesh. Tool actions are commands.
5. **Player-affecting forces** (fan, spring pad, bumper, gravity inverter, tractor, qa_arm `apply_external_*`): the host
   detects contact with a remote player's *server-side ghost collider* and sends `player.impulse` (local scope) to
   the owning client.
6. **Deterministic ids for world fixtures**: the existing static key hashes (`static:/root/World/BottomMaw`,
   `workbench:auto:<k>`, `gate:<id>`). Feed camera ids get host-assigned (`feed_camera.gd _ensure_id` uses time + randi).
7. Pin physics on all peers (`perf.pin_physics 60`, R33) and reset interpolation on teleports.
8. Late join switches from "strip pools" to "include pools" (spawn puppets from host entity list).
9. Bandwidth guard: hard cap on replicated entities per client (interest radius 30 m plus the maw area), and a
   "too many objects" degrade mode that drops the update rate of far bodies to 2 Hz.

---

## 13. Testing strategy

### 13.1 Headless (no game, no Steam): `tests/headless/suites/test_mp_*.gd`

Run by the existing `tools/test-headless.ps1`. The MP mod is copied like other mods. `FakeGameAdapter` holds a fake
GameState (BigInt fake), UnlockManager (milestones with actions), GameProgression (phase + async transition stub with
settle delay), MenuManager, Steamworks (`_granted`, `_probe_ids`, `ACH_*`, `_meets`, `_get_stat`) and InputMap. One
process runs one host session and 1-3 client sessions over `transport_loopback`.

| Id | Test |
|---|---|
| H-NET1 | hello mismatch on each field → reject with the right key; match → welcome |
| H-NET2 | stale `sid`, duplicate `q`, out-of-order unreliable avatar frames dropped |
| H-NET3 | oversized / unknown-kind / non-JSON-safe frames dropped and counted; flood → kick |
| H-CMD1 | client command → host → result; timeout → ERR_UNAVAILABLE; session end fails pending |
| H-CMD2 | a purchase result is never processed before its econ delta (ordering, with jitter) |
| H-CMD3 | `save.isolate`, `perf.pin_physics`, `achievements.suppress` on a client never reach the host |
| H-CMD4 | remote `money.set` refused unless `mp_allow_remote_cheats` |
| H-EC1..4 | money above int64 round-trips as a string; 1000 random add/spend ops on the host leave clients byte-identical; periodic full state heals an injected client corruption; two checksum mismatches → resync, three resyncs → session end |
| H-EC5 | client-local `add_money` is reverted; client-local `spend` produces one `charge` |
| H-BUY1..6 | locked item, missing enabled_level, max level, unaffordable, pool full → host rejects; success replicates level; double-press sends one command; rewire failure → shop unavailable; unrouted local buy reverted with no charge |
| H-PH1..3 | phase begin/settled ordering; client never calls change_phase on its own (hole gate); phase 5 → ENDING, joins refused |
| H-LJ1..4 | join while host STARTING / phase 0 waits; join during TRANSITION deferred until settled; join during ENDING refused; snapshot sha mismatch → retry once, then fail |
| H-SE1..4 | client leave → host roster/avatar removed; host leave → client ABORTING → menu dialog; lobby owner migration = host left; host loss during client LOADING_WORLD deferred to the safe point |
| H-PA1..3 | `open_menu` → tree unpaused next frame, movement locked, camera disabled, held object released; close → restored; ENDING → guard off |
| H-SV1..2 | client isolation on before load and off after leave; quick_save/quick_load events erased and restored, re-erased after `bindings_changed` |
| H-ACH1..3 | join with a progressed snapshot grants nothing; a threshold crossed after join grants once; `none` grants nothing |
| H-AV1..3 | puppets have no groups or physics and are not named PlayerController; interpolation is correct under jitter and loss; time_scale 0 does not freeze interpolation |
| H-UI1..4 | (against a fake MainMenu built from a minimal stub scene) injection idempotent; duplicate has no `_on_play_pressed` connection; Esc pops panels; Sandbox blocked while picking |
| H-LB1..4 | fake LobbyService: members_changed redraw; friend lobby list fills, refreshes and disables mismatches; leave on every exit path; join_requested in world deferred to menu |
| H-SP1 | all existing suites pass with PittMultiplayer installed and no session (extensions inert) |

### 13.2 Two-instance ENet loopback (`tools/test-mp-loopback.ps1`)

1. **T0 gate:** build `dist/devclient/` (loader + MP mod + PittAPITests). Write `decomp/override.cfg`:
   ```ini
   [application]
   config/use_custom_user_dir=true
   config/custom_user_dir_name="PittMP-Dev"
   [autoload]
   PittAPI="*<repo>/dist/devclient/mods/PittAPI/pittapi.gd"
   ```
   Run `<godot_console> --headless --path decomp --import` once (minutes). Then run a probe:
   `--path decomp --pittapi-instance=probe -- --pittmp-print-userdir --quit`. Assert the user dir is
   `%APPDATA%/PittMP-Dev` and **abort the whole script otherwise** (R26). The real `Project P.I.T.T` folder is
   SHA-256-hashed before and after the run (same guard as test-live).
2. Launch instance A (`--pittapi-instance=host -- --pittmp-autotest=host`) and instance B
   (`--pittapi-instance=client -- --pittmp-autotest=client`), both `PITTAPI_GAME_DIR=dist/devclient`, non-console
   Godot exe, windowed small. The `PittAPITests` mp suite drives them:
   - L-1 host: `save.isolate` + `achievements.suppress`, new game, `phase.set 1`, open (ENet, dev lobby);
   - L-2 client: join → snapshot → world loaded → PLAYING within 180 s;
   - L-3 both: money set on the host appears on the client exactly; a client buys an upgrade (rewired button pressed
     programmatically) → host level +1 → client level +1; the client fine path sends `charge`;
   - L-4 avatars visible both ways within 1 s of movement; spawn offset valid (on floor);
   - L-5 host `phase.set 2` → the client plays the transition, both settle at 2; checksum equal;
   - L-6 host opens the pause menu → the client's avatar of the host keeps updating and the host tree is not paused;
   - L-7 client leaves → host roster 1; client rejoins (late join at phase 2) → PLAYING;
   - L-8 host quits → the client shows MP_HOST_LEFT and is at the main menu with isolation off.
   Reports: `user://pittapi-host/test_report.json`, `user://pittapi-client/test_report.json` (in PittMP-Dev).
3. **Live variant** (`-HostLive`): the host is the real game through `steam://rungameid/4026250` (test-live
   machinery, save hash guard, `save.isolate`, `achievements.suppress`), and the client is the decomp instance. This
   proves the release-template behaviour of the host side (R38). Only stages allowed to launch the game run this.

### 13.3 Manual Steam checklist (owner; 2 accounts on 2 PCs, mutual friends, same install)

Before: both run `tools/install.ps1`. Account B notes its achievement state (or runs with `mp_achievements=none`).
Both back up `%APPDATA%\Godot\app_userdata\Project P.I.T.T`.

| # | Step | Expect |
|---|---|---|
| M-1 | Main menu | "MULTIPLAYER" directly under PLAY, same font/size/hover sound; layout not overlapping the title; returns after leaving a game |
| M-2 | A: Multiplayer → Host | Lobby screen, A listed in the centre, Start/Invite/Leave |
| M-3 | B: Multiplayer → Join | A's lobby row "A — 1/10 — Waiting" within about 2 s; Refresh works |
| M-4 | B joins via row | Both lists show 2 players; A's lobby count 2/10 on a third friend's list (optional) |
| M-5 | A: Invite → overlay; B accepts the invite while at the main menu, and again while in a single-player world | Main menu: straight to the lobby. In world: toast, then a join prompt at the next main menu |
| M-6 | B: Steam friends list → "Join Game" on A; B cold-start from that link (`+connect_lobby`) | Lands in A's lobby |
| M-7 | Version mismatch (B disables a client_required mod) | Row disabled with a reason; forced join rejected with a dialog |
| M-8 | A: Start → pick a slot → Load | B sees "Host is loading", then loads in next to A |
| M-9 | Move around, crouch, jump | Smooth puppets with name labels; no collision with the puppet |
| M-10 | B buys an upgrade, a tool and a crate | A's money drops by exactly the price; B's terminal updates; the tool appears in B's world only (MP1); the crate price escalates on both |
| M-11 | A leaves to the main menu (confirm text warns) | B gets MP_HOST_LEFT and is at the main menu; no lobby remains (C's Join list empty) |
| M-12 | Late join: A in game at phase ≥ 2, B joins | B loads straight into the phase with correct money and unlocks; no achievement pop for already-met ones |
| M-13 | Quit both games with Alt-F4 mid-session | No ghost lobby on a third friend's Join list after 10 s |
| M-14 | Phase transition while connected; phase 3 slow-mo | Both see the cinematic; no disconnect; money still equal |
| M-15 | Esc / Steam overlay on both | The other player keeps moving; own player doesn't walk while the menu is open |
| M-16 | After the session: B's save files unchanged (hash), A's slot saved normally | |

---

## 14. Contract additions (`core/contract_mp.gd`, checked at boot and by `tools/contract_check.py`)

Autoload members:

- `MenuManager.{game_paused, current_menu, open_menu, request_auto_pause, play_ui_sound}`
- `UnlockManager.{unlocked_milestones, milestones, _on_stat_changed, _on_phase_changed, _execute_action, _queue_notification, milestone_unlocked, load_save_data, get_save_data}`
- `GameProgression.{current_phase, change_phase, phase_changed, ending_active, elevator_exited, reset_run_state}`
- `SaveManager.{_save_game_state, _save_game_statistics, _save_hole, _save_vertical_gates, _save_cameras, _save_minable_blocks, _save_loop_puzzle, should_load_on_ready, save_locked, active_save_path}`
- `Steamworks.{_granted, _probe_ids, ACH_STAT, ACH_PHASE, ACH_GATE, _meets, _get_stat, evaluate_all, check_consumerism, is_steam_initialized}`
- `GameState.{money, bank, upgrades, tools, toys, products, combos, purchased_once, apply_remote_tier, money_updated, bank_updated, stat_changed}`
- `InputManager.{bindings_changed, apply_bindings}`

Scene-script members:

- `main_menu.{_launch_game, _on_play_pressed, _on_return_save_load, _on_sandbox_pressed, _focus_current_panel, _on_mouse_entered, _temporarily_ignore_input, ignore_input, _pending_new_game, click_sound, hover_sound, SLOT_COLOR_*}`
- `upgradeUI.{_create_upgrade_row, _create_tool_buy_row, _create_toy_buy_row, _acknowledge_row, _spawn_tool_instance, _spawn_toy_instance, _play_sound, _spawn_floating_text, update_ui, update_credits}`
- `hole.{_check_phase_completion, _trigger_ending, target_radius, phase_nutrition_total}`
- `pause_menu.{_on_save_pressed, _on_load_pressed, _on_delete_save_pressed, _on_main_menu_pressed, _return_to_main_menu, _on_quit_pressed}`
- `player_controller.{last_safe_position, is_crouching, is_sprinting}`

Any missing member disables **multiplayer as a whole**: the Multiplayer button shows `MP_ERR_INCOMPATIBLE_BUILD`.
There is no partial MP mode (fail closed).

---

## 15. Concrete file list

New:

```
mods/PittMultiplayer/mod.json                 id, version 0.1.0, api ^1.1, multiplayer client_required, provides ["net"],
                                              extensions [4 files below], game_versions ["1.0.8"]
mods/PittMultiplayer/main.gd
mods/PittMultiplayer/core/{proto,codec,transport,transport_enet,transport_steam,transport_loopback,session,
                           mp_authority,game_adapter,replicator_econ,snapshot,guards,achievements,avatars,contract_mp}.gd
mods/PittMultiplayer/lobby/{lobby_service,lobby_service_steam,lobby_service_local,lobby_service_fake}.gd
mods/PittMultiplayer/ui/{menu_injector,mp_menu_router,screen_hostjoin,screen_lobby,screen_join,row_factory,strings,dialogs}.gd
mods/PittMultiplayer/extensions/{main_menu_ext,upgrade_ui_ext,hole_ext,pause_menu_ext}.gd
mods/PittMultiplayer/README.md                MP1 semantics (private physics), settings, troubleshooting
tests/headless/fakes/fake_game_adapter.gd     (+ fake main menu stub scene for UI tests)
tests/headless/suites/test_mp_{net,commands,econ,buy,phase,latejoin,session,pause,saves,achievements,avatars,ui,lobby,singleplayer}.gd
mods/PittAPITests/suites/suite_mp.gd          (two-instance driver; armed only by the autotest flag)
tools/test-mp-loopback.ps1                    (T0 user-dir gate, import, two instances, report merge, save hash guard)
tools/dev-client.ps1                          (build dist/devclient, write decomp/override.cfg, launch one dev instance)
docs/mp/MP1-MANUAL-TEST.md                    (section 13.3 as a printable checklist)
```

Changed (loader, minimal):

```
loader/core/commands.gd          L1 scope:"local"
loader/core/builtin_commands.gd  mark local-scope builtins
loader/api/net.gd + pittapi.gd   L2 privileged net hook, L3 begin_apply/end_apply, L5 --pittapi-instance
loader/core/game_bridge.gd       L3 reason/origin tagging
loader/core/contract.gd          L4 expose check() to mods
loader/schema/mod.schema.json    "provides"
loader/mod.json                  version 1.1.0 (api ^1.1)
TESTING.md, README.md            MP sections
```

---

## 16. Build order (stop at each gate if a spike fails)

1. Spikes:
   - **T0**: custom user dir via override.cfg in the decomp editor instance;
   - **T1**: SteamMultiplayerPeer works polled manually;
   - **T2**: GodotSteam signatures;
   - **P1**: pause menu usable with the tree unpaused (live);
   - **P2**: pitch reset after leaving phase 3;
   - SteamMultiplayerPeer channel count honours `max_channels=4`.
2. Loader L1-L5 plus their tests (the existing 102 still pass).
3. proto/codec/transport_loopback/session/mp_authority plus H-NET/H-CMD.
4. game_adapter + replicator_econ + guards plus H-EC/H-BUY/H-PH/H-PA/H-SV.
5. snapshot + late join plus H-LJ/H-SE; achievements plus H-ACH.
6. avatars plus H-AV.
7. lobby services + UI plus H-UI/H-LB; Steam implementations.
8. ENet loopback two-instance suite (L-1..L-8), then the live-host variant.
9. Manual checklist M-1..M-16 with the owner.

---

## 17. Explicit non-goals and known limitations of MP1

- Shared physics, objects, machines, tools in hands (MP2).
- Host migration, kicking, chat, an in-game roster UI (toasts only).
- Sandbox sessions.
- Client-side earnings (off by default; see section 0).
- Per-player wallets or upgrade levels (one shared co-op wallet).
- Anti-cheat beyond validation and rate limits (friends-only).

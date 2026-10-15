# Multiplayer MP1: "lean" architecture proposal

Angle: the simplest robust thing. One RPC relay node, JSON envelopes over Godot's high-level
multiplayer (`SteamMultiplayerPeer` for real play, `ENetMultiplayerPeer` for dev/tests), host
authoritative for everything except each player's own movement. Optimized for shipping MP1 fast and
for debuggability: every byte on the wire is a readable JSON envelope that can be logged, replayed and
asserted in tests.

Inputs: `docs/MULTIPLAYER-UI-SPEC.md` (owner requirements, authoritative), `docs/API-DESIGN.md`,
`README.md`, `TESTING.md`, `docs/map/*.md`, the loader code in `loader/`, and the read-only decompile
in `decomp/`. Every game symbol below was re-checked in `decomp/` (file:line given); GodotSteam names
were grepped in the bundled `libgodotsteam.windows.template_release.x86_64.dll`.

---

## 0. Summary of decisions

| Topic | Decision |
|---|---|
| Transport | Godot high-level multiplayer on a **custom `SceneMultiplayer` rooted at our mod node** (`get_tree().set_multiplayer(mp, ^"/root/PittAPI/Mods/PittMultiplayer")`). Peer = `SteamMultiplayerPeer` (`host_with_lobby` / `connect_to_lobby`) or `ENetMultiplayerPeer` (localhost). Nothing else knows which. |
| Wire format | One relay node, 3 RPCs (reliable control, unreliable transforms, reliable bulk). Payload = UTF-8 JSON of `{"t": type, "s": seq, "d": data}`. Snapshot = zstd-compressed JSON in 48 KB chunks. |
| PittAPI seam | `HostAuthority` / `ClientAuthority` (extend `core/authority.gd`), installed through `api.net`. Client commands go to the host, run through `Commands.dispatch_remote(env, sender_peer)`, results come back. |
| Replication model | **State-based, idempotent**: the host broadcasts the economy/progression state (money, bank, phase, hole, unlocks, item tables) whenever it changes (throttled). Clients overwrite. Missed messages, reorders and late join all collapse into "apply latest state". |
| MP1 world model | **Shared progression, parallel physics worlds.** Each peer simulates its own objects (products, tools, machines) exactly as in single player; everything that changes the shared economy is forwarded to the host as a *contribution* (money delta, stat counters, maw nutrition) and comes back in the host state. MP2 replaces this with host-run physics (section 12). Owner decision point (section 15). |
| Purchases | On clients, the terminal's buy buttons are re-wired (upgradeUI.gd extension) to send `PittMultiplayer.buy_*` commands to the host; the host charges and levels up; tools/toys then spawn in the buyer's own world. |
| Snapshot / late join | Reuse the game's own save collectors (`SaveManager._save_game_state()` etc., save_manager.gd:276-298) to build a save-format dictionary on the host, ship it, write it on the client as an isolated save file under `user://pittapi/mods/PittMultiplayer/`, and let the **game's own load path** (`should_load_on_ready` + `_launch_game`) load it. Session start and late join are the same code path. |
| Pause | MP: the tree is never paused. A pause guard unpauses each frame while menus stay open; local movement and camera input are blocked while a menu is up. |
| Saves | Host saves normally to its slot. Clients never save: `save.isolate` on the session file, Save/Load/Delete hidden, F5/F9 blocked. The session file is deleted at the end. |
| Achievements | Per peer, local (the game's own hooks fire on each machine). Option to suppress the burst on late join. Host cheats suppress achievements for everyone. |
| Lobby UI | `LobbyService` (only file that calls `Steam.*` lobby APIs) -> signals -> dumb panels injected into `main_menu.tscn`'s `Background` as siblings of `MenuButtons`/`MenuLoad`, toggled the same way. A `DevLobbyService` (ENet) and `FakeLobbyService` (headless) implement the same interface. |
| Loader changes | Small: a `local` command scope, a net-provider install hook with session signals, peer names, contract entries for every game member MP uses. No core netcode. |

---

## 1. Facts this proposal relies on (re-verified)

| # | Fact | Evidence |
|---|---|---|
| L1 | `project.godot [steam] multiplayer_peer/max_channels=4`, `embed_callbacks=false`, `initialize_on_startup=true`. Steam callbacks are pumped only by `Steamworks._process` (`Steam.run_callbacks()`, PROCESS_MODE_ALWAYS). | decomp/project.godot:250-255, steamworks.gd:439 |
| L2 | The bundled DLL contains `SteamMultiplayerPeer`, `create_host`, `create_client`, `host_with_lobby`, `connect_to_lobby`, `get_steam_id_for_peer_id`, `get_peer_id_for_steam_id`, `server_relay`, `no_nagle`, `no_delay`, `debug_level`, `createLobby`, `joinLobby`, `leaveLobby`, `setLobbyData`, `getLobbyData`, `setLobbyJoinable`, `requestLobbyData`, `getLobbyOwner`, `getNumLobbyMembers`, `getLobbyMemberByIndex`, `getFriendCount`, `getFriendByIndex`, `getFriendGamePlayed`, `getFriendPersonaName`, `getPersonaName`, `getSteamID`, `activateGameOverlayInviteDialog`, `setRichPresence`, `getLaunchCommandLine`, `getPlayerAvatar`, `allowP2PPacketRelay`; signals `lobby_created`, `lobby_joined`, `lobby_chat_update`, `lobby_data_update`, `persona_state_change`, `join_requested`, `avatar_loaded`, `peer_connected`. Version string found: 4.19.1. Exact argument lists are not visible in the DLL: code calls through `has_method` and a small adapter (section 2.3). | `grep -a` on the DLL |
| L3 | The game has zero networking code and never touches `SceneTree.multiplayer`. | grep `multiplayer` in decomp/scripts |
| L4 | `main_menu.gd` is loaded only after our autoload (splash threads it). Scene connections: `Play.pressed -> _on_play_pressed`, `*.mouse_entered -> _on_mouse_entered` (main_menu.tscn:1612-1631). Panels are sibling `VBoxContainer`s under `Background` with identical layout (anchors_preset 4, offset_left 49, offset_top -76, offset_right 785, offset_bottom 384; main_menu.tscn:445-500). `Play` has `theme_override_fonts/font` + `font_size 104`; `MenuLoad` buttons use size 52. `Background.theme = main_menu.tres`. | main_menu.tscn |
| L5 | `main_menu._unhandled_input` handles `ui_cancel` for its three panels and **always** calls `set_input_as_handled()` (main_menu.gd:126-139). `_focus_current_panel` only knows its three panels (:73). `MenuManager.register_scaled_menu($Background)` scales fonts once at `_ready`; `MenuManager.apply_menu_scales()` re-applies idempotently using a `base_font_size` meta (menu_manager.gd:313-337). | main_menu.gd, menu_manager.gd |
| L6 | `_launch_game(scene_path)` (main_menu.gd:678) is the single entry to the world for Load / New / Sandbox. `_on_load_pressed` (:219) = `set_active_slot`, `reset_run_state`, phase preset from `peek_saved_phase`, `should_load_on_ready = true`, `_launch_game`. | main_menu.gd |
| L7 | `SaveManager._save_game_impl` builds `save_data` from collectors: `_save_game_state`, `UnlockManager.get_save_data`, `_save_game_statistics`, `_save_object_pools`, `_save_player_position`, `GameProgression.current_phase`, `demo_end_triggered`, `_save_cameras`, `_save_hole`, `_save_vertical_gates`, `_is_press_in_scene`, `_is_terminal_in_scene`, `_is_bowling_set_in_scene`, `WorkbenchSpawning.get_save_data`, music, `_save_minable_blocks`, `_save_pickaxe`, `_save_loop_puzzle`, `UpgradeUI.get_seen_save_data` (save_manager.gd:276-298). The collectors don't write files; `save_game` pauses the tree only around them. | save_manager.gd |
| L8 | `load_game()` reads `active_save_path` (encrypted first, plaintext fallback) and `save_exists()` is just `slot_has_data(active_save_path)` = file exists (save_manager.gd:1309, 1792). `set_active_save_path` accepts any path (:1773). `_write_slot_index` is a no-op for non-slot paths (F11). | save_manager.gd |
| L9 | `MenuManager.open_menu` sets `get_tree().paused = true` for every menu but MainMenu (menu_manager.gd:107-120); `player_controller._physics_process` and `main_camera._physics_process/_input` early-return on `get_tree().paused` (player_controller.gd:212, main_camera.gd:180/219); mouse look is skipped while `MenuManager.current_menu != null` (player_controller.gd:195). | menu_manager.gd, player_controller.gd, main_camera.gd |
| L10 | Purchases: upgrades/products/combos `button.pressed` lambda -> `GameState.buy` (upgradeUI.gd:1185-1202); tools: `can_afford`, `spend`, `purchased_once`, `Steamworks.check_consumerism`, `_spawn_tool_instance(tool, level)` (:1358-1362); toys: same plus crate price escalation of `toys[k].buy_prices[0]` (:1538-1555). Each `_create_*_row` **returns the row** and the button is `row.get_meta("button")`. | upgradeUI.gd |
| L11 | Maw: `GameState.add_money(base_value, product_type)` (bottom_maw.gd:205), `products_consumed[type] += 1`, `total_products_consumed += 1`, two `stat_changed` emits, then `product_consumed(type, nutrition, body_id)` (:219). Hole is connected to it (hole.gd:77), accumulates `phase_nutrition_total` and calls `_check_phase_completion` -> `change_phase(2..4)` / `_trigger_ending` (hole.gd:167-252). Hole state = `get_save_data()` / `apply_saved_state()` (:361-395). | bottom_maw.gd, hole.gd |
| L12 | Unlocks: `UnlockManager._trigger_milestone(id, m)` = append + `_execute_action` + `milestone_unlocked.emit` + notification (unlock_manager.gd:1726). `load_save_data` replays `_execute_action` (:2189). | unlock_manager.gd |
| L13 | Combo payout is `GameState.add_bonus(total_bonus)` inside `hud.show_result` (hud.gd:670). | hud.gd |
| L14 | `get_first_node_in_group("player")`: exactly 18 call sites in 11 files: save_manager (3), game_progression (3), security_room (3), golf_club (2), cannon, elevator, fall_sequence, gravity_inverter, pause_menu, test_black_hole, tractor_beam (1 each). | grep |
| L15 | Rich presence: the game sets only keys `money` and `steam_display` (steamworks.gd:255-256) and clears all keys only in `clear_presence()`. A `connect` key we set survives its 0.3 s pushes. | steamworks.gd |
| L16 | PittAPI: `Commands.dispatch_remote(envelope, sender_peer)` re-runs every gate and takes origin from the transport (commands.gd:205); `authority_only` is enforced inside `_dispatch` (:225); `PittAPI._set_authority(a)` exists (pittapi.gd:376); `api.data_dir()` = `user://pittapi/mods/<id>/` (mod_context.gd:78); `save.isolate` accepts any `.save` under `user://pittapi/` that is not slot-like (builtin_commands.gd:454-471) and re-asserts lock/path every frame. Mods run under `/root/PittAPI/Mods/<id>` with `PROCESS_MODE_PAUSABLE` on the parent (pittapi.gd:203). | loader |

---

## 2. Transport and its abstraction

### 2.1 Layers

```
Session (state machine, roster, handshake)        net/session.gd
  └─ Relay  (the ONE RPC node, envelopes in/out)  net/relay.gd
       └─ SceneMultiplayer (custom, rooted at /root/PittAPI/Mods/PittMultiplayer)
            └─ MultiplayerPeer  <- made by a Transport factory
                 SteamTransport  -> SteamMultiplayerPeer   (real play)
                 EnetTransport   -> ENetMultiplayerPeer    (dev, tests; localhost)
                 LoopbackTransport -> in-process pair, no engine peer (headless unit tests)
```

`Transport` is a tiny factory interface (net/transport.gd):

```gdscript
func kind() -> String                       # "steam" | "enet" | "loopback"
func host(opts: Dictionary) -> Error        # opts: {lobby_id?, port?, max_peers}
func join(target: Dictionary) -> Error      # {lobby_id} | {address, port}
func get_peer() -> MultiplayerPeer          # null for loopback
func peer_display_name(peer_id: int) -> String
func peer_platform_id(peer_id: int) -> String   # steam id as string, "enet:<id>" in dev
func close() -> void
```

The Relay only ever sees `MultiplayerPeer` signals (`peer_connected`, `peer_disconnected`) and
`multiplayer.get_remote_sender_id()`. So Steam vs ENet is a one-line difference in `Session`.

### 2.2 Why a custom SceneMultiplayer rooted at our node

`get_tree().set_multiplayer(SceneMultiplayer.new(), ^"/root/PittAPI/Mods/PittMultiplayer")` gives the MP
mod its own `MultiplayerAPI`:
- RPC paths are relative to our node, identical on every peer because mods load identically.
- The game's nodes can never receive or send RPCs by accident; the default tree multiplayer stays
  `OfflineMultiplayerPeer`.
- `SceneMultiplayer.auth_callback` is available for the version handshake if we want it later (MP1 does
  the handshake as the first envelope; simpler to debug).
- SceneTree polls custom multiplayers every frame regardless of pause (spike S-MP7 confirms with Steam).

The mod's net nodes set `process_mode = PROCESS_MODE_ALWAYS` (their parent `Mods` is PAUSABLE).

### 2.3 SteamTransport

- Host: after `LobbyService` reports `lobby_entered(lobby_id, is_owner=true)`:
  `peer = SteamMultiplayerPeer.new(); peer.host_with_lobby(lobby_id)`.
  Fallback if `host_with_lobby` is missing: `peer.create_host(0)`.
- Client: after `lobby_entered(lobby_id, is_owner=false)`: `peer.connect_to_lobby(lobby_id)`.
  Fallback: `peer.create_client(Steam.getLobbyOwner(lobby_id), 0)`.
- Before the first peer: `Steam.initRelayNetworkAccess()` if `Steam.has_method` it (cheap, idempotent).
- `server_relay = true` when the property exists (works behind NAT through Valve's relays).
- `peer_display_name(id)` = `Steam.getFriendPersonaName(peer.get_steam_id_for_peer_id(id))`.
- Every call is wrapped in `SteamAdapter` (net/steam_adapter.gd): one place with `has_method` checks,
  argument shapes and logging; spike S-MP2 pins the exact signatures against GodotSteam 4.x docs and
  the DLL.
- Same Steam account on two processes cannot P2P to itself. Steam is therefore only tested manually
  with two accounts (section 13.4).

### 2.4 EnetTransport (dev/test)

- Host `ENetMultiplayerPeer.create_server(port, max_peers - 1, 4)`; client
  `create_client(address, port, 4)`. Defaults `127.0.0.1:24810` from `api.config`.
- Enabled by config `transport = "enet"` (default `"steam"`), or by the autotest flag.
- Optional fault injection for debugging interpolation and reliability: `sim_latency_ms`,
  `sim_jitter_ms`, `sim_loss_pct` applied in the Relay (delay queue / drop on the unreliable channel).
- Spike S-MP1 confirms `ClassDB.class_exists("ENetMultiplayerPeer")` in the shipped release template
  (ENet is in the default export templates; if missing, dev/tests use the editor instance on both
  sides).

### 2.5 Channels

| Channel | RPC mode | Used for |
|---|---|---|
| 0 | `reliable` | handshake, session control, command envelopes and results, contributions, econ state |
| 1 | `unreliable_ordered` | player transforms (20 Hz) |
| 2 | `reliable` | snapshot chunks (bulk; separate channel so a 1 MB snapshot never blocks control traffic) |

ENet is created with 4 channels; Steam already has `max_channels=4` (L1). Channel 3 is reserved for MP2
entity snapshots.

---

## 3. Envelope format

### 3.1 Relay node (net/relay.gd)

```gdscript
extends Node
signal received(sender: int, msg: Dictionary)

@rpc("any_peer", "call_remote", "reliable", 0)
func _r(bytes: PackedByteArray) -> void: _in(bytes)
@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _u(bytes: PackedByteArray) -> void: _in(bytes)
@rpc("any_peer", "call_remote", "reliable", 2)
func _b(bytes: PackedByteArray) -> void: _in(bytes)

func send(to: int, type: String, data: Dictionary, chan := 0) -> void   # to = 0 broadcast, 1 host
func _in(bytes): var sender := multiplayer.get_remote_sender_id(); decode; validate; received.emit(sender, msg)
```

- Encoding: `JSON.stringify(msg).to_utf8_buffer()`. Payloads are JSON-safe by construction (they come
  from `PittSerial.to_json_safe`). Decoding failures and unknown types are counted, logged and dropped.
- Size cap per message 256 KB (anything larger must be chunked); per-sender rate cap on channel 0.
- Every message is logged at DEBUG (`[mp] -> 3 cmd 212B`), and the last 200 are kept in a ring buffer
  dumped by the `mp dump` console command. That is the main debugging tool.

### 3.2 Message

```json
{"v": 1, "t": "<type>", "s": 1234, "d": { ... }}
```

`s` is a per-sender sequence number (diagnostics, dedupe of contributions). `v` is the MP protocol
version (also in the handshake).

| `t` | Direction | Channel | `d` |
|---|---|---|---|
| `hello` | C->H | 0 | `{proto, pitt_version, pittapi_version, mp_version, mods:["id@ver"] (client_required only), name, platform_id}` |
| `welcome` | H->C | 0 | `{peer_id, slot, roster:[{peer, slot, name, color}], session:{state, phase, sandbox}}` |
| `bye` | both | 0 | `{reason: "version_mismatch"\|"host_left"\|"kicked"\|"full"\|"ending"\|"leave", detail}` |
| `roster` | H->C | 0 | `{roster:[...]}` (on every join/leave) |
| `sess` | H->C | 0 | `{op: "starting"\|"in_world"\|"ending", scene?}` |
| `snap_begin` / `snap_chunk` / `snap_end` | H->C | 2 | `{id, bytes, chunks, sha256}` / `{id, i, b64}` / `{id}` (zstd-compressed JSON of the save dictionary) |
| `ready` | C->H | 0 | `{snap_id}`: client's world is up; host starts econ + transforms for it |
| `cmd` | C->H | 0 | a PittAPI command envelope (`{v,id,name,args,mod,origin,t}`) |
| `res` | H->C | 0 | `{id, result:{ok, value, error, code}}` |
| `econ` | H->C | 0 | economy/progression state (section 6.2), full or partial, with `ack` |
| `xf` | both | 1 | `{p:[x,y,z], y:yaw, pi:pitch, v:[x,y,z], f:flags, t:ms}` (client->host; host fans out with `peer`) |
| `evt` | both | 0 | `{name: "mod.<id>.*", payload}` relayed mod events (opt-in API, section 4.4) |
| `toast` | H->C | 0 | `{key, args}` host-originated notices ("X joined") |

Base64 for chunks keeps the "everything is JSON" rule; the 33 % overhead on a compressed snapshot is
irrelevant at join time. If profiling disagrees, `_b` can take raw bytes later without touching
anything else.

---

## 4. Plugging into PittAPI (Command / Authority / Entities / Events)

### 4.1 Authorities

```
core/authority.gd (base = LocalAuthority)
  ├─ mods/PittMultiplayer/net/host_authority.gd    is_authority=true,  is_multiplayer=true, peers=roster
  └─ mods/PittMultiplayer/net/client_authority.gd  is_authority=false, is_multiplayer=true, local_peer_id=multiplayer id
```

- **Host**: `submit()` is the base behaviour (dispatch now). Incoming `cmd` from peer P:
  `var r = commands.dispatch_remote(env, P)` (P from `get_remote_sender_id()`, never from the envelope),
  reply `res {id, result: r}`. The host also emits `command.executed` for remote commands (one line in
  the host's handler) so audit/log tooling sees them.
- **Client**: `submit(env)`:
  - if the command's scope is `local` (new loader flag, section 4.5): `commands.dispatch_envelope(env)`
    then `complete()` immediately;
  - else send `cmd`, keep `env` in `_pending[id]`, complete when `res` arrives; 10 s timeout ->
    `ERR_UNAVAILABLE "host did not answer"`; on disconnect all pending fail with `ERR_UNAVAILABLE`.
  This is exactly what README "Multiplayer readiness" promised; mods that honour `result.done` /
  `completed` work unchanged.
- Installed on session start through `api.net.install_provider(authority)` (loader addition), removed on
  session end (core restores a fresh `LocalAuthority`). Core emits `net.authority_changed` (exists) plus
  the existing `PittNet.session_started/session_ended/peers_changed` signals (currently never emitted).

### 4.2 Client-side state application is a local command

The client applies host state through internal commands registered by the MP mod with
`{"local": true, "internal": true, "authority_only": false}`:

- `PittMultiplayer.apply_econ` (money, bank, items, unlocks, hole, phase)
- `PittMultiplayer.apply_snapshot_prepare` (write session file, set paths, launch)

`internal` means they cannot be called remotely and do not spam `command.executed`; `local` means the
ClientAuthority runs them on this machine with `ctx.is_replay = true`. This keeps the PittAPI rule
"every state change is a command" without a second mutation path, and the MP mod's own apply code is
testable through `commands.execute` in headless tests.

### 4.3 Entities

- Players: `entities.register_player(node, peer_id)` already reserves ids 1..999 per peer. Local player
  stays slot 1 on its own machine; remote puppets get `register_player(puppet, peer)` on each machine.
  Needed loader addition: `unregister_player(peer)` and a provider-only privileged entry (mods have a
  restricted view).
- Players' entity ids are therefore **per-machine**; across the wire players are identified by
  **peer id** (and slot from `welcome`), never by entity id. Documented in `api.net.get_players()`.
- MP1 replicates no pooled/static entities (parallel worlds). Entity id allocation is untouched: on a
  client `can_allocate()` is false for authority-allocated ids, so `entity.spawn` from a client mod goes
  to the host and spawns in the **host's** world in MP1 (correct for MP2, documented as an MP1 quirk).

### 4.4 Events

- No generic event replication in MP1. Because clients apply host state by writing the game's own
  fields **and emitting the game's own signals** (`money_updated`, `bank_updated`, `phase_changed` via
  `change_phase`, `milestone_unlocked` via `_trigger_milestone`), the GameBridge on each client already
  produces `money.changed`, `phase.changed`, `unlock.milestone`, `item.level_changed` locally. Mods on
  clients just work.
- Mod-to-mod messaging: `get_mod_api("PittMultiplayer").broadcast_event("mod.MyMod.x", payload)` sends an
  `evt`; receivers re-emit it through the core bus with `origin = sender peer` (needs the existing
  `emit_internal` plus an `origin` override parameter; tiny loader addition).

### 4.5 Loader additions (all small, all justified)

| File | Change | Why |
|---|---|---|
| `core/commands.gd` | New opt `local: bool` (default false). `_dispatch`: `local` commands skip the `authority_only` check and are refused when `remote`. `describe()` exposes `internal` and `local`. | Client authority must know which commands run on the issuing machine; machine-local builtins must never run on the host. |
| `core/builtin_commands.gd` | Mark `achievements.suppress`, `perf.pin_physics`, `save.isolate`, `presence.suppress`, `player.teleport`, `player.impulse` as `local: true`. | They act on *this* process (its Steam, its saves, its player). Without it a client test run would isolate the **host's** saves. |
| `api/net.gd` + `pittapi.gd` | `install_provider(authority)` / `uninstall_provider()` (only for a mod whose manifest has `"net_provider": true`, one at a time); emits `session_started/ended`, forwards `peers_changed`; `get_peer_name(peer)`, `get_players() -> [{peer, slot, name, entity_id}]`. `_set_authority(null)` restores LocalAuthority. | Formalises the documented `_set_authority` seam instead of mods poking `/root/PittAPI`. |
| `core/entities.gd` | `unregister_player(peer)`; provider-only `register_remote_player(node, peer)`. | Puppets get stable player ids, cleaned on leave. |
| `core/events.gd` | `emit_internal(..., origin := -1)` override. | Relayed `evt` keeps the real origin. |
| `core/contract.gd` | Feature group `mp` listing every game member in section 14.2. | `contract_check.py` flags game updates that break MP; MP refuses to start a session if `mp` is disabled (button shows disabled with a reason). |
| `schema/mod.schema.json` | `net_provider: boolean`. | Manifest-declared privilege. |
| `ui/toast_layer.gd` | none | Already works on the main menu. |

No menu-injection API in core for MP1: the main-menu work is one script extension owned by the MP mod
(section 7). If a second mod ever needs a menu button, generalise it then.

---

## 5. Session lifecycle and scene coordination

### 5.1 State machine (net/session.gd)

```
IDLE ──host()──> LOBBY_HOST ──Start──> HOST_PICKING (game's save panel) ──_launch_game──> HOST_LOADING ──world.ready+save.applied──> IN_WORLD
IDLE ──join()──> LOBBY_CLIENT ──snap received──> CLIENT_LOADING ──world.ready──> IN_WORLD (sends `ready`)
any ──leave/bye/disconnect──> CLOSING ──> IDLE (lobby left, peer closed, authority uninstalled, isolation off)
IN_WORLD ──phase 5 / secret ending──> ENDING ──world exits──> IDLE (reason "ending", no error dialog)
```

### 5.2 Host Start

1. Lobby panel: host presses **Start**. The router shows the game's own `MenuLoad` panel (slot list,
   Continue / New Game / Sandbox / Back) in "MP host" mode, with a gold title line "Choose a save to host"
   on top. Reusing the real panel means slot logic, corrupt-save quarantine, sandbox rules and
   controller focus are the game's code. (Owner decision: alternatively Start could reuse the last slot
   with no picker; section 15.)
2. Back (`_on_return_save_load`) in MP host mode returns to the Lobby panel instead of `MenuButtons`
   (main_menu extension).
3. Load/New/Sandbox end in `_launch_game(scene_path)`. The extension calls `super` and notifies the
   mod: Session -> `HOST_LOADING`, lobby data `state = "starting"`, broadcast `sess {op:"starting"}`.
   Clients' lobby panels show "Host is loading...".
4. Host `world.ready` and, for loaded saves, `save.applied` (pools respawned): build the snapshot
   (section 9), send it to every handshaken client, lobby data `state = "in_game"`. From here the lobby
   stays listed for late join.
5. Host starts the econ broadcaster and transform fan-out. Puppets appear as clients report `ready`.

### 5.3 Client load (start and late join are the same)

On `snap_end` (sha256 verified):
1. `apply_snapshot_prepare` (local command):
   - write the decompressed save JSON **encrypted** with the game's password read at runtime
     (`FileAccess.open_encrypted_with_pass(path, WRITE, SaveManager.SAVE_PASSWORD)`; the constant is read
     from the live autoload, never copied into the repo) to
     `user://pittapi/mods/PittMultiplayer/session.save` (`api.data_dir()`). Encrypted, so the game's
     reader takes its normal path and logs no "unrecognized file" engine error;
   - `save.isolate {enabled:true, path:<session.save>}` (re-asserts `save_locked`, `autosave_enabled =
     false` and the path every frame; it survives `elevator.gd:57` resetting `save_locked`);
   - `GameState.sandbox_mode = snap.sandbox`;
   - exactly what `_on_load_pressed` does minus `set_active_slot`: `GameProgression.reset_run_state()`,
     `current_phase = peek_saved_phase()` if > 0, `SaveManager.should_load_on_ready = true`,
     `menu._pending_new_game = false`, `menu._launch_game("res://scenes/world.tscn")` on the
     `MainMenu`-group node.
2. The game loads the world and `SaveManager.load_game()` applies money, items, unlocks (replayed by
   `load_save_data`), phase, hole, gates, workbenches, pools (the host's objects at that instant become
   the client's starting objects) and the player position (the client spawns where the host stood).
3. On `world.ready` + `save.applied` the client sends `ready`; the host sends a full `econ` (so anything
   that changed during loading is applied) and starts sending transforms.
4. Phase 0 special case (spike S-MP3): a fresh new game is still in the elevator at phase 0, which the
   game never saves. If loading a phase-0 snapshot misbehaves, the client instead starts a local new
   game (`_pending_new_game = true`, same sandbox flag) and receives state through `econ` only. Either
   way it is one branch in `apply_snapshot_prepare`.

### 5.4 Leaving and disconnects

| Who / how | Host side | Client side |
|---|---|---|
| Client presses Leave (lobby) or pause > Main Menu, or quits | `peer_disconnected` -> remove from roster, free puppet, `unregister_player`, lobby `members` updated, toast "X left" | `world.exited`/menu -> Session `CLOSING`: `leaveLobby`, close peer, uninstall authority, `save.isolate {enabled:false}`, delete session.save |
| Host presses Leave, pause > Main Menu, or Quit | broadcast `bye {reason:"host_left"}`, flush 250 ms (one-shot timer; on quit via `NOTIFICATION_WM_CLOSE_REQUEST` best effort), `leaveLobby`, close peer | on `bye` or `server_disconnected`: if in world, call the game's own `PauseMenu._return_to_main_menu()` (pause_menu.gd:104, the full singleton reset) ; then on the main menu show the game's `ConfirmDialog` "MP_HOST_LEFT_TITLE / MP_HOST_LEFT_BODY" |
| Network drop (no `bye`) | as client leave | as host left, body "MP_CONNECTION_LOST" |
| Version mismatch | `bye {reason:"version_mismatch", detail}` right after `hello` | dialog with the detail; Join screen already shows such lobbies disabled when lobby data says so |
| Lobby full | Steam refuses join (`lobby_joined` response != success) | dialog "MP_LOBBY_FULL" |

`leaveLobby` is called on every path back to the main menu (spec: no ghost lobbies), plus in the mod's
`_exit_tree` / `NOTIFICATION_WM_CLOSE_REQUEST`.

### 5.5 In-session restrictions (both roles)

- In-game **Load** (pause menu Load, F9 `quick_load` -> `begin_load_reload`, save_manager.gd:163) is
  blocked for host and clients: it reloads the scene and would desync everyone. Pause-menu Load/Delete are
  hidden by the pause_menu extension; F5/F9 are swallowed by the player_controller extension (`_input`
  override that consumes `quick_save`/`quick_load` on clients and `quick_load` on the host, with
  `hud.show_restrict_message(tr("MP_NOT_IN_MULTIPLAYER"))`).
- Host Save / autosave / checkpoints are untouched.

### 5.6 Scene changes inside a session

- PHASE_5 (main ending) changes scene on each machine locally (`change_phase(5)` -> black hole scene).
  The host's phase goes to 5; each client's econ apply calls `change_phase(5)` and runs its own ending.
  Session state `ENDING`; when a peer's world exits, it leaves quietly (no error dialog).
- Secret ending (security_room.gd) is triggered by the local player only; it runs locally and that
  peer's session ends when its world exits. The others continue.
- Phase 2-4 cinematics run locally on each machine when the phase arrives (they also spawn local debris,
  play music, and on clients their `checkpoint_save` is blocked by the isolation lock).

---

## 6. Economy and progression replication (host-authoritative)

### 6.1 What is shared vs per-peer in MP1

| Shared (host state, replicated) | Per-peer (parallel worlds, local) |
|---|---|
| `money`, `bank`, `total_money_gained/spent` (host only), phase, hole `target_radius` + `phase_nutrition_total`, `unlocked_milestones`, item tables (`level`, `enabled`, `enabled_levels` via actions, toys `buy_prices`), `purchased_once`, `sandbox_mode`, stat counters used by milestones (`products_consumed.*`, `total_products_consumed`, `products_crafted.*`, `products_autocrafted.*`) | all physics objects, workbench timers, machines, combos, buffs, remote channels, panel rack, gates, pickaxe/UV/torch finds after join, mining, gambling terminal UI |

### 6.2 Host -> client: `econ` state

The host keeps a dirty set fed by core events (`money.changed`, `bank.changed`, `phase.changed`,
`unlock.milestone`, `item.level_changed`, plus a 1 Hz hole poll and a 1 Hz safety full send). Every
100 ms, if dirty, it sends one `econ`:

```json
{"money": "123456789012345678901", "bank": 12.5, "phase": 2,
 "hole": {"target_radius": 3.4, "phase_nutrition_total": 18000.0},
 "unlocked": ["m_a", "m_b"],                       // full list on full sends, additions otherwise
 "items": {"upgrades": {"sprint": {"level": 1, "enabled": true}}, "toys": {"bumper": {"buy_prices": [500]}} },
 "purchased_once": {"broom": true},
 "full": false, "ack": {"7": 42}}                  // per client: last contribution seq applied
```

`money` alone changes constantly (every feed), so a money-only `econ` is ~60 bytes; item tables are
sent only when dirty (and in full every 1 s for self-healing, ~3 KB, and on `ready`).

### 6.3 Client apply (`PittMultiplayer.apply_econ`, local command, `ctx.is_replay`)

Idempotent; order matters:
1. **unlocked**: for each id not yet in `UnlockManager.unlocked_milestones`, call
   `UnlockManager._trigger_milestone(id, milestones[id])` (L12): runs the actions, emits
   `milestone_unlocked` (UpgradeUI badges refresh) and shows the game's own unlock notification on the
   client too. Unknown ids are skipped (mod milestones of a host-only mod).
2. **items**: write `level`/`enabled` (and toys `buy_prices`, `purchased_once`) into `GameState` tables.
   Side effects that `GameState.buy` would have run locally are reproduced for the parallel world:
   `remote_tier` level change -> `GameState.apply_remote_tier()`; `products/*/auto_machine` level change
   -> `WorkbenchSpawning.auto_machine_purchased(key, old_level)` (so the auto workbench appears in the
   client's world too); then `UpgradeUI.update_ui()` if present; `bridge.mark_items_dirty()`.
3. **money/bank**: `GameState.money = BigInt.from_string(host_money + unacked_local_delta)`;
   `money_updated.emit(money)` (load-path semantics, save_manager.gd:824, no stat side effects);
   `bank = x; bank_updated.emit(x)`.
4. **hole**: write `phase_nutrition_total` and `target_radius` on the `saveable_hole` node (its
   `_process` animates `current_radius` towards the target).
5. **phase**: if host phase > local `current_phase` -> `GameProgression.change_phase(host_phase)` (runs the
   cinematic locally; phase 5 runs the ending). Never moves backwards.

While applying, a re-entrancy flag (`_applying`) tells the contribution forwarder to ignore the
resulting local events.

### 6.4 Client -> host: contributions (MP1 interim)

Clients keep running the game's own maw, combos, crates, statue, terminal and fines in their own world.
Their effect on shared state is forwarded instead of discarded:

- The forwarder listens to core events on the client while `!_applying`:
  `money.changed` (`delta`, `sign`, `reason` in add|bonus|spend|direct), `bank.changed`,
  `stat.changed` for the whitelisted counters (it keeps the previous value per stat, so the 10 Hz
  throttle never loses increments), and BottomMaw `product_consumed(type, nutrition, body_id)` for hole
  nutrition (connected on `world.ready`).
- Every 100 ms it batches them into one command (goes to the host through the ClientAuthority):

```
PittMultiplayer.contribute {seq, money:[{d:"500", r:"add", p:"duck"}, {d:"1000", r:"spend"}],
                            bank: -20.0, stats: {"products_consumed.duck": 3, "total_products_consumed": 3},
                            nutrition: [{p:"duck", n:500}]}
```

- Host handler (authority_only): `add` -> `GameState.add_money(int, p)` (counts toward
  `total_money_gained`, milestones, host achievements), `bonus` -> `add_bonus`, `spend` -> `spend`
  (floors at 0, same as single player), BigInt-sized amounts through the `money.add` big path; stat
  counters `GameState.<dict>[key] += n` then `stat_changed.emit(path, value)` (UnlockManager evaluates
  on the host); nutrition -> `hole._on_product_consumed(p, n, -1)` on the host's hole, which is the only
  hole allowed to call `_check_phase_completion` (hole.gd extension: no-op on clients).
- Dedupe by `(peer, seq)`; sanity caps (no negative/garbage digits, at most N entries per batch, money
  per batch bounded by a generous multiple of the host's own rate) and a log line on anything clamped.
  Trust model: friends-only lobby, cooperative game; MP2 removes client contributions entirely.
- Unacked prediction: the client keeps contributions not yet covered by `econ.ack[my_peer]` and adds
  them on top of the host's money in step 6.3.3, so the counter never jumps back while a delta is in
  flight.

Why this instead of "clients can't earn in MP1": it makes MP1 actually playable together (shared
wallet, shared hole, shared phase, shared unlocks) with very little code, and every piece of it is
replaced, not rewritten, in MP2.

### 6.5 Purchases (routed as commands)

`extensions/upgrade_ui_ext.gd` (upgradeUI.gd is a world scene script, extendable; keep the `is_mirror`
early return, upgradeUI.gd:290):

```gdscript
func _create_upgrade_row(category, key, subkey := "") -> HBoxContainer:
    var row = super(category, key, subkey)
    _mp_rewire(row, "upgrade")      # no-op unless MP client
    return row
# same for _create_tool_buy_row(tool_name, level, ...) and _create_toy_buy_row(toy_name)
```

`_mp_rewire` (forwarding to the mod) on a client: take `row.get_meta("button")`, remember the original
`pressed` callables (`button.pressed.get_connections()`), disconnect them, connect our handler:

- recall mode (`row.get_meta("recall_mode")`): call the original callable (recall is local to the
  parallel world);
- otherwise `execute_async("PittMultiplayer.buy", {kind, category, key, subkey, tool, level, toy})` -> host;
- on the reply, play the same feedback the game uses (`_play_sound(upgrade_sound/buy_sound/error_sound)`,
  `_create_success_effect`, `_flash_label`, `_spawn_floating_text(button, tr("UI_PURCHASED"/
  "UI_INSUFFICIENT_FUNDS"))`); for tools/toys the client then calls its own
  `_spawn_tool_instance(tool, level)` / `_spawn_toy_instance(toy)` (the item appears in the buyer's
  world) and `Steamworks.check_consumerism()`.

Host handler `PittMultiplayer.buy` (authority_only, schema-validated):
- upgrades/products/combos -> the existing `item.buy` logic (affordability first; the auto-machine bug
  workaround, game_state.gd:1083);
- tools: `can_afford(buy_prices[level])`, `spend`, `purchased_once[tool] = true`,
  `Steamworks.check_consumerism()` (no spawn on the host in MP1);
- toys: same plus the crate price escalation table from upgradeUI.gd:1546 (re-implemented as data in the
  mod, not copied code);
- the change reaches every client through `econ` (items, `purchased_once`, toys `buy_prices`, money).

The host's own terminal is untouched (it already runs on the authority).

### 6.6 Combo payout

MP1: combos are per peer (each peer's own maw feeds its own ComboSystem). A client's
`hud.show_result -> add_bonus` (hud.gd:670) is forwarded as a `bonus` contribution, so there is no double
payout: the host never sees the client's `combo_ended`. MP2 (host maw): the hud.gd extension gates the
`add_bonus` on clients and the combo becomes host-only.

---

## 7. Lobby service and UI

### 7.1 LobbyService (lobby/lobby_service.gd, one node, no UI)

Interface (base class, also the fake's contract):

```gdscript
signal lobby_entered(info: Dictionary)          # LobbyInfo
signal lobby_left(reason: String)
signal members_changed(members: Array)          # [MemberInfo]
signal lobby_data_changed(info: Dictionary)
signal friend_lobbies_changed(list: Array)      # [LobbyInfo]
signal join_requested(lobby_id: String)         # invite accepted / +connect_lobby
signal error(code: String, detail: String)

func host(max_members := 10) -> void
func join(lobby_id: String) -> void
func leave() -> void
func invite_friends() -> void
func refresh_friend_lobbies() -> void
func set_scan_active(on: bool) -> void          # Join panel visible -> events + 10 s fallback scan
func set_state(state: String) -> void           # "waiting" | "starting" | "in_game" | "ending"
func current() -> Dictionary                    # LobbyInfo or {}
```

Model (lobby/lobby_model.gd, plain dictionaries so they are JSON-safe and diffable in tests):
`LobbyInfo {id, owner_id, host_name, members, max, state, pitt_version, pittapi_version, mp_version,
joinable, reason}`; `MemberInfo {id, name, is_owner, is_self, net: "lobby"|"connected"|"in_world"}`.
Steam ids are carried as **strings** (64-bit ids must survive JSON).

`SteamLobbyService` (the only file that calls `Steam.*` lobby/friends functions):
- Host: `Steam.createLobby(Steam.LOBBY_TYPE_FRIENDS_ONLY, MAX_MEMBERS)` (const 10). On
  `lobby_created(connect, lobby_id)`: `setLobbyData` `pitt_version`, `pittapi_version`, `mp_version`,
  `host_name`, `members`, `max`, `state=waiting`; `setLobbyJoinable(true)`; rich presence `connect =
  "+connect_lobby <id>"`, `steam_player_group = <id>`, `steam_player_group_size = n` (re-asserted on each
  change; L15 says the game won't clear them).
- Members: after `lobby_joined`, `getNumLobbyMembers` + `getLobbyMemberByIndex`; `lobby_chat_update`
  -> rebuild; `persona_state_change` -> name resolved; host updates `members` on every change.
- Join list: loop `getFriendCount()` / `getFriendByIndex(i, FRIEND_FLAG_IMMEDIATE)`, `getFriendGamePlayed`
  -> if `id == 4026250` and `lobby` set -> `requestLobbyData(lobby)`; `lobby_data_update` -> row
  update; `persona_state_change` -> re-check that friend. Fallback rescan every 10 s only while
  `set_scan_active(true)`; Refresh button calls `refresh_friend_lobbies()`.
- Rows are disabled with a reason when `pitt_version`/`pittapi_version`/`mp_version` differ.
- `join_requested(lobby_id, friend_id)` and the `+connect_lobby <id>` launch argument
  (`OS.get_cmdline_args()` and `Steam.getLaunchCommandLine()`, read once at boot and again on the first
  main menu) emit `join_requested`. Router: on the main menu -> join directly; in a world -> confirm
  dialog "Leave the current game and join?".
- `leave()`: `leaveLobby`, clear our rich presence keys only.

`DevLobbyService` (ENet): host = start ENet server; Join list shows one row "Local host
(127.0.0.1:24810)" when a TCP-less probe (`ENet create_client` with 1 s timeout) succeeds, or always in
dev mode; members come from the session roster. `FakeLobbyService` (tests): methods record calls,
`emit_*` helpers drive signals. Session never cares which one it has.

### 7.2 Screens (dumb views)

```
ui/mp_router.gd         panel stack (push/pop, Esc = back), owns which sibling panel is visible
ui/host_join_panel.gd   Host / Join / Back
ui/lobby_panel.gd       centered member list; Leave; host: Invite friends, Start
ui/join_panel.gd        friend lobbies list (rows like save-slot rows), Refresh, Back, empty state
ui/ui_style.gd          clones look from the live menu nodes (no copied assets)
ui/strings.gd           MP_* keys registered with TranslationServer (en + cheap locales)
```

Views subscribe to `LobbyService`/`Session` signals in `_ready`, disconnect in `_exit_tree`, redraw from
the model, never call `Steam`. All buttons connect `mouse_entered -> menu._on_mouse_entered` (the game's
hover sound) and play `menu.click_sound` via `MenuManager.play_ui_sound` (exactly like
`_play_ui_sound`, main_menu.gd:202).

### 7.3 Injecting into main_menu.tscn without breaking it

One script extension, `extensions/main_menu_ext.gd` (`extends "res://scripts/main_menu.gd"`; main_menu.gd
loads after PittAPI's `_init`, L4). Each override calls `super` and forwards to the mod node
(`/root/PittAPI/Mods/PittMultiplayer`, `has_method` guarded, so a quarantined/missing mod degrades to
vanilla):

| Override | What it adds |
|---|---|
| `_ready()` | `super()`, then `mod.inject_main_menu(self)` |
| `_on_return_save_load()` | if the MP router is in "host picking" mode: hide `MenuLoad`, `router.show("lobby")`; else `super()` |
| `_unhandled_input(event)` | if one of our panels is visible and `ui_cancel` pressed: `router.back()`, `set_input_as_handled()`, return; else `super(event)` (L5: the original swallows `ui_cancel` even when none of its panels is visible) |
| `_focus_current_panel()` | if one of our panels is visible: `router.focus_current()`; else `super()` (controller focus on device switch) |
| `_launch_game(scene_path)` | `mod.on_launch_game(scene_path)` (host start notification), then `super(scene_path)` |

`inject_main_menu(menu)`:
1. **Multiplayer button**: `var b = menu.get_node("Background/MenuButtons/Play").duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)`
   (no `DUPLICATE_SIGNALS`, so the copied scene connection to `_on_play_pressed` is not carried over),
   `b.name = "Multiplayer"`, `b.text = "MP_MULTIPLAYER"`, `MenuButtons.add_child(b)`,
   `MenuButtons.move_child(b, Play.get_index() + 1)`, connect `pressed -> router.open_host_join` (guarded by
   `menu.ignore_input` like the game's handlers) and `mouse_entered -> menu._on_mouse_entered`. The theme
   overrides (font, size 104) come with the duplicate, so a future restyle of Play carries over.
   Disabled with a tooltip reason if contract feature `mp` is off or Steam isn't initialized (ENet dev
   mode excepted).
2. **Panels**: each panel is a `VBoxContainer` sibling of `MenuLoad` under `Background`, created by
   `duplicate()`-ing `MenuLoad`'s **layout only** (anchors/offsets copied from it at runtime: preset 4,
   49/-76/785/384) and filled with buttons duplicated from `MenuLoad/New` (size 52) and labels using
   the title font `res://addons/ridiculous_coding/GravityBold8.ttf` with gold
   `Color(0.969, 0.729, 0.078)`, both `load()`ed from `res://`. List rows are instances of the game's own
   `res://scenes/save_slot_row.tscn` (the same scene `_populate_slots` uses), tinted with the game's
   `SLOT_COLOR_*` constants read from the menu instance; the lobby member list sits centered in the
   screen per spec (a separate centered `VBoxContainer` inside the lobby panel's full-rect holder).
3. Show/hide works exactly like the game: `MenuButtons.visible = false; panel.visible = true` and back,
   with the game's `_temporarily_ignore_input()` after each swap and `grab_focus()` on the first button
   when `InputManager.using_gamepad`.
4. `MenuManager.apply_menu_scales()` after injection (fonts follow the menu scale setting; idempotent,
   L5).
5. The main menu is re-instanced on every return from gameplay (`change_scene_to_file(main_menu)`), so
   injection simply runs again from `_ready`; the router re-attaches to `Session` and, if a lobby is
   still open (client returning after a host ending), opens straight on the lobby panel.

Spike S-MP6: with 5 buttons at size 104 the `MenuButtons` box (460 px tall, grows both ways) must still
fit at menu scale 1.0 and the max scale; if not, the injector sets `theme_override_constants/separation`
on `MenuButtons` slightly lower (the only deviation, measured, not guessed).

### 7.4 Strings

`MP_MULTIPLAYER, MP_HOST, MP_JOIN, MP_START, MP_INVITE, MP_LEAVE, MP_REFRESH, MP_NO_FRIENDS_HOSTING,
MP_IN_GAME, MP_WAITING, MP_VERSION_MISMATCH, MP_PLAYERS_FMT ("{n} / {max}"), MP_HOST_LOADING,
MP_CHOOSE_SAVE_TO_HOST, MP_CONFIRM_LEAVE_TITLE/BODY, MP_HOST_LEFT_TITLE/BODY, MP_CONNECTION_LOST,
MP_LOBBY_FULL, MP_JOIN_FROM_GAME_TITLE/BODY, MP_NOT_IN_MULTIPLAYER, MP_PLAYER_JOINED, MP_PLAYER_LEFT`.
`Translation` resources per locale built in code and `TranslationServer.add_translation` at mod init;
English always, others where cheap. Dialogs use the game's `ConfirmDialog` (`load("res://scripts/confirm_dialog.gd").new()`, `setup(...)`, added to the menu), same as `_on_quit_pressed`.

---

## 8. Player avatars and the 18 `player` lookups

### 8.1 Each peer simulates its own player

Nothing about the game's PlayerController changes. Its 18 `get_first_node_in_group("player")` call
sites (L14) all mean "the local player" and stay correct in MP1:

| Files | Meaning in MP | Action |
|---|---|---|
| save_manager.gd (3) | snapshotable check, save/load player position | host saves its own position; clients never save; client load places the client at the host's saved position (desired spawn) |
| game_progression.gd (3), elevator.gd, fall_sequence.gd, test_black_hole.gd, security_room.gd (3) | local cinematics (phase transitions, ending suction, black hole, secret ending) | run per machine on the local player |
| golf_club.gd (2), gravity_inverter.gd, tractor_beam.gd, cannon.gd | local tool effects on the local player | correct in parallel worlds (the tool is local); MP2 revisits |
| pause_menu.gd | Unstuck -> local player | correct |

Rule: puppets are **never** in groups `player`, `main_camera`, `head`, `draggable` or any interaction
group, and have no physics body in MP1. So the 16 `is_in_group("player")` body checks and the
security cameras' `head` tracking are unaffected.

### 8.2 Sending

`world/avatars.gd` on every peer, in world only: at 20 Hz (`tick_hz` config) read the local player
(`api.player.get_local()`), its yaw (`rotation.y`) and the camera pitch (`MainCamera.rotation.x`), and send
`xf {p, y, pi, v, f, t}` on channel 1 to the host. Flags `f`: crouching, sliding, holding (has
`picked_object`), equipped tool name hash (cosmetic). The host fans each client's `xf` out to the other
clients with `peer` added, and sends its own.

### 8.3 Puppet

`world/puppet.gd`, a `Node3D` under `/root/World/PittMP_Players/<peer>` (created on `world.ready`, freed
on `world.exited`):
- Visual: `MeshInstance3D` with a `CapsuleMesh` (radius 0.35, height 1.8, centered at the player's
  collision height), a small `BoxMesh` "visor" child pitched with the camera so you can see where they
  look, `StandardMaterial3D` tinted from an 10-color slot palette. Built from engine primitives, so no
  game asset is copied or depended on. (A duck or tool mesh "hat" from `res://` can be added later.)
- Name: `Label3D` billboard above the head, font `load("res://assets/PublicPixel-rv0pA.ttf")`, outline,
  `no_depth_test` off, fixed pixel size; text = persona name (Steam) or `Peer N` (ENet dev).
- Interpolation: a 1 s ring buffer of `(t_sender, pos, yaw, pitch)`; render time = newest - 100 ms;
  lerp position, `lerp_angle` yaw/pitch; snap if the gap is > 5 m (teleport/respawn); extrapolate at
  most 150 ms with the last velocity; hide after 2 s with no data. Sender clock offset is estimated per
  peer (min of `now - t` over a window), so no clock sync is needed.
- `entities.register_remote_player(puppet, peer)`; `api.net.get_players()` returns them.

---

## 9. Snapshot (late join and start)

`sync/snapshot.gd` on the host:

`build()` starts from a deep copy of `SaveManager.save_data` (so unknown keys such as mods' save keys and `version`
survive), then fills each top-level key the same way a real save does: it stamps `timestamp` and calls the game's own
collectors for `game_state`, `unlocked_milestones`, `game_statistics`, `object_pools`, `player_position`, `phase` and the
rest of the key list built in save_manager.gd `_save_game_impl()` (around lines 276-298), each guarded by `has_method` /
contract "mp". Finally it adds a `pitt_mp` key (`proto`, `host_peer`, `sandbox`, `snap_id`) and returns the dictionary.

- Same keys and the same collector functions as a real save, so whatever the game can load, the client
  can load, and game updates that change the save format carry over automatically.
- No pause (the collectors only read state); a few tens of ms on a big world, measured by spike S-MP8.
  If a collector throws, the snapshot is aborted and retried in 1 s.
- Built once per join burst (several clients joining within 2 s share one snapshot).
- Encoded `JSON.stringify` -> `to_utf8_buffer().compress(FileAccess.COMPRESSION_ZSTD)` -> 48 KB chunks
  on channel 2 -> client verifies sha256, decompresses, parses, checks `pitt_mp.proto`.
- The last sent/received snapshot can be dumped as plain JSON to `api.data_dir()/last_snapshot.json`
  with `mp dump snapshot` (debugging), never automatically.
- Deltas after the snapshot are the `econ` stream (section 6), which is full-state anyway, so a snapshot
  that is a few hundred ms stale is corrected by the first `econ` after `ready`.

---

## 10. Pause

`world/pause_guard.gd` (PROCESS_MODE_ALWAYS), active only while a session is in `IN_WORLD`:

- Each `_process`: if `get_tree().paused` and the cause is a menu (`MenuManager.game_paused` or
  `MenuManager.current_menu != null`), set `get_tree().paused = false`. `MenuManager.game_paused`
  stays true, so the game's own close/back logic and the Esc toggle in
  `player_controller._unhandled_input` keep working. One frame of pause at most; `SaveManager.save_game`
  pauses and unpauses synchronously within one call, so it is never affected.
- While a menu is up in a session: movement is locked with the existing PittAPI movement lock
  (`golf_aim_mode` meta), mouse look is already skipped (`current_menu != null`), and the main_camera
  extension returns early from `_input` and `handle_input` so clicks on menu buttons don't grab/throw.
- The world (other players, machines, physics) keeps running for everyone. Music's pause filter no
  longer kicks in (cosmetic).
- `end_of_game.gd:102` / `session_complete.gd:152` pause after the session is already `ENDING`; the guard
  is off by then.
- Mods: the README rule "a mod cannot pause the tree in an MP session" is enforced by this same guard.

---

## 11. Achievements and save policy

### 11.1 Achievements

- Per peer and local. Each machine's `Steamworks` keeps firing from its own `stat_changed`,
  `phase_changed` and `save_loaded` hooks (steamworks.gd:325-390):
  - phase/ending achievements: every peer, because each runs `change_phase` locally;
  - stat achievements: from each peer's own local stats (client counters are local in MP1), and on the
    host from the aggregated contributions;
  - consumerism: the buyer's `check_consumerism()` after a confirmed purchase (`purchased_once` is
    replicated).
- Late join burst: loading a snapshot triggers `Steamworks._on_save_loaded -> evaluate_all()` against
  the host's statistics. Config `achievements_on_join` (default `true`, "shared progress", owner decision
  section 15). When false, the client temporarily disconnects that one connection during the snapshot
  load and reconnects after `save.applied`.
- Cheats: if any cheat command succeeds on the host (core `on_cheat_used`), the host broadcasts
  `toast + flag`, and every peer runs `achievements.suppress` (now a `local` command) for the rest of the
  session. Sandbox follows the game (the game does not block achievements in sandbox).

### 11.2 Saves

| Role | Policy |
|---|---|
| Host | Saves its own slot as in single player (autosave, checkpoints, manual). The save contains only the host's position. Unknown top-level keys survive; MP adds none. |
| Client | Never touches a slot: `save.isolate` on `user://pittapi/mods/PittMultiplayer/session.save` for the whole session (re-asserted per frame); pause Save/Load/Delete hidden; F5/F9 swallowed; `set_active_slot` never called (so `profile.cfg` `last_slot` is not written). On session end: isolation off (restores the previous path/flags), session.save (+ .bak/.tmp) deleted through SafeFS. |
| Ending on a client | `mark_game_completed()` writes `profile.cfg [progress] game_completed` and the ending force-saves to the active path (the session file). Writing "completed" for a client who finished the game in co-op is treated as correct (owner decision section 15); it never touches a slot. |

The live MP test asserts the save-hash guard on **both** machines (real game user dir and the peer-2
user dir).

---

## 12. MP2 plan (physics objects, products, machines, tools) - designed, not built

MP2 flips the world model from parallel to **one host-simulated world**:

1. **Host-run world**: only the host's maw, hole, workbenches, crates, terminal, statue, press, ore
   processor and force writers run gameplay code. On clients, the same scripts are gated by thin
   extensions (`if PittMP.is_client(): return` at the gameplay entry points listed in
   production-objects H6/H7/H10 and world-physics #13). Contributions (6.4) are deleted.
2. **Entity replication** on channel 3: host sends `ent_spawn {eid, pool_id, xf, extra}` /
   `ent_despawn {eid}` from the PittAPI pool reconciler events (`entity.spawned/despawned`, already
   authority-allocated ids), clients spawn mirrors through `ObjectPoolManager.spawn` (correct visuals via
   `on_pool_spawn`) and freeze them (`freeze_mode = KINEMATIC`). The per-entity `extra` schema is the
   save format's (`_save_object_pools`, save_manager.gd:657-795): value drain, gambled, tint, grade, etc.
3. **Transform snapshots**: 15-20 Hz, unreliable, quantized (pos 1 mm, quat smallest-three), interest
   management (only bodies within N m of a player, plus anything awake), priority by distance and
   velocity, per-entity sequence to drop stale updates; client interpolation 100 ms like puppets.
4. **Carry/throw ownership**: a client grabbing a body sends `grab {eid}`; the host grants temporary
   ownership; the owner simulates (the game's `main_camera` carry code runs unmodified on the owner) and
   streams its transform; on drop/throw ownership returns to the host with the release velocity.
   main_camera extension hooks `_begin_carry/drop_object` and the throw block (poll `picked_object`
   diff, as GameBridge already does).
5. **Equipped tools on remote players**: puppets show a proxy mesh of the equipped tool; tool effects
   (fan, tractor beam, vacuum) are requested from the host (`tool_use {eid, action}`) and run there.
6. **Player-affecting forces**: puppets get a kinematic body in group `remote_player`; forces the host
   computes against a remote player are sent as `impulse` to the owning client, which applies them with
   `apply_external_impulse`.
7. **Interaction requests**: workbench crafting, terminal levers, statue pet, cauldron tune
   (`interact_ray.gd:467` and friends) become `PittMultiplayer.interact {eid, verb}` commands.
8. **Late join** stays the same snapshot path; only `object_pools` now means "the shared world".
9. Bandwidth target: 10 players, 300 awake bodies, under 256 kbit/s per client with interest management.

---

## 13. Testing strategy

### 13.1 Headless (no game, `tools/test-headless.ps1`, every change)

New suites in `tests/headless/suites/`, with fakes extended (`fakes/steam.gd` lobby API shape is not
needed because `FakeLobbyService` replaces the service, not Steam):

| Suite | Covers |
|---|---|
| `test_mp_codec` | envelope encode/decode, size cap, unknown type drop, chunking + sha256 + zstd round trip, malformed JSON |
| `test_mp_authority` | `LoopbackTransport` pair in one process: ClientAuthority sends `cmd`, host `dispatch_remote` uses the transport sender id (forged `origin` ignored), `res` completes `result.done/completed`, timeout -> ERR_UNAVAILABLE, disconnect fails pending, `local` commands never leave the machine, remote call of an `internal`/`local` command refused |
| `test_mp_commands_scope` | loader: `local` flag gates, builtins marked local, `describe()` flags, provider install/uninstall restores LocalAuthority, session signals, manifest `net_provider` required |
| `test_mp_econ` | host builder diff/dirty logic; client `apply_econ` idempotent (apply twice = once), unlock replay calls `_trigger_milestone` once per id, items + toys prices, phase never goes backwards, unacked delta prediction, `_applying` prevents forwarding loops |
| `test_mp_contrib` | forwarder batches money/stat/nutrition, dedupe by seq, caps, host applies via fake GameState and hole stub |
| `test_mp_purchase` | upgradeUI stub row with meta `button`: rewire on client, recall uses the original callable, host `buy` for upgrade/tool/toy incl. crate escalation and insufficient funds |
| `test_mp_lobby_ui` | `FakeLobbyService` drives the router and panels on a stub main menu scene (`Background/MenuButtons/Play`, `MenuLoad`, `New`...): button inserted right after Play with Play's overrides and **without** the `_on_play_pressed` connection, panel swap like the game, Esc/back, empty state, mismatch rows disabled, `join_requested` routing, re-injection on menu re-instance |
| `test_mp_pause_guard` | tree unpaused while `MenuManager.game_paused`, movement lock applied/released, inactive outside sessions |
| `test_mp_snapshot` | builder uses the fake SaveManager collectors and keeps unknown keys; client prepare writes the session file through the allowed path, enables isolation, never a slot path |
| `test_mp_two_process` | spawns a **second headless Godot process** (`OS.create_process` on the console exe with the same headless project and a `--peer2` user arg and a second generated project name so `user://` differs) and connects over **ENet localhost**: handshake, version mismatch `bye`, `cmd` round trip, `econ` replication between two fake GameStates, transform stream, host leave -> client sees `host_left`. Real sockets, still no game. |

### 13.2 Two-instance live ENet loopback (real game + decomp editor instance)

`tools/test-mp.ps1` (only run by stages allowed to launch the game):

1. Refuse if `projectpitt.exe` or a decomp Godot is running. Hash save files of **both** user dirs.
2. Install into the game with `-WithTests -WithMP` (adds `PittMultiplayer`, sets its config
   `transport=enet`).
3. Prepare peer 2 from the decompiled project (gitignored, files may be added there):
   - `decomp/override.cfg`:
     ```ini
     [application]
     config/use_custom_user_dir=true
     config/custom_user_dir_name="PittMP_Peer2"
     [autoload]
     PittAPI="*<repo>/dist/mp-peer2/mods/PittAPI/pittapi.gd"
     ```
     The custom user dir is essential: without it the decomp instance would share the real game's
     `%APPDATA%\Godot\app_userdata\Project P.I.T.T` saves. It lands in `%APPDATA%\PittMP_Peer2`.
   - `dist/mp-peer2/mods/` = copies of `loader/`, `mods/PittMultiplayer`, `mods/PittAPITests`;
     env `PITTAPI_GAME_DIR=dist/mp-peer2` (honoured only under `OS.has_feature("editor")`).
   - One-time `"<godot console>" --headless --path decomp --import` (minutes).
4. Write autotest flags: game `{"suites":["mp_host"], ...}` in the real user dir, peer 2
   `{"suites":["mp_client"], ...}` in `PittMP_Peer2`.
5. Launch host: `steam://rungameid/4026250`; launch client: `"<godot>" --path decomp` (the editor binary
   skips `restartAppIfNecessary`, steamworks.gd:146).
6. Suites (in `mods/PittAPITests/suites/`):
   - `mp_host`: `save.isolate` + `achievements.suppress` (both now `local`), isolated new game like the
     gameplay suite, host session over ENet, wait for client `ready`; then: client puppet appears and
     moves (interpolated position within tolerance of client-reported path), money/phase/unlock changes
     reach the client (assert via an `mp_probe` command result), a client `buy` charges host money,
     a client contribution raises host money and hole nutrition, pause guard keeps the tree unpaused
     with the pause menu open, `phase.set 2` replicates and the client runs the cinematic, F9 blocked,
     then host leave.
   - `mp_client`: joins `127.0.0.1:24810`, loads from snapshot (asserts `active_save_path` = session
     file, `save_locked`, money/items equal the host's), sends moves on a scripted path, buys one
     upgrade and one tool through the rewired button handler, feeds a spawned product to its maw, then
     on host leave asserts the return to main menu + dialog, isolation off, session file deleted.
   - A late-join variant: the client connects 20 s after the host is in world.
7. Poll both reports, kill both processes, re-hash both user dirs: **any change to a save file fails**.
8. Restore `decomp/override.cfg` (remove ours).

Same-account caveat: both instances initialise Steam with the same account (allowed for two processes;
spike S-MP1), but Steam P2P to yourself does not work, hence ENet.

### 13.3 Spikes (do first, ~15 min each)

| Spike | Question |
|---|---|
| S-MP1 | `ENetMultiplayerPeer` exists in the shipped release template; the decomp editor instance boots with PittAPI from override.cfg and a custom user dir while the real game runs on the same Steam account. |
| S-MP2 | Exact `SteamMultiplayerPeer` API in the bundled GodotSteam (`host_with_lobby(lobby_id)`, `connect_to_lobby(lobby_id)`, peer id <-> steam id, channels honour `max_channels=4`); signal argument lists of `lobby_created`, `lobby_joined`, `lobby_chat_update`, `lobby_data_update`, `join_requested`, `persona_state_change`; `getFriendGamePlayed` dictionary keys. Pin them in `steam_adapter.gd`. |
| S-MP3 | Loading a phase-0 snapshot (elevator) works; otherwise the new-game fallback (5.3.4). |
| S-MP4 | Encrypted session.save written with the runtime `SAVE_PASSWORD` loads through `load_game`; `profile.cfg` and slots untouched (hash). |
| S-MP5 | Pause guard UX: pause menu, options, controls menu, upgrade terminal and Steam overlay all behave with the tree running. |
| S-MP6 | Five 104 px buttons fit `MenuButtons` at min and max menu scale. |
| S-MP7 | Custom `SceneMultiplayer` via `set_multiplayer(..., path)` is polled with both peers, including while the tree is (briefly) paused. |
| S-MP8 | Snapshot build time and size on a late-game save (target < 100 ms, < 2 MB compressed). |

### 13.4 Manual two-account Steam checklist (owner)

Needs two PCs (or one PC + Steam Deck/laptop) with **different Steam accounts that are friends**, both
with the game, PittAPI and PittMultiplayer installed via `tools\install.ps1 -WithMP` (same versions),
`transport=steam`.

1. A: main menu shows **Multiplayer** directly under Play, same font/size; hover sound plays; controller
   focus moves through it.
2. A: Multiplayer > Host. Lobby screen lists A's persona name centered; Invite + Start + Leave visible.
3. B: Steam friends list shows A "In P.I.T.T." with "Join Game". B: Multiplayer > Join lists A's lobby
   with `1 / 10` and `Waiting`; Refresh works; no lobby -> "No friends are hosting".
4. B joins from the Join list. Both lobby screens show A and B within 2 s; A's row count on a third
   friend's Join screen shows `2 / 10`.
5. A: Invite opens the Steam overlay invite dialog; B accepts an invite while on the main menu (tests
   `join_requested`). Repeat with B's game closed (Steam launches it with `+connect_lobby`).
6. A: Start -> save panel -> New Game. B sees "Host is loading", then loads into the same world, spawns
   next to A. Both see each other's capsule + name label moving smoothly; no jitter at walking speed.
7. Shared economy: A feeds ducks, B's money rises; B feeds ducks in B's world, A's money and hole
   progress rise; B buys an upgrade at the terminal: both see the level and the money drop once; B buys
   a tool: it appears in B's world.
8. Phase: reach phase 2 (or `phase.set 2` with cheats): both play the transition.
9. Pause: B opens the pause menu: A keeps moving and B's world keeps running; B cannot move or grab
   while the menu is open; B's pause menu has no Save/Load/Delete; F5/F9 do nothing on B; F9 does
   nothing on A.
10. Late join: C (third account) joins while in game -> lands in the running world synced (money,
    upgrades, phase).
11. B leaves (pause > Main Menu): A sees "B left", the puppet disappears; B is on the main menu, not in
    a lobby (A's lobby count drops).
12. A quits to the main menu: B (rejoined) is returned to the main menu with "The host ended the
    session".
13. Pull B's network cable mid-game: B gets "Connection lost" within ~10 s, A drops B.
14. Version mismatch: install an older PittMultiplayer on B: A's lobby shows disabled with the reason.
15. After all: B's `%APPDATA%\Godot\app_userdata\Project P.I.T.T` has no new/changed `savegame*`; A's
    slot saved normally; no `pittapi/mods/PittMultiplayer/session.save` left on B.

---

## 14. Concrete file list

### 14.1 New mod `mods/PittMultiplayer/`

```
mod.json                      id PittMultiplayer, multiplayer "client_required", net_provider true,
                              extensions [main_menu_ext, upgrade_ui_ext, hole_ext, pause_menu_ext,
                              main_camera_ext, player_controller_ext]
main.gd                       entry: config, strings, builds Session/LobbyService/Replicators, commands,
                              console commands (mp status|peers|host|join <addr>|leave|dump [snapshot]|
                              lag <ms> <loss>), public API (is_client, is_session, broadcast_event, ...)
net/transport.gd              factory interface
net/steam_transport.gd        SteamMultiplayerPeer
net/enet_transport.gd         ENetMultiplayerPeer (localhost dev/tests)
net/loopback_transport.gd     in-process pair (headless)
net/steam_adapter.gd          every Steam.* signature in one place (has_method, arg shapes, logging)
net/relay.gd                  the single RPC node (_r/_u/_b), fault injection, ring-buffer log
net/codec.gd                  envelope encode/decode, chunking, zstd, sha256
net/session.gd                state machine, handshake (hello/welcome/bye), roster, start/leave/end
net/host_authority.gd         extends core/authority.gd
net/client_authority.gd       extends core/authority.gd (pending, timeout, local scope)
lobby/lobby_service.gd        base: signals + model + interface
lobby/steam_lobby_service.gd  the only Steam lobby/friends/presence caller
lobby/dev_lobby_service.gd    ENet dev lobby
lobby/fake_lobby_service.gd   headless fake
lobby/lobby_model.gd          LobbyInfo / MemberInfo helpers (JSON-safe dicts)
ui/mp_router.gd               panel stack, Esc/back, focus, host-picking mode
ui/host_join_panel.gd
ui/lobby_panel.gd
ui/join_panel.gd
ui/ui_style.gd                clone layout/buttons/rows from live menu nodes; load res:// fonts/theme
ui/strings.gd                 MP_* translation keys
sync/econ_replicator.gd       host dirty tracking + econ send; client apply (via apply_econ command)
sync/contribution.gd          client forwarder + host contribute handler
sync/purchase_router.gd       PittMultiplayer.buy (host) + client rewire handler
sync/snapshot.gd              build (collectors) / prepare+launch (client)
world/avatars.gd              local transform sender, host fan-out, puppet manager
world/puppet.gd               capsule + visor + Label3D, interpolation buffer
world/pause_guard.gd          tree-unpause + local input lock
world/save_guard.gd           client isolation lifecycle, F5/F9/Load policy, session file cleanup
policy/achievements.gd        on-join burst option, cheat broadcast -> suppress
extensions/main_menu_ext.gd   _ready/_on_return_save_load/_unhandled_input/_focus_current_panel/_launch_game
extensions/upgrade_ui_ext.gd  _create_upgrade_row/_create_tool_buy_row/_create_toy_buy_row (is_mirror safe)
extensions/hole_ext.gd        _check_phase_completion no-op on clients
extensions/pause_menu_ext.gd  hide Save/Load/Delete in session (clients), Load (host)
extensions/main_camera_ext.gd _input/handle_input early return while a menu is up in a session
extensions/player_controller_ext.gd  _input: swallow quick_save/quick_load per policy
README.md                     user-facing: how to host/join, dev ENet mode, known MP1 limits
```

Every extension is thin: `super` + one forward to the mod node with `has_method` guards, so a
quarantined or disabled MP mod leaves vanilla behaviour.

### 14.2 Loader changes

```
loader/core/commands.gd          `local` opt, describe() flags, remote refusal
loader/core/builtin_commands.gd  mark 6 builtins local
loader/core/authority.gd         doc + get_peer_name() default, get_players() default
loader/api/net.gd                install_provider/uninstall_provider, signals, get_players, get_peer_name
loader/pittapi.gd                provider gate (manifest net_provider), restore LocalAuthority, emit session events
loader/core/entities.gd          register_remote_player / unregister_player
loader/core/events.gd            emit_internal origin override
loader/core/contract.gd          feature "mp": main_menu._launch_game/_on_return_save_load/_unhandled_input/
                                 _focus_current_panel/_temporarily_ignore_input/ignore_input/_pending_new_game/
                                 click_sound/_on_mouse_entered; SaveManager._save_game_state/_save_game_statistics/
                                 _save_object_pools/_save_player_position/_save_cameras/_save_hole/
                                 _save_vertical_gates/_save_minable_blocks/_save_pickaxe/_save_loop_puzzle/
                                 _is_press_in_scene/_is_terminal_in_scene/_is_bowling_set_in_scene/save_data/
                                 should_load_on_ready/peek_saved_phase/SAVE_PASSWORD/set_active_save_path;
                                 UnlockManager._trigger_milestone/unlocked_milestones/milestones;
                                 WorkbenchSpawning.get_save_data/auto_machine_purchased;
                                 GameState.apply_remote_tier/purchased_once/products_consumed/total_products_consumed;
                                 GameProgression.change_phase/reset_run_state/current_phase;
                                 hole._on_product_consumed/_check_phase_completion/phase_nutrition_total/target_radius;
                                 upgradeUI._create_upgrade_row/_create_tool_buy_row/_create_toy_buy_row/
                                 _spawn_tool_instance/_spawn_toy_instance/update_ui/_play_sound;
                                 pause_menu._return_to_main_menu; MenuManager.apply_menu_scales/play_ui_sound/game_paused;
                                 Steamworks._on_save_loaded/check_consumerism
loader/schema/mod.schema.json    net_provider
```

### 14.3 Tests, tools, docs

```
tests/headless/suites/test_mp_{codec,authority,commands_scope,econ,contrib,purchase,lobby_ui,pause_guard,snapshot,two_process}.gd
tests/headless/fakes/  main_menu stub scene builder, upgrade_ui stub, hole stub, pause_menu stub
mods/PittAPITests/suites/suite_mp_host.gd, suite_mp_client.gd
tools/install.ps1      -WithMP switch (copies mods/PittMultiplayer)
tools/test-mp.ps1      two-instance ENet run (section 13.2), double save-hash guard
tools/mp-peer2.ps1     prepare/restore decomp/override.cfg + dist/mp-peer2, one-time import
docs/mp/MANUAL-STEAM-TEST.md   the checklist of 13.4
TESTING.md, README.md  MP sections
```

### 14.4 Build order

1. Spikes S-MP1, S-MP2, S-MP7 (transport), S-MP4, S-MP3 (snapshot load), S-MP6.
2. Loader additions + `test_mp_commands_scope`.
3. Codec, Relay, Loopback/ENet transports, Session handshake, authorities + `test_mp_codec/authority/two_process`.
4. Snapshot build/prepare + save guard; ENet two-instance smoke (host + decomp peer) with join-in-world.
5. Econ replicator + contributions + purchases + hole/upgradeUI extensions + tests.
6. Avatars/puppets, pause guard, main_camera/player_controller/pause_menu extensions.
7. LobbyService (Fake, Dev, Steam) + router + panels + main_menu extension + `test_mp_lobby_ui`.
8. Achievements policy, strings, `mp` console, docs; live `test-mp.ps1`; owner's manual Steam checklist.

---

## 15. Open decisions for the owner

1. **MP1 world model**: parallel physics worlds with shared progression (this proposal) vs. clients as
   spectators of the host's progression until MP2. Recommended: parallel, because it is playable and
   all pieces are reused by MP2.
2. **Start flow**: Start opens the game's own save panel (recommended) vs. "host the last used slot".
3. **Late-join achievements burst** (`achievements_on_join`, default true).
4. **Client ending writes `profile.cfg` "game completed"** (the game's own ending code does it): accept
   (recommended) or suppress (would need a guard around `mark_game_completed` on clients).
5. **Host in-game Load disabled during a session** (recommended) vs. "reload kicks everyone to re-sync".

## 16. Risks

- GodotSteam API drift (S-MP2): isolated in `steam_adapter.gd`; ENet path keeps development unblocked.
- Calling private game methods (`_save_*`, `_trigger_milestone`, `_on_product_consumed`): all listed
  in contract feature `mp`, so a game update disables MP cleanly instead of crashing, and
  `contract_check.py` names the broken member.
- Parallel worlds can look odd (players don't see each other's ducks); stated plainly in the MP README
  as an MP1 limitation.
- Contribution trust: acceptable for friends-only co-op; removed in MP2.
- Unpaused menus: the pause menu's options/controls screens were never exercised with a running tree
  (S-MP5).

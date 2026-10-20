# PittMultiplayer MP2: one host-simulated shared world

Status: **design, ready to build** (three parallel streams, section 10). It extends
`docs/mp/MP-DESIGN.md` (MP1, built and verified, "MP1 §n" below) and refines MP1 §12. Nothing in MP1's
transport, lobby, session state machine, snapshot load path, econ mirror, purchases rewire, avatars, pause
guard or save isolation is redesigned; MP2 adds to them. Where this document and MP1 disagree on MP2
behaviour, this document wins. `docs/MULTIPLAYER-UI-SPEC.md` stays authoritative for UI.

Game: Project P.I.T.T. v1.0.8 (Steam 4026250), Godot 4.7.2, Jolt, PittAPI 1.1 → 1.2. Line numbers are
`decomp/scripts/*.gd` (read-only, never committed). Every function named in section 4 was located in the
decomp while writing this; members marked **(verify)** are pinned by a spike (section 12) before the code
that uses them.

Concurrency note: while this was written another agent was fixing `world/puppet.gd`, `world/avatars.gd`,
the spawn logic in `sync/snapshot.gd` and the lobby UI files (including the avatar "visor" bar that hides
the remote player). MP2 does **not** depend on their internals: it reads avatar poses only through a new
accessor (`Session.avatar_pose`, 10.1) that reads the newest MP1 avatar frame kept by the Session (never the
puppet node), equipped tools are shown as the real tool entity at the remote player's hands (6.4) rather than
as a child of the puppet, it never touches `ui/` or `lobby/`, and it edits `sync/snapshot.gd` only in
`strip()` (3.8).

---

## 0. Decisions (owner defaults, recorded)

MP1 decisions D1-D7 stay unless superseded here.

| # | Decision | Default | Why |
|---|---|---|---|
| D8 | **One host-simulated world** replaces private physics (supersedes D1/D2). No private/shared switch; `MP_PROTO = 2`, so MP1 and MP2 builds list each other as incompatible. The `client_earnings` config key is removed (ignored if present). | yes | A switch doubles the test matrix and keeps contributions (the main MP1 trust hole) alive. |
| D9 | **Combos are shared**: one combo, run by the host (only the host's maw consumes). Clients mirror it in their HUD. Any player dying in the maw or falling off the map resets it (the game's rule). | shared | Per-player combos need attribution of every consumed item to a feeder; conveyors, roombas and cannons have no feeder. One combo is the co-op feel. |
| D10 | **Player effects are computed where the player is simulated.** A client's copy of a fan, spring pad, bumper, magnet, gravity inverter, tractor field, piston pusher, portal, maw, press or fail-safe acts on that client's own player with zero latency. The host never applies game effects to remote players, except host-decided discrete events (qa_arm whack, recoil of a tool fired on the host for a remote owner), which go to the owning client as `player.impulse`. | yes | Lag-free movement; no double application. |
| D11 | **Bought tools, toys and fixtures exist once**, spawned on the host at the game's own spawn spot, and any player may use them (fixes MP1's "tool appears only in the buyer's world"). | yes | Shared world. |
| D12 | **Grab is first come, first served, no stealing.** The host's own grabs go through the same ownership table. | yes | Simple and fair. |
| D13 | **The panel rack is per player** (`GameState.panel_stack` is the carried rack). The host keeps one stack per peer. | per player | It is an inventory, not world state. |
| D14 | **Shared world state**: gambling `bank`, `mining_bank`, remote channels and links, `pickaxe_tier`/`pickaxe_found`, `uv_unlocked`, `torch_unlocked`, `keypad_revealed`, `elevator_hacked`, buffs. Mirrored host → clients. | shared | One terminal, one ore processor, one remote channel set in the world. |
| D15 | **Secret ending is shared** (supersedes D6): a successful keypad hack sends every peer through its own escape ride and the session moves to `ending`. | shared | The keypad and elevator are one world object now. |
| D16 | **Phase-5 ending**: body replication stops, each client turns its puppets back into local dynamic bodies, and every peer runs the game's own ending locally (consistent with D5). | yes | The ending suction is GameProgression (an autoload we cannot extend) and purely a finale. |
| D17 | **Loop puzzle**: a run is timed on the runner's own machine and submitted to the host, which owns the puzzle state (energy, clones, best, solved). | yes | The puzzle samples one local player. |
| D18 | **Weight plate** counts remote players (8.0 each) through their host ghosts. Fallback if the extension point fails spike S-M7: only objects and the host player count (recorded limitation). | counts | Co-op puzzle. |
| D19 | **Interdiction alarm** stays per peer (each peer's own player triggers its own countdown). | local | Cosmetic + a safety stat. |
| D20 | **Late join** loads the game snapshot with **no** objects, then fetches a separate **world snapshot** (entities with host ids, fixtures, ownership, combo) cut at the moment the joiner's world is ready. | yes | Fresher (objects move during a 10 s load), carries host ids, and spawns puppets instead of local dynamic objects. |
| D21 | **Physics detail**: config key `physics_detail` = low / normal / high (24 / 48 / 96 KB/s per client), host-side, written to lobby data. The lobby UI control comes later (the lobby UI is being changed by another stream now). | normal | |
| D22 | Players pass through each other (as MP1). Remote players collide with host bodies (ghosts). On clients the local player passes through small puppet products (mass ≤ 2 kg) instead of being blocked by kinematic ducks; it still stands on crates, tools and fixtures. | yes | A kinematic pile of ducks is a wall otherwise. |
| D23 | Physics tick pinned at **60 Hz** on every peer for the whole session (`perf.pin_physics 60`). | yes | Frame-count logic (portal locks, piston rider window) and the codec's tick stamps. |
| D24 | Client stats are mirrored from the host (`products_*`, `total_*`, combo stats) and applied with `stat_changed`, so crossing-based achievements fire on clients under the MP1 "presence" policy. World-event achievements (BAD, SECRET, LOOP, INVISIBLE, MORE, EXTRA, MEGA) are broadcast by the host. | presence | Clients no longer consume anything locally. |

---

## 1. World model and principles

```
 HOST (authoritative)                                CLIENT (puppets)
 /root/World  + /root/ObjectPools                     /root/World  + /root/ObjectPools (same scene)
  real RigidBodies (dynamic) ──frames ch2──────────▶   same pooled nodes, frozen KINEMATIC, host eid
  entity spawn/despawn/meta ──ch3 (reliable)───────▶   spawned through ObjectPoolManager.spawn, adopted
  fixtures (press, benches, gates…) state ──ch3────▶   same fixtures, logic gated, state applied
  ghosts of remote players (AnimatableBody) ◀──avatar frames ch2── local player (CharacterBody)
  rigs (Camera3D per remote player) ◀────tool_in / interact ch3─── input on targets
  econ / phase / unlock / hole / combo ─ch0────────▶   mirror (money clamp)
  ownership table ◀──own_req/own_rel ch3, held frames ch2──▶ predicted grab (local sim)
```

Principles (each one is a test, section 11):

- **P1 Host simulates every consequence.** A client's world is the same scene with the same fixtures, but
  every replicated body is a puppet: `freeze = true`, `freeze_mode = FREEZE_MODE_KINEMATIC`, driven by
  host frames. Collision shapes and layers stay, so the local player stands on crates and the interact ray
  hits puppets.
- **P2 Forces on puppets are inert by construction.** Jolt ignores impulses and forces on frozen bodies, and
  the puppet driver rewrites the transform every physics tick at a late priority. So the many force writers
  in the game (fans, magnets, bumpers, spring pads, inverter, tractor, vacuum suction, roomba, cannon spread,
  anomaly impulses) need **no** extension on clients. The driver also re-asserts `freeze`/`freeze_mode` every
  tick and counts `puppet_unfreeze` (game code such as `place()`/`_unfreeze()` can flip them).
- **P3 Every non-force side effect is gated.** Money, stats, `ObjectPoolManager.spawn/recycle`, metas used as
  protocol (`consumed`, `pending_maw_recycle`, `in_cannon_barrel`, `in_vacuum_bag`, `terminal_pull`),
  reparenting, teleports, phase, GameState flags and achievements are host-only. Each is cut with a thin
  script extension (section 4) that returns early on clients.
- **P4 Player branches run on the player's machine** (D10).
- **P5 Client money is a pure mirror.** `econ_client` re-asserts the host's last money every physics frame;
  any local write (a fine, a combo payout, a missed gate) is reverted and counted (`local_money_writes`).
  This is the safety net that replaces MP1 contributions.
- **P6 Stray guard.** A pooled object that becomes active on a client without a host eid (debris from the
  client's GameProgression, a missed gate) is recycled in the same frame and counted (`stray_spawns`).
- **P7 MP1 rules hold:** extensions are inert outside a session (first line is the vanilla path), they call
  `super` and game members by name only, and every member used is in a contract file. One narrow
  exception: a **client-side player branch** may call the local player's public API (`respawn_safe`,
  `apply_external_impulse`, `main_camera.release_held_object`) where the game's branch is inside a function
  that must be gated as a whole (press, qa_arm). Each such override is listed in section 4 and has a test.

### 1.1 Gate kinds (contract; implemented in `gameplay/mp_gate.gd`, semantics relied on by all streams)

| Kind | Host | Client, normal | Client, **apply scope** (`api.net.is_applying()`) | Client, **input scope** |
|---|---|---|---|---|
| `sink` | pass | block | block | block |
| `replay` | pass | block | **pass** (BODIES/GAMEPLAY apply replicated state by calling the game's own setter) | block |
| `input(verb)` | pass | block (machine-originated, e.g. a scheduler on a client) | pass | **forward** `interact`/`tool_in` to the host, then block |
| `input_predict(verb)` | pass | block | pass | forward, then **pass** (super runs for local feedback; its mutators are gated themselves) |

- **Input scope** is set by GAMEPLAY's extensions around the game's input dispatchers only:
  `main_camera.handle_input` (:425), `main_camera._do_interact` (:2091), `interact_ray.handle_workbench_interaction`
  (:468), `_stop_crafting_if_manual` (:486), `handle_automated_workbench_interaction` (:494),
  `handle_terminal_interaction` (:511), `handle_button_interaction` (:592), and the golf club's own `_input`
  (:161). A gated method reached from inside these frames was caused by the local player; anything else on a
  client was caused by a local machine copy and is blocked silently (the host's copy does it).
- **Host exec** (`MpGate.exec_peer`): when the host executes a forwarded verb it sets `exec_peer = P`
  around the call and wraps it in `PlayerEffectRedirect` (6.6).
- Every gate checks `session live` first; outside a session all gates pass (single player unchanged, H-SP1).

---

## 2. Protocol changes

### 2.1 Version and welcome

- `MP_PROTO = 2` (lobby data `mp_proto`, hello `proto`). `welcome.rules` gains
  `{world: "shared", physics_detail, budget_bps, tick_hz: 60, pools: [sorted POOL_CONFIG keys], pools_hash}`.
  The client compares `pools_hash` with its own pool table and rejects with `version` on mismatch (same build
  is already enforced; this catches a modded pool table). Pool ids travel as indices into `pools`.
- `rules.client_earnings` is removed.

### 2.2 Channels (MP1 §2.2 updated)

| Ch | Mode | MP2 use |
|---|---|---|
| 0 | reliable ordered | MP1 control/state stream + `world_req`, `wsnap_begin/end`, `netq`, `combo`. Commands (`cmd`/`res`) incl. the new MP2 commands. |
| 1 | reliable ordered | MP1 snapshot chunks + world-snapshot chunks (frame kind 3, distinct `xfer` ids). |
| 2 | unreliable | Avatar frames (kind 2), **body frames (kind 4, H→C)**, **held frames (kind 5, C→H)**. Max 1200 B per packet. |
| 3 | reliable ordered | **World lifecycle**: JSON `ents`, `meta`, `own*`, `fx`, `pimp`, `interact`, `tool_in`, `fixture_spawn`. |

Ordering guarantee used throughout: everything about one entity's existence and ownership travels on ch3 in
one order per direction. Body frames on ch2 may arrive before the spawn (buffered 500 ms) or after the
despawn (tombstones, 5 s).

### 2.3 Binary frames (`net/codec.gd`, little endian)

**Frame kind 4: body state (host → client), ≤ 1200 bytes**
```
header (10 B): u8 kind=4 | u8 pkt_flags (0) | u16 count | u32 host_ms (host wall clock of the physics tick sampled) | u16 pkt_seq
record (19 B base):
  u32 eid
  u8  rflags   1=LIN 2=ANG 4=SLEEP 8=SNAP(teleport) 16=HELD(by someone else) 32=HIDDEN 64=NOCOLLIDE(equipped) 128=reserved
  u8  epoch    (low 8 bits of the ownership epoch)
  i24 x, y, z  (1/1024 m, range ±8192 m)
  u32 rot      smallest-three: 2 bits index of the dropped component, 3 × 10 bits in [-1/√2, 1/√2]
  [LIN] i16 vx, vy, vz (1/100 m/s, clamp ±327)       +6 B
  [ANG] i16 wx, wy, wz (1/100 rad/s, clamp ±327)     +6 B
```
Typical moving body 25 B, sleeping/rest record 19 B, at most 47 records per packet. Decoders reject NaN,
counts that overrun the buffer, and positions beyond ±8000 m.

**Frame kind 5: held body (client → host), ≤ 2 records**
```
header (8 B): u8 kind=5 | u8 seq | u16 count | u32 client_ms
record (31 B): u32 eid | u16 epoch | i24 x,y,z | u32 rot | i16 v×3 | i16 w×3
```
`seq` is the sender's frame counter mod 256 (one per frame sent); the host counts gaps as `held_gaps`. An
older sender writes 0 every time, which reads as a repeat and counts nothing.

Encoders/decoders: `Codec.encode_bodies(host_ms, seq, records: Array) -> PackedByteArray`,
`Codec.decode_bodies(bytes) -> {host_ms, seq, records:[{eid, flags, epoch, p: Vector3, q: Quaternion,
l: Vector3, a: Vector3}]}` (empty Dictionary on error), `Codec.encode_held / decode_held` the same shape with a
16-bit `epoch`. Quantisation helpers are public statics (`q_pos`, `dq_pos`, `q_rot`, `dq_rot`) for tests.

### 2.4 New JSON messages

All JSON carries `{k, sid, q}` as in MP1; ch3 has its own per-direction `q` sequence.

| `k` | Ch | Dir | Body | Owner |
|---|---|---|---|---|
| `world_req` | 0 | C→H | `{}` after the game world is loaded and `save.applied` | BODIES |
| `wsnap_begin` / `wsnap_end` | 0 | H→C | `{xfer, bytes, raw, chunks, sha256, cut_q}` / `{xfer}` (chunks ch1) | BODIES |
| `netq` | 0 | C→H | `{rx_pkts, gaps, late, interp_ms, puppets, strays, local_money_writes}` every 1 s | BODIES |
| `ents` | 3 | H→C | `{t, sp:[[eid, pool_idx, x,y,z, qx,qy,qz,qw, lx,ly,lz, flags, meta|null], …], fb:[[eid, key, …same tail]], dp:[eid, …], hid:[[eid, 0|1]]}`; `sp` pooled spawns, `fb` fixture bodies, `dp` despawns, `hid` hidden toggles | BODIES |
| `meta` | 3 | H→C | `{m:[[eid, {field: value}], …]}` (pooled and static ids) | BODIES (transport), adapters by BODIES + GAMEPLAY |
| `own_req` | 3 | C→H | `{eid, seen_epoch}` | GRAB |
| `own_rel` | 3 | C→H | `{eid, epoch, s:{p,q,l,a}, thrown, placed, panel_state?, throw_meta?}` | GRAB |
| `own_equip` / `own_unequip` | 3 | C→H | `{eid, epoch}` / `{eid, epoch, drop:[x,y,z], s}` | GRAB |
| `own` | 3 | H→C | `{ev:"grant"|"deny"|"revoke"|"set", eid, peer, kind:""|"held"|"equipped", epoch, reason?, s?}` (`set` = broadcast of a change to everyone else) | GRAB |
| `interact` | 3 | C→H | `{eid, verb, arg?, aim?:{o:[x,y,z], d:[x,y,z]}}` | GAMEPLAY |
| `tool_in` | 3 | C→H | `{eid, verb, arg?, aim?}` (input to a tool the sender has equipped) | GAMEPLAY |
| `fx` | 3 | H→C | `{list:[{kind, eid?, pos?, args?}, …]}` one-shot cosmetic effects, achievements, notifications | GAMEPLAY |
| `pimp` | 3 | H→C | `{v:[x,y,z], src}` impulse for the receiver's own player; `{respawn:true, src}`; `{teleport:[x,y,z], src}` | GAMEPLAY |
| `fixture_spawn` | 3 | H→C | `{key:"press"|"trading_terminal"|"bowling_set", level}` | GAMEPLAY |
| `combo` | 0 | H→C | section 6.9 | GAMEPLAY |

New PittAPI commands (ch0 `cmd`, all `remote: true`, authority scope, host-revalidated):
`PittMultiplayer.penalty {kind:"maw"|"fail_safe"}`, `PittMultiplayer.recall {tool}`,
`PittMultiplayer.rack_store {eid}`, `PittMultiplayer.rack_withdraw {}` (GAMEPLAY). `PittMultiplayer.contribute`
is deleted (BODIES).

### 2.5 Caps and rate limits (host side, per peer; MP1 §2.3 mechanism)

| Class | Rate / burst | Kick |
|---|---|---|
| `interact` + `tool_in` | 20/s, 40 | 3× for 5 s |
| `own_*` | 10/s, 20 | same |
| held frames (kind 5) | 40/s, 80 | same |
| `world_req` | 1 per session state change | refused otherwise |
| JSON C→H on ch3 | ≤ 4 KB each | dropped |
| H→C `ents`/`meta` | ≤ 64 KB each (zstd above 1 KB, MP1 frame kind 1) | split by the sender |

### 2.6 Session module registry (BODIES implements on day 1; GAMEPLAY and GRAB plug in)

`net/session.gd` no longer grows per feature. Each stream ships one **module** object; `main.gd` loads
`world/bodies/bodies.gd`, `gameplay/gameplay.gd`, `grab/grab.gd` (each optional; a missing file is logged and
MP2 is disabled with `MP_ERR_INCOMPATIBLE_BUILD`) and calls `session.register_module(m)` before the session
starts. The full signatures are in section 10.1.

---

## 3. MP2a: bodies (STREAM BODIES)

### 3.1 What is replicated, and its id

| Class | Examples | Id | Lifecycle source (host) | Client node |
|---|---|---|---|---|
| **Pooled body** | products, candy, crates, tools, toys, debris, ores, keycards, recycle cubes, panels | dynamic eid from PittAPI (≥ 1000, authority-allocated, MP1 §3.3) | PittAPI pool reconciler (`entity.spawned/despawned`), every physics frame (L8) | `ObjectPoolManager.spawn(pool_id)` adopted under the host eid (L7) |
| **Fixture body** (non-pooled RigidBody in the world) | `World/Fuse`, `Fuse2`, `Fuse3`; the 12 `Pillars/*` security cameras (`camera_pivot.gd`); the pickaxe on its rack; `uv_lamp`; `torch_light`; bowling pins | static id = `PittEntities.static_id(key)`; keys `static:<node path>`; pins `bowling:pin:<gen>:<i>` (marker index) | `fixtures.gd` registry at `world.ready` + the pin generation meta | the same scene node (pins: spawned by the client's own set in apply scope, then adopted) |
| **Static fixture** (state only, no transform stream) | BottomMaw, Floor (hole), press, trading terminal, bowling set, every workbench and the cauldron, ore processor, minable blocks, gates, shutters, generator, weight plate, card reader, keypad, elevator, loop puzzle, erasable texts | static id; the loader's keys (`static:/root/World/BottomMaw`, `workbench:auto:<k>`, `workbench:manual:<k>`, `press`, `trading_terminal`, `gate:<gate_id>`, `block:<parent>_<name>`) plus `bowling_set`, `cauldron`, `loop_puzzle`, `keypad`, `card_reader`, `elevator`, `ore_processor`, `erasable:<path>` | `fixtures.gd` | same scene node |
| **Player** | avatars | slot 1..999 (MP1) | MP1 avatars | MP1 puppet (unchanged) |

Anything not in this table (particles, Label3D texts, ghost previews, trajectory renderers, menu falling
ducks, `product_stream`/`stream_spawner` MultiMeshes, the black-hole shader) is local and never replicated.

### 3.2 Loader changes (PittAPI 1.2, BODIES)

| # | File | Change | Why |
|---|---|---|---|
| L7 | `core/entities.gd`, `api/net.gd` | Provider-only `api.net.adopt_entity(node, eid, pool_id_or_key) -> Error` and `api.net.release_entity(eid)`: on a non-authority peer, registers a node under a host-assigned id (pooled or static) and emits `entity.spawned/despawned` with `source:"net"`. Refused on the authority and for ids already bound. | `id_of(node)` on clients must return host ids, for mods and for us; the reconciler allocates nothing on clients. |
| L8 | `core/entities.gd` | `set_reconcile_mode({full_every_frame: bool, detect_reuse: bool, gate_full_diff: bool})` (provider only). While hosting, a set change is seen in the physics frame it happens. **P10 gate** (default, PittAPI setting `entity_reconcile_gate`): every frame a per-pool signature (active size and the last active node, where spawn appends) is compared, and the full set diff runs only when it changed, when a watched pooled node changed visibility or left the tree, when the registry changed, on a pending reuse, or as a 1 s safety net; with the gate off it runs every frame. **Reuse detection**: each pooled node's `visibility_changed` is counted; a node still active that went hidden then visible within one physics frame, **and** carries neither `in_cannon_barrel` nor `in_vacuum_bag`, was recycled and respawned (`_deactivate` then `_activate`, object_pool_manager.gd:719/:692) and gets despawn + spawn with a **new** id. | The press recycles a duck and spawns a flat duck in the same frame; the total count does not change and the node can be the same one. |
| L9 | `core/entities.gd` | The `entity.spawned` payload gains `reused: bool`. | Diagnostics, mods. |
| — | `loader/mod.json` | 1.2.0 (api ^1.2); `PittMultiplayer` declares `api_version ^1.2`. | |

### 3.3 Host replicator (`world/bodies/replicator_host.gd`)

**Tracking.** On `entity.spawned` (pooled) and on fixture registration the host creates an `Ent` record:
`{eid, node, pool_idx|key, kind, last_sent[peer]{p,q,t}, acc[peer], sleeping, hidden, owner, epoch,
meta_hash, born_ms, boost_until}`. On `entity.despawned` the record becomes a 5 s tombstone.

**Lifecycle batching (ch3).** Spawns, despawns, hidden toggles and meta changes are collected per physics
frame and flushed as one `ents` + one `meta` message per peer at most every 33 ms (30 Hz), and always
immediately before any `own` message for the same eid (ordering). A spawn carries the full pose, velocity and
full meta (3.5). Peers that are still loading get nothing on ch3 until their world-snapshot cut (3.7).

**Flags, every send tick:**
- `HIDDEN`: `not node.visible`, or meta `in_cannon_barrel` / `in_vacuum_bag` (cannon `_load_body` cannon.gd:318
  hides and reparents; vacuum `_ingest` vacuum.gd:373). Sent once in `ents.hid`; no frames while hidden; the
  first frame after unhiding carries `SNAP`.
- `SNAP`: a position jump > 4 m since the last sent pose that velocity does not explain
  (`|Δp| > |v|·Δt + 1 m`), a portal teleport (host hook on `portal._do_teleport`, 4.3), the first frame after
  `HIDDEN`, or an L8 reuse.
- `SLEEP`: `RigidBody3D.sleeping`, or frozen STATIC (placed tools, `panel_state == 1`). A sleeping body is
  sent **once** with `SLEEP`, then repeated at 250 ms, 1 s and 3 s to survive loss; after that only the
  **rest refresh** (one sleeping body per peer per send tick, round-robin, about 570 B/s) heals any loss.
  A body that wakes is sent at once. Since 0.2.3 the first SLEEP of each rest goes out ahead of the awake
  records (a FIFO, oldest first, at most 60 % of a tick while bodies are awake); the repeats wait in one FIFO
  per stage and take at most `SLEEP_SHARE` (40 %) of a tick, after the first sends. Bytes the awake
  selection does not want this tick (every awake body gated, say) go to the SLEEP queues as well. `mp stats` carries the
  backlog and the age of the oldest queued first SLEEP.
- **Net-rest** (0.2.3): an awake body that nobody holds or follows and whose pose stays within 2 mm / 0.5° for
  400 ms is treated as resting (SLEEP, repeats, rest refresh) even though Jolt keeps it awake (a pile) or it is
  a still frozen-KINEMATIC body. A watch compares its pose every send tick and wakes it once it moves 5 mm or
  turns. A frozen body that is hidden (cannon barrel, vacuum bag) or out of the tree counts as resting; hidden
  bodies are re-checked every send tick, because the cannon and the vacuum show a body before they drop its
  barrel / bag meta and unfreeze it (the visibility signal still sees it hidden), so a body fired right after
  loading streams, with SNAP, on the next tick.
- `HELD`: owner ≠ host (GRAB calls `set_owner_view`). Records for an eid are **never sent to its owner**.
- `NOCOLLIDE`: owner kind `equipped` (the tool sits on someone's rig, 6.4).
- `epoch`: low byte of the ownership epoch.

**Per-peer sender (30 Hz; `world/bodies/priority.gd`, `budget.gd`).** For each in-game peer `c` with avatar
position `a_c` (`Session.avatar_pose`) and each awake, visible entity `e`:

```
w = kind_w(e) * dist_w(|p_e - a_c|) * motion_w(|v_e|) * boost_w(e)
kind_w   : held by another peer 4.0, held by the host player 3.0, tool/toy/fixture body 1.5, product/debris 1.0, candy 0.6
dist_w(d): 1 / (1 + (d / 8 m)^2), floor 0.05
motion_w : 1 + clamp(|v| / 4, 0, 3)
boost_w  : 3.0 for 2 s after spawn, SNAP, release/throw, an interaction verb on it, or contact with a ghost
acc[c][e] += w * dt
```
**Change gating (0.2.3).** The sender keeps, per peer, the last record it sent of each awake body (pose,
velocity and angular velocity as encoded, time). `w` is further multiplied by `change_w(err)`, where `err` is
the distance between the pose that peer's client extrapolates from that record (as `Interp.sample`: `p + l·t`,
and `q` turned by `a·t` when `Interp` rotates, which the host reads from `Interp` itself) and the current pose,
plus the rotation angle. `change_w` is 0 below 2 mm and 0.5°, so the body is not a candidate for that peer, and
`1 + clamp(err / 5 cm + angle / 10°, 0, 3)` otherwise. The client only extrapolates for about one update
interval (at least `Interp.EXTRAP_MIN_MS`, 100 ms), so a record with LIN or ANG is a candidate again whatever
its error once it is more than half a send interval short of the smaller of that and 100 ms (about 83 ms; it
goes out on the tick at about 100 ms): a body in steady motion is thinned to about 10 Hz, never held by the
client, and stays inside the 11.2 staleness target whichever Interp the build carries. A body not sent to a peer for 1 s is a candidate again whatever its error (the
forced refresh, which heals a lost record; `refreshes` counts the ones actually sent); SNAP and boost bypass
the gate, as does a body not yet sent since it woke. LIN is only encoded at 0.05 m/s or faster (19 B records
for still or crawling bodies).
Each tick the sender takes entities in descending `acc` until the tick's byte budget `budget_bps(c) / 30`
is used (records 19-31 B, packets ≤ 1200 B), sends them and zeroes their `acc`. Selection is a bucketed
partial sort; the host spends at most **2 ms per tick** on selection for all peers and resumes the scan next
tick when over (`sel_overrun`). Motion values are computed once per tick and shared by all peers.

**Budget (`budget.gd`).** `budget_bps(c)` starts at the `physics_detail` value (24 / 48 / 96 KB/s) and adapts
from `netq` and the client's ping RTT. The RTT minimum is the minimum of the last 30 s of reports (a
slower route becomes the new baseline; a report with loss > 5 % only counts when it lowers the minimum, so a
bottleneck does not become it while the cut works on it; after a whole 30 s window of nothing but lossy
reports their lowest RTT is the minimum, so lasting 5-15 % loss on a slower route cannot pin the floor for
good). Congestion for 2 s → ×0.7 every 2 s: loss > 15 %, or loss > 5 %
while the RTT rose 20 ms over the minimum, may cut to the 12 KB/s floor; RTT alone (> 2× the minimum and
> minimum + 50 ms) cuts at most to half the configured value, never below 18 KB/s (so on `low` too it stays
above the loss floor). `report()` also ignores RTT alone while the host is overloaded (`replicator_host.gd` passes its overload
factor).
Clean for 5 s → +15 % of the configured value per second up to it. Probe-up: quiet (no queueing, loss ≤ 5 %)
for 10 s at the configured value → +5 % of it per second up to a ceiling of 3× configured (at most
400 KB/s, the host-wide upload cap); any queueing or loss above the configured value drops straight back
to it and holds the probe off for 30 s; without a report in the last 2.5 s the probe does not step. On the
host the Steam transport sets SteamNetworkingSockets' global SendRateMax (the min stays Steam's, so its bandwidth estimate keeps working) to the probe
ceiling + 64 KB/s only when that is above Steam's documented default of about 256 KB/s (in practice
`high`: 352 KB/s), so Steam's pacing never caps below the ceiling; it logs the value it set. Avatars (about 1 KB/s per player), econ and control
are outside this budget.

**Physics overload guard.** If `Performance.TIME_PHYSICS_PROCESS` exceeds 80 % of the 16.7 ms tick for 5 s,
the host halves every budget (fewer, staler updates; never a tick change, D23) and shows the host
`MP_PHYSICS_OVERLOADED` at most once a minute. Since 0.2.3 it sheds CPU first: at most 256 candidates take
part per send tick (held, SNAP-owing and boosted ones always, the others in a window that moves on every
tick) and the physics catch-up cap drops from 8 to 4 steps per frame while pinned. With a single peer in game
the budget is not halved (that only made the one client's view staler; the every-other-tick serve that saves
CPU needs two or more peers).

### 3.4 Client replicator (`world/bodies/replicator_client.gd`, `world/bodies/puppet_body.gd`)

**Spawn** (inside `api.net.begin_apply(1)` / `end_apply()`, so `replay` gates pass):
1. `obj := ObjectPoolManager.spawn(pools[pool_idx], p, Vector3.ZERO)`. Null (pool exhausted) → the eid stays
   *pending* and is retried every 0.5 s (`client_pool_full`); its frames are buffered meanwhile.
2. `obj.global_basis = Basis(q)`, then **puppetize**: `freeze_mode = FREEZE_MODE_KINEMATIC`, `freeze = true`,
   meta `pitt_mp_puppet = eid`. `contact_monitor` stays on (impact audio still plays locally; the damage paths
   are gated, section 4). If the node is in group `product` and `mass ≤ 2.0`: the local player gets
   `add_collision_exception_with(obj)` (D22).
3. `api.net.adopt_entity(obj, eid, pool_id)` (L7).
4. Apply the meta (3.5); emit `entity_added(eid, obj)`.

`on_pool_spawn()` has already run inside `spawn()`. Spawn audio is muted during world-snapshot batches by
holding `SaveManager.is_loading = true`, which is what the game itself does in `_load_object_pools`
(save_manager.gd:1034); never for live spawns.

**Despawn:** `ObjectPoolManager.recycle(obj)` in apply scope, `api.net.release_entity(eid)`, the D22 exception
removed, 5 s tombstone (late frames ignored). A despawn wins over `local_sim`: GRAB hears `entity_removed`
first and drops the carry.

**Driving (`puppet_body.gd`; a per-entity record, not a node).** One `_physics_process` on the replicator at
`process_physics_priority = 100` (after the game scripts) drives every puppet that got a frame in the last
2 s or is still interpolating:
- Render time `rt = host_now − interp_delay`, `interp_delay = clamp(2 × jitter + 33 ms, 66, 200)` (100 ms
  default), using the MP1 clock offset (`Session.host_now`).
- Ring of the last 6 states per entity; Hermite position interpolation when both neighbours carry `LIN`
  and lie at most 100 ms apart, linear otherwise (a tangent scaled by a long span swings off the path);
  `slerp` for rotation. Extrapolation with linear and angular velocity for about one update interval of
  the body (the smaller of its last two record spacings + 50 ms, clamped to 100-600 ms; 250 ms with one
  record), then hold. The sampled velocity is always the derivative of the sampled curve (zero in
  before / hold / sleep).
- `SNAP`, an error > 5 m, or an epoch change → teleport; otherwise corrections blend over 150 ms. A blend
  starts only when new data arrives (the ring changed), from where the puppet would be drawn on the old
  curve, for position and rotation. A running blend restarts only when the new error is larger than what is
  left of it; a smaller one is folded in and the blend still ends on time. A still pose (before / hold /
  sleep) is written once, not every frame, and again only if game code moved the node off it.
- It writes `global_transform` (a kinematic move, so the local player is pushed and carried; physics
  interpolation is on, project.godot:187, so rendering is smooth) and re-asserts `freeze`/`freeze_mode`.
- `SLEEP`: place exactly and stop driving until the next record.
- `HIDDEN`: `visible = false`, collision layers saved and zeroed, restored on unhide. `NOCOLLIDE`: layers
  zeroed while set.
- Frames for an unknown eid wait 500 ms for the spawn, then are dropped (`orphan_frames`).

**`local_sim` (GRAB, equip).** `set_local_sim(eid, true)` stops driving, sets `freeze = false` (the game's carry
code moves the body), removes the D22 exception and clears the ring (the host sends nothing of a body to its
owner, so every state in it is pre-grab and must never be drawn again). `set_local_sim(eid, false,
min_epoch)` keeps the body local until the render time passes the first host record with
`epoch ≥ min_epoch` (older records are dropped), then re-puppetizes. The host's copy started from the
release state one way later and is drawn `interp_delay` behind, so the stream is drawn ahead of `rt` by the
local pose's lead along its velocity (≤ 400 ms, fading out over 1 s: the body slows briefly instead of
jumping back) and the rest blends over 150 ms. With no such record within 1 s any host record will do; with
none at all within 3 s the local pose is kept (`release_kept_local`) and the next record blends from it.
A grab that ends in its own epoch (deny, undo, pending timeout) hands back to the newest pre-grab state,
kept aside when the ring was cleared: the host never moved the body and may send nothing while it sleeps.

**Riders (0.2.2).** A body GRAB carries (local_sim, not equipped) takes the puppets in or on it along: every
pooled puppet it touches (`get_colliding_bodies`; the game's carry turns `contact_monitor` on) or whose
position lies inside the box of its collision shapes (grown 5 cm, plus 0.6 m above; scanned every 4th frame)
becomes local_sim too and simulates with it, while the host's copies ride the host's kinematic follower.
Without this a crate with ducks inside could not be lifted on a client: the ducks were frozen KINEMATIC
puppets resting on the crate's floor, and a kinematic body never yields. Riders are host-owned (`own` kind
`""`, no HELD flag, not hidden); one that the host reports held or hidden leaves at once. When the carry ends
(the carried body is a puppet again) every rider returns to puppet mode like `set_local_sim(eid, false,
newest epoch)`: a 150 ms blend to the host pose. Nothing is sent for riders.
On the host the riders ride the kinematic follower (3.3 `host_follow`), which therefore has to move evenly:
follower frames play at the sender's spacing (held frame `t_ms`, at most 100 ms past their arrival) on a
clock that advances exactly one physics tick per step. It steers toward the interpolated pose with bounded acceleration
(40 m/s^2, gain 12/s, snap beyond 1 m), so frames that arrive late in a burst bend its path instead of
jerking it. With arrival times and the wall clock, frames that
came in bursts moved the follower in uneven steps and a full crate shook its ducks out (a Jolt check: a
kinematic box lifting 24 ducks 1 m in 0.5 s keeps 24 when it moves every tick, 17 when it moves every other
tick).

**Stray guard (`world/bodies/stray_guard.gd`).** Every physics frame (priority 101) and every process frame,
the client compares `Σ pool.active.size()` with its puppet + local_sim count and, on a mismatch, diffs the
active sets. Any active pooled node without `pitt_mp_puppet` that is not `local_sim` is recycled at once
(`stray_spawns`, logged with its `pool_id`). Expected, silent sources: GameProgression debris
(`_spawn_debris_chunk` :756, `_spawn_phase4_debris` :1104) and `GameState.dump_panel_stack` (:1130). Any
other source is a missed gate, and the loopback tests fail on it.

### 3.5 Entity meta (`world/bodies/entity_meta.gd`, registry `world/bodies/meta_sync.gd`)

The generic per-entity meta uses **exactly the field vocabulary of the game's own save schema**
(`SaveManager._save_object_pools`, save_manager.gd:657-795), read field by field from the live node, plus
`is_flattened`, `grade` and `owner`:

`is_active, is_placed | panel_state, tint_color, gambled, crude_source, starter_crate, value,
current_variant, scheduler_mode/interval/duration, stat_index, camera_id, watched_camera_id,
current_channel, is_repelling, piston{offset,phase,timer}, preset (piston_2), wpreset (piston_3), remote_channel,
bag_count (vacuum), queue_count (cannon), is_flattened (flat_duck), grade (anomaly)`.

The client apply mirrors `_load_object_pools` (save_manager.gd:1034-1240) per field and calls the same game
setters inside apply scope: `remote_toggle(want)` or `is_active` + `update_fan_state()`, `_apply_tint()`,
`set_crude_source()` then `set_grade()`, `_apply_variant()`, `apply_placed_state()`, `apply_piston_save_data()`,
`value` + `_update_value_label()`, scheduler fields + `_update_screen()`/`_refresh()`, camera ids,
`current_channel` + `_update_screen()`, `flip_mode()`, `flatten_mesh_world_y()`. **Never on clients:**
`apply_loaded_bag` and `apply_loaded_queue` (they spawn), `GameState.remote_link_tool` (links come from the
GAMEPLAY mirror field, 6.10).

**Meta sync.** `register_meta(kind, matcher, read, apply, rate_hz)`: GAMEPLAY adds kind-specific adapters
(fixtures, qa_arm pose, workbench progress, terminal display, …). The host polls each reader for awake or
recently interacted entities at its `rate_hz` (default 4 Hz; 10-15 Hz for animated machines while active;
1 Hz for puzzles), diffs against the last sent dictionary (`meta_hash`) and sends only changed fields.
`meta_dirty(eid)` pushes at once (after an interaction). Fixture meta is part of the world snapshot.

### 3.6 Fixtures registry (`world/bodies/fixtures.gd`)

At `world.ready` on both roles it resolves the fixture list of 3.1 by node path and group (`saveable_hole`,
`BottomMaw`, `press`, `trading_terminal`, `workbench`, `automated_workbench`, `cauldron`, `ore_processor`,
`saveable_block`, `vertical_gate`, `gate_shutters`, `security_keypad`, `security_elevator`, `loop_puzzle`,
`saveable_camera`, `fuse`) and tracks each node with `api.entities.track(node, key)` on the host and
`adopt_entity` on clients (same static id). Late fixtures (press, terminal, bowling set, benches from
WorkbenchSpawning) are picked up from `get_tree().node_added` filtered by those groups. Fixture bodies are
puppetized on clients like pooled bodies. A key that resolves on one side only is logged
(`fixture_mismatch`) and ignored.

### 3.7 World snapshot and late join (`world/bodies/world_snapshot.gd`)

The sequence extends MP1 §9.2 (the game snapshot path is unchanged except the strip table, 3.8):

```
client: game snapshot loaded (no objects), save.applied
client → host  world_req                                       (ch0)
host:  cut = this peer's current ch3 seq; build the wsnap in this physics frame;
       from now on queue ch3 for the peer (ents/meta/own/fx after the cut)
host → client  wsnap_begin {xfer, …, cut_q} + chunks (ch1) + wsnap_end
client: verify sha256; apply 150 entities per physics frame (SaveManager.is_loading held);
        then replay the buffered ch3 messages with q > cut_q, in order
client → host  ready {xfer}         (the MP1 message, now sent after the world apply)
host:  starts body frames (ch2) to the peer, full econ, roster, combo and avatar fan-out (MP1)
```

wsnap JSON (zstd, 32 KB chunks; joins within 2 s share one build, as in MP1):
```
{ "cut_q": n, "host_ms": t, "pools_hash": "…",
  "ents":     [[eid, pool_idx, x,y,z, qx,qy,qz,qw, lx,ly,lz, ax,ay,az, flags, owner, epoch, meta], …],
  "fbodies":  [[eid, key, x,y,z, qx,qy,qz,qw, flags, owner, epoch, meta], …],
  "fixtures": {"<static id>": meta, …},
  "sections": {"grab": {...}, "gameplay": {...}} }        # module sections (10.1)
```
Targets (spike S-M8 measures them): 300 entities ≈ 60 KB raw / 12 KB zstd, applied in < 0.3 s; 3000 entities
≈ 600 KB raw / 110 KB zstd, built in < 30 ms on the host (one frame hitch, accepted) and applied in < 2 s
behind the loading screen. Cap 32 MB raw (MP1).

### 3.8 Removing MP1 contributions and the private-world wording (BODIES)

- Delete `sync/contributions.gd`, the `PittMultiplayer.contribute` command (`session._register_commands`),
  `session.ext_feed` and the contributions wiring. `hole_ext._on_product_consumed` keeps only the vanilla
  path (the client maw never emits now); `_check_phase_completion` and `_trigger_ending` stay blocked on
  clients.
- `econ_client`: no pending ledger; `money = host money` exactly; the **money clamp** (P5) runs every physics
  frame. `econ_host`: no `ack`.
- The econ mirror gains (BODIES): `bank` (emits `bank_updated` on apply), `mining_bank`, and `stats` (the
  `game_statistics` counters; dirty on the host's `stat_changed`, full every 2 s, applied with
  `stat_changed.emit` in apply scope, D24). A mirror **field registry**, `econ_host.register_field(name, read,
  apply)`, carries GAMEPLAY's fields (6.10).
- `Snapshot.strip()` (MP2 table): `object_pools` stays `{}` (objects come in the wsnap); `press_spawned`,
  `trading_terminal_spawned`, `bowling_set_spawned` and `pickaxe` are **kept from the host** (the client's own
  load path builds the same fixtures); `bank`/`mining_bank` are kept (shared, D14); `panel_stack` becomes the
  joiner's host-side stack (GAMEPLAY provides it through its module section; empty by default). Only `strip()`
  and its constants change; the concurrent spawn-position fix in `snapshot.gd` is not touched.
- Session `_host_buy` no longer sends `grant` (items spawn on the host); `purchases.on_grant` becomes a no-op
  (GAMEPLAY).
- `MP_MP1_PRIVATE_WORLD` is no longer shown anywhere (it is already only registered); the mod.json
  description and the README "Known limitations" are rewritten for MP2. The key stays registered so the UI
  string test keeps passing until the UI owner retires it.
- Tests deleted or rewritten: the contribution cases of `test_mp_net_econ` become money-clamp and mirror
  cases; review-fix cases #4, #5 and #11 (contribution resend, feed budget, floored fine) become their MP2
  equivalents (penalty dedupe and rate, 6.8). The join-time fine absorption (#12) moves to the host: penalties
  from a peer within 5 s of its `ready` are ignored.

---

## 4. Host-only gameplay: every sink and force writer (STREAM GAMEPLAY)

### 4.1 How to read the tables

- **Hook**: `ext` = a PittAPI script extension `extensions/gameplay/<script>_ext.gd` that
  `extends "res://scripts/<script>.gd"` (MP1 §1 rule 4, API-DESIGN §4). `sig` = a signal connection made by a
  GAMEPLAY module (no extension). `node` = node-level property set at world ready (for autoloads, which are
  BLOCKED from extension). `—` = nothing needed (P2: forces on puppets are inert; or local by design).
- **Gate** column uses the kinds of 1.1. `sink f` means `f` returns early on clients; `replay f` means `f`
  runs on clients only when BODIES/GAMEPLAY apply host state; `input f → verb` means a client's local player
  call is forwarded as `interact{eid, verb}` (or `tool_in` for an equipped tool) and the host runs the same `f`
  on its node under host exec (6.6).
- **Client sees**: what replaces the gated effect on a client.
- Every extension method has the same skeleton (no copied game code):

```gdscript
extends "res://scripts/press.gd"
const G = preload("../../gameplay/mp_gate.gd")

func interact():
	if G.input(self, "press"): return          # client: forwarded (or blocked); host/SP: falls through
	super()

func process_crushed_items():
	if G.sink(self):
		G.client_player_branch_press(self)      # P7 exception: release_held_object + respawn_safe on the local player
		return
	super()
	G.host_after(self, "press_cycle")           # host: meta_dirty + fx
```

### 4.2 Economy sinks and money writers

| Script (node) | Host-only (gate on clients) | Player input (verb) | Hook | Client sees |
|---|---|---|---|---|
| `bottom_maw.gd` (World/BottomMaw) | sink `_on_body_entered` :128 for every body except the local player; `_handle_body_cleanup` :278 and `_recycle` :315 for non-player bodies | — | ext | The puppet despawns ~3 s later (`ents.dp`). `fx maw {type,pos}` (host wraps `maw_effect` :375) → client `maw_effect(type,pos)` in apply scope. Local player falling in: super runs (respawn, `show_death`, tube wobble); its local `spend(_maw_fine())` is reverted by the money clamp and the client sends `penalty{kind:"maw"}` (6.8). |
| `hole.gd` (Floor) | sink `_check_phase_completion` :228, `_trigger_ending` :251 (MP1 `hole_ext`, kept); `_on_product_consumed` :167 no longer fires on clients | — | ext (MP1 file, BODIES) | `hole` message (MP1): `target_radius`, `phase_nutrition_total`. |
| `press.gd` (fixture `press`) | sink `process_crushed_items` :119 (client keeps only the player branch: `release_held_object` + `respawn_safe`, P7), sink `_spawn_pending_anomalies` :202, `replace_with_flat_product` :238 | input `interact` :52 → `press` | ext | meta `is_pressing` rising edge → replay `start_pressing` :82 (tween + audio; its crush callback is the gated function above). Flat ducks arrive as entities with `is_flattened`. |
| `gambling_terminal.gd` (fixture `trading_terminal`) | sink `_on_collector_body_entered` :321, `_collect` :343, `_sweep` :293, `_arc_to_intake` :405, `_bank_and_despawn` :442, `_despawn` :468, `_do_roll_or_stop` :145, `_resolve` :191, `_spawn_recycle_cube` :716, `sweep_tools_all` :736 | via `terminal_control.gd` (separate ext): input `interact` :18 → `sweep_products`/`sweep_tools`/`roll` (by its `Action`), input `hold_complete` :87 → `sweep_all`; `hold_progress`/`hold_cancel` stay local (cosmetic bar) | ext ×2 | Arcing bodies stream normally (they are host tweens). Meta `{rolling, roll_mult, result_text}` → the terminal's label refresh in apply scope. `bank` from the econ mirror (`bank_updated` → `_on_bank_updated` :594). The recycle cube is a normal entity. |
| `golden_duck_statue.gd` (toy) | sink `_on_bless_body_entered` :191 (writes `money.add_int` directly, :209) | input `interact` :376 → `pet` (also writes money, :388) | ext | `fx statue_bless {eid, amount}` → `_spawn_bless_text`, `_play_sparkle_burst`; `fx statue_pet` → `_spawn_pet_text`, `_triumphant_quack`. Money from econ. |
| `ore_processor.gd` | sink `_on_intake_body_entered` :86, `_process_ore` :96, `_process_pickaxe` :116, `_drop_at_output` :168, `place_lamp_at_output` :191, `reconcile_lost_ore` :265 (also skipped in `_on_save_loaded` :245 on clients) | — | ext | `mining_bank` from the econ mirror, then `_update_labels` in apply scope. |
| `mining_ore.gd` | sink `recover_to_home` :135 (writes `mining_bank`, :146) | — | ext | — |
| `minable_block.gd` | sink `take_hit` :129, `_on_impact_area_body_entered` :146, `_break_block` :205, `_spawn_ore` :255 | (hits come from the pickaxe, host exec) | ext | meta `{hp, broken}` → replay `apply_saved_state` :302 / `_update_crack_visuals` :187; fx `block_hit` → `_play_hit`. |
| `erasable_text.gd` | sink `_award_clean` :498 | — | ext | Scrubbing stays local (the holder's sponge paints the holder's own copy; cosmetic). Meta `fully_erased` → `_apply_fully_erased` :490. |
| `camera_pivot.gd` (fixture bodies) | sink `_integrate_forces` :35 break detection, `destroy_camera` :84 (`spend(100)`, `BAD`) — replay on clients | — | ext (must be applied in the loader's `_init`: the script loads with main_menu.tscn, world-physics §7 #19) | meta `destroyed` → replay `apply_saved_state` :112; `fx ach BAD`. |
| `fail_safe.gd` (FailSafe 1-4) | sink `_on_body_entered` :7 for every body except the local player | — | ext | Recovered tools reappear at the tube via frames (`SNAP`). Local player: super (respawn); local `spend(1)` reverted by the clamp; `penalty{kind:"fail_safe"}`. |
| `hud.gd` | host: `_spawn_special_bonus_text` :446 → after super, `fx bonus_text {text,color}` to all; client: `show_result` :649 runs (its `add_bonus` is reverted by the clamp) | — | ext | Combo results and bonus texts (6.9). |
| `basketball_hoop.gd` (toy) | sink `_on_rim_body_entered` :113, `_on_product_consumed` :143, `_award_dunk_bonus` :167 | — | ext | `fx bonus_text`. |
| `speed_radar.gd` (toy, equipable) | sink `_on_detection_body_entered` :143, `_on_product_consumed` :189, `_award_speeding_bonus` :213 | — | ext | meta `{last_speed}` → `_update_label`; `fx radar_flash` → `_trigger_flash`. |
| `spring_pad.gd` (+`spring_pad_2.gd` extends it by path) | sink `_register_bonus_ticket` :606, `_on_product_consumed` :641, `_award_launch_bonus` :681 | — | ext (spring_pad.gd only) | `_on_launch_body_entered` :195 keeps running: puppets are inert, `_launch_player` :328 launches the local player (D10), squash/text are local cosmetics. |
| `golf_club.gd` (toy, equipable) | sink `_fire_shot` :279, `_on_product_consumed` :946, `_award_hole_in_one_delayed` :982 | input (in its own `_input` :161) shot → `tool_in golf_shot {power, aim}` | ext | Host runs `_fire_shot` on its rig copy; host override of `_get_camera` :1084 returns the rig during host exec. |
| `upgradeUI.gd` | purchases: MP1 rewire kept; `_spawn_tool_instance` :1804 and `_spawn_toy_instance` :1863 run on the host only (client: only in apply scope for `fixture_spawn`); `_recall_tool` :2389 → command; host `_unit_owned_elsewhere` :2444 also true for bodies owned by a remote peer | buy rows (MP1) | ext (MP1 file, GAMEPLAY) | The bought item appears for everyone as an entity (or as a fixture through `fixture_spawn`). |

### 4.3 Products, crates and other self-destructing bodies

| Script | Host-only | Hook | Client sees |
|---|---|---|---|
| `duck.gd`, `lucky_duck.gd`, `flat_duck.gd`, `flat_duck_luck.gd` | nothing (audio only in `_on_body_entered`) | — | Puppet; `is_flattened` meta → `flatten_mesh_world_y` :30. |
| `pinata.gd` | sink `_process_impact_deferred` :101, `_burst` :159, `_spawn_candies` :303, `on_whacked` :503 | ext | `fx pinata_burst {eid}` → `_spawn_burst_effects` :232 just before the despawn (same ch3 batch, fx first). |
| `cash_register.gd` | sink `_drain_value` :197 (also reached from `_process` :89), `_on_depleted` :216, `on_whacked` :410 | ext | meta `value` → `_update_value_label`; `fx register_depleted` → `_spawn_destroy_effect` :230. |
| `candy.gd` | sink `_expire` :228 | ext | `fx candy_expire` → `_spawn_expire_effects` :249; decay tint runs locally from the local clock (cosmetic); meta `tint_color`. |
| `anomaly.gd` | sink `_process_impact_deferred` :260; `_apply_random_impulse` :232, `_apply_repulsion` :295, `_apply_aoe_shockwave` :325 are force writers (inert on puppets; (verify) that the shockwave never targets the player, else it becomes a D10 local branch) | ext | meta `grade`, `crude_source` → `set_crude_source` :621 then `set_grade` :527. |
| `wodd_crate.gd` (`class_name GamblingCrate`; `metal_crate.gd`, `plush_crate.gd`, `anomaly_crate.gd` extend it) | sink `_on_body_entered` :145 (damage), `break_crate` :191, `_spawn_loot` :564, `_spawn_products` :618, `_spawn_tool` :660, `_apply_buff` :710, `on_whacked` :916 | ext on `wodd_crate.gd`; spike S-M3 confirms the take-over reaches the three subclasses through the class_name (else one ext per subclass) | `fx crate_break {eid, rarity, buff}` → `_spawn_break_effects` :458, `_spawn_floating_rarity_text` :387, `_spawn_floating_buff_text` :724; loot arrives as entities; buffs from the mirror (6.10). |
| `recycle_cube.gd` | nothing (the maw pays its `recycle_value` meta on the host) | — | Puppet. |
| `debris.gd` | sink `_on_body_entered` :198, `_destroy_tool` :295, `_respawn_tool_via_tube` :328 | ext | Client-spawned debris is recycled by the stray guard; host debris arrives as puppets; `fx debris_hit` → `_spawn_destruction_effect` :371, `_apply_landing_shake` :415 (local camera shake if near). |
| `keycard.gd`, `mining_ore.gd` (except above), `box*.gd`, `crate.gd`, `cushion.gd`, `panel.gd`, `panel2.gd`, `sponge.gd` | nothing (cushion groups and sponge paint are local) | — | Puppets. Panels: `panel_state` meta + `_rebuild_merge_group` (`slick_panel.gd` :509) as the load path does. |

### 4.4 Production

| Script | Host-only | Player input (verb) | Hook | Client sees |
|---|---|---|---|---|
| `workbench.gd` (World/ManualDuckWorkbench) | sink `craft_item` :241 | input `start_crafting` :62 → `craft_start`, input `stop_crafting` :80 → `craft_stop` (both reached from `interact_ray.handle_workbench_interaction` :468 / `_stop_crafting_if_manual` :486) | ext | meta `{is_crafting, craft_progress}` at 10 Hz while crafting; the client's `_process` :96 advances the bar between updates; HUD `WorkbenchProgress` from the local copy. Host keeps a **holder set** per bench: `stop_crafting` runs only when the last holder releases (host's own player included). |
| `manual_cash_workbench.gd` | sink `_do_full_piston_sequence` :375, `_on_piston_reached_top` :403, `_spawn_cash_register` :423 | input `interact` :115, `start_crafting` :120, `stop_crafting` :154 | ext | meta `{is_crafting, progress, stage}` → `_show_stage` :342 in apply scope. |
| `manual_pinata_workbench.gd` | sink `_spawn_pinata` :657 (and its sequence functions, same pattern) | input start/stop | ext | same |
| `automatic_duck_workbench.gd` | sink `craft_item` :343; `start_crafting` :102 from its own `_process` :137 timer is machine-originated → blocked on clients | input `turn_on` :77 / `turn_off` :89 (from `handle_automated_workbench_interaction` :494) → `toggle` | ext | meta `{is_turned_on, is_crafting, progress}`; products appear as entities at the bench's spawn point with the host's launch velocity. |
| `automatic_cash_workbench.gd` | sink `_do_full_piston_sequence` :512, `_on_piston_reached_top` :540, `_spawn_cash_register` :567 | input `turn_on` :150 / `turn_off` :166 | ext | meta `{is_turned_on, stage}` → `_show_stage` :475. |
| `automatic_pinata_workbench.gd` | sink `_spawn_pinata` :716 (+ sequence) | input turn_on/turn_off | ext | same |
| `anomaly_workbench.gd` (cauldron) | sink `_on_body_entered` :817, `_register_ingredient` :833, `_on_body_exited` :890, `_rescan_intake` :761, `_start_ritual` :983, `_complete_ritual` :489, `_abort_ritual` :562, `_refuse_ingredient` :723, `_spiral_suction_ingredient` :1210, `_spawn_effigy` :1493, `_spawn_keycard` :1580, `_eject_pickaxe` :1619, `_freeze_pickaxe_catalyst` :1737 | input `interact` :427, `start_crafting` :449, `stop_crafting` :462, `scroll_tune_up` :1758 / `scroll_tune_down` :1762 → `tune_up`/`tune_down` | ext | meta `{duck, crown, bear counts, ritualizing, min_purity, cooldown}` → `_set_count_label` :1427, `_update_indicator` :1400, `_reveal_black_sphere`/`_collapse_black_sphere` (replay). Ingredients are pulled by the host (streamed). |
| `proxy_intern.gd` (tool) | sink `_latch` :151, `_unlatch` :159, `_drive_target` :176 | input `interact` :194; replay `remote_toggle` :200 | ext | `is_active` meta. |
| `shift_scheduler.gd` (tool) | sink `_tick_schedule` :190, `_press_target` :241, `_apply_state` :254 | input `interact` :278, `scroll_tune_up/down/cycle` :314/:323/:335; replay `remote_toggle` :295 | ext | scheduler meta → `_update_screen`/`_refresh`. |
| `workbench_spawning.gd` (autoload) | benches spawn identically on every peer (phase, snapshot, `auto_machine_purchased`, MP1 §6.3) | — | — | Same fixtures everywhere (static ids). |

### 4.5 Machines and tools (force writers)

| Script | Force writers | Host-only (gate) | Player input / replay | Hook | Client sees |
|---|---|---|---|---|---|
| `fan.gd` (fan, fan2) | `_physics_process` :57 impulses + random torque; player `apply_external_force` | — (inert; player branch local) | input `toggle_fan` :127, `interact` :132; replay `remote_toggle` :313 | ext | `is_active` → `update_fan_state` :137. |
| `fan_3.gd` | `_physics_process` :103 | sink `_apply_zero_g` :187, `_tick_zero_g` :222, `_restore_gravity` :248, `_flush_all_zero_g` :269 (they write `gravity_scale` on bodies) | input `toggle_fan` :284, `interact` :289; replay `remote_toggle` :307 | ext | same. |
| `magnet.gd` / `magnet_2.gd` | `_physics_process` :45 / :160 | — | input `toggle_magnet` :120, `interact` :205, magnet_2 `scroll_tune_up/down` :188/:194, `flip_mode` :200; replay `remote_toggle` :244 | ext ×2 | `is_active`, `is_repelling` → `flip_mode`. |
| `gravity_inverter.gd` | `_apply_field_forces` :194; `_apply_player_force` :210 (local player, D10) | — | input `toggle_field` :241, `interact` :263; replay `remote_toggle` :267 | ext | `is_active` → `_apply_visual_state` :290. |
| `tractor_beam.gd` | `_update_pull` :141; `_apply_player_pull` :242 (local, D10) | — | input `equipped_lmb_pressed/released`, `equipped_rmb_pressed` :285/:289/:293 → `tool_in`, `toggle_beam` :302, `interact` :309; replay `remote_toggle` :313 | ext | `is_active` → replay `_activate`/`_deactivate` :323/:336. |
| `vacuum.gd` / `vacuum_2.gd` | `_apply_suction_forces` :314 | sink `_check_ingestion` :340, `_ingest` :373, `_release_one` :424, `_release_all` :482, `_force_clear_bag` :854 | input `equipped_lmb_pressed/released`, `equipped_rmb_pressed` :591/:599/:604 → `tool_in`, `toggle_vacuum` :545, `interact` :563, vacuum_2 `scroll_tune_*` :176/:180, `cycle_filter` :184; replay `remote_toggle` :568 / :159 | ext ×2 | `is_active`, `bag_count`; ingested bodies become `HIDDEN`. The holder's bag gauge reads the local (empty) bag: approximate (limitation). |
| `orbit_tool.gd` | `_apply_angular_repulsion` :422, `_apply_lift_force` :919 | sink `_try_capture` :234, `_capture_sweep` :288, `_capture_body` :299, `_write_orbit_position` :395 (writes body transforms), `_check_for_releases` :454, `_release_at_index` :516, `_release_all` :588, `_drop_maw_claimed_body` :939 | input `interact` :609, `toggle_orbit` :613; replay `remote_toggle` :627 | ext | Orbiting bodies stream normally. |
| `roomba.gd` | self-drive `_apply_force_to` :495 etc. | — (inert) | input `interact` :580; replay `remote_toggle` :595 | ext | `is_active`; the roomba is a puppet. |
| `qa_arm.gd` | `_whack` :424 sets velocities, `_drive_bat` :495 | client: sink `_physics_process` :164 (the state machine), `_fire` :283, `_whack` :424; host ext: `_is_valid_target` :366 also accepts ghosts, `_whack(ghost)` → `pimp` with `player_bonk_impulse`/`player_bonk_lift` + `record_safety_violation` (P7 exception: the game's own player branch at :436-447) | input `interact` :532, `toggle_arm` :536; replay `remote_toggle` :546 | ext | meta `{state, yaw, bat_xform}` at 15 Hz while not OFF → turret and bat poses set in apply scope. |
| `piston.gd` (+ `piston_2.gd`, `piston_3.gd` by path) | `_drive_pusher` :194 (kinematic, deterministic) | sink `_scan_for_riders` :456, `_adopt_rider` :509, `_release_rider` :548, `release_all_riders` :583, `release_rider_body` :594 | input `interact` :285, `toggle_piston` :289, piston_2 `scroll_tune_up/down` :114/:120, `cycle_preset` :127; replay `remote_toggle` :294, `apply_piston_save_data` :648, `set_preset` :143; piston_3 (review round 2) input `scroll_tune_up/down` :277/:281 (no super: own ext), replay `cycle_weight_preset` / `set_weight_preset` :285/:297, meta `wpreset`; clients count puppets in `_compute_front_mass` :222 | ext ×3 | The client's `_physics_process` :152 advances the phase locally (deterministic); `piston` meta at 10 Hz while active corrects it. The pusher pushes the local player (D10). |
| `cannon.gd` (+ `cannon_2.gd`) | `fire` :362 spread + impulse; recoil on the player when equipped (:424) | sink `_on_intake_body_entered` :265, `_try_auto_load` :280, `_load_body` :318, `fire` :362, `_force_clear_queue` :1228 (cannon_2 `_process` :122 auto-fire reaches `fire`, blocked) | input `interact` :509 → `fire`; replay `remote_toggle` :517 / `remote_pulse` :523 | ext | `queue_count`; fired bodies unhide with `SNAP`; `fx cannon_fire` → `_trigger_muzzle_flash` :449, `_emit_smoke` :484. Recoil for a remote owner goes through `PlayerEffectRedirect` (6.6). |
| `spring_pad.gd` / `spring_pad_2.gd` | `_apply_launch` :282 sets velocity | economy part in 4.2 | — | (4.2) | Inert on puppets; player launch local. |
| `bumper.gd` (toy) | `_on_bumper_body_entered` :143 | — | — | — | Inert on puppets; `_bounce_player` :449 local; `_do_pop` cosmetic. |
| `disco_ball.gd` (toy) | `_fire_beat` :238 | — | input `interact` :288 | ext | `is_active`. |
| `portal.gd` (+ `PortalPairManager`, autoload) | `_teleport_rigid_body` / `_teleport_character_body` (portal_pair_manager.gd:303/:333) | client: sink `_do_teleport(body)` :356 unless `body` is the local player; host: after super, mark the eid `SNAP` | — (placement via GRAB) | ext | Teleported bodies `SNAP`. The local player uses its own portal copies (D10). |
| `broom.gd` | `interact` :136 sweep impulses | — on clients (inert); host runs it for a remote holder via `tool_in` | input (equipped) `interact` → `tool_in sweep` | ext | Trajectory preview stays local. |
| `pickaxe.gd` (fixture body) | `_resolve_hit` :123, `_break_tool` :162 | sink `_resolve_hit`, `_break_tool`, `upgrade_tier` :206; replay `_apply_tier_visual` :225 | input_predict `equipped_lmb_pressed` :104 / `equipped_lmb_held` :119 → `tool_in` (local swing animation plays) | ext | Tier meta; block state (4.2). |
| `remote.gd` (tool) | — | sink `_toggle_channel` :165, `_toggle_all_channels` :173, `try_link_tool` :193, `unlink_tool` :217, `unlink_all` :229 | input `remote_lmb_pressed` :131, `cycle_channel` :139, `try_interact_with_target` :151 (arg: target eid) → `tool_in`; replay `remote_toggle` :427 | ext | Channel states + links from the mirror (6.10) → `_update_all_antenna_visuals`. |
| `feed_camera.gd` / `feed_screen.gd` | — | host-only id: `_ensure_id` :127 runs only on the host; (verify) `CameraFeedManager` re-keys a camera whose `camera_id` is changed by the meta apply | input `feed_screen.interact` :218 → `cycle` | ext ×2 | `camera_id`, `watched_camera_id` meta → `_set_camera` :165; rendering local. |
| `stat_sign.gd` (toy) | — | — | input `interact` :423 → `page` | ext | `stat_index`; pages read mirrored stats. |
| `slick_panel.gd` | `_create_merge_body_for_group` :434 (derived, local) | — | — | — | Rebuilt from `panel_state` meta. |
| `main_camera.gd` | carry/throw velocity writes | see 5 (GRAB) and 6.11 (panel rack) | — | ext ×2 | — |

### 4.6 World puzzles, security and progression fixtures

| Script | Host-only | Player input / replay | Hook | Client sees |
|---|---|---|---|---|
| `vertical_gate.gd` (3 gates) | replay `solve` :51 (it calls `Steamworks.on_gate_opened` and queues the world notification locally: that is wanted on every peer) | — | ext | meta `solved` rising edge → replay `solve()` (animated); late join: `apply_saved_state(true)` :135. |
| `gate_shutters.gd` | sink `_on_fuse_slot_body_entered` :22 | replay `apply_shutters_saved_state` :105 | ext | meta `slots` → replay. Fuses are fixture bodies (grabbable through GRAB). |
| `gate_power_generator.gd` | sink `_on_intake_body_entered` :59, `_physics_process` :41 (overlap polling), `_trigger_power_up` :151 | replay `apply_generator_saved_state` :196 | ext | meta `{accumulated_value, activated}`. |
| `gate_weight_plate.gd` | sink `_physics_process` :39 (solve trigger); host ext `_recalculate_mass` :79 adds 8.0 per ghost on the plate (D18, spike S-M7 pins the field it writes) | — | ext | Gate opening via `vertical_gate`. |
| `fuse.gd` (fixture bodies) | `_on_loading` :124, `_snap_to_slot` :155, `_reset_to_base` :136 run on the host | — | — | Fixture-body puppets. |
| `card_reader.gd` | sink `_on_intake_body_entered` :48 | — | ext | `keypad_revealed` mirror → `call_group("security_keypad","reveal")` in apply scope; `fx ach SECRET`. |
| `security_keypad.gd` | sink `button_pressed` :79, `_on_success` :104, `_on_fail` :125 | — | ext | meta `entry` → `_refresh_label` :147; success → `fx hack_success` (D15). |
| `keypad_button.gd` | — | input `interact` :37 → `key {value}` | ext | `_press_anim` :46 plays locally (input_predict). |
| `elevator.gd` | replay `on_hack_success` :328 (→ `_run_escape_ride` :362, `_halt_facility` :438) | — | ext | `fx hack_success` → every peer runs `on_hack_success()` in apply scope; its own player rides; the session goes to `ending` (D15). |
| `security_room.gd` | per-peer cinematic (local) | — | — | — |
| `loop_puzzle.gd` | sink `on_button` :476 (and so `_buy_clone`/`_upgrade_speed`/`_upgrade_energy`), `_set_new_best` :398, `_check_win` :549, `_solve` :557, `_reset_object` :302 (bodies); `_on_start_entered` :243 / `_on_end_entered` :255 / the run sampling stay local for the local player | client run end → `interact loop_run {time, path}` (host checks `time ≥ 0.5 × best` and path size ≤ 4096, then `_set_new_best`) | ext | `get_save_state` :629 → meta at 1 Hz on change → replay `apply_save_state` :641. |
| `loop_button.gd` | — | input `interact` :49 → `loop_button {action}` | ext | `_press_anim` local. |
| `uv_lamp.gd`, `torch_light.gd` (fixture bodies) | sink `interact` :77 / :23 (unlock flags, `INVISIBLE`, notification, `queue_free`) | input `collect_on_grab` :117 / :74 → `collect` | ext ×2 | Flags from the mirror; meta `collected` hides the node; `fx notify {key}`, `fx ach INVISIBLE`. |
| `interdiction_area_3d.gd` | — (D19 local) | — | — | Local countdown/alarm. |
| `bowling_pin_set.gd` (fixture `bowling_set`) + `pin.gd` | sink `_spawn_pins` :234 (replay on clients for a new `gen`), `_despawn_pins` :287 (replay), `_check_pin_states` :302, `_register_knockdown` :397, `_update_multiplier` :435, `_push_multiplier` :474 | — | ext | meta `{gen, multiplier}`; pins are fixture bodies `bowling:pin:<gen>:<i>`; `fx bowling_text` → `_spawn_bowling_label` :502. |

### 4.7 Autoload-owned writers (BLOCKED from extension) and cosmetic-only scripts

| Script | Writer | Handling |
|---|---|---|
| `game_progression.gd` | debris `_spawn_debris_chunk` :756, `_spawn_phase4_debris` :1104; `setup_new_game` :177 (starter crates, never on clients: they load a snapshot); ending suction `_physics_process` :1267, `_rescan_suction_bodies` :1346, `_detach_as_rigidbody` :1490, `on_player_consumed` :1373 | Client debris → stray guard. Ending → D16 (replication stops, local ending). |
| `game_state.gd` | `dump_panel_stack` :1130 (spawns panels) | Client spawn → stray guard; the rack goes through 6.11. |
| `combo_system.gd` | `add_to_combo` :155 (called only by the host maw now; unlocks MORE/EXTRA/MEGA :168-174) | node: client `ComboSystem.set_physics_process(false)` while in a session; mirror (6.9); `fx ach` for MORE/EXTRA/MEGA. |
| `portal_pair_manager.gd` | teleports | Gated at `portal._do_teleport` (4.5). |
| `object_pool_manager.gd` | `recycle_all_active` :614 (credits/ending) | Local ending (D16). |
| `workbench_spawning.gd`, `unlock_manager.gd` | benches, unlocks | MP1 handling (identical benches; detached UnlockManager). |
| `black_hole.gd`, `test_black_hole.gd`, `stream_spawner.gd`, `product_stream.gd`, `falling_object*.gd`, `tool_tube.gd`, `alarm_light.gd`, `uv_code.gd`, `uv_graffiti.gd`, `uv_light.gd`, `maw_hit_effect.gd`, `megastructure_corridor.gd`, `observatory_window.gd`, `fall_sequence.gd`, `sphere.gd`, `draggable.gd` | cosmetic, test-only or unused | Nothing. |

---

## 5. MP2b: grab ownership (STREAM GRAB)

### 5.1 Ownership table (host-authoritative, `grab/ownership_host.gd`)

`eid → {owner_peer, kind: "" | "held" | "equipped", epoch: int (u16, wraps), since_ms, last_rx_ms}`.
Default: owner 1 (host), kind `""`, epoch 0. Every change increments `epoch`, is pushed to BODIES with
`set_owner_view(eid, owner, kind, epoch)` and is broadcast as `own {ev:"set"}` to the other in-game peers.
The host's own player is peer 1: a host grab sets `{1, "held"}` so clients see `HELD` and do not try.

### 5.2 Client grab with prediction (`extensions/grab/main_camera_grab_ext.gd`, `grab/ownership_client.gd`)

1. `main_camera._begin_carry(obj, keep_hands)` (:693) on a client, for a replicated `obj` (`pitt_mp_puppet`
   meta, fixture bodies included):
   - **Local refusal** (no request, `super` not called, the game's pick simply does not happen): the eid's
     last known `own` is another peer, or its flags carry `HELD`, or its meta says `in_cannon_barrel`,
     `in_vacuum_bag`, `consumed`, `pending_maw_recycle` or group `terminal_pull`.
   - Otherwise **predict**: `bodies.set_local_sim(eid, true)`, `super(obj, keep_hands)` (the game's carry runs
     unchanged: joint, gravity/inertia metas, velocity carry), and send `own_req {eid, seen_epoch}` (ch3).
2. **Host** on `own_req` (`can_take(eid, peer)`): deny with a reason when the eid is unknown or despawned,
   already owned (`owned`), its node carries any metas above (`busy`), the requester is not `in_game`, has
   no avatar pose yet (`no_pose`) or is farther than `max_grab_distance + 2 m` (`far`; avatar pose vs
   body), or any GAMEPLAY deny rule says so
   (cannon queue, vacuum bag, terminal arc, press stroke, cauldron ritual). Otherwise grant:
   `epoch += 1`, owner = peer, kind `held`, `bodies.host_follow(eid, peer)` (the host body becomes a
   kinematic follower), reply `own {ev:"grant", eid, epoch}`, broadcast `set`.
3. **Deny** on the client: if still carrying it, `main_camera.release_held_object()` (:982, the game's safe
   drop) with a GRAB flag so the release path below does not send `own_rel`; then
   `bodies.set_local_sim(eid, false, host_epoch)` (snap or blend back to the host pose).
4. **Held stream** (owner → host): while `picked_object == obj`, at 30 Hz, frame kind 5 on ch2 with the
   exact local state and the granted epoch. Before the grant arrives, frames carry epoch 0; the host
   accepts them from the owner while its grant is unacknowledged (counted `held_early`), so the host copy
   follows from the first frame instead of hanging one RTT and then jumping. The host feeds valid frames
   (sender = owner, epoch = current or that epoch 0, position within the held reach of the sender's eye:
   `2 × max_grab_distance + 1 m + |avatar velocity| × 0.15 s`, at most 9 m) to `bodies.host_follow_push`,
   which drives the kinematic follower 50 ms behind (not 100: the host copy interacts with the host world).
   Invalid frames are counted (`held_rejected`); 1.0 s of continuous distance violations revokes (`far`).
5. **Other clients** see the body through normal host frames with `HELD` (priority weight 4.0).

### 5.3 Release and throw handoff

- **Detection** (client): GRAB's `_physics_process` (priority 99, after `main_camera` at default 0) diffs
  `main_camera.picked_object`. `drop_object` (:735) is also wrapped to mark a plain drop; a throw is the
  inline rMouse block in `handle_input` (:568-617), detected by the diff plus the fresh `player_throw_time`
  meta (products) or a velocity jump > 2 m/s (anything else). Equip (`equipped_item` set) is not a release
  (5.5).
- **State capture**: on the **next** physics frame after the release (the throw impulse and torque are then
  integrated), read `{p, q, l, a}`, `placed`/`panel_state` (the game called `place()` deferred on drop),
  and for products `player_throw_time` (sent as age in ms) and `player_throw_position`.
- Client → host `own_rel {eid, epoch, s, thrown, placed, panel_state?, throw_meta?}` on ch3. The client
  keeps simulating its copy dynamically, then calls `bodies.set_local_sim(eid, false, epoch + 1)`: the body
  returns to puppet mode once the render time passes the first host record with the new epoch (3.4
  `local_sim`: drawn ahead by a fading lead, then a 150 ms blend).
- **Host** on `own_rel` (owner and epoch must match, else ignored): `bodies.host_release(eid, s)` (exact
  pose and velocities, `freeze = false`, dynamic again, woken), restore throw metas (`player_throw_time =
  now − age`, so long-range feed stats count), if `placed` call `place()` in host exec (sticky tools may
  decide differently on the host: the host result wins through meta), `panel_state` likewise; `epoch += 1`,
  owner = host, kind `""`, boost 2 s, broadcast `set`.
- A release that races the grant (`own_req` then `own_rel` before the grant arrived) is processed in order
  on the host because ch3 is ordered: grant, then release. If the request was denied, the `own_rel` epoch
  does not match and is ignored; the client already reverts on the deny.

### 5.4 Revocation, timeouts and disconnect

| Trigger (host) | Action |
|---|---|
| No held frame from the owner for 1.5 s (`held`) | revoke `silence`: `host_release(eid, last_state)`, epoch+1, `own {ev:"revoke"}` to the owner. A host-originated grant (rack withdraw) gets 1 s more; a `silence` or `far` revoke of a grant that never got a held frame is also counted `grant_never_carried` (a `rack` store of a fresh grant, the busy client re-racking, is not) |
| No packet of any kind from the owner for 0.5 s while its frames are silent (the link stalled, not the carry) | no revoke: the hold is frozen (the follower keeps its last state, no far check, `link_stalls`); the silence clock restarts when the link does. The Session's own 15 s peer timeout ends it as `left` |
| Owner disconnects / leaves | revoke every eid they own; equipped tools are unequipped at the owner's last avatar pose (6.4) |
| The body is consumed / starts a maw recycle / enters a cannon, vacuum, terminal arc, press stroke, cauldron | GAMEPLAY calls `grab.revoke(eid, reason)` (the game's own code already ran on the host) |
| The entity despawns | ownership row deleted; the client hears `entity_removed` and drops the carry |
| The last accepted held state (not the follower node) is beyond the held reach of the owner's eye (5.2 step 4), or its frames are, for 1.0 s | revoke `far`; nothing is measured before the first held frame |
| Client opens a menu | the MP1 pause guard calls `release_held_object()` → normal release |

On `own {ev:"revoke"}` the client force-drops with `release_held_object()` (no `own_rel`) and blends back.

### 5.5 Equip handoff (protocol owned by GRAB; host-side effect owned by GAMEPLAY)

- Client: GRAB's diff sees `equipped_item` become a body it holds → `own_equip {eid, epoch}`; the body stays
  `local_sim` (the game reparents it under the client camera). Host: kind `equipped`, epoch+1,
  `owner_changed(eid, peer, "equipped", epoch)` → GAMEPLAY puts the host copy on that peer's rig (6.4);
  BODIES flags it `NOCOLLIDE`.
- Unequip on the client (`unequip()` makes it `picked_object` again): `own_unequip {eid, epoch, drop, s}` →
  host kind `held` (GAMEPLAY takes it off the rig and calls `unequip(current_scene, drop)` in host exec), the
  held stream resumes.
- Host player equips: kind `equipped` owner 1, nothing else (it is the host's own camera).

### 5.6 Host-side refusal for the host player

`main_camera_grab_ext._begin_carry` on the host: if `owner_of(eid)` is a remote peer → do not call `super`
(the host cannot grab what a client holds); else set `{1, "held"}` and call `super`. Host releases mark
`{1, ""}`.

---

## 6. MP2c: tools, machines and interactions (STREAM GAMEPLAY)

### 6.1 Purchases: one shared world copy

- Client purchase flow is MP1 §6.5 unchanged up to the host handler. `host_buy_tool` / `host_buy_toy` now
  call the **host's own** `upgradeUI._spawn_tool_instance(tool, level)` / `_spawn_toy_instance(toy)` (via
  `gameplay_adapter.upgrade_ui()`; the same row lambdas' side effects as MP1: `spend`, `purchased_once`,
  `check_consumerism`, crate escalation). The pooled item becomes an entity and appears for everyone.
- Fixtures (`press`, `trading`, `bowling_pin_set`): the host spawns the scene instance; GAMEPLAY broadcasts
  `fixture_spawn {key, level}` and every client runs the same `_spawn_tool_instance` /
  `_spawn_toy_instance` on its own terminal in apply scope (the client's `SaveManager` in-flight flags behave as
  in single player). Late joiners get them from the kept snapshot flags (3.8).
- Recall rows (`recall_mode`): `PittMultiplayer.recall {tool}` → host `_recall_tool(tool)` (:2389). The host
  extension of `_unit_owned_elsewhere` (:2444) returns true for units owned by a remote peer, so a friend's
  held tool is not yanked.
- Test: "client buys a tool and host sees it" (11.2 P2).

### 6.2 `world.interact` (`gameplay/interact_client.gd`, `gameplay/interact_host.gd`)

- Client gate `input(node, verb, arg)` resolves the node's eid (pooled or static id; a child collider walks up
  to the nearest tracked ancestor), adds `aim` (local camera origin and forward), sends `interact`, plays the
  game's local feedback where the extension marks it `input_predict` (button press animations, interact
  audio is played by `main_camera._do_interact` anyway), and returns.
- Host: validate (sender in game; eid tracked; sender's avatar within 4.5 m of the node, or 6 m for the
  terminal and benches; verb in the per-script whitelist of section 4; 20/s), then call the mapped method on
  the host node inside host exec (6.6). Unknown verbs are dropped and counted.
- Hold-to-use: `craft_start`/`craft_stop` maintain the bench holder set (4.4); `sweep_all` is sent once on
  `hold_complete` (the hold bar is local).
- After a successful verb: `bodies.meta_dirty(eid)` and `bodies.boost(eid, 2)`.

### 6.3 Remote camera rigs (`gameplay/rigs.gd`, host only)

One `Camera3D` (`current = false`) per remote in-game peer under `/root/World/PittMP_Rigs/<slot>`, posed
every physics frame from that peer's newest avatar frame **extrapolated to now** (not the 100 ms-delayed
render pose): position + the host player's own `CameraPivot` local offset (read once), yaw from the frame,
pitch from the frame's pitch. A `tool_in`/`interact` carrying `aim` snaps the rig to the exact aim before the
call.

### 6.4 Equipped tools on remote players

- On `owner_changed(eid, P, "equipped")` the host calls `node.equip(rig_P)` in host exec: the game's own equip
  zeroes collision and reparents the tool under the rig. Each frame `rigs.gd` sets the tool's local transform
  the way `main_camera.update_equipped_item_properties` does for the local camera: the hard-coded poses of
  the groups `broom`, `fan`, `remote`, `golf_club`, then `equipped_offset`/`equipped_rotation_deg` (0.2.2:
  before, the broom kept `equip()`'s built-in -90 degree yaw on a rig, so its push axis, `basis.z`, and its
  sweep area pointed to the player's left).
- Operator feedback of a tool on a rig is not drawn on the host (0.2.2): the broom's outlines and trajectory
  (`_update_preview`), the cannon's trajectory (`_should_show_trajectory`) and the golf club's ball
  indicator (`_process_idle`); the club on a rig also ignores the host player's mouse (`_input`).
- Every other peer (host included) therefore sees the **real tool entity** floating at P's hands: the host
  streams its pose like any body, flagged `NOCOLLIDE`. This is the "equipped proxy on the puppet" with no
  extra model and no dependency on `puppet.gd`.
- P itself sees its local copy under its own camera (local_sim, game code).
- `tool_in {eid, verb}` from P (only for a tool P has equipped) → host calls the duck-typed method on the
  rig copy: `equipped_lmb_pressed`, `equipped_lmb_released`, `equipped_lmb_held` (sent at 10 Hz while held),
  `equipped_rmb_pressed`, `interact`, `remote_lmb_pressed`, `cycle_channel(±1)`,
  `try_interact_with_target(node_of(arg))`, `golf_shot` (→ `_fire_shot`), `scroll_tune_up/down`.
  Continuous effects (vacuum suction, tractor pull, fan blowing while equipped) then run in the tool's own
  `_physics_process` on the host, aimed by the rig.
- On P's machine the same input runs `super` for feedback (spool sound, beam visual, swing) while the
  mutators are gated (section 4), so P sees the authoritative effect one RTT later.
- Spike S-M6 checks each equipable tool's aim source: tools using `get_parent()` (pickaxe `_resolve_hit`) or
  their own muzzle transform work on a rig; tools using `get_viewport().get_camera_3d()` get a host override
  returning the rig during host exec (golf `_get_camera`), otherwise they are listed as limitations.

### 6.5 Ghost colliders for remote players (`gameplay/ghosts.gd`, host only)

- One `AnimatableBody3D` per remote in-game peer: capsule r 0.35, h 1.8; `collision_layer` = the player layer
  (bit value 2), `collision_mask = 0`; groups `pitt_mp_ghost` and `maw_inert` (the maw skips it, bottom_maw.gd
  :129); meta `pitt_mp_ghost_peer`; **never** in group `player` (R1); collision exception with the host's
  PlayerController (players pass through each other, D22).
- Pose: newest avatar frame extrapolated ≤ 150 ms, moved in `_physics_process` so host bodies are pushed by
  remote players (a friend walking through a duck pile scatters it for everyone). Spike S-M5 pins the
  AnimatableBody move mode (`sync_to_physics`) that pushes correctly under Jolt.
- Host machines treat ghosts as generic bodies: every `is_in_group("player")` branch ignores them (D10), the
  game's group filters (product/tool/…) skip them. Explicit uses: qa_arm whack (4.5), weight plate (D18),
  priority boost for bodies touching a ghost (3.3).

### 6.6 Player effects (`gameplay/player_fx.gd`)

- **Local branches** (D10): nothing to send; the client's own machine copies do it.
- **`pimp`** host → owning client: `{v}` → `api.commands.execute("player.impulse", {impulse: v})` (local scope,
  MP1 L1); `{respawn}` → `respawn_safe()`; `{teleport}` → `player.teleport`. Impulses from one tick are summed
  per peer and sent at most 30 times a second.
- **`PlayerEffectRedirect`** (host exec wrapper): around every host-side call made for remote peer P
  (`interact`, `tool_in`, rig equip/unequip, rig-run `fire`), snapshot the host player's `velocity`,
  `external_velocity`, `global_position` and metas `golf_aim_mode`; after the call, restore them and forward
  the deltas to P as `pimp` (`v` from the velocity deltas, `teleport` if the position jumped > 1 m). Example:
  a cannon equipped by P fires on the host and its recoil (cannon.gd:424, `get_first_node_in_group("player")`)
  would hit the host player; the redirect moves it to P. Effects caused later by host physics (a tween
  callback, a field) are world events and are not redirected.

### 6.7 Machines, toggles and remote channels

Toggles (`interact`, `toggle_*`) are `input` verbs; `remote_toggle` is `replay` (only the host's remote
channels, schedulers and fail-safes call it). The resulting `is_active` reaches clients through the generic
meta and is applied with the same `remote_toggle`, which also fixes the HUD toggle count
(`GameState.update_toggle_tool_count`). Remote channel states and links are a mirror field (6.10); the
client's remote tool redraws its antenna LEDs from it.

### 6.8 Penalties (`PittMultiplayer.penalty`)

Client-side player branches that charge money (maw fine `bottom_maw._maw_fine()`, fail-safe `spend(1)`) run
locally for their respawn effect; the money clamp reverts the local charge and the client sends
`penalty {kind}`. Host: one per peer per 2 s (dedupe), ignored within 5 s of the peer's `ready`
(join grace); `maw` → `GameState.spend(maw._maw_fine())` on the host maw + `record_safety_violation()` +
`ComboSystem.reset_combo()` (D9); `fail_safe` → `spend(1)` + `reset_combo()`.

### 6.9 Combos (D9, `gameplay/combo_mirror.gd`)

- Host: connects to every `ComboSystem` signal (`combo_started/updated/ended/broken`,
  `chain_combo_triggered`, `diversity_bonus_triggered`, `rhythm_bonus_triggered`, `mega_combo_activated`) and
  sends `combo` on ch0 at ≤ 10 Hz while active plus on every event:
  `{a: is_combo_active, c: current_combo, t: combo_timer, w: get_current_time_window(), tb: total_bonus,
  ch: current_chain_level, dm: diversity_multiplier, rc: rhythm_consistency, mp: mega_combo_progress,
  ma: mega_combo_active, mm: mega_combo_multiplier, bm: bowling_multiplier,
  ev: [["started", lvl], ["ended", lvl, total], ["broken"], ["chain", lvl, bonus], ["diversity", types, bonus],
  ["rhythm", c, bonus], ["mega", mult]]}`.
- Client: `ComboSystem.set_physics_process(false)` while in a session (restored in teardown); write the fields
  in apply scope, emit the matching signals for `ev` so the game HUD reacts (`hud._on_combo_*`), and emit
  `combo_updated(current_combo, progress)` every frame from a locally decremented timer between updates. The
  HUD's `show_result` calls `add_bonus` locally; the money clamp reverts it (the host already paid it).
- The combo payout and `GameState._on_combo_ended` stats happen on the host only; client stats arrive through
  the stats mirror.

### 6.10 Mirror fields registered by GAMEPLAY (`econ_host.register_field`)

`remote: {channels: [[eid, …], …], states: [bool, …], tier}` (applied with `GameState.set_remote_channel_state`
in apply scope; links rebuilt from eids), `flags: {uv_unlocked, torch_unlocked, pickaxe_tier, pickaxe_found,
keypad_revealed, elevator_hacked, secret_ending_seen}`, `buffs: [[type, mult, remaining, duration], …]`
(client `GameState.activate_buff` in apply scope so the HUD shows them; buffs only change host-simulated
values), `panel_stack` (the receiving peer's own stack, 6.11).

### 6.11 Panel rack (D13)

`main_camera._try_rack_store` (:844) on a client → `rack_store {eid}` (the held panel): host recycles that
entity and appends its pool id to the peer's host-side stack. `_try_withdraw_panel` (:863) /
`_refill_from_panel_stack` (:934) → `rack_withdraw {}`: host spawns the panel at the peer's rig hands and
calls `grab.grant(eid, peer, "held", carry=true)`. The client starts the carry itself
(`GrabAdapter.carry_granted`) once it has both the grant and the adopted puppet, in either order: two
physics frames to settle (as the game does), then the game's `_begin_carry(panel, true)` turned to the
camera's `_rack_basis`. It never calls the game's `_carry_after_spawn` (:958): that one's busy branch pushes
the pool id back on the local rack and recycles the node, which on a client is a host-owned puppet. If the
hands are full by then, the client sends `rack_store` for the panel (GAMEPLAY's client rack), else releases
it where it is (`own_rel`). The client's `GameState.panel_stack` is the mirrored field (HUD count via
`panel_stack_changed`).

### 6.12 Effects and achievements (`gameplay/fx.gd`)

`fx` kinds (host → all, ch3, batched with the entity messages so an effect precedes its despawn): `maw`,
`pinata_burst`, `register_depleted`, `candy_expire`, `crate_break`, `debris_hit`, `cannon_fire`,
`statue_bless`, `statue_pet`, `block_hit`, `radar_flash`, `bowling_text`, `bonus_text`, `notify {key}`,
`hack_success`, and `ach {id}` for the world-event achievements unlocked in host-only code (`BAD`
camera_pivot.gd:90, `SECRET` card_reader.gd:74, `LOOP` loop_puzzle.gd:565, `INVISIBLE` uv_lamp.gd:82, `MORE`
/ `EXTRA` / `MEGA` combo_system.gd:168-174). Clients apply `ach` through the MP1 achievements policy
(presence: unlocked for everyone present; `none`: nothing). Effects whose target eid is unknown on the client
are dropped.

### 6.13 Phase transitions and the ending

- Phase 2-4 transitions (MP1 replication) run the cinematic on every peer; client-side GameProgression debris
  is stray-guarded, host debris is real.
- Phase 5 (D16): the host stops body frames and sends `ents {freeze_world:true}`; each client stops driving,
  unfreezes every puppet (`local_sim` for all) and lets its own GameProgression ending act on them. No
  ownership after this point (all held bodies released locally).
- Secret ending (D15): `fx hack_success` → `elevator.on_hack_success()` on every peer in apply scope; the host
  enters session `ending`.

---

## 7. Physics tick pinning

- At `world_started` on every peer: `perf.pin_physics {hz: 60}` (PittAPI builtin, local scope: stops
  `PerformanceMonitor` processing and sets `Engine.physics_ticks_per_second = 60`), and
  `Engine.max_physics_steps_per_frame = 8`. Restored in teardown (`PerformanceMonitor.set_process(true)`).
- The host's body frames stamp the **host wall clock** of the tick (`host_ms`), not a tick counter, so a
  client running slower still interpolates correctly; tick counts are never compared across peers.
- `Engine.time_scale` (phase 3 cinematic, game_progression.gd:684-740) slows the host simulation for
  everyone; puppets follow because frames carry wall-clock stamps. Client timers in our code use wall clock
  (MP1 rule 6).
- Test: every peer reports 60 Hz after join and after a phase 3 transition; `PerformanceMonitor.current_state`
  changes do not change the tick.

---

## 8. Bandwidth: budget defaults and measurement

| Stream | Direction | Default | Notes |
|---|---|---|---|
| Body frames + `ents`/`meta`/`fx`/`own` | H→C per client | **48 KB/s** (`physics_detail` normal; low 24, high 96), adaptive (3.3) | about 2000 moving-body updates/s at 25 B, e.g. 100 nearby moving bodies at 20 Hz |
| Avatars | H→C per client | ~0.9 KB/s per other player | MP1, 20 Hz × 44 B |
| Econ/phase/combo/control | H→C | < 1 KB/s average | full econ every 2 s |
| Held frames | C→H | ~1 KB/s while holding | 30 Hz × 39 B (header + record) |
| Avatar + interact + own + netq | C→H | < 2 KB/s | |

Steady state for 4 players and a busy floor: about 50 KB/s down per client and 150 KB/s up at the host,
within Steam relay limits.

**Measurement (BODIES):** `transport.gd` counts bytes and packets per peer, per channel, per direction in
1 s windows (ring of 60); `session.net_stats() -> {peer: {ch: {tx_bps, rx_bps, tx_pps}}}`; console
`mp stats`; client `netq` (gaps, late frames, interpolation delay, puppet count, strays, local money writes).
PittMPTests asserts on these (11.2 B5, B6). Staleness metric: for bodies within 10 m of the client avatar and
moving faster than 0.5 m/s, `now − last_update` p95 ≤ 150 ms at normal detail without conditioning.
The client measures it live: the replicator's counters carry `cl_stale_p95_ms` / `cl_stale_n` (last 2048
samples at 10 Hz over every visible puppet, also ones no longer driven, so starvation past the 2 s idle cut
still counts) next to `cl_frame_p95_ms` / `cl_frame_max_ms` (last 600 rendered frames, sampled on
`SceneTree.process_frame`, not per physics step),
`cl_physics_load`, `cl_phys_active` (`PHYSICS_3D_ACTIVE_OBJECTS`) and `cl_active`, refreshed every second
(so `mp stats` and `dump()` see them); netq carries `frame_p95_ms`, `stale_p95_ms` and `physics_load` to the host.

---

## 9. Failure modes and guards

| Failure | Guard | Counter / test |
|---|---|---|
| A sink not gated on a client (double money, local spawns) | money clamp (P5), stray guard (P6), loopback fails on any non-zero unexpected counter | `local_money_writes`, `stray_spawns` |
| Game code unfreezes a puppet (`place()`, `_unfreeze()`) | driver re-asserts freeze each tick | `puppet_unfreeze` |
| Frame before spawn / after despawn | 500 ms buffer / 5 s tombstones | `orphan_frames` |
| Lost unreliable frames of a sleeping body | 4 repeats + rest refresh | B-scenario under 5 % loss |
| Lost reliable ch3 message | not possible within a connection (ENet/Steam reliable ordered); a reconnect is a new session | — |
| Pool exhausted on a client | pending eid retried every 0.5 s | `client_pool_full` |
| Pool tables differ | `pools_hash` reject at welcome | handshake test |
| Same-frame recycle + respawn of one node | L8 reuse detection → new eid; else the host's `SNAP` heuristic | `test_entities` reuse case |
| Fixture key resolves on one side only | logged, ignored | `fixture_mismatch` |
| Host overloaded (thousands of awake bodies) | 2 ms selection cap, at most 256 candidates per tick (held / SNAP / boosted always), physics catch-up steps 8 → 4, budget halving only with two or more peers, toast; the tick never changes | `sel_overrun`, `cand_shed` |
| Client bandwidth drop / loss | adaptive budget (×0.7 / +15 %/s, probe to 3× while clean), floor 12 KB/s on loss, half the configured value (at least 18 KB/s) on RTT alone | `budget_bps`, per-peer `rtt` in `mp stats` |
| Owner silent / gone / paused | revoke after 1.5 s, on disconnect, via the pause guard release | G-scenarios |
| Grab race (two peers, or host and client) | host first-come on ordered ch3; host player through the same table | G2 |
| Held body desync or cheating | distance check vs the owner's avatar, epoch check, rate limit | `held_rejected` |
| Interaction spam / out of reach | 20/s limit, distance check, verb whitelist | `interact_rejected` |
| A peer's client mod spawns entities | MP1: `entity.spawn` from a client runs on the host (authority command, remote-refused unless allowed) | MP1 test |
| Joiner arrives during heavy activity | ch3 queued from the cut; wsnap applied in batches; frames start after `ready` | B4 |
| World snapshot too big | 32 MB raw cap; above it the join is refused with `MP_ERR_WORLD_TOO_BIG` (needs ~200k entities, beyond pool maxima) | unit |
| Teleports interpolate visibly | `SNAP` flag | B-scenario portal case |
| Phase 3 `time_scale` | wall-clock stamps | 7 |
| Session ends mid-hold | teardown releases all `local_sim` bodies; the client world is being left anyway | MP1 teardown |
| Extension applied but the session code is missing | every extension checks `Engine.get_meta("pitt_mp")` and the module's existence; absent → vanilla path | H-SP1 |
| Game update renames a member | contract files per stream (10.4); MP disabled as a whole | contract check |

---

## 10. Interface contract and file ownership (normative)

The three streams build against this section at the same time. A change needs the owners of both sides to
agree, and an edit here first. MP1 §5 (UI ⇄ NET) is unchanged; the lobby and UI files are out of scope for
all three MP2 streams.

### 10.1 Session module registry (BODIES implements in `net/session.gd`)

```gdscript
# net/session.gd additions (BODIES)
signal world_started(role: String)        # both roles: host OPEN with world ready / client after its wsnap apply + ready
signal world_stopped(reason: String)      # before teardown step 4 (MP1 §4.6), or at phase 5 (D16, reason "ending")
signal peer_world_ready(peer: int)        # host: a client finished its wsnap apply (its `ready` arrived)
signal peer_left(peer: int)               # host: after roster removal

func register_module(m: Object) -> void   # main.gd, before the session goes live; registration order = call order
func get_module(name: String) -> Object   # "bodies" | "gameplay" | "grab" | null
func is_host() -> bool
func my_peer_id() -> int
func send_world(peer: int, k: String, body: Dictionary) -> Error   # JSON on ch3; peer 0 = every in-game peer (host only)
func send_unreliable(peer: int, bytes: PackedByteArray) -> Error  # ch2 (frames 4/5); peer 1 from clients
func send_msg(peer: int, k: String, body: Dictionary = {}) -> Error   # MP1 (ch0)
func host_now() -> int                                             # MP1 clock
func in_game_peers() -> Array                                      # MP1
func slot_of(peer: int) -> int                                     # MP1
func peer_of_slot(slot: int) -> int
func avatar_pose(peer: int) -> Dictionary
    # {ok: bool, pos: Vector3, yaw: float, pitch: float, vel: Vector3, t_ms: int (host ms of the newest frame),
    #  eye: Vector3 (pos + the local CameraPivot offset)}; host: any remote peer; client: any peer incl. host.
    # Reads ONLY the MP1 avatar frame data kept by Session (Session._on_packet caches the newest decoded
    # frame per peer before handing it to avatars.on_frame) - never puppet.gd / avatars.gd internals.
func local_pose() -> Dictionary            # same shape for the local player
func net_stats() -> Dictionary             # 8
func counters() -> Dictionary              # merged module counters (each module's counters())
```

Module duck type (every method optional except `mod_name`):

```gdscript
func mod_name() -> String                                   # "bodies" | "gameplay" | "grab"
func msg_kinds() -> Dictionary   # {"ch3_c2h": [...], "ch3_h2c": [...], "ch0_c2h": [...], "ch0_h2c": [...], "raw_c2h": [frame kinds]}
func on_session_start(session: Object, role: String) -> void
func on_world_started() -> void
func on_world_stopped(reason: String) -> void
func on_msg(peer: int, k: String, msg: Dictionary) -> void   # routed by kind; host: peer = sender; client: peer = 1
func on_raw(peer: int, kind: int, bytes: PackedByteArray) -> void   # ch2 frames other than avatars (BODIES: 4, GRAB: 5)
func on_peer_world_ready(peer: int) -> void
func on_peer_left(peer: int) -> void
func wsnap_section() -> Dictionary                          # host: this module's part of the world snapshot
func apply_wsnap_section(d: Dictionary) -> void             # client: before the buffered ch3 replay
func tick(now_ms: int) -> void                              # Session._process (PROCESS_MODE_ALWAYS)
func counters() -> Dictionary
func teardown() -> void                                     # MP1 teardown, after step 3, in reverse registration order
```

Proto: the union of all modules' `msg_kinds()` is whitelisted at registration (BODIES also pre-lists every kind
of 2.4 in `proto.gd` so a missing module only means its messages are dropped and counted). Kinds are accepted
only in session state `in_game` (and `loading` for `wsnap_*`/`world_req`).

### 10.2 BODIES module API (`world/bodies/bodies.gd`, `get_module("bodies")`)

```gdscript
signal entity_added(eid: int, node: Node)      # host: tracked + replicated; client: puppet created (meta applied)
signal entity_removed(eid: int)                # both; fired BEFORE the node is recycled on clients

# both roles
func node_of(eid: int) -> Node
func eid_of(node: Object) -> int               # 0 if not replicated; walks up from a child collider to the tracked ancestor
func is_replicated(eid: int) -> bool
func kind_of(eid: int) -> String               # "pooled" | "fixture_body" | "fixture"
func pool_id_of(eid: int) -> String
func flags_of(eid: int) -> int                 # last known record flags (HELD, HIDDEN, NOCOLLIDE, SLEEP)
func meta_of(eid: int) -> Dictionary           # last applied (client) / last sent (host) meta
func set_owner_view(eid: int, owner_peer: int, kind: String, epoch: int) -> void   # called by GRAB on every change
func register_meta(kind: String, matcher: Callable, read: Callable, apply: Callable, rate_hz: float = 4.0) -> void
    # matcher(node) -> bool; read(node) -> Dictionary (JSON-safe); apply(node, d: Dictionary) -> void (client, apply scope)
func register_fixture(key: String, node: Node) -> int        # static id; GAMEPLAY may add keys (bowling pins)
func unregister_fixture(key: String) -> void

# host only
func host_follow(eid: int, peer: int) -> void                # body -> frozen KINEMATIC follower of the owner's stream
func host_follow_push(eid: int, state: Dictionary, t_ms: int) -> void   # state {p: Vector3, q: Quaternion, l: Vector3, a: Vector3}
func host_release(eid: int, state: Dictionary) -> void       # exact state, dynamic again, woken
func boost(eid: int, seconds: float) -> void
func meta_dirty(eid: int) -> void
func mark_snap(eid: int) -> void                             # teleports (portal hook)
func freeze_world() -> void                                  # phase 5 (D16)

# client only
func set_local_sim(eid: int, on: bool, min_epoch: int = 0) -> void
func is_local_sim(eid: int) -> bool
func host_state(eid: int) -> Dictionary                      # newest host record {p,q,l,a,flags,epoch,host_ms}
```

Rules: BODIES never calls GAMEPLAY or GRAB; it only exposes the above and emits signals. Fixture keys of 3.1 are
BODIES'; GAMEPLAY adds only the keys it creates (pins). Client meta `apply` callbacks always run inside
`api.net.begin_apply(1)` / `end_apply()`.

BODIES also provides to GAMEPLAY: `econ_host.register_field(name: String, read: Callable, apply: Callable)`
(host `read() -> Variant` JSON-safe, client `apply(v)` in apply scope; sent on change and with every full econ),
and the codec statics of 2.3.

### 10.3 GRAB module API (`grab/grab.gd`, `get_module("grab")`)

```gdscript
signal owner_changed(eid: int, owner_peer: int, kind: String, epoch: int)   # both roles; kind "" | "held" | "equipped"

func owner_of(eid: int) -> int          # 1 (host) by default
func hold_kind(eid: int) -> String
func epoch_of(eid: int) -> int
func is_mine(eid: int) -> bool          # client: owned by this peer
# host only
func can_take(eid: int, peer: int) -> String               # "" or a deny reason
func add_deny_rule(rule: Callable) -> void                 # rule(eid: int, node: Node, peer: int) -> String ("" = allow)
func revoke(eid: int, reason: String) -> void
func grant(eid: int, peer: int, kind: String = "held", carry: bool = true) -> void   # GAMEPLAY rack withdraw
```

GRAB owns `own_*` kinds, frame kind 5 handling and `extensions/grab/main_camera_grab_ext.gd` (overrides only
`_begin_carry`, `drop_object`, `release_held_object`). GRAB calls into BODIES only through 10.2 and never
touches GAMEPLAY files.

### 10.4 GAMEPLAY module API (`gameplay/gameplay.gd`, `get_module("gameplay")`) and the gate

```gdscript
# host only
func rig_of(peer: int) -> Camera3D
func ghost_of(peer: int) -> Node3D
func host_exec(peer: int, c: Callable) -> Variant           # MpGate.exec_peer + PlayerEffectRedirect around c
func player_impulse(peer: int, v: Vector3, src: String) -> void
func holders_of(eid: int) -> Array                          # bench holder set (tests)
```

`gameplay/mp_gate.gd` (static, `const G = preload(...)` in every GAMEPLAY extension; semantics of 1.1):
```gdscript
static func live() -> bool
static func is_client() -> bool
static func sink(node: Object) -> bool                      # true = return early
static func replay(node: Object) -> bool
static func input(node: Object, verb: String, arg = null) -> bool
static func input_predict(node: Object, verb: String, arg = null) -> bool
static func begin_input_scope() -> void ; static func end_input_scope() -> void
static var exec_peer: int                                   # host: the peer a host_exec call runs for, else 0
```
GAMEPLAY registers its own commands (`penalty`, `recall`, `rack_store`, `rack_withdraw`; `remote: true`) through
`api.commands` in `on_session_start`; the MP1 buy commands stay registered by the session and call
`purchases.host_buy_*` (GAMEPLAY) as before.
GAMEPLAY listens to `grab.owner_changed` (rigs) and `bodies.entity_added/removed`, registers meta adapters,
deny rules (`in_cannon_barrel`, `in_vacuum_bag`, `terminal_pull`, press stroke, cauldron ritual) and mirror
fields. GAMEPLAY calls `grab.revoke` from its sink extensions on the host when the game consumes or captures
an owned body.

### 10.5 Wire ownership

| Item | Owner |
|---|---|
| Frame kinds 4 and 5 layouts, `Codec.encode/decode_bodies`, `encode/decode_held`, quantisation helpers | BODIES (GRAB consumes kind 5 through the codec) |
| `ents`, `meta`, `world_req`, `wsnap_*`, `netq`, rest refresh, budget, priority | BODIES |
| `own`, `own_req`, `own_rel`, `own_equip`, `own_unequip`, held-frame validation | GRAB |
| `interact`, `tool_in`, `fx`, `pimp`, `fixture_spawn`, `combo`; commands `penalty`, `recall`, `rack_store`, `rack_withdraw`; host purchase spawning | GAMEPLAY |
| `proto.gd` whitelist and rate classes of 2.5 | BODIES (edits on request, listed here already) |

### 10.6 mod.json and extension order (BODIES writes, day 1)

`extensions` order: the four MP1 files; `extensions/grab/main_camera_grab_ext.gd`; then
`extensions/gameplay/*` with **every base script before its subclasses** (`vacuum` before `vacuum_2`,
`magnet` before `magnet_2`, `piston` before `piston_2` before `piston_3`, `fan` before `fan_3`, `wodd_crate` before any crate
subclass ext, `spring_pad` before any `spring_pad_2` ext), and `main_camera_interact_ext.gd` after the GRAB
main_camera ext. A missing file is a quarantine error, so each stream commits pass-through stubs (`extends`
+ nothing) of all its own extension files on day 1, and `main.gd` tolerates missing module files (MP2
disabled with a log line, MP1 suites still green).

### 10.7 Contracts with the game (one file per stream, core format, checked by `api.contract_check`)

- BODIES `world/bodies/contract_bodies.gd`, features `mp2.bodies`, `mp2.wsnap`: `ObjectPoolManager._pools`,
  `_initialized`, `spawn`, `recycle`, `POOL_CONFIG`; `SaveManager.is_loading`, `_save_object_pools`;
  `RigidBody3D` members are engine API (not listed); every setter of 3.5 (`remote_toggle`, `update_fan_state`,
  `_apply_tint`, `set_crude_source`, `set_grade`, `_apply_variant`, `apply_placed_state`,
  `apply_piston_save_data`, `_update_value_label`, `_update_screen`, `_refresh`, `flip_mode`,
  `flatten_mesh_world_y`, `_rebuild_merge_group`); `GameState.bank`, `mining_bank`, `bank_updated`;
  `PerformanceMonitor`; `hole` members (MP1).
- GAMEPLAY `gameplay/contract_gameplay.gd`, features `mp2.sinks`, `mp2.machines`, `mp2.interact`, `mp2.combo`:
  every function named in section 4 as gated, replayed or forwarded, plus `ComboSystem` fields and signals of
  6.9, `GameState.set_remote_channel_state`, `remote_channels`, `remote_channel_states`, `activate_buff`,
  `panel_stack`, `panel_stack_changed`, `upgradeUI._spawn_tool_instance`, `_spawn_toy_instance`,
  `_recall_tool`, `_unit_owned_elsewhere`, `hud._spawn_special_bonus_text`, `bottom_maw._maw_fine`,
  `maw_effect`, `interact_ray` dispatchers of 1.1, `main_camera.handle_input`, `_do_interact`,
  `_try_rack_store`, `_try_withdraw_panel`, `_refill_from_panel_stack`, `_carry_after_spawn`.
- GRAB `grab/contract_grab.gd`, feature `mp2.grab`: `main_camera.picked_object`, `equipped_item`,
  `max_grab_distance`, `interact_ray`, `_rack_basis`, `_begin_carry`, `drop_object`, `release_held_object`,
  `handle_input`; metas are
  strings (not checkable) and are listed in the file's comments.

Any missing member disables multiplayer as a whole (MP1 §11).

### 10.8 Test doubles (each stream owns the doubles of the *other* sides it needs)

- GRAB: `tests/headless/fakes/mp2_grab/fake_bodies.gd` (10.2 surface, records calls; drives `entity_added/removed`).
- GAMEPLAY: `tests/headless/fakes/mp2_gameplay/fake_bodies.gd`, `fake_grab.gd` (10.3 surface).
- BODIES: `tests/headless/fakes/mp2_bodies/fake_grab.gd` (calls `set_owner_view` like GRAB),
  `fake_gameplay.gd` (registers a meta adapter and a mirror field).
- Conformance: `test_mp2_bodies_contract.gd` asserts that `bodies.gd` **and** both `fake_bodies.gd` have every
  10.2 member; `test_mp2_grab_contract.gd` the same for `grab.gd` and `fake_grab.gd` (10.3);
  `test_mp2_gameplay_contract.gd` for `gameplay.gd`, `mp_gate.gd` (10.4) and BODIES' `fake_gameplay.gd`. Drift
  fails the owner's suite.

### 10.9 File ownership

**STREAM BODIES** (and nothing else):
```
loader/core/entities.gd, loader/api/net.gd, loader/pittapi.gd (version), loader/mod.json      L7-L9, PittAPI 1.2
mods/PittMultiplayer/mod.json, main.gd, README.md                                         modules, contracts, ext list (10.6)
mods/PittMultiplayer/net/{session,proto,codec,transport,transport_enet,transport_steam,transport_loopback,contract_net}.gd
mods/PittMultiplayer/game/game_adapter.gd                                                 econ/mirror changes only
mods/PittMultiplayer/game/bodies_adapter.gd                                               new: pools, physics, fixtures
mods/PittMultiplayer/sync/{econ_host,econ_client}.gd                                      money clamp, stats/bank mirror, register_field
mods/PittMultiplayer/sync/snapshot.gd                                                     strip() table and its constants ONLY (3.8)
mods/PittMultiplayer/sync/contributions.gd                                                deleted
mods/PittMultiplayer/extensions/hole_ext.gd
mods/PittMultiplayer/world/bodies/{bodies,replicator_host,replicator_client,puppet_body,interp,priority,budget,
                                   meta_sync,entity_meta,fixtures,stray_guard,world_snapshot,contract_bodies}.gd
mods/PittMultiplayer/mp2/strings_mp2.gd, mods/PittMultiplayer/mp2/i18n/*.json             MP2 keys, 10 locales:
        MP_PHYSICS_OVERLOADED, MP_ERR_WORLD_TOO_BIG, MP_WORLD_LOADING, MP_HELD_BY ({name})
mods/PittMPTests/mp2/{scenario_mp2,bodies_host,bodies_client}.gd                         harness + B-scenarios
mods/PittMPTests/main.gd                                                                  one line: role "mp2" (after the concurrent scenario fix lands)
tests/headless/suites/test_mp2_bodies_*.gd  (codec, priority, budget, interp, meta, stray, wsnap, econ, contract)
tests/headless/fakes/mp2_bodies/**
tests/headless/suites/test_mp_net_econ.gd, test_mp_net_review_fixes.gd                   contribution cases rewritten (3.8)
tools/test-mp-loopback.ps1 (-Suite mp1|mp2|all, -Scenario <id>), tools/test-headless.ps1 (contract files), tools/contract_check.py
docs/mp/MP2-DESIGN.md (this file, by agreement), TESTING.md (MP2 sections)
```

**STREAM GAMEPLAY** (and nothing else):
```
mods/PittMultiplayer/extensions/gameplay/<script>_ext.gd for every script marked "ext" in section 4:
    bottom_maw, press, gambling_terminal, terminal_control, golden_duck_statue, ore_processor, mining_ore,
    minable_block, erasable_text, camera_pivot, fail_safe, hud, basketball_hoop, speed_radar, spring_pad,
    golf_club, pinata, cash_register, candy, anomaly, wodd_crate (+ crate subclasses if S-M3 needs them),
    debris, workbench, manual_cash_workbench, manual_pinata_workbench, automatic_duck_workbench,
    automatic_cash_workbench, automatic_pinata_workbench, anomaly_workbench, proxy_intern, shift_scheduler,
    fan, fan_3, magnet, magnet_2, gravity_inverter, tractor_beam, vacuum, vacuum_2, orbit_tool, roomba,
    qa_arm, piston, piston_2, cannon, disco_ball, portal, broom, pickaxe, remote, feed_camera, feed_screen,
    stat_sign, vertical_gate, gate_shutters, gate_power_generator, gate_weight_plate, card_reader,
    security_keypad, keypad_button, elevator, loop_puzzle, loop_button, uv_lamp, torch_light,
    bowling_pin_set, interact_ray, main_camera_interact
mods/PittMultiplayer/extensions/upgrade_ui_ext.gd                                         (MP1 file)
mods/PittMultiplayer/sync/purchases.gd                                                    host spawns; on_grant no-op; recall
mods/PittMultiplayer/gameplay/{gameplay,mp_gate,interact_client,interact_host,rigs,ghosts,player_fx,penalties,
                               combo_mirror,fx,fixture_adapters,machine_meta,mirror_fields,rack,contract_gameplay}.gd
mods/PittMultiplayer/game/gameplay_adapter.gd
mods/PittMPTests/mp2/{gameplay_host,gameplay_client}.gd                                  P-scenarios
tests/headless/suites/test_mp2_gameplay_*.gd  (gate, interact, rigs, redirect, penalties, combo, fx, purchases, contract)
tests/headless/fakes/mp2_gameplay/**
tests/headless/suites/test_mp_net_purchase.gd                                             MP2 spawn cases
```

**STREAM GRAB** (and nothing else):
```
mods/PittMultiplayer/extensions/grab/main_camera_grab_ext.gd
mods/PittMultiplayer/grab/{grab,ownership_host,ownership_client,held_stream,release_capture,contract_grab}.gd
mods/PittMultiplayer/game/grab_adapter.gd
mods/PittMPTests/mp2/{grab_host,grab_client}.gd                                          G-scenarios
tests/headless/suites/test_mp2_grab_*.gd  (protocol, prediction, release, timeouts, disconnect, contract)
tests/headless/fakes/mp2_grab/**
```

**Nobody in MP2** touches: `mods/PittMultiplayer/ui/**`, `lobby/**`, `extensions/main_menu_ext.gd`,
`world/puppet.gd`, `world/avatars.gd` (being fixed concurrently; MP2 reads poses through `Session.avatar_pose`),
`world/{pause_guard,input_guard,save_guard}.gd`, `policy/achievements.gd` (GAMEPLAY calls its existing public
grant path), `extensions/pause_menu_ext.gd`, `sync/progression.gd`, and the existing PittMPTests scenario files.
`decomp/` is read-only and never committed.

---

## 11. Tests

### 11.1 Headless (every change; `tools/test-headless.ps1`, one process, loopback transport, fake adapters)

| Suite (owner) | Covers |
|---|---|
| `test_mp2_bodies_codec` | frames 4/5 round trip, quantisation error bounds (pos ≤ 0.5 mm, rot ≤ 0.1°), NaN/overrun rejection, 1200 B packing |
| `test_mp2_bodies_priority` / `_budget` | weights, starvation (every awake body sent within 3 s at 200 bodies), byte budget per tick, adaptive ×0.7 / +15 %, windowed RTT minimum, probe-up ceiling, single-peer overload, 2 ms selection cap |
| `test_mp2_bodies_interp` | Hermite/slerp, extrapolation cap, SNAP, blend, sleep exactness, unknown-eid buffer, tombstones, under loopback 100 ms ± 30 / 5 % loss |
| `test_mp2_bodies_meta` | save-schema read/apply field by field on stub nodes, diffing, never `apply_loaded_bag/queue` on clients |
| `test_mp2_bodies_stray` / `_wsnap` | stray recycle, expected-source silence; wsnap cut + ch3 replay ordering under reordered delivery, batch apply, sha mismatch |
| `test_mp2_bodies_econ` | money clamp reverts any local write in one frame, stats mirror emits `stat_changed` once per change, `contribute` gone |
| `test_entities` (loader, extended) | L7 adopt/release, L8 reuse detection (hidden→visible within a frame) vs cannon store/fire |
| `test_mp2_grab_protocol` | grant/deny/epoch, race (host vs client, two clients), release ordering before grant, revoke on silence/disconnect/far, host-player refusal |
| `test_mp2_grab_prediction` | local refusal rules, deny undo, release capture next frame, throw meta age |
| `test_mp2_gameplay_gate` | four gate kinds × three scopes; input scope only from the listed dispatchers |
| `test_mp2_gameplay_interact` | whitelist, distance, rate, holder set, host exec |
| `test_mp2_gameplay_redirect` | PlayerEffectRedirect restores the host player and forwards the delta |
| `test_mp2_gameplay_combo` / `_penalties` / `_purchases` / `_fx` | mirror events → signals; penalty dedupe + join grace; host spawn on buy; fx before despawn |
| `test_mp2_*_contract` | 10.8 conformance |
| `H-SP1` | all existing suites green with MP2 installed and no session |

### 11.2 Two-instance loopback (`tools/test-mp-loopback.ps1 -Suite mp2`, decomp editor ×2; `-HostLive` variant in a launch stage)

Every scenario also asserts at the end, on the client: `stray_spawns` only from the expected sources,
`local_money_writes` only where the scenario expects a reverted local fine/payout, `orphan_frames ≤ 1 %`, no
script errors in either log, the real save folder hash unchanged (MP1 T0 gate). Conditioning runs use the MP1
transport conditioner. Screenshots go to `dist/screens/mp2-*.png`.

**BODIES**
| Id | Scenario | Pass criteria |
|---|---|---|
| B1 | Host spawns 50 ducks and pushes them with impulses | client has 50 puppets with the host eids within 2 s; while moving, client pose vs host history at the same host_ms ≤ 5 cm p95; at rest ≤ 1 cm; no frames for resting bodies after 3 s except the rest refresh; screenshot "client sees host's spawned ducks moving" |
| B2 | Host recycles 20; host press flattens a duck (same-frame reuse) | client despawns within 300 ms; a flat duck with a new eid, no leftover duck |
| B3 | Cannon loads then fires a duck | hidden on the client while loaded; reappears at the muzzle with SNAP (no interpolated streak) |
| B4 | **Late join with 350 entities** (mixed pools; 30 moving under fans; one held by the host; a loaded cannon; placed sticky tools; a lit fan) | `world_req` → `ready` ≤ 3 s after save.applied; 350 puppets with matching pool ids and metas (tint, is_active, placed, queue_count); zero strays; then the 3000-entity variant records build/apply times (target 30 ms / 2 s) |
| B5 | **Bandwidth**: 200 awake ducks tumbling in two fans for 30 s | client downstream p95 of 1 s windows ≤ 48 KB/s × 1.1; nearby moving staleness p95 ≤ 150 ms |
| B6 | **B1 + B5 under 100 ms ± 30 ms, 5 % loss** | pose error p95 ≤ 25 cm while moving, ≤ 1 cm 3 s after rest; budget adapts down and recovers within 15 s of conditioning off |
| B7 | Money clamp | a client-local `GameState.add_money` (test hook) is reverted within one physics frame; `PittMultiplayer.contribute` is an unknown command on the host |
| B8 | Phase 2 transition | client GameProgression debris recycled as expected strays; host debris visible as puppets |
| B9 | Tick pin | both peers at 60 Hz after join and after `phase.set 3` |

**GAMEPLAY**
| Id | Scenario | Pass criteria |
|---|---|---|
| P1 | **Both feed the maw, phase progresses once**: host throws ducks; client fires a host-placed cannon at the maw (`interact fire`) and toggles a fan that blows ducks in; the host sets nutrition near the phase-1 target first | host money rises by exactly the host-computed sum; `products_consumed` counts each duck once; phase 2 begins once on the host and the client plays one transition; client money equals host money throughout |
| P2 | **Client buys a tool and the host sees it** (a fan, a crate toy, then the press) | host money − price once; the tool exists once with one eid on both; the press fixture appears on both; nothing appears only on the client |
| P3 | **Automatic workbench products appear identically**: host buys the auto duck machine; the client turns it on | ducks appear on the client with the host eids, poses converge as B1; `products_autocrafted` only on the host, mirrored on the client; zero client strays |
| P4 | Manual bench co-craft | host and client hold craft; one releases, crafting continues; ducks appear on both |
| P5 | Press and terminal by the client | press with a duck inside → one flat duck for both, money once; sweep + roll → `bank` mirrored, the recycle cube is an entity |
| P6 | Fields act on the client's own player | spring pad launches the client player (vertical velocity spike on the client; the host sees the avatar rise); a fan pushes it |
| P7 | qa_arm whacks the remote player | the client receives `pimp` and its player moves; the host stat `safety_violations` +1 |
| P8 | Ghost push | the client walks through 20 resting ducks: they move on the host and on the client |
| P9 | Equip a vacuum (with GRAB) | host rig ingests ducks (HIDDEN on the client); the host sees the vacuum at the client avatar's hands, NOCOLLIDE |
| P10 | Shared combo | host feeds 5 ducks fast: client HUD shows combo 5; the payout happens once (host money), client money equals host |
| P11 | Penalty | the client jumps into the maw: respawn on the client, host money − `_maw_fine()` once, combo reset |

**GRAB**
| Id | Scenario | Pass criteria |
|---|---|---|
| G1 | **Client grabs and throws a duck; the host sees it land** | grant within RTT + 50 ms; while carried, the host copy is within 10 cm of the client pose 50 ms later; after the throw the host body lands within 0.5 m of the client's local landing; the client converges to the host pose; epoch +2 |
| G2 | Race: host and client grab the same duck within 20 ms | exactly one owner; the loser's carry is undone within one RTT |
| G3 | Deny: grab a duck in a cannon / one being consumed | local refusal or host deny; no carry remains |
| G4 | Owner silence (test hook stops held frames) | revoked after 1.5 s ± 0.2; the client drops |
| G5 | Disconnect while holding | the host releases the body at its last state; it falls on the host |
| G6 | Client opens the pause menu while holding | normal release, the body falls on both |
| G7 | **Throw ducks into the maw** (with P1) | money, stats and nutrition counted once each |
| G8 | G1 under 100 ms ± 30 ms, 5 % loss | landing within 1 m; no stuck ownership |
| G9 | Place a sticky panel | host panel placed STATIC, pose ±1 cm |
| W1 | Manual duck workbench: the HUD progress bar is the operator's (0.2.2) | the client crafts: its bar shows, the host's stays hidden; the host crafts: its bar shows, the client's stays hidden |
| W2 | Client holds craft at a manual bench (0.2.2) | the hold spans items: a 12 s hold yields the host's count within 1 |
| M1 | Open upgrade menu follows another player's purchase (0.2.2) | the client's open menu shows the host's purchase (row level / price) and a money-only change (credits) without reopening; the host's open menu shows a client's purchase |
| T1 | Client's equipped broom sweeps along its facing (0.2.2) | at 4 yaws: the rig copy pushes along the rig's view (dot > 0.9) and a duck 2.6 m in front moves >= 0.2 m within 35 degrees of the facing |
| G10 | **Client lifts the CRATE tool with ducks inside** (0.2.2, real input path: interact ray + LMB) | empty, with 3 ducks and full (24 dropped in 3 layers, >= 18 inside; lifting it may drop <= 4 of the top layer, on both peers alike): granted, no deny, the crate rises ≥ 0.3 m on both peers, the host copy within 15 cm of the client pose, the ducks stay inside it on both while lifted and swung; after the drop the client converges within 5 cm; control: the host lifts it, the client sees it raised with the ducks inside |
| G11 | **Client takes panels from its rack and the carry starts** (0.2.3, real input path: the rack key, then LMB places a panel with auto_rack on and the game's own refill withdraws the next; the host seeds the client's rack with 3 panels) | each withdraw: within 1.5 s the client camera's `picked_object` is the panel the host granted (mine, local_sim, `carry_started` +1); the host row is the client's and leaves `await_ack` within 1.5 s; the host copy within 15 cm of the client pose; 3.5 s after the grant (past the 1 s grace + 1.5 s silence limit) still held by the client, no `silence`/`far` revoke, `grant_never_carried` unchanged; the placed panel goes back to the host. Hands full when a grant lands: `carry_busy` and `carry_racked` +1, the hands keep their panel, the host racks it again (`rack_stored` +1, revoke reason `rack`), it disappears on the client, the client's `panel_stack` equals the host's, `puppet_lost` unchanged (the vanilla `_carry_after_spawn` busy branch never ran), no panel lies loose |

**Integration (all streams):** I1 = P1 + G7 + B4 in one session with a late joiner during the feeding; I2 =
I1 with `-HostLive` (real game host, launch stage only).

### 11.3 Manual Steam checklist additions (`docs/mp/MANUAL-STEAM-TEST.md`, owner, two PCs)

Shared ducks visible and smooth; grab and throw to each other; buy a tool on one PC and use it on the other;
co-op workbench; combo shown on both; `mp stats` under 50 KB/s per client; late join on a busy floor.

---

## 12. Spikes (before the code that depends on them)

| Spike | Question | Blocks |
|---|---|---|
| S-M1 | Jolt, frozen KINEMATIC RigidBody3D: impulses/forces inert; `linear_velocity` writes ignored; `body_entered` still reported for contacts with dynamic and static bodies (`generate_all_kinematic_contacts=true`); kinematic moves push the CharacterBody player | P2, puppets |
| S-M2 | L8 visibility pair detection on the real press flatten and on cannon store/fire | L8 |
| S-M3 | `take_over_path("res://scripts/wodd_crate.gd")` reaches `metal/plush/anomaly_crate.gd` (class_name `GamblingCrate`) | crate ext |
| S-M4 | `add_collision_exception_with(puppet)` lets the player walk through ducks while `InteractRay` still hits them | D22 |
| S-M5 | AnimatableBody3D ghost moved in `_physics_process` pushes Jolt bodies (with/without `sync_to_physics`) | ghosts |
| S-M6 | Aim source of every equipable tool when equipped on a non-current Camera3D rig | 6.4 |
| S-M7 | `gate_weight_plate._recalculate_mass` field to add ghost mass | D18 |
| S-M8 | wsnap build/apply time and size at 300 / 3000 entities; spawn audio muting via `SaveManager.is_loading` | 3.7 |
| S-M9 | `CameraFeedManager` after a `camera_id` change from meta apply | feed cameras |
| S-M10 | Puppet smoothness with physics interpolation; our physics priority 100 runs after game scripts | driver |
| S-M11 | `SteamMultiplayerPeer` unreliable packets of 1200 B are delivered unfragmented | codec size |

---

## 13. Build order

1. **Day 1:** BODIES commits the module registry, `avatar_pose`, the proto whitelist of 2.4, codec frames 4/5,
   PittAPI 1.2 skeleton (L7-L9 signatures), `mod.json` with the full 10.6 list. GAMEPLAY and GRAB commit
   pass-through stubs of all their extension files and module skeletons. Everyone commits the 10.8 doubles.
2. Spikes S-M1, S-M3, S-M5, S-M10, S-M11 (they decide mechanisms); then S-M2, S-M4, S-M6-S-M9.
3. In parallel:
   - **BODIES:** L7-L9 + tests → host replicator → client replicator + stray guard → meta → fixtures → wsnap →
     contribution removal + clamp + mirrors → budget/priority → B1-B9.
   - **GAMEPLAY:** gate + input scope → sink extensions in the order economy (4.2), products (4.3),
     production (4.4), machines (4.5), puzzles (4.6) → interact host/client → purchases → rigs + ghosts +
     redirect → combo/fx/penalties/rack → P1-P11.
   - **GRAB:** host table + protocol → client prediction ext → held stream → release capture → timeouts →
     G1-G9 (against fake gameplay deny rules first).
4. Integration: all contract suites green; `-Suite mp2` I1; I2 in a launch stage; owner runs 11.3.

---

## 14. Known MP2 limitations (README)

- Tool effects of an equipped tool reach the holder one round trip late (the host runs them).
- The vacuum's bag gauge on the holder's own view is approximate; another player's scrubbing of erasable
  text is not visible (the reward is shared).
- A remote player's cannon shows no trajectory to that player (the client never holds the loaded queue).
- Impact sounds of remote bodies come from local kinematic contacts and may differ from the host's.
- Remote players have no weight on host bodies (they push, they do not press down), except the weight plate
  (D18).
- No host migration, chat, kick UI or sandbox sessions (MP1). The physics-detail lobby control is config-only
  until the UI stream adds it.

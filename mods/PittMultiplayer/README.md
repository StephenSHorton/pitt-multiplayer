# PittMultiplayer (MP2)

Steam co-op for Project P.I.T.T. v1.0.8 on PittAPI 1.2. Design:
[`docs/mp/MP-DESIGN.md`](../../docs/mp/MP-DESIGN.md) (MP1: transport, lobby, session,
late join) and [`docs/mp/MP2-DESIGN.md`](../../docs/mp/MP2-DESIGN.md) (the shared world).

**AI-assisted, unofficial.** Written with AI assistance (Anthropic's Claude). Not affiliated with or
endorsed by Froke, the developer of Project P.I.T.T. The official P.I.T.T. community doesn't accept fully
AI-generated mods, so please don't post or promote this mod in its official spaces (Discord, etc.). You need
to own the game on Steam; this repo contains none of the game's code or asset files.

**World model (MP2): one shared world, simulated by the host.** Every duck, crate,
tool, machine and puzzle exists once, in the host's world; everyone sees the same
objects move. On a client every object is a puppet driven by the host (smoothed,
about 100 ms behind). Money, unlocks, item levels, phase, the hole, combos, the
gambling bank and the mining bank are one co-op state owned by the host.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -WithMP
```

Every player needs the same PittAPI and PittMultiplayer version (and the same
`client_required` mods); mismatched lobbies show disabled in the Join list. MP1 and
MP2 builds do not see each other as compatible.

## Playing

Main menu > **Multiplayer** > Host (friends-only Steam lobby, up to 10) or Join (open
lobbies of your Steam friends). The host presses Start and picks a save in the game's
own save panel; everyone loads into that world. Friends can join while the game is
running (late join): they load the host's state, then the current objects.

- Only the host's world earns: feeding the maw, machines, gambling and combos pay
  into the shared wallet once, whoever caused them.
- Purchases at the terminal go through the host; bought tools and toys appear once,
  in the shared world, and anyone may use them.
- Grab and throw work for everyone (first come, first served); what a friend holds
  shows as held.
- The pause menu pauses only you. Only the host saves; clients never write a save.
  In-game Load is disabled for everyone.
- Steam achievements: nothing is granted for progress you load into; thresholds you
  cross while connected count.
- The host leaving (main menu or quit) ends the session for everyone.

## Settings (`%APPDATA%\Godot\app_userdata\Project P.I.T.T\pittapi\config\PittMultiplayer.cfg`)

| Key | Default | |
|---|---|---|
| `transport` | `steam` | `enet` = localhost dev/tests |
| `physics_detail` | `normal` | host: object updates per client, `low` / `normal` / `high` (24 / 48 / 96 KB/s) |
| `achievements` | `presence` | `none` / `all` |
| `allow_remote_cheats` | `false` | host accepts cheat commands from clients |
| `steam_peer_mode` | `socket` | `lobby` = `host_with_lobby` / `connect_to_lobby` |
| `dev_address`, `dev_port`, `dev_targets`, `dev_name` | | ENet dev lobby |

`client_earnings` (MP1) is gone and ignored if present. Console: `mp stats` shows
the bandwidth per peer and channel and the replication counters.

## Diagnostics (0.2.1)

While a session runs, both host and clients write one line every 10 s to
`...\Project P.I.T.T\pittapi\pittapi.log`:

```
[INFO ] [PittMultiplayer] mp stats: client in_game/open peers 2 rtt 12 ms | ch0 tx 686/58833B rx 673/133934B, ch1 tx 0/0B rx 2/23494B, ch2 tx 223/9447B rx 7061/5407725B, ch3 tx 15/2343B rx 224/24773B | drops {} | world rx 224 tx 15 buffered 0 dropped 0 | puppets 417 records_rx 210583 orphans 0 strays 0 | avatars 1
```

(packets/bytes per channel since the session started, protocol drops by reason, world
messages, replicated objects). The first drop of each reason is also logged once as a
WARN (`protocol drop kind_not_allowed:ents ...`). When a session ends (or the game
quits) its full state is written to `...\pittapi\mp_session_last.json`. Please attach
both files to a bug report.

0.2.1 fixes the first two-PC Steam test: the bundled GodotSteam (4.19.1) only uses Steam
lanes 0-2 and sent the shared world's channel 3 on lane 0, where it was dropped, so a
client saw no newly spawned objects and none of its interactions (grabs, machines,
crafting) reached the host. Host and clients must all run 0.2.1.

## Known MP2 limitations

- Tool effects of an equipped tool reach the holder one round trip late (the host
  runs them).
- The vacuum's bag gauge on the holder's own view is approximate; another player's
  scrubbing of erasable text is not visible (the reward is shared).
- Equipped poses of brooms, fans, remotes, golf clubs and cannons on other players use
  a default hand offset.
- Impact sounds of remote bodies come from local kinematic contacts and may differ
  from the host's.
- Remote players have no weight on host bodies (they push, they do not press down),
  except on the weight plate.
- Object rotations travel in 32 bits (about 0.06 degrees on average, 0.2 at worst).
- Objects are shown about one link latency plus 70 ms behind the host (that is what
  keeps them smooth). The per-client budget drops when the link is congested (RTT
  rising, or more than 15 % loss), not on light random loss; on a bad link (100 ms +- 30,
  5 % loss) flying objects are within about 7-18 cm of the host's position 95 % of the
  time (half the time within 1 mm), resting ones exactly where the host has them. The
  budget recovers within about 10 s of the link getting clean. Body frames to all
  clients together are capped at about 400 KB/s on the host.
- When a combo ends, a client's HUD pays the bonus out locally (the game's own
  `hud.show_result` calls `GameState.add_bonus`); the money mirror reverts it in the
  same frame and the host's single payout arrives a moment later.
- Secret ending: a successful keypad hack arms the escape elevator for every player;
  each player's ride is their own. The session does not switch to "ending" at the hack
  (the facility is still playable); it ends when the host leaves.
- A crowded floor (several hundred awake objects) can overload the host's physics; the
  host then halves the per-client budgets (never below 12 KB/s) until it recovers.
- A player standing inside a pile keeps it awake on the host (their collider pushes
  it), so that pile keeps using bandwidth.
- A late join is prepared in one host frame (about 12 ms with 350 objects, more on very
  large floors): everyone may feel a short hitch when someone joins a huge factory.
- Clear items (pause menu) is host-only; it clears the shared world for everyone.
- Not yet covered by an automated two-instance test (headless only): cannon load/fire,
  the phase-2 debris, two players crafting at one manual bench at once, press/terminal by a client, fields and the
  qa_arm acting on a client, equipped vacuum, throwing into the maw while a late joiner
  loads, sticky panels.
- No host migration, chat, kick UI or sandbox sessions. The physics-detail lobby
  control is config-only for now.

## For modders

- `api.net.is_multiplayer()`, `is_authority()`, `get_players()`, `get_session_info()`;
  signals `session_started` / `session_ended` / `peers_changed` and the events
  `net.session_started`, `net.session_ended`, `net.peers_changed`,
  `mod.PittMultiplayer.*`.
- On a client, commands with scope `authority` (the default) run on the **host**:
  `entity.spawn` from a client mod spawns in the host's world. Register per-machine
  utilities with `{"scope": "local"}`.
- Entity ids are the host's on every peer: `api.entities.id_of(node)` of a puppet is
  its host id (`entity.spawned` with `source == "net"` on clients).
- Replicated state arrives inside `begin_apply`/`end_apply`: those events carry
  `source == "net"` (and `money.changed.reason == "net"`).

## Layout

`net/` transport (ENet, Steam, loopback), protocol + codec (frames 4 / 5), Session
(with the MP2 module registry), MpAuthority, roster, clock, contract ·
`game/game_adapter.gd`, `game/bodies_adapter.gd` (the BODIES game boundary) · `sync/`
econ host/client (money clamp, bank / stats mirror, mirror fields), purchases,
progression, snapshot · `world/` avatars, puppets, pause/input/save guards ·
`world/bodies/` BODIES (replicators, puppets, interpolation, priority, budget, meta,
fixtures, stray guard, world snapshot) · `gameplay/`, `extensions/gameplay/`
GAMEPLAY · `grab/`, `extensions/grab/` GRAB · `mp2/` MP2 strings · `policy/` ·
`extensions/` upgrade_ui, hole, pause_menu (main_menu: UI stream). UI stream:
`lobby/`, `ui/`.

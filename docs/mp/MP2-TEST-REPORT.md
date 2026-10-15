# MP2 test report (2026-10-15)

Integration of the three MP2 streams of `docs/mp/MP2-DESIGN.md` (BODIES `68bbdb8`,
GAMEPLAY `c7c73c6`/`e47805c`, GRAB `9fd90af`), followed by real runs on this PC (one
Steam account, so every multi-instance run is ENet on 127.0.0.1). Every number below is
from a run listed here; reports and screenshots are in `dist/` (gitignored).

**Review round 2 (latest runs, after the fixes in "Review round 2" below):**

| Run | Command | Result | Report |
|---|---|---|---|
| Headless suites | `tools\test-headless.ps1` | **423 passed, 0 failed**; every script parse-checked; contracts and manifests OK | `dist/headless-report.json` |
| MP2, decomp host + decomp client | `tools\test-mp-loopback.ps1 -Suite mp2` | **host 92/92, client 93/93, PASSED** | `dist/mp-loopback-report.mp2-2inst.json` |
| MP2, **real game host** + decomp client | `tools\test-mp-loopback.ps1 -Suite mp2 -HostLive` | **host 92/92, client 93/93, PASSED** | `dist/mp-loopback-report.mp2-live.json` |
| MP2, 3 instances (host + 2 clients) | `tools\test-mp-loopback.ps1 -Suite mp2 -Clients 2` | **host 95/95, client 93/93, client2 23/23, PASSED** (re-runs the two harness fixes of the first round) | `dist/mp-loopback-report.mp2-3inst.json` |
| MP1 regression, decomp x2 | `tools\test-mp-loopback.ps1 -Suite mp1` | **host 38/38, client 34/34, PASSED** | `dist/mp-loopback-report.mp1-final.json` |
| MP1 regression, real game host | `tools\test-mp-loopback.ps1 -Suite mp1 -HostLive` | **host 38/38, client 34/34, PASSED** | `dist/mp-loopback-report.mp1-live.json` |
| Live UI (real game, real Steam lobby) | `tools\test-mp-ui-live.ps1` | **PASSED** | console |

First round (integration), for reference: headless 409/0; MP2 decomp host 86/87, client
84/84; real game host 87/87, 84/84; 3 instances 90/90, 84/84, 22/23; MP1 both 38/38, 34/34.
The sections below up to "Review round 2" describe that first round.

The real save folder (`%APPDATA%\Godot\app_userdata\Project P.I.T.T`) was hashed
before and after every run: **unchanged every time**. Every run checked for and left no
`projectpitt.exe` / Godot process. The game is left with the normal install
(`tools\install.ps1 -WithMP`).

## The owner's bug: "a black bar (the face) blocks the view of the player"

Fixed in `5853e21` (before MP2): joiners spawned inside the host's capsule, so each
camera sat inside the other puppet and its near-black visor box filled the screen. The
puppet now has a small light face plate, fades out from 1.25 m and hides inside 0.9 m of
the camera, and joiners spawn beside the host. MP2 does not touch `puppet.gd` /
`avatars.gd`, and adds nothing near a remote player that could cover the view (the host's
ghost collider has no mesh; the per-player rig camera is never `current`).

New loopback scenario **V1** checks it on both sides, in every MP2 run:

| Check (both sides) | Real game host run |
|---|---|
| other player's puppet drawn, opaque (transparency 0.00), in the camera frustum at 3.5 m | pass / pass |
| name label shown; face plate <= 0.3 m wide and light (value > 0.7) | pass / pass |
| nothing of the MP layer drawn within 0.5 m of the camera; the camera is the game's MainCamera | pass / pass |
| client walks into the host (camera 0.3 m from the capsule axis): the puppet hides | pass (body hidden) |

Screenshots looked at: `loop-livehost-mp2-v1-host-sees-client.png` (real game, 21:9: the
blue client capsule with its name and a small light face plate, nothing dark),
`loop-client-mp2-v1-client-sees-host.png` (yellow host capsule, gold name),
`loop-client-mp2-v1-client-inside-host.png` (standing inside the host: clear view, no bar),
`loop-client-mp2-b6-client-conditioned-at-rest.png` (host about 1.2 m away in a pile:
fully visible, nothing covers the view).

## Integration changes (cross-stream requests and mismatches)

- **Crate subclasses (spike S-M3, real game).** `metal/plush/anomaly_crate.gd` extend
  `wodd_crate.gd` by `class_name GamblingCrate`; once `wodd_crate.gd` was taken over they
  failed to compile ("Could not find class GamblingCrate"), so those crates could not
  spawn. Each now has its own extension with the same gates, listed before
  `wodd_crate_ext.gd` (it compiles the subclass against the original crate), and the
  loader lets a mod extend a script that only its own earlier extensions loaded. Verified
  in the real game's log (all four applied, no compile error) and by
  `test_mp2_gameplay_crates` + `test_extensions.test_base_loaded_by_own_earlier_extension_may_be_extended`.
- **GRAB tests** loaded `main_camera_grab_ext.gd` again on top of the taken-over
  `main_camera.gd` (every step counted twice): the rig now uses the game path when the
  extension is already in its chain; the override test compares with the game script.
- **UI:** `lobby_model.MP_PROTO` 2 (D8).
- **BODIES for GRAB/GAMEPLAY:** `host_release(eid, {})` only stops the follower (capture
  revokes leave the body as the game set it); an equipped tool is not driven by the
  follower (GAMEPLAY's rig poses it). Already in place: stub copy of `mp2_*`, contract and
  `mod.json` entries for GRAB, message whitelist and rate classes for GAMEPLAY kinds,
  wrap-around epoch compare, tick pinning.
- **Harness:** `scenario_mp2.gd` runs BODIES -> V1 -> GAMEPLAY -> GRAB -> B6 -> end
  checks -> G5; `-Clients 2` adds a third instance; world-snapshot timings in
  `session.wsnap_stats`.

## Fixes found by the real runs

| Found | Fix |
|---|---|
| Under 100 ms latency puppets rendered **ahead** of the newest frame and only extrapolated (B6 moving p95 0.40 m) | render delay = mean lateness of body frames + 2 x jitter + 33 ms (clamp 66-200). B6 p95 now 0.09-0.24 m |
| Budget cut on a quiet LAN: any 25 ms ping counted as "RTT > 2 x the 1 ms minimum" | RTT is congested only when also >= 50 ms above the minimum |
| Budget recovery too slow (> 20 s from the floor) | +15 % of the configured value per second after 5 s clean (about 10 s) |
| Host overload halving pushed a floor-budget client to 6 KB/s | the halving never goes below 12 KB/s |
| MP1 scenario still tested private-world contributions (removed in MP2) | on an MP2 session the host drops ducks into the one maw and the client checks the income once |
| `install.ps1 -WithMP` after a `-WithTests` install left the emptied test-mod folders in `mods/` | the installer also removes folders its previous install emptied |
| Harness: mark values read flat, lambda capture, BigInt stats, timing of the client's position vs the host's test spawns, B6 sample time pairing | fixed in `PittMPTests` |

## MP2 scenarios (real game host run unless noted)

**BODIES**

| Id | Result | Evidence |
|---|---|---|
| B4 late join, **350 entities** (crates, ducks, cash registers, flat and lucky ducks) | pass (all runs) | 350 puppets with the host's ids and pool ids, ids adopted (L7), 377 wsnap rows; snapshot 111 KB raw / 15.9 KB zstd, built in 10.4 ms (decomp 12.3 ms); `world_req` -> ready **360 ms** (received 43 ms, applied 317 ms); 0 strays. 3-instance: client2 joined late into a 3-player session in 519 ms. 3000-entity variant not run |
| B1 50 ducks pushed | pass | 50/50 puppets with host eids, all moving records carry velocity; at rest worst error **0.7 mm** (target 1 cm); screenshot `loop-client-mp2-client-sees-host-ducks-moving.png` shows the airborne ducks on the client |
| B2 recycle 20 + same-frame reuse | pass | despawned within 2 s, same node got a new eid, no leftovers (active == puppets) |
| B5 bandwidth per client | pass | see "Bandwidth" |
| B6 100 ms +- 30, 5 % loss | pass (live host) | moving error p50 **1.1 mm**, p95 **9.0 cm** (decomp host: 15 cm; 3-instance: 23.5 cm; target 25 cm); at rest worst **0.7 mm** after 3 s; budget fell to the 12 KB/s floor and was back to 48 KB/s within 15 s |
| B7 money clamp | pass | a local `add_money(1000)` reverted within one physics frame; `PittMultiplayer.contribute` unknown on the host |
| B9 tick pin | pass | 60 Hz on both after the join, host PerformanceMonitor stopped; client still 60 Hz in the end checks, after the phase-2 change |
| B3 cannon, B8 phase-2 debris | not run (no two-instance scenario yet; headless only) | |

**GAMEPLAY**

| Id | Result | Evidence |
|---|---|---|
| P8 ghost + rig follow the client | pass | ghost at the client avatar (0.0 m), rig at its eye, rig not current |
| P2 client buys a broom and the press | pass | host charged exactly 5050 once (50 + 5000); one new broom with the same eid on both; one press on both; client money == host; 0 client strays; the client then **grabs the bought broom** (granted, host table owner = client, back to host after the drop) |
| P3 automatic workbench | pass | host bought the duck machine, the client turned it on through the host (`interact`), 3 ducks made on the host (`products_autocrafted.duck` 0 -> 3), same eids on the client, resting poses within **0.7 mm**, 0 client strays |
| P10 shared combo | pass | host combo 5, client HUD combo 5 (its own ComboSystem physics off), client money == host after the payout |
| P11 penalty | pass | applied once, second within 2 s deduped, money mirrored |
| P1 maw feeding, **phase progresses once** | pass | 5 ducks consumed exactly once, money rose once; nutrition one tick short + one duck: host phase 1 -> 2 with exactly one `phase_changed`, the client played exactly one transition and ended in phase 2, money equal afterwards, host back to `open` |
| P4-P7, P9 | not run (headless only) | |

**GRAB**

| Id | Result | Evidence |
|---|---|---|
| G1 client grabs and throws, host sees it | pass | predicted locally, granted in **17 ms** (decomp 33-34 ms); host copy follows within 0.4 um; released, back to the host, epoch +2, host body dynamic; client converged to the host's landing (0.000 m) |
| G3 deny (body being consumed) | pass | host deny `busy`, no carry left |
| G2 race, same instant | pass | exactly one owner (start skew 11 ms), table matches, loser undone |
| G4 owner silent | pass | revoked after **1525 ms** (1500 +- 200), client dropped, no `own_rel` |
| G6 pause menu while holding | pass | normal release, body dynamic on the host |
| G5 disconnect while holding | pass | revoked on leave (`left`), body dynamic on the host and falls |
| G7-G9 | not run | |

**End checks (client, every MP2 run):** stray spawns 0, orphan frames 0, 60 Hz, local money writes 3 = B7's test write + the two combo payouts the client's
HUD made locally and the clamp reverted (P10, P1; see README limitations).

## Bandwidth (host -> each client, 1 s windows, while 50 ducks fly over a 400-object floor)

| Run | Client | Windows (B/s) | Budget |
|---|---|---|---|
| real game host | 1 | 31 791, 46 505, 49 500, 50 236 | 48 000 |
| decomp host | 1 | 42 874, 45 040, 48 709, 49 419 | 48 000 |
| 3 instances | 1 | 12 312, 17 142, 17 706, 20 437 | 48 000 |
| 3 instances | 2 | 5 366, 7 604, 9 046, 10 018 | 16 464 (adapted down: three editor instances on one PC) |

The body stream stays at its budget (the pass bound is budget x 1.1 + 2 KB/s); the
1-2 KB/s over 48 000 is the lifecycle/meta/control traffic outside the body budget.
Over the whole bodies section the host sent 13 056 records in 422 packets (340 KB).
Under conditioning the budget went to the 12 KB/s floor and back to 48 KB/s within 15 s.

## MP1 regression with the real game

Both MP1 runs (decomp x2 and real game host) pass every MP1 step on an MP2 build: join
and snapshot, avatars both ways and the 10 m teleport, `money.add` exact on the client
and refused from it, income counted once (step 4 now feeds the one shared maw), upgrade
and tool purchase, phase 2 + unlock replication, local pause (tree never paused, host
puppet keeps moving), leave + rejoin at phase 2, 100 ms +- 30 / 5 % loss, host leave ->
client on the main menu with `host_left`, isolation off, session file deleted.
Screenshot `loop-client-2b-sees-host-at-spawn.png` (both players in the start elevator,
about 1.3 m apart): the host capsule with its light face plate, no dark bar.

## Review round 2: verified issues and outcomes

Three reviews (correctness, performance, coverage). Each finding was re-checked against
the code and the decompiled game first.

| # | Issue | Outcome | Change |
|---|---|---|---|
| R1 | Client pause menu "Clear items" recycles host puppets; pool LIFO reuse lets two eids drive one node | **Fixed** | `pause_menu_ext`: Clear items refused on clients (`MP_HOST_ONLY`). `ReplicatorClient` hardened: a node handed out by the pool that another puppet still drives, or a puppet node recycled / disabled by client code, drops that puppet and respawns its eid from the newest host state (`puppet_lost`); `pooled_count` kept incrementally |
| R2 | `build_wsnap` overwrites `meta_last`, swallowing unsent meta changes for peers already in the world | **Fixed** | the not-yet-sent diff is queued into the meta stream before `meta_last` moves |
| R3 | A client can rack a panel the host player holds | **Fixed** | refused when anyone else holds / equips it (`hold_kind` + owner), and while the maw / cannon / vacuum / press has it. Placed panels stay rackable (the game unplaces them) |
| R4 | Session end / phase 5 frees tools equipped on remote rigs | **Fixed** | `rigs.unequip_all()` on host world stop and in `rigs.clear()`; GRAB's `world_stopped` emits owner_changed (unequip) before restoring the freeze state |
| R5 | Fast release + re-grab within one RTT is force-dropped | **Fixed** | a re-grab waits while the released request is unanswered (refusal `pending`) |
| R6 | `own_rel` / `own_unequip` trust the client's position and throw origin | **Fixed** | release state further than grab reach + 2.5 m from the owner's eye falls back to the last accepted held frame (velocities capped at 60 m/s); throw origin and unequip drop clamped to reach (`rel_clamped`) |
| R7 | Hold-to-craft forwarded every frame, resetting host progress | **Partly valid**: `interact_client` already sends one start per hold (no flood, no bucket drain). Real parts fixed: the host no longer restarts a bench that already crafts (second holder), and a release before the replayed `is_crafting` still sends the stop |
| R8 | A leaving player's racked panels are deleted | **Fixed** | the stack comes back as panels at the player's last pose (or next to the host); also on host world stop (`rack_returned`) |
| P1 | 9 clients: per-tick CPU cap skips peers, their rate falls far below budget, nothing reports it | **Fixed** | shared per-tick work (below); a skipped peer's next serve gets the bytes of the ticks it missed (up to 3); `stats()` reports measured `eff_bps` and `host_scale` |
| P2 | Per-peer redo of weights, sort, record encode | **Fixed** | once per tick: peer-independent weight, sizes, positions, owner, and record bytes (encoded lazily once, SNAP patched per peer); per peer only distance weight + a packed accumulator array + native-sorted top-k (`Priority.select_top`) |
| P3 | Client loops over every puppet each physics frame | **Fixed** | only the active set is driven; a 64-per-frame round-robin re-asserts the freeze and checks for lost nodes |
| P4 | 1200 B packets vs Steam's fragmentation point; Nagle on | **Fixed** | senders pack to 1100 B (`PACK_TARGET`, decoders still accept 1200); `no_nagle = true` on the Steam peer (present in the bundled GodotSteam). S-M11 itself still needs the two-PC test (manual test 15.9) |
| P5 | World snapshot built and serialized in one host frame; 3000 not measured | **Partly fixed**: the client no longer normalizes the numeric row fields (only each row's meta); the host build stays one frame. **Known gap**, see below |
| P6 | Snapshot chunks sent unchecked | **Fixed** | a refused chunk aborts the join at once (`bye` `MP_ERR_WORLD_SEND`, `wsnap_send_failed`) |
| P7 | Due SLEEP sends can starve awake bodies | **Fixed** | at most 40 % of a tick while bodies are awake (`sleep_capped`); the schedule is only walked when something is due |
| P8 | Budget ignores packet headers / overhead, no host-wide cap | **Fixed** | every packet's header + 40 B overhead come out of the budget; `HOST_UPLOAD_BPS` = 400 KB/s splits across peers (never below a peer's 12 KB/s floor) |
| P9 | Overload guard measures its own cost and does not cut CPU | **Fixed** | the replicator's own time is subtracted from the physics load; under overload each peer is served every other tick (its banked budget keeps the byte rate) |
| P10 | Random loss pins the budget at the floor; reordering counted as loss | **Fixed** | cut on RTT congestion, loss > 15 %, or loss > 5 % with RTT +20 ms (queueing); late packets are subtracted from the reported gaps |
| P11 | Other per-frame / per-tick allocations | **Partly fixed**: meta poll and awake sampling iterate without `keys()`; `send_world` stringifies once for all peers. Remaining: decoded records are still one Dictionary each |
| P12 | ch3 cap checked on encoded size on the host, raw size on the client | **Fixed** | the host checks both, and counts `world_too_large` |
| P13 | Resting scan: 40 per tick, position only | **Fixed** | the scan scales to a 1 s lap and detects rotation in place |
| C1 | Wheel / right-click / D-pad on machines (main_camera `_input`, `_handle_dpad_context`) outside the input scope: dropped on clients | **Fixed** | both wrapped in the input scope; loopback P12 drives the real `_input` |
| C2 | LMB toggle of automatic benches (`interact_ray._input`) outside the input scope | **Fixed** | wrapped; loopback P3 now toggles through `interact_ray._input` |
| C3 | Weight piston (`piston_3`) not handled | **Fixed** | `piston_3_ext.gd`: tune forwarded, `cycle_weight_preset` / `set_weight_preset` replay-only, meta `wpreset`; contract entries |
| C4 | `piston_3` client phase never leaves RETRACTED (puppets are frozen) | **Fixed** | on clients the front mass counts puppets (they stand for dynamic host bodies) |
| C5 | Loopback never uses the real input path; harness fixes not re-run | **Fixed** for the dispatchers above (P3, P12) and re-run (3 instances pass). Other gaps listed below |

New tests: headless `test_mp2_gameplay_review` (7), `test_mp2_bodies_review` (4),
`test_mp2_grab_prediction.test_regrab_waits_for_the_released_request`,
`test_mp2_grab_release.test_far_release_state_is_clamped`,
`test_mp2_bodies_codec.test_pack_records_matches_pack_bodies`, budget cases; loopback
P12 (magnet_2 and piston_3 tuned with the client's real mouse-wheel dispatcher: host
flips / changes the preset, the client replays it) and P3 through `interact_ray._input`.
A harness race found by the 3-instance run (a duck spawned in the same frame had id 0 in
the host's list) was fixed in `gameplay_host._active_ids`.

**Round 2 numbers.** Bandwidth host -> client (1 s windows, B5): real game host 36.2,
44.9, 45.8, 46.7 KB/s; decomp host up to 46.7 KB/s; 3 instances: client 1 up to 48.5,
client 2 up to 48.5 KB/s, both at the full 48 KB/s budget (first round: 20.4 and 10.0).
B6 (100 ms +- 30, 5 % loss): moving error p50 0.9 mm / p95 7.4 cm (real host), 14 cm
(decomp), 18 cm (3 instances); resting 0.7-0.8 mm; budget still adapts down (RTT) and
recovers within 15 s. B4 late join, 350 objects: 111 KB raw / 15.8 KB zstd, host build
11.7 ms, client apply 311 ms, request to ready 350 ms.

Micro-benchmarks (editor console build, headless, `_send_tick` with 9 peers, 60 ticks):

| Awake / resting | Before: us/tick, B/tick/peer | After: us/tick, B/tick/peer |
|---|---|---|
| 50 / 400 (1 peer) | 345, 1577 | 341, 1526 |
| 50 / 400 | 2074 (60/60 overruns), 1048 | 989 (0 overruns), 1422 |
| 200 / 800 | 2352, 523 | 1588 (0), 1462 |
| 500 / 2500 | 3211, 338 | 2690 (2), 1528 |
| 1000 / 2000 | 3303, 179 | 3328 (banked), 1387 |

(B/tick/peer after the change is net of the 40 B/packet overhead now counted; 1600 is
the 48 KB/s tick.) Client `physics_step`, 3000 puppets all idle: 2443 us -> about
500 us per frame (the remaining per-frame cost is the moving puppets' transform writes).

## Remaining blockers / not covered

- No blocker. Not automated yet: B3, B8, the 3000-entity wsnap timing, P4-P7, P9, G7-G9,
  I1/I2 as one combined session (their parts ran in one session each run).
- Large worlds: the world snapshot is still built, stringified and compressed in one host
  frame per joiner. Measured 11.7 ms at 350 objects (317 B per row); extrapolated about
  35 ms at 1000 and about 100 ms at 3000, felt once by everyone per join. A binary row
  format and a build spread over frames are the next step (not done in this round).
- Host CPU at extreme load: 1000 awake bodies with 9 clients still takes about 3.3 ms per
  30 Hz send tick (editor build); every peer now keeps its byte rate.
- Steam fragmentation (S-M11) and the effect of `no_nagle` are only checkable over real
  Steam: `MANUAL-STEAM-TEST.md` 15.9.
- Real Steam between two PCs (SteamMultiplayerPeer data path, NAT/relay bandwidth) needs
  the owner: `docs/mp/MANUAL-STEAM-TEST.md` section 15.
- Secret ending D15 is partial (the hack arms the elevator for everyone; the session does
  not move to `ending`), recorded in the README limitations.

# MP1 test report (2026-10-14)

Integration of the UI and NET streams of `docs/mp/MP-DESIGN.md`, followed by
real runs. Every number below comes from a run on this PC (one Steam account).
Reports and screenshots are in `dist/` (gitignored):

| Run | Command | Result | Report |
|---|---|---|---|
| Headless suites | `tools\test-headless.ps1` | **245 passed, 0 failed** (+ contract checks, parse checks) | `dist/headless-report.json` |
| Live UI in the real game, real Steam lobby | `tools\test-mp-ui-live.ps1` | **38 passed, 0 failed**, saves unchanged (run ui-live-20261014-224235) | `dist/mp-ui-live-report.json`, `dist/screens/live-*.png` |
| Two instances (decomp editor x2), ENet loopback | `tools\test-mp-loopback.ps1` | **host 34/34, client 31/31** (run 20261014-224324) | the JSON was overwritten by the next run (same file name); console summary recorded here |
| Real game as host + decomp client, ENet loopback | `tools\test-mp-loopback.ps1 -HostLive` | **host 34/34, client 31/31** (run 20261014-224450) | `dist/mp-loopback-report.json`, `dist/screens/loop-*.png` |

These numbers are from the re-run after the review fixes (section "Review fixes"
below). The first integration run had 226 headless, 35 live UI and 32/28 loopback
checks; the added checks cover the fixes.

The real save folder (`%APPDATA%\Godot\app_userdata\Project P.I.T.T`) was
SHA-256-hashed before and after every run that touched the game: unchanged
every time. No `projectpitt.exe` or Godot process was left running. The game is
left with the normal install (`tools\install.ps1 -WithMP`: PittAPI,
ExampleMod, PittMultiplayer; no test mods).

## Integration changes

- **LobbyService `set_lobby_data(key, value)`** (NET request 1). Owner only; `state`
  is reserved for `set_state()`. Steam writes it with `setLobbyData`. The headless test
  `test_mp_ui_steam.test_host_creates_friends_only_lobby` checks it.
- **Start-availability reasons** (UI request 3). `Session.can_start()` now returns
  `MP_START_NOT_HOST`, `MP_START_BUSY` (starting or loading) and `MP_START_NOT_READY`.
  These keys are registered in all 10 locales. Before, it returned `MP_HOST_ONLY` and the
  unregistered `MP_ERR_BUSY`.
- **Already compatible.** The other cross-stream requests needed no change:
  - `dev_targets` is a comma string, which the dev service parses.
  - `lobby_left` without `lobby_entered` is ignored while the session is idle.
  - `ended` is emitted on every teardown, including on the main menu.
  - `roster.to_members` uses `platform_id` as the id.
  - `mod.json` lists `main_menu_ext`.
  - `test-headless.ps1` runs both contract files.
  - `stub_lobby.gd` is in place.
  - The UI maps `host_state` "starting" to `MP_HOST_LOADING` and "loading" to `MP_JOINING`.
- **PittMPTests changes:**
  - New `scenario_ui_live.gd` (role `ui_live`) and its driver `tools/test-mp-ui-live.ps1`.
  - Screenshot and face-the-puppet helpers in `scenario_base.gd`; the loopback flag now
    carries `screens_dir`.
  - Two test bugs fixed (below).

## 1. Live UI in the real game (Steam)

`tools\test-mp-ui-live.ps1` installs `-WithMP -WithTests` and forces
`transport=steam`; the cfg is backed up and restored. It launches through
`steam://rungameid/4026250`, and the scenario drives the screens through the real
buttons' `pressed` signals. Each check passed:

- **Main menu:**
  - `MPMultiplayer` is at index 2, directly after `Play` at index 1, in the same
    `Background/MenuButtons`.
  - It uses the same theme font and size as Play.
  - It sits below Play on screen (y 404 for Play, 492 for Multiplayer).
  - It is enabled, since Steam is available (`lobby_available {ok: true}`).
  - See `live-01-main-menu.png`. The label is translated by the game's auto-translate
    ("Multiplayer").
- **Host/Join:** the menu buttons are hidden and the Host/Join panel shows
  (`live-02-host-join.png`).
- **Join, empty state:**
  - The friend scan is active while the panel is visible: 0 rows and "No friends are
    hosting" in the game's save-slot style (`live-03-join-empty.png`).
  - Back stops the scan.
- **Host, real Steam lobby:**
  - `createLobby(FRIENDS_ONLY=1, 10)` created lobby `109775245203784932`.
  - Steam reports owner = my SteamID, 1 member and a member limit of 10.
  - Lobby data:
    `{host_name: <host persona name>, pitt_version: 1.0.8, pittapi_version: 1.1.0, mp_proto: 1, mods_hash: 9f9765610a7ba95e, state: waiting, members: 1, max: 10}`.
  - Session state is `lobby` with a Steam transport target.
  - The lobby screen lists exactly one row, "<host persona name> / Host | You", under
    "PLAYERS 1/10".
  - Start and Invite are visible and Start is enabled (`live-04-lobby-host.png`).
- **Leave:**
  - The game's ConfirmDialog opens (`live-05-leave-confirm.png`). Confirming leaves:
    the service is out of the lobby, the session is idle, and the rich-presence
    `connect` is cleared.
  - The screen goes back to Host/Join, then the main menu (`live-06`, `live-07`).
  - **Note:** Steam's `getNumLobbyMembers` still returned 1 for the lobby we had left. It
    is a stale local cache for a lobby you are no longer in, so it is recorded and not
    asserted. The first run asserted it and failed on exactly this; the leave itself
    was correct.
- At 3440x1440 (ultrawide) the member list sits right of the menu column, in the
  free area, as the UI stream designed it.

## 2. Two-instance ENet loopback

Host and client each run `PittMPTests`, and the two exchange marks through
their report files. Conditioning is 100 ms ± 30 ms latency with 5% loss in step 10.
The same scenario passed twice: once with two decomp editor instances, and once
with the real Steam game as host (`-HostLive`) and a decomp client. Values below
are from the `-HostLive` run unless marked.

| Requirement | Evidence |
|---|---|
| Host Start → both load the world | host `start_game`, `host_open` (state in_game); client `in_game_within_180s` (join 9.8 s) |
| Late join through a snapshot | client joins a host already in the world: money `4999998` = host, phase 1 = host |
| Avatars both ways, moving | host `client_puppet_on_host`; client `host_puppet_within_1s`, `teleport_within_300ms` (19 ms with -HostLive, 77 ms with decomp; puppet at exactly the host's position); `loop-client-3-sees-host.png` (the yellow "Host" capsule with its name label), `loop-host-8-sees-client-rejoined.png` (blue client capsule) |
| Money host → client | `host_money_exact` (client 5123454 = host) |
| Client income → host, no double count | `host_money_includes_client_income` (5125954 expected = actual), `converged_no_double_count`, `host_products_consumed_rose` |
| Client purchase routed to host | client presses a real UpgradeUI row: `sprint` level 0 → 1 on both (`upgrade_level_plus_one_mirrored`, `host_level_plus_one`); tool `press` charged on the host (5125944 → 5120944) and spawned only in the client's world (`tool_in_own_world`) |
| Phase replication | host `phase.set 2`: both settle phase 2 (`host_settled_2`, `client_transition_settled`) |
| Unlock replication | host forces `unlock_box`: `unlock_replicated` on the client |
| Pause is local only | client opens the real pause menu: 0/122 physics frames paused, the host puppet moved 2.02 m meanwhile, the menu is open (`loop-client-7-local-pause.png`) |
| Leave / rejoin mid-game (late join) | client leaves → main menu, session file deleted, host roster back to 1; rejoins in 4.1 s at phase 2 with the host's money (`rejoined_at_phase_2`, `rejoined_puppet_on_host`) |
| Under latency and loss | `money_under_conditioning`, `avatars_under_conditioning`, measured RTT 169 ms |
| Host quits → client back to menu with a message | client `client_back_on_main_menu`, `ended_host_left` (reason `host_left`), isolation off, session file deleted, authority back to `local`; `loop-client-9-host-left-menu.png` shows the game's dialog "Session ended / The host ended the session" |
| Saves | client `isolated` (active save = session file) and `save_locked`; real save folder hash unchanged |

### Test bugs fixed during the runs

1. **`tool_in_own_world`** counted only ObjectPoolManager objects. The press (and the
   trading terminal) are scene instances added to `current_scene` by
   `upgradeUI._spawn_tool_instance`, so the count now includes `current_scene`
   children. It passes (118 → 120).
2. **`teleport_within_300ms`** timed out after 3 s because the host teleported 10 m
   along +X into level geometry, and the physics pushed it away from the asserted
   target. The host now teleports halfway toward the client's puppet and marks its
   *actual* position. The lag is now 19 to 77 ms.

## Review fixes (2026-10-14, second pass)

Two static reviews (NET/sync and UI) reported 21 issues. Each was re-checked
against the code and the decomp before it was fixed; none turned out to be a
false positive. One (the member list position) was kept and recorded as a
deviation instead of being changed.

| # | Sev | Issue | Fix | Evidence |
|---|---|---|---|---|
| 1 | critical | Host loops `value/1e18` times on a big money contribution | `add_money_digits` / `spend_floor_digits` use one BigInt `add_big`/`sub_big` above 18 digits (like the loader's `money.add`); contributions over 30 digits are refused | `test_huge_money_is_one_bigint_operation` |
| 2 | major | Host runs any non-cheat authority command from clients (`money.add`, `item.buy`, `entity.*`) | Loader: new `remote` registration flag (in `describe`). Host allowlist: only `remote: true` commands (contribute, buy_*) run for clients, everything else gets `ERR_DENIED` | `test_non_remote_commands_refused`; live `client_money_add_refused` |
| 3 | major | Any Steam user with the host's SteamID is admitted; hello name trusted | Steam transport: hello admitted only for lobby members (5 s grace for a trailing `lobby_chat_update`, then refused); names come only from the lobby; peers that leave the Steam lobby are kicked | `test_steam_peer_must_be_lobby_member` |
| 4 | major | Timed-out contribution dropped, then resent as a new seq (double income) | `ERR_UNAVAILABLE` keeps the entry pending and resends it with the same seq (the host answers dup); only a definite refusal drops it | `test_unacked_contribution_resent_with_same_seq` |
| 5 | major | Feed entries unchecked: a client can finish phases at once | Known product types only (`lucky_` allowed); per-peer nutrition budget of 5 % of the phase's need per second (2 s burst), read from the `hole.gd` constants | `test_feed_types_and_budget` |
| 6 | major | Direct `UnlockManager.check_milestones()` calls still unlock on clients | While detached, every milestone gets an unmet `requires` sentinel (only `check_milestones` reads `requires`; `force_unlock` ignores it), restored at teardown | `test_check_milestones_blocked_on_clients`; live `milestones_blocked`, `direct_check_milestones_unlocks_nothing` |
| 7 | major | Steam "Join Game" while the game runs was ignored | `join_game_requested(steam_id, connect)` connected; lobby id parsed from the connect string | `test_join_game_requested_connect_string`; manual checklist 4.4 |
| 8 | major | "Multiplayer" at size 104 widened the menu column and moved Play/Options/Credits/Quit about 97 px right | `ui/fit_width.gd`: Play's size when the label fits, else the largest size that fits the 736 px column; re-fit on locale and menu-scale changes | `test_label_fits_the_menu_column`; live `column_keeps_its_width` (736), `play_centred_in_column` (417 = 417), font 66 vs Play 83; `live-01-main-menu.png` |
| 9 | minor | Chunks overtaking `snap_begin` were dropped (join hang) | Client buffers early chunks (bounded) and replays them on `snap_begin`. Conditioning gained `channel_delay_ms`; the loopback rejoin now runs with the control channel 300 ms late | `test_chunks_before_snap_begin`; live `rejoin_with_chunks_before_header` (early_chunks 1) |
| 10 | minor | `ready` accepted without a served snapshot; `cmd` from lobby/loading peers | `ready` needs the matching `_serving` xfer; `cmd` needs roster state `in_game` | `test_ready_needs_a_served_snapshot`, `test_cmd_refused_before_in_game` |
| 11 | minor | A floored fine came back as income | Delta computed against the floored expectation; the pending ledger entry absorbs the cut-off part | `test_floored_fine_is_not_income` |
| 12 | minor | Joiner spawned on a ring into walls ($1-2 join cost) | Spawn on the host's last safe position + 0.3 m; small fines (up to $100) in the first 5 s are absorbed locally | `test_join_time_fine_absorbed`; live `join_cost_zero` (host stays at 5,000,000) |
| 13 | minor | Isolation lifted before the client left the host's world | Save hold: isolation stays on until the world is gone (or 240 s if it never appeared); `force_main_menu` fallback when there is no PauseMenu | `test_client_leave`; live `session_file_deleted`, `isolation_off` |
| 14 | minor | Pause guard unpaused the secret ending's end screen | Exempt while an end-of-game menu is `MenuManager.current_menu` | `test_pause_guard_exempts_end_screen` |
| 15 | minor | Late avatar frames recreated ghost puppets; reused slots kept stale puppets | Frames for slots not in the roster are ignored; a slot whose peer changed is freed | `test_no_ghost_puppet_for_departed_slot` |
| 16 | minor | Buy timed out after the host charged: item lost | Host sends `grant` on the ordered control stream; a client whose result timed out spawns the item on the grant | `test_late_grant_spawns_the_item` |
| 17 | minor | `int(env.id)` on a non-int id | Id read only when it is an int | `test_cmd_refused_before_in_game` |
| 18 | minor | Member list not at the exact screen centre | Kept: the exact centre overlaps the column at 16:9 and 4:3. Recorded as a deviation for the owner in `MULTIPLAYER-UI-SPEC.md` | spec |
| 19 | minor | Host leaving left a joinable stale lobby | Host sets state `ending` (not joinable) before `leaveLobby` | `test_host_marks_lobby_ending_before_leaving` |
| 20 | minor | Join list lost controller focus when the focused row vanished | Falls back to `first_focus()` while a gamepad is in use, like the lobby panel | code only (no gamepad in headless) |
| 21 | minor | `+connect_lobby` consumed before Steam was up | Retried every 0.5 s for up to 10 s while `MP_ERR_NO_STEAM`; consumed only when the join can run | `test_launch_arg_join_waits_for_steam` |
| 22 | minor | 39 of 75 strings untranslated in 9 locales | All 75 keys in all 10 locales | `test_every_locale_complete` |

Also fixed along the way: the conditioned send queue used an unstable sort, and
packets sent after conditioning was switched off could overtake queued ones on a
reliable channel. Both now keep send order.

## Observations, not failures

- **Joining no longer costs money** (`join_cost_zero` passed in both loopback runs).
- **Multiplayer button size.** In English the label is drawn at 66 px against
  Play's 83 px (menu scale 0.8), so the column keeps the game's layout. A shorter
  label would restore the full size; see the deviation note in the UI spec.
- **The host-side puppet** is still hard to see at a distance in dark areas
  (`loop-host-3-sees-client.png`). Possible polish: an unshaded rim or emission.
- **The client's pause menu still shows Save / Load / Delete.** Pressing them is
  refused with `MP_HOST_ONLY`. Hiding them would be clearer.
- **Install tooling:** this time, uninstall followed by `install.ps1 -WithMP` left no
  empty test folders.

## Not covered (needs two PCs and two Steam accounts)

These cannot be tested from one Steam account: the SteamMultiplayerPeer data path,
a second member joining a real Steam lobby, friend lobby discovery with a real
friend, overlay invite acceptance, `join_requested`, `join_game_requested`,
`+connect_lobby`, the lobby-membership check with a real second account, and
bandwidth. See `docs/mp/MANUAL-STEAM-TEST.md`.

## Re-run

```powershell
powershell -ExecutionPolicy Bypass -File tools\test-headless.ps1
powershell -ExecutionPolicy Bypass -File tools\test-mp-loopback.ps1            # 2 decomp instances
powershell -ExecutionPolicy Bypass -File tools\test-mp-loopback.ps1 -HostLive  # real game hosts (launches the game)
powershell -ExecutionPolicy Bypass -File tools\test-mp-ui-live.ps1             # real game, real Steam lobby (launches the game)
powershell -ExecutionPolicy Bypass -File tools\uninstall.ps1; powershell -ExecutionPolicy Bypass -File tools\install.ps1 -WithMP   # back to the normal install
```

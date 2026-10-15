# Manual Steam multiplayer test (MP1 + MP2 shared world)

The automated tests cannot cover real Steam play: one Steam account cannot
connect to itself, so `tools/test-mp-loopback.ps1` uses ENet on localhost. This
checklist covers the Steam path (friends-only lobby, SteamMultiplayerPeer,
invites, rich presence). Run it on two PCs.

## Already verified automatically (one PC)

`docs/mp/MP1-TEST-REPORT.md` covers these: the menu button and screens in the real game,
hosting a real friends-only Steam lobby (data, owner, limit 10, leave), the Join empty
state, and over ENet loopback with the real game as host the whole session flow
(start, late join, avatars, shared money and purchases, phase and unlocks, local pause,
rejoin, host quit). This checklist is for what needs **two Steam accounts**: the
SteamMultiplayerPeer data path, discovery through a real friend, invites,
`join_requested` / `+connect_lobby`, and bandwidth. Watch for the known quirk
"joining costs the wallet $1-2" (MP1 report) and note if it happens on Steam too.

## You need

- Two PCs, two Steam accounts that are **friends**, both owning Project P.I.T.T. v1.0.8.
- The same repo revision on both: `powershell -ExecutionPolicy Bypass -File tools\install.ps1 -WithMP`
  (game closed). `tools\uninstall.ps1` removes everything again.
- A backup of both save folders: `%APPDATA%\Godot\app_userdata\Project P.I.T.T\`
  (copy the whole folder). Also note the SHA-256 of every `savegame*`, `sandbox.save*`
  and `profile.cfg` on PC **B** (the client):
  `Get-ChildItem "$env:APPDATA\Godot\app_userdata\Project P.I.T.T" -File | Get-FileHash`
- Transport must be Steam (the default). If you used the loopback tests on this PC,
  check `...\Project P.I.T.T\pittapi\config\PittMultiplayer.cfg`: `transport="steam"`.

PC **A** hosts, PC **B** joins. Logs: `...\Project P.I.T.T\pittapi\pittapi.log`
on each PC. With `dev_console=true` in `pittapi\config\pittapi.cfg`, the console
(`` ` ``) command `mp dump` prints the session state, RTT, drops and counters.

Write down PASS/FAIL and anything odd for every step.

## 1. Menu

1. Start the game on A. **Multiplayer** sits directly below **Play**, same font, size,
   hover sound and click sound as Play.
2. With a controller: the button is reachable with the d-pad and Esc/B goes back.
3. Start a single-player game, return to the main menu: the button is still there
   (exactly one).

## 2. Host lobby

1. A: Multiplayer > Host. The lobby screen shows A's Steam name in the centre, with
   the host tag. Buttons: Start, Invite friends, Leave.
2. A: Invite friends opens the Steam overlay invite dialog for this lobby.
3. On B's Steam friends list, A shows "Join Game" (rich presence).

## 3. Join list

1. B: Multiplayer > Join. A's lobby appears **without** pressing Refresh, with A's
   name, `1 / 10` and "Waiting".
2. Refresh works. Leave on A: within ~10 s the row disappears on B.
3. With no friend hosting: the empty state text is shown.

## 4. Joining (three ways)

1. B: click A's row: B enters the lobby, both lists show 2 players.
2. B leaves; A sends an overlay invite; B accepts: B enters the lobby.
3. B quits the game. B: Steam friends list > A > "Join Game": the game starts and
   goes straight into A's lobby (`+connect_lobby`).
4. B leaves the lobby but keeps the game running on the main menu. B: Steam friends
   list > A > "Join Game": B goes straight into A's lobby (`join_game_requested`).
5. B starts the game while Steam is still connecting (launch from "Join Game" right
   after Steam starts): the join is not lost; B lands in A's lobby once Steam is up.

## 5. Start

1. A: Start. A sees the game's own save panel (Continue / New Game). Sandbox is refused
   with a message. B shows "Host is loading".
2. A picks a save (or New Game). A loads into the world; B loads into the **same**
   progress (money, unlocked items, phase) and spawns next to A.
3. Both see the other as a coloured capsule with a name label; movement is smooth
   (no teleporting every frame), jumps and crouching look right.

## 6. Shared economy

1. A earns money (feed the maw): B's money rises by the same amount.
2. B feeds the maw (throws a duck in): A's money rises once (not twice) and B's money
   equals A's (MP2: there is one maw, run by A; B's money is a mirror).
3. B buys an upgrade at the terminal: the level rises on both; money is charged once.
4. B buys a tool: money is charged once; the tool appears **once**, at the terminal's
   spawn spot, and both see it (MP2 shared world; see section 15).
5. Both press buy at the same moment with money for only one purchase: only one goes
   through, money never negative.

## 7. Progression

1. An unlock on A (e.g. the first milestone) shows the unlock notification on B too.
2. Fill the hole to phase 2 on A (or with A's console `cmd phase.set {"phase":2}`):
   both play the phase-2 transition and end in phase 2.

## 8. Pause

1. B opens the pause menu: A keeps playing; B's puppet on A stops moving; B's own
   player is frozen while the menu is open.
2. B opens the Steam overlay (Shift+Tab): same as above, A unaffected.
3. B: pause > Save / Load / Delete: refused with a message. A: Save works; Load and
   Delete are refused.

## 9. Late join

1. With A in the world (phase 2), a friend (or B after leaving) joins from the Join
   list ("In game"): they load straight into A's world at phase 2 and money.

## 10. Leaving

1. B: pause > Main Menu: B is on the main menu without a dialog; A sees "B left".
2. A: pause > Main Menu: the confirm text says the session ends; B returns to the main
   menu with "The host ended the session".
3. A in a session with B: Alt-F4 on A. Within ~15 s B returns to the main menu with
   "Connection lost".
4. 10 s after each case: no lobby of A is left in B's Join list (no ghost lobby).
5. A and B in game: A's roster and toasts show B under B's Steam persona name (the
   host never uses the name B's game sends).
6. If B drops out of the Steam lobby while the P2P connection stays up, A removes B
   from the session within a few seconds.

## 11. Version mismatch

1. On B, change `mods\PittMultiplayer\mod.json` version (or install an older build).
   A's lobby shows disabled on B with the reason. Restore it afterwards.

## 12. Saves

1. On B, re-hash the save files from "You need": **all unchanged** (B never saves in a
   session; the session file lives in `pittapi\mods\PittMultiplayer\session\` and is
   deleted when the session ends).
2. On A, continue A's slot in single player: it holds the merged co-op progress.

## 13. Achievements

1. B joins a lobby whose progress already meets some achievements B does not have:
   **nothing** is granted on join.
2. A threshold crossed while connected (e.g. a phase change) grants it once on B.

## 14. Bandwidth

1. Windows Task Manager > Performance > Ethernet/Wi-Fi on A with 2 players walking
   around: under ~50 KB/s per client (MP2 body frames are budgeted at 48 KB/s per client
   by default; `mp stats` shows the per-client numbers).

## 15. MP2 shared world (two PCs)

The automated loopback (`docs/mp/MP2-TEST-REPORT.md`) covers these over ENet on one PC;
this checks them over Steam between two real players.

1. **Shared ducks.** A spawns or crafts a handful of ducks and pushes them (walk into
   them, throw one). B sees the same ducks move, smoothly, and they come to rest in the
   same places on both screens (compare a pile side by side).
2. **Grab and throw to each other.** B picks up a duck and throws it at A: A sees it
   carried at B's hands while B holds it and sees it fly and land where B saw it land.
   A then throws one back to B. Both try to grab the same duck at the same moment: only
   one gets it, the other's hands stay empty (no duck stuck between them).
3. **Buy on one PC, use on the other.** B buys a broom (or a fan) at the terminal: money
   drops once; exactly one broom appears at the terminal on both screens. A picks it up
   and uses it; B sees A holding it.
4. **Co-op workbench.** Buy the automatic duck machine (one of you): it appears on both
   PCs. B switches it on: A sees it running and both see the same ducks come out.
5. **Combo on both.** A throws several ducks into the maw quickly: the combo counter
   shows on both HUDs, the payout is added once (B's money equals A's after it ends).
6. **Avatars.** Stand 2-4 m apart and look at each other: the other player is a
   coloured capsule with a small light face plate and a name tag, clearly visible. Walk
   into each other: the other capsule fades and disappears instead of covering the
   screen (no black bar), the name tag stays.
7. **Bandwidth.** With `dev_console=true`, console `mp stats` on A while both play on a
   busy floor: the per-client downstream stays under 50 KB/s.
8. **Late join on a busy floor.** With a few hundred objects lying around, a third
   friend (or B after leaving) joins: they load in within seconds after the loading
   screen and see every object where A has it.
9. **Packets on Steam (spike S-M11).** During step 7, open Steam's networking overlay
   (or `steam://open/console` then `net_status`) on A: the packets per second to B
   should be about the same as the messages sent (roughly 60-70 per second at the full
   budget, plus avatars); about twice that means body frames are being fragmented.
10. **Machines with the mouse wheel.** B looks at a magnet II, a vacuum II and a weight
    piston (piston III) and scrolls the wheel: the mode / filter / weight preset changes
    on both screens. B left-clicks an automatic duck machine: it switches on for both.
11. **Clear items.** On B (not the host) the pause menu's Clear items says only the host
    can do it; on A it clears loose products for both players.
12. **The 0.2.0 bug (lanes).** A holds left click at the manual duck workbench: B sees
    the new duck pop out. B does the same at the bench: a duck appears on both screens.
    B grabs it. In both `pittapi.log`s the `mp stats` lines show `ch3` traffic in both
    directions (`ch3 tx N/..B rx M/..B` with N, M > 0 on the host and the client) and
    `drops {}`; there is no `protocol drop kind_not_allowed:ents` (or `:interact`,
    `:own_req`) WARN.

## Reporting

Send `pittapi\pittapi.log` and `pittapi\mp_session_last.json` (written when a session
ends or the game quits) from both PCs and the PASS/FAIL list. After the test:
`tools\uninstall.ps1` (or keep it installed) and restore the save backups if anything
looks wrong.

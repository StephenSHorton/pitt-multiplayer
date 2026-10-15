# Multiplayer UI spec (owner requirements)

Input for the Steam multiplayer phase. Built on PittAPI (see `API-DESIGN.md`).
All GodotSteam names below were checked against the game's bundled
`libgodotsteam.windows.template_release.x86_64.dll`.

## Look & feel: match the game's existing UI (owner requirement)

The new screens must look like part of the game, not a mod. Checked in `scenes/main_menu.tscn` / `scripts/main_menu.gd`:

- **Same navigation pattern.** The main menu swaps sibling `VBoxContainer` panels under `Background` (`MenuButtons` ↔ `MenuLoad`, same anchors/offsets: left-middle, `offset_left 49`, `offset_top -76`, 736×460). Our Host/Join, Lobby and Join panels are new sibling panels laid out the same way and toggled the same way. No separate pop-up windows.
- **Same resources, loaded from `res://`, never copied:** Theme `res://assets/main_menu.tres` (in-game overlays: `res://assets/menuUI.tres`), button font `res://assets/PublicPixel-rv0pA.ttf`, title font `res://addons/ridiculous_coding/GravityBold8.ttf` with gold `Color(0.969, 0.729, 0.078)`.
- **Same sizes:** top-level buttons font size 104 (like Play/Options/Credits/Quit), sub-panel buttons 52 (like Continue/New), list rows styled like the save-slot rows in `MenuLoad/ScrollContainer/SlotContainer`.
- **Same feel:** the `hover_sound` (`res://assets/hover.mp3`) / `valid_ui.mp3` sounds the menu already plays, focus handling via `grab_focus()` for controller/keyboard, and the game's existing confirm dialog (`scripts/confirm_dialog.gd`) for "Leave lobby?" and errors.
- **Text:** the game uses translation keys (`MENU_PLAY`, 12 locales via `LocalizationManager`). Our strings get keys too (`MP_MULTIPLAYER`, `MP_HOST`, ...) registered with `TranslationServer`. English is the fallback; other locales are filled in where cheap.
- The Multiplayer button is created by **duplicating the real `Play` button node** (keeping its overrides) and inserting it right after `Play` in `Background/MenuButtons`, so any future restyle of the game's buttons carries over automatically.

## Screens

### 1. Main menu: `Multiplayer` button
- Sits directly **below the Play button**, as a duplicate of the real Play button (see Look & feel).
- Opens the Host/Join screen.
- It is injected by the mod, so it must survive menu re-entry (returning from gameplay, closing options).

### 2. Host / Join screen
- Two choices: **Host** and **Join**, plus **Back**.

### 3. Host → Lobby screen
- Host calls `Steam.createLobby(LOBBY_TYPE_FRIENDS_ONLY, 10)`. The lobby is **visible to friends only**. Max **10** players (constant, easy to change).
- On `lobby_created`, the host sets lobby data: `pitt_version`, `pittapi_version`, `host_name`, `members` (count), `state` = `waiting`.
- The host also sets rich presence (`connect` = `+connect_lobby <id>`) so friends see "Join Game" in Steam.
- The lobby screen shows **the list of joined players in the center of the screen** (Steam persona name; avatar optional). No chat.
- Buttons: **Leave**. The host also gets **Invite friends** (`activateGameOverlayInviteDialog`) and a **Start** button for the next phase (proposed; owner to confirm).

### 4. Join screen
- Lists **open lobbies hosted by Steam friends**, showing host name and player count (`members / 10`).
- Clicking a row calls `joinLobby(id)` and goes to the Lobby screen.
- Lobbies with a mismatched `pitt_version`/`pittapi_version` show as disabled with a reason.
- Shows an empty state ("No friends are hosting") when there are none.

## How the screens update (event-driven)

Friends-only lobbies **do not show up in `requestLobbyList` searches**; Steam hides them from the public list.
Discovery goes through friends instead:

| Screen | Initial fill | Live updates (events) |
| --- | --- | --- |
| Lobby | `getNumLobbyMembers` + `getLobbyMemberByIndex` after `lobby_joined` | `lobby_chat_update` (join / leave / disconnect / kick) → rebuild list; `persona_state_change` → name/avatar resolved; `lobby_data_update` → host state |
| Join | loop over friends: `getFriendGamePlayed(friend)` → if `id` == this app and `lobby` is set → `requestLobbyData(lobby)` | `persona_state_change` (friend started/stopped a game or lobby) → re-check that friend; `lobby_data_update` → update that row's count/state |

- The host keeps lobby data `members` up to date on every `lobby_chat_update`. That's how joiners see counts for lobbies they aren't in (Steam only gives exact member lists to members).
- Fallbacks, because Steam events can be missed: a **Refresh** button on the Join screen, plus a slow safety re-scan (~10 s) only while the Join screen is open. Events are the primary path; polling is backup only.
- Also handle `join_requested` (accepted a Steam invite / clicked "Join Game" in the friends list) and a `+connect_lobby <id>` launch argument → go straight to the Lobby screen.

## Code organization

- `LobbyService` (one node, no UI): owns all Steam lobby calls and signals. Exposes its own signals (`lobby_entered`, `members_changed(members)`, `lobby_left(reason)`, `friend_lobbies_changed(list)`) and a plain-data model (`LobbyInfo`, `MemberInfo`).
- Screens are dumb views: they subscribe to `LobbyService` signals in `_ready`/`tree_entered`, disconnect on exit, and redraw from the model. No screen talks to `Steam` directly.
- Screen navigation through a small `MpMenuRouter` (push/pop, Esc = back) that uses the game's existing menu flow (`MenuManager`) where possible.
- Leaving or returning to the main menu always calls `leaveLobby` (no ghost lobbies).
- Must also work against a fake `LobbyService` for headless tests (no Steam needed).

## Owner decisions (2026-10-14)
- **Start:** yes. The host has a **Start** button; pressing it loads every lobby member into gameplay together. Only the host sees it.
- **Late join:** yes. Friends can join a lobby whose game is already running. The lobby stays discoverable while in-game (lobby data `state` = `in_game`), the Join screen shows it as "In game", and joining loads the joiner straight into the running world, synced to the host's current state.

## Implementation deviations (recorded 2026-10-14, owner to confirm)
- **Lobby member list position.** The list is centred in the free area to the right of the menu column, not in the exact centre of the screen. The game's title and button column take the left part of the screen, and a list in the exact centre would overlap the column at 16:9 and 4:3. To use the exact centre instead, change `members_root.offset_left` in `mods/PittMultiplayer/ui/menu_injector.gd`.
- **Multiplayer button size.** The button is a duplicate of Play and uses Play's font size whenever the label fits the game's 736 px menu column. "Multiplayer" and most translations are wider than that at size 104, which would make the column grow and push Play/Options/Credits/Quit off the title axis. In that case the label uses the largest font size that fits (`ui/fit_width.gd`), recomputed on every language or menu-scale change. A shorter label (for example "Co-op") in `ui/i18n/*.json` would bring back the full size.
- **"Join Game" while the game runs.** Steam reports this as `join_game_requested(steam_id, connect)` (rich presence `connect`), not `join_requested`. Both are handled.

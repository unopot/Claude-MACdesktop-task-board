# Changelog

## 2.4.1
- The **iPhone Live** switch is this computer's own: it is saved as `liveActivity` in `~/.claude/task-board-prefs.json`, which the pusher already reads, instead of writing the iPhone app's `phone-live.conf`. The two switches stay separate — the cards are pushed only when both this switch and the one in the iPhone app are on. It shows whenever the pusher's config is there (no shared folder needed).
- The two switches on the board are just a name and a slider now (no **On** / **Off** text), so the Done header has more room. The Details pane keeps the text.

## 2.4.0
- **iPhone Live switch** next to **Next step** on the board (and in the Details pane and the phone layout), for people who run the TaskBoard iPhone Live Activity pusher. It only shows when this computer has the pusher's config (`~/.claude/task-board-live.json`) and a shared folder is set, so nobody else sees it. It writes `phone-live.conf` in the shared folder — the same file as the iPhone app's own switch — so whichever computer is pushing ends the lock screen and Dynamic Island cards, or brings them back.
- The scanner (`scan.pl`) reads `phone-live.conf` in that case and passes it on as `phone` (`show`, `path`).
- `tests/scan.t` grows from 68 to 75 checks (the switch shows only with the pusher's config and a shared folder; off / missing / unreadable file; it is never read as a snapshot); a new UI test covers the switch on the desktop board, the phone layout and the Details pane.

## 2.3.1
- The menu bar counter has no **Quit** item any more: quitting it kept it away until the next session started, which looked like it was gone. Switch **Menu bar counter** off in the settings to stop it.

## 2.3.0
- **Menu bar counter.** A coloured count in the macOS menu bar (yellow needs input, blue running, green done) that is there even when no session is open, or while a Remote Control session from another computer is open. Click it for the sessions, click one to switch to it. A plain `osascript` script (`menubar.js`), started by `menubar.pl` when a session opens, detached and one at a time; new setting **Menu bar counter** (on by default) turns it off.
- The scanner (`scan.pl`) takes `--latest FILE`: each round's line is written to that file atomically (the menu bar reads it).
- `tests/scan.t` grows from 66 to 68 checks (`--latest`); `tests/menubar.test.tsx` covers starting it from a desktop session, stopping it when the setting is off, and leaving it alone in sessions with no window.

## 2.2.0
- **Open sessions from your other computers.** Clicking a card from another computer opens that session through Remote Control (`claude://claude.ai/code/session_…`); the desktop app opens it as a Remote Control session. It needs Remote Control on for that session on its own computer (desktop app setting **Connect new sessions to Remote Control**). Cards from a computer still on 2.1.x carry no Remote Control id and stay read-only. Same in the Details pane.
- The scanner (`scan.pl`) reads each session's Remote Control id (the last entry of `bridgeSessionIds` in the desktop app's session list) and writes it as `bridge`, so the snapshot in the shared folder carries it.
- `tests/scan.t` grows from 64 to 66 checks (the Remote Control id is read, and is empty without desktop metadata); the cross-computer UI tests cover clicking a card from another computer.

## 2.1.1
- The grey tag on a card from another computer is that computer's **label** (the **This computer's label** setting; default Win on Windows, Mac on macOS), not its operating system. With several computers of the same kind give each its own label; it doubles as the file name in the shared folder. The Details pane no longer repeats it as "on <name>".

## 2.1.0
- **See sessions from your other computers.** Each computer writes a snapshot of its sessions into a shared folder in a synced drive (default: iCloud Drive, `Claude Code/task-board-shared`) every 10 seconds and reads the others'. Cards from another computer carry a grey **Win** / **Mac** tag, show up in the Details pane with "on <computer>", and are read-only (no click-to-switch). Two new settings: **Shared folder for other computers** (empty = off) and **This computer's name in the shared folder** (empty = host name). Snapshots older than 10 minutes count as offline. Works with the matching plugin on the other computer: [Claude-WINdesktop-task-board](https://github.com/unopot/Claude-WINdesktop-task-board) / [Claude-MACdesktop-task-board](https://github.com/unopot/Claude-MACdesktop-task-board).
- The scanner takes `--shared DIR` and `--device NAME`; its output and the local snapshot carry `device` and `os`, plus `remote` (the other computers' snapshots, verbatim) when sharing is on. The board merges them (`mergeRemote` in `plan.ts`).
- The platform-specific bits of `register.tsx` (scanner command, home folder, snapshot path, how a `claude://` link is opened, default shared folder) now sit in one block at the top of the file; the rest of the file is identical in the Windows and macOS repositories.
- `tests/scan.t` grows from 48 to 64 checks: the shared folder is written and read, stale / same-name / broken / temporary files are skipped, the shared copy never nests, `~` expands to the home folder.

## 2.0.1
- Cards press down: while the mouse button is held on a clickable card (board or Details pane) it sinks about 4px (margin-top +0.4 rows, margin-bottom −0.4 rows, so the cards below stay put) and its background darkens a touch; it springs back on release. Releasing outside the card cancels the click.

## 2.0.0 (macOS)
- macOS port of [Claude-WINdesktop-task-board](https://github.com/unopot/Claude-WINdesktop-task-board) 1.9.7. Same board, same details panel, same settings.
- The background scanner is now `scan.pl`, a Perl script: every Mac ships `/usr/bin/perl` with `JSON::PP`, so nothing needs installing. Its first pass over a 35 MB transcript takes well under a second.
- Reads the desktop app's session list from `~/Library/Application Support/Claude/claude-code-sessions`; the shared snapshot and the switch files live under `~/.claude` as before.
- Clicking a card switches sessions through `open claude://…`.
- A session that just received a new prompt counts as running right away, instead of as "done" until the first assistant line arrives.
- Narrow prompt box (the Mac window is a little narrower than the Windows one): the **Suggest next step** switch, **Details** and the usage ring keep one line; the Running / Done headers truncate instead of wrapping.
- `tests/scan.t` exercises the scanner against synthetic transcripts (`perl task-board/tests/scan.t`).

## 1.9.7
- With next-step suggestions showing (or "thinking…"), the collapse arrow sits at the right end of the suggestion header instead of its own row, so a tall board no longer pushes it out of view.

## 1.9.6
- The collapse arrow at the bottom right sits half a row lower, clear of the session cards.

## 1.9.5
- Faster start: the scanner's first pass is about twice as fast (ordinal string search, inlined timestamp parsing).
- New sessions show the board at once from a shared snapshot (`~/.claude/task-board-snapshot.json`, written at most every 10 s, used when under 10 minutes old, its timers moved forward to now) instead of waiting for their own first scan.

## 1.9.0 – 1.9.4
- Phone layout (Claude mobile app via Remote Control): one narrow column, buttons in place of click layers, folded by default.
- A collapse / expand arrow at the bottom right of the board on desktop and phone; the choice is remembered for new sessions.
- Next-step suggestions react to the first click: click layers are mounted while suggestions are still loading, and fire on pointer down.

## 1.8.4
- Author and marketplace owner: unopot; marketplace name `unopot-mods`.

## 1.8.3
- Details show who does the work: a **Main** row with the session's model and effort ("no subagents this turn" when there are none); each subagent sits under the step that started it. Running cards show "N agents" while subagents run.

## 1.8.2
- Tidier details panel: an equal-width stage strip, then one aligned step table; long lists fold finished stages.

## 1.8.1
- **needs input** (yellow) when a session waits on a permission dialog, a question or an MCP form; the guessed idle-tool-call **waiting** is light blue.

## 1.8.0
- Ring for the account's five-hour usage limit at the right of the Running header.

## 1.7.x
- Two columns (Running / Done), two-line cards with static percentage bars, details panel with stages, steps, timings and subagents, current-session highlight, hide finished sessions.

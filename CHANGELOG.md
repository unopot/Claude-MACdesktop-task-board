# Changelog

## 2.6.2
- **Warns when iCloud stops uploading.** Every 5 minutes the scanner drops a small probe file into the shared folder and checks 90 seconds later whether iCloud has uploaded it (`brctl status`). If not, the Running header shows a yellow warning with how long the upload has been stuck and how many files are waiting, so the other computer and the phone going blind no longer goes unnoticed for hours. Cleared as soon as the probe uploads. Only when the shared folder is in iCloud Drive.

## 2.6.1
- **Only pop-ups turn a card yellow.** A question in the next-step box at the end of a turn no longer counts as needs input: that turn is done (green). Yellow is for things that pop up and wait for your click: permission dialogs, questions, plan approvals, MCP forms and "New session / Do it here" cards.

## 2.6.0
- **Background work keeps a card running.** The desktop app now sends subagents, long commands and workflows to the background and ends the turn; the card used to turn green while they were still running. A background command, subagent or workflow now counts as running until its completion notice arrives (at most 6 hours).
- **More kinds of "needs input".** A turn that ends with a question in the next-step box, an unanswered plan approval, and a "New session / Do it here" card now turn the card yellow, along with permission dialogs, questions and MCP forms. Replying clears it.
- **Steps from the desktop app's task list.** Sessions that keep their plan with the desktop app's own task list (instead of TaskCreate or TodoWrite) show their steps, progress and step times again.

## 2.5.1
- The usage ring in the Running header no longer reads `· in 2h 27m`: with the new Context ring the Mac window has no room for it.

## 2.5.0
Same as the Windows version's 2.5.0.
- **Context ring.** The Running header now has a second ring between the title and the usage ring: how full this session's context window is (the figure the desktop app no longer shows by the prompt box), coloured from 80%.
- The usage ring is labelled **5h Usage** and reads `· in 2h 27m` instead of `· resets in 2h 27m`.

## 2.4.6
Same as the Windows version's 2.4.2 / 2.4.3.
- **Only one scanner process per computer.** Sessions, the menu bar counter and the iPhone pusher start `scan.pl --lead-only`: when another scanner already leads, it prints one line `{"follow":"<file>"}` and exits, and the caller reads the leader's output file (`~/.claude/task-board-scan-<id>.json`) every few seconds instead of keeping a Perl process alive just to pass lines on. When that file stops updating for 10 seconds (the leading session closed), the caller starts the scanner again and the first one to get the lock leads.
- **Your own conflict copies are cleaned up once they are stale.** Copies such as `Mac 2.json`, `Mac(1).json` or a leftover `Mac.json.*.tmp` in the shared folder are deleted after 30 seconds without updates. Fresh ones are kept: iCloud sometimes renames the just-written snapshot itself, and readers already keep the newest snapshot per device.
- **A snapshot iCloud has not downloaded yet no longer stalls the scanner.** Another computer's new conflict-named snapshot can sit in the shared folder as a placeholder; reading it waited for a download that never came, and the board stopped updating. Such files are now skipped and iCloud is asked to download them (`brctl download`), so they are read on a later round; a read that still hangs is given up after 2 seconds.

## 2.4.5
- **One scanner per computer does the work.** The desktop app keeps recently opened sessions alive in the background, and each one started its own `scan.pl`, so a dozen scanners read every transcript every 3 seconds. Now the first scanner takes a lock (`~/.claude/task-board-scan-<id>.lock`) and writes each line to `~/.claude/task-board-scan-<id>.json`; the others just pass that line on. When the leading session closes, another scanner takes over within a few seconds. Scanners with different settings (shared folder, device name) use different locks.
- The snapshot in the shared folder is written in place instead of being swapped in with a rename, and only by the leading scanner. Many writers renaming the same file made iCloud keep conflict versions, and the other computer saw the snapshot as `Mac(1).json`.

## 2.4.4
- Each session in the snapshot carries `msgAgeSec`: seconds since its last timestamped message (main transcript or subagents). The desktop app sometimes appends bookkeeping lines to an old session's transcript (Remote Control, cost), which makes the file look new; `ageSec` still follows the file, `msgAgeSec` does not. The iPhone pusher and app use it to decide what finished recently.
- A session no longer shows as running just because its transcript file was touched: the 90-second "still running" rule also needs a recent message.

## 2.4.3
- **Details** on the desktop board is a three-dot button (⋯) that never gets cut off; the hidden count moved out of it (the Details pane still lists hidden sessions).

## 2.4.2
- The Done header on the desktop board shows just the count (no "· cache left"): the Mac window is narrow and the two switches need the room. Each card still shows its own cache countdown.

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

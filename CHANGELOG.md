# Changelog

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

# mac-wine-cursor-fix

**Fixes the mouse cursor in Windows games on a Mac (Porting Kit / Wineskin).**

Does one of these happen in your game?

- 🖱️ **You can't see your cursor in menus.** You have to click around blindly.
- 🖱️ **The cursor stays on screen while you play**, stuck in the middle or following your aim.
- 🖱️ **The cursor disappears after you Cmd+Tab out and back in.**

If so, your game's Wine engine probably has this bug, and one command fixes it.

> Example: ULTRAKILL through Porting Kit with the `WS12WineCX26.3_DXMT` engine had both problems. After the fix, the cursor shows in menus and disappears during gameplay, like on Windows.

---

## Why it happens (short version)

Porting Kit games carry their own copy of Wine. Some of those Wine engines, the CrossOver-based ones (with **CX** in the name), have three built-in changes:

1. **In fullscreen the cursor is always hidden**, even in menus where the game wants it shown.
2. **When the game asks to hide the cursor, an arrow is shown instead**, so you see it while playing.
3. **When you Cmd+Tab back into a fullscreen game, the cursor is hidden again**, whatever the game wants.

This tool finds exactly those three spots in the game's Wine and turns them off. It changes **9 bytes** in one file and keeps a backup. If the tool doesn't recognise the code exactly, it changes **nothing**.

---

## How to use it

You'll paste one command into **Terminal**. You don't need to understand it.

> **How to open Terminal:** press **⌘ Command + Space**, type **Terminal**, and press **Return**.

1. **Quit the game** completely.
2. Copy this command and paste it into Terminal (⌘ Command + V), **but don't press Return yet**. Note the space at the end:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/snipstxd/mac-wine-cursor-fix/main/fix-cursor.sh | bash -s -- 
   ```

3. Open Finder and **drag your game's app onto the Terminal window**. Its location gets typed in for you. Porting Kit games are usually in your home folder's **Applications** folder (in Finder: **Go → Home → Applications**).
4. Press **Return**.

You'll see one of these:

| Message | What it means |
|---|---|
| `Fixed! Start "My Game" again.` | ✅ Done. Open the game and check the cursor. |
| `is already fixed. Nothing to do.` | ✅ This game was already fixed earlier. |
| `uses a Wine engine without this cursor bug` | Your game's engine doesn't have this bug, or it's a version this tool doesn't know. Nothing was changed. |
| `doesn't contain Wine` | It's a normal Mac app, not a Wine game. Nothing to fix. |
| `is running. Quit it first` | Quit the game fully, then run the command again. |

### Only check, without changing anything

Use the same command with `--check` added before the app:

```bash
curl -fsSL https://raw.githubusercontent.com/snipstxd/mac-wine-cursor-fix/main/fix-cursor.sh | bash -s -- --check 
```

Then drag your game in and press Return.

### Undo

```bash
curl -fsSL https://raw.githubusercontent.com/snipstxd/mac-wine-cursor-fix/main/fix-cursor.sh | bash -s -- --undo 
```

Then drag your game in and press Return. This puts back the exact original file.

---

## Good to know

- **Only fix the games that have the problem.** Each Porting Kit game has its own copy of Wine, so the fix applies to one game at a time and never touches anything else.
- **If Porting Kit updates or reinstalls the game**, it may replace the fixed file. Just run the command again.
- **It doesn't change mouse sensitivity.** If your sensitivity feels crazy (one small move spins you around), check whether someone set `UseConfinementCursorClipping` to `n` in the game's Wine settings. That causes it. Remove that setting.
- **Screenshots don't show the cursor on macOS**, so look at the screen itself to check.

---

## Technical details

The fix patches `winemac.so`, Wine's macOS display driver, inside the app bundle (usually `Contents/SharedSupport/wine/lib/wine/x86_64-unix/winemac.so`):

| Location | Original | Patched |
|---|---|---|
| `-[WineApplicationController updateCursor:]`: `if ([self hasFullscreenWindow]) clientWantsCursorHidden = YES;` | `je` (`0x74`) | `jmp` (`0xEB`), so the check is skipped |
| `macdrv_SetCursor`: `if (!cursor_name && !cursor_frames) cursor_name = CFSTR("arrowCursor");` | `jne` (`0x75`) | `jmp` (`0xEB`), so a NULL cursor hides the cursor like upstream Wine |
| `macdrv_update_fullscreen_windows` block, which runs when the app is activated: `[controller hasFullscreenWindow] ? [controller hideCursor] : [controller unhideCursor]` | `mov sel,%rsi` (7 bytes) | `pop rbx; pop r14; pop rbp; ret; nop; nop`, so it returns before overriding the game's cursor state |

The script doesn't use fixed offsets. It searches for each instruction pattern, then confirms it by following the pointers: the Objective-C selectors must be `hasFullscreenWindow`, `hideCursor` and `unhideCursor`, the CFString must be `"arrowCursor"`, and the function prologue must match what the early return pops. It only patches if it finds exactly the three expected locations. Games fixed with an older version of this tool get just the missing patch. The original is saved as `winemac.so.before-cursor-fix` next to it.

The script uses only `bash` and `/usr/bin/perl`, which are included with macOS, so you don't need to install anything.

## License

[MIT](LICENSE)

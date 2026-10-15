# NotchIsland 2.0

A Dynamic Island for the MacBook notch, written in SwiftUI, inspired by Halo. Requires macOS 15 or later on Apple silicon.

## What's in the notch

**When nothing's happening** it's just the notch. When something is, it grows "ears" on each side, in this order of priority:

| What | Left | Right |
|---|---|---|
| Volume / brightness keys | speaker or sun | level bar |
| Charging, low battery, screenshot, download, timer done | icon | % or file name |
| Claude Code needs your permission | ✋ | Needs you (plus a sound) |
| A call (any app using the mic) | app icon | how long |
| Focus timer | timer | countdown |
| Claude Code working | ✦ | elapsed time |
| Music | album art | equalizer |

Plus three bigger pop-outs under the notch: **notification banners** (click to open), **live dictation** text, and optionally the **current lyric line**.

**Hover to open.** Six tabs:

- **Home**: iPhone-style Now Playing (drag the bar to seek, shuffle, repeat, lyrics button) next to today's date and your next event.
- **Reminders**: check off or add reminders.
- **Shelf**: drag any file onto the notch to park it. New screenshots and downloads land here automatically. Drag out, double-click to open, right-click for AirDrop.
- **Clipboard**: your last 30 copies. Click one to copy it again. Kept in memory only, and copies from password managers are skipped.
- **Focus timer**: 5/15/25/50 minutes.
- **Claude Code**: live sessions, what each one is doing, and how long.

The ☕ button in the top bar keeps your Mac awake.

**Right-click the notch** (or click the capsule in the menu bar) for settings: lyrics under the notch, notifications, volume HUD, hide in fullscreen, keep awake, dictation key, Connect Claude Code, Quit.

## Build and run

```bash
cd ~/Downloads/NotchIsland
./build.sh --install
```

That compiles, replaces the copy in Applications and opens it. Use `./build.sh --run` to test without installing.

## Permissions (first launch)

| Permission | For | When it asks |
|---|---|---|
| **Accessibility** | volume/brightness HUD, dictation, notifications, fullscreen hiding | at launch. Turn NotchIsland on in System Settings → Privacy & Security → Accessibility. It starts working within a few seconds, no restart needed. |
| Automation | controlling Spotify / Music | first time music plays |
| Reminders, Calendars | Reminders tab, next event | at launch |
| Downloads folder | downloads on the shelf | at launch |
| Microphone, Speech Recognition | dictation | the first time you hold the dictation key |

**After every rebuild, Accessibility has to be turned on again.** Each build has a new signature, so `build.sh` clears the old approval and macOS asks again.

## Dictation

Hold **Fn (🌐)**, talk, let go. Your words are typed wherever the cursor is. Change the key (or turn it off) from the right-click menu.

If holding Fn opens the emoji picker or switches keyboards, go to System Settings → Keyboard and set **"Press 🌐 key to"** to **Do Nothing**. Or switch dictation to right Option.

## Claude Code

Open the Claude Code tab and click **Connect Claude Code** (or use the right-click menu). This adds hooks to `~/.claude/settings.json` (a backup is saved next to it as `settings.json.notchisland-backup`). Each hook writes a tiny file to `~/.notchisland/events` that NotchIsland reads and deletes. Nothing leaves your Mac. Already-open Claude Code sessions need a restart to pick up the hooks. **Disconnect** removes only NotchIsland's hooks.

## Launch at login

Add NotchIsland in System Settings → General → Login Items & Extensions → Open at Login.

## Troubleshooting

- **Volume or brightness keys show the normal macOS pop-up**: Accessibility isn't on yet (see above). External speakers that don't support software volume also fall back to macOS.
- **No notification banners in the notch**: needs Accessibility. Notification Center's layout changes between macOS versions, so this feature is the most likely to need adjusting on yours. The normal macOS banner still shows too.
- **Music isn't showing**: System Settings → Privacy & Security → Automation, allow NotchIsland to control Spotify / Music.
- **Permissions act strange**: reset all of them and relaunch:
  ```bash
  for s in Accessibility AppleEvents Reminders Calendar Microphone SpeechRecognition; do tccutil reset $s com.example.notchisland; done
  ```

## Known limits

- Music works with Spotify and Apple Music, not browser audio.
- Lyrics come from LRCLIB, a free lyrics database. Only the song title, artist, album and length are sent.
- Some FaceTime calls may not show in the call indicator, because the mic is used by a system process rather than the FaceTime app.

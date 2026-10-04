# Spotify for Tern

Control Spotify through using Tern, with cover art, playback and volume
controls. Needs the Spotify Desktop to be app running.

## Install

```sh
tern plugin install /path/to/tern-spotify
```

To use it, open the command palette in Tern and run **Spotify: Open player**. 

For development, use `tern plugin link /path/to/tern-spotify` instead.

Requires Windows 10+ with PowerShell 5.1 and Windows Script Host, macOS automation
permission, or Linux with [`playerctl`](https://github.com/altdesktop/playerctl).

## Controls

With the player focused:

| Key | Action |
| --- | --- |
| `space`, `k` | Play / pause |
| `←`, `→` | Seek ±10 seconds |
| `n` / `p` | Next / previous track |
| `s` / `r` | Shuffle / cycle repeat |
| `+` / `-` | Volume ±5% |
| `m` | Mute |
| `o` | Open Spotify |

## Notes

- An unfocused PiP may need two clicks: one to focus and enlarge, another to
  activate the control.

If it isn't working make sure that Spotify is open and run `tern plugin list` to check status.

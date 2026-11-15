# ServerDrop

AirDrop between your Mac and a Linux server, over [Taildrop](https://tailscale.com/kb/1106/taildrop).

- **Mac → server:** drop files or folders on the ServerDrop Dock icon (or its window).
- **Server → Mac:** `tomac file.png report.html` on the server; files land in `~/Downloads`
  with a notification, even when the app is closed. Handy for agents running on the box.
- **History:** the app's window lists every transfer both ways. Double-click to show in Finder,
  right-click to send again. Right-click the Dock icon for the last few.

Folders travel as `.zip`. No server to run and nothing leaves your tailnet: Taildrop is
peer-to-peer and encrypted between devices on the same Tailscale account.

## Requirements

- macOS 13+ with the Tailscale app and its CLI at `/usr/local/bin/tailscale`
  (Tailscale menu → Settings → Install CLI), and Xcode command line tools (`swiftc`)
- A Linux server on the same tailnet that you can `ssh <name>` into, with `python3`
- Both machines logged into the same Tailscale account

## Install

```sh
./install.sh my-server        # the server's Tailscale machine name (also used for ssh)
```

This builds `~/Applications/ServerDrop.app`, adds it to the Dock, starts a launchd agent
(`io.github.tg1482.serverdrop.recv`) that receives into `~/Downloads`, and copies `tomac`
to `~/.local/bin` on the server. Rerun it after any change.

### The server must receive, too

Taildrop parks incoming files in an inbox until something collects them. Run a collector
on the server, for example as a systemd user service:

```ini
# ~/.config/systemd/user/taildrop-inbox.service
[Unit]
Description=Collect Taildrop files into ~/inbox

[Service]
ExecStart=/usr/bin/tailscale file get --loop --conflict=rename %h/inbox
Restart=always

[Install]
WantedBy=default.target
```

```sh
mkdir -p ~/inbox
sudo tailscale set --operator=$USER      # lets your user run `tailscale file get`
systemctl --user enable --now taildrop-inbox
loginctl enable-linger $USER             # keep it running while logged out
```

## Files

| File | Runs on | What it does |
|---|---|---|
| `ServerDrop.swift` | Mac | Dock app: sends dropped files, shows the history |
| `recv.sh` | Mac (launchd) | `tailscale file get --wait` loop into `~/Downloads`, logs and notifies |
| `tomac` | server | sends files to the Mac, logs to `$DROP_INBOX/.dropd/log.jsonl` |
| `icon.swift` | Mac | renders the app icon at build time |
| `install.sh` | Mac | builds and installs all of the above |

The Mac history lives in `~/Library/Application Support/ServerDrop/history.jsonl`; the
receiver's errors go to `~/Library/Logs/ServerDrop-recv.log`.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/io.github.tg1482.serverdrop.recv
rm -rf ~/Applications/ServerDrop.app ~/Library/LaunchAgents/io.github.tg1482.serverdrop.recv.plist \
       "$HOME/Library/Application Support/ServerDrop"
```

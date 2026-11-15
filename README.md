# ServerDrop

AirDrop between your Mac and a Linux server, over [Taildrop](https://tailscale.com/kb/1106/taildrop).

- **Mac → server:** drop files or folders on the ServerDrop Dock icon or window.
- **Server → Mac:** `tomac file.png some-folder/` on the server; files land in `~/Downloads`
  with a notification, even when the app is closed.
- **History:** the window lists transfers both ways; double-click one to show it in Finder.

Folders travel as `.zip`. Taildrop is peer-to-peer and encrypted, between devices on one
Tailscale account.

## Install

Needs macOS 13+, Xcode command line tools, the Tailscale app with its CLI at
`/usr/local/bin/tailscale`, and a server on the same tailnet that you can `ssh` to.

```sh
./install.sh my-server        # the server's Tailscale machine name
```

The server also needs something collecting incoming Taildrop files, for example:

```sh
sudo tailscale set --operator=$USER
mkdir -p ~/inbox && tailscale file get --loop --conflict=rename ~/inbox
```

## Files

- `ServerDrop.swift` — the Dock app: sends dropped files, shows the history
- `recv.sh` — launchd agent on the Mac: receives into `~/Downloads`
- `tomac` — sends from the server to the Mac
- `icon.swift` — renders the app icon at build time
- `install.sh` — builds and installs all of the above

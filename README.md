# Flamm

**Fold space. Forward ports.**

Flamm is a native macOS menu-bar app for managing local SSH port forwards. It
uses the hosts you already have in `~/.ssh/config`, keeps each forward visible,
and shows whether its local endpoint is healthy before you need it.

The name comes from Flamm's paraboloid: the two-sheeted spatial geometry used to
visualize the throat of an Einstein–Rosen bridge.

## Features

- Discover and switch between concrete host aliases from `~/.ssh/config`
- Import a target's existing `LocalForward` entries on first launch
- Start and stop all forwards together or control them individually
- Add optional names while retaining standard `local:remote` port mappings
- Enable, disable, add, edit, and remove forwards in a native settings window
- Check local reachability continuously with per-port traffic-light status
- Detect occupied local ports before starting and skip conflicting forwards
- Use the system SSH client, config, keys, agent, proxy jumps, and host settings

| Light | Meaning |
| --- | --- |
| Green | The forward is active and accepts local TCP connections |
| Yellow | Connecting, unreachable, or blocked by a local port collision |
| Red | Stopped or failed |
| Gray | Disabled |

## Requirements

- macOS 13 Ventura or newer
- Swift 5.9 or newer
- An SSH target configured for non-interactive authentication

Flamm runs SSH in batch mode. Keys, certificates, and agent-backed credentials
work normally; interactive password prompts do not.

## Build

```sh
./Scripts/test.sh
./Scripts/build-app.sh
open build/Flamm.app
```

The build script produces an ad-hoc signed application bundle at
`build/Flamm.app`.

## How forwarding works

Flamm starts `/usr/bin/ssh` with the selected config alias and a private OpenSSH
control socket. Configured forwards are cleared for that connection, then Flamm
adds only the enabled, collision-free ports. Existing host names, users,
identity files, `Match` rules, proxy jumps, and keep-alive settings continue to
come from OpenSSH.

Starting a port enables it and installs its forward. Stopping it removes the
live forward but keeps it enabled for the next global start. Disabling it also
excludes it from future global starts.

Flamm binds local forwards to `127.0.0.1`. It checks each local port before
installation, leaves conflicts untouched, and explains the warning from that
port's submenu.

## Privacy and credentials

Flamm does not store SSH credentials or send configuration anywhere. Editable
app settings are stored locally with `UserDefaults`; authentication remains the
responsibility of the system SSH client.

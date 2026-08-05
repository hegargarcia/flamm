<p align="center">
  <img src="./assets/banner.svg" alt="Flamm — fold space, forward ports" width="100%" />
</p>

<h1 align="center">Flamm</h1>

<p align="center">
  Native SSH tunnels, one click from the macOS menu bar.
</p>

<p align="center">
  <a href="https://github.com/hegargarcia/flamm/releases/latest">Download</a> ·
  <a href="#setup">Setup</a> ·
  <a href="./development.md">Development</a>
</p>

Flamm is a native macOS menu-bar app for managing local SSH port forwards. It
uses the hosts already defined in `~/.ssh/config`, keeps each forward visible,
and tells you whether its local endpoint is ready before you need it.

```text
localhost:5432  ──  Flamm  ──  SSH target  ──  127.0.0.1:5432
```

The name comes from [Flamm's paraboloid](https://en.wikipedia.org/wiki/Flamm%27s_paraboloid),
a visualization of curved space around a Schwarzschild black hole. The icon
reduces that idea to two endpoints meeting at a narrow bridge.

## What it does

- Discovers concrete host aliases from `~/.ssh/config` and sorts them A–Z.
- Imports a target's existing `LocalForward` entries on first launch.
- Starts and stops every forward together, or controls ports individually.
- Adds optional human-readable names while preserving standard `local:remote`
  port mappings.
- Enables, disables, adds, edits, and removes forwards in a native settings
  window.
- Checks local reachability and reports each port with a native status light.
- Detects occupied local ports before connecting and leaves collisions alone.
- Uses the system SSH client, config, keys, agent, proxy jumps, and host rules.

| Light | Meaning |
| --- | --- |
| Green | The forward is active and accepts local TCP connections. |
| Yellow | The forward is connecting, unreachable, or blocked by a local collision. |
| Red | The forward is stopped or failed. |
| Gray | The forward is disabled. |

## Setup

Download the latest `.dmg` from
[Releases](https://github.com/hegargarcia/flamm/releases/latest), open it, and
drag **Flamm** to **Applications**.

> [!NOTE]
> The current build is ad-hoc signed and not notarized. On first launch,
> Control-click **Flamm** in Applications and choose **Open**.

Flamm needs macOS 13 Ventura or newer and at least one concrete host alias in
`~/.ssh/config`:

```sshconfig
Host database
    HostName 10.0.0.42
    User deploy
    IdentityFile ~/.ssh/id_ed25519
```

Open Flamm from the menu bar, choose **SSH Target**, configure forwards under
**Settings**, then select **Start**. Flamm runs SSH in batch mode, so keys,
certificates, and agent-backed credentials work normally; interactive password
prompts do not.

## Port controls

Each port row opens its own controls:

- **Start** enables the port and installs its forward immediately.
- **Stop** removes the live forward but keeps it enabled for the next global
  start.
- **Disable** removes it and excludes it from future global starts.

Mappings use `local:remote` notation. When both values match, Flamm shows the
port once. An optional name appears first so entries such as `Postgres — 5432`
stay easy to scan.

Before installing a forward, Flamm tries to bind its local port on
`127.0.0.1`. If another process already owns it, Flamm skips that forward,
shows a yellow light, and explains the collision in the port submenu.

## How it works

Flamm starts `/usr/bin/ssh` with the selected config alias and a private OpenSSH
control socket. It clears configured forwards for that connection, then adds
only the enabled, collision-free ports. Host names, users, identity files,
`Match` rules, proxy jumps, and keep-alive settings continue to come directly
from OpenSSH.

App preferences are stored locally with `UserDefaults`. Flamm does not store
SSH credentials, modify `~/.ssh/config`, or send configuration anywhere.

## Development

Build, test, install, and package Flamm from source using the
[development guide](./development.md).

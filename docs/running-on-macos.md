# Running web-tool on macOS with Apple's `container`

This guide covers running the published `dockmann/web-tool` image with
[Apple's `container`](https://github.com/apple/container) runtime on macOS,
including automatic start at login. It is the alternative to
[`scripts/run-web-tool-docker.sh`](../scripts/run-web-tool-docker.sh) for people
who prefer not to run Docker Desktop.

## Requirements

- **Apple Silicon Mac** (M1 or newer). The runtime does not support Intel Macs.
- **macOS 26 or later.** The upstream project only supports macOS 26+ and does
  not address issues that cannot be reproduced there. This guide assumes macOS
  26/27.
- **Apple's `container` CLI** installed (see below).

web-tool itself is architecture-neutral: the published image is multi-platform
(`linux/amd64` and `linux/arm64`), and the arm64 variant is pulled by default on
Apple Silicon.

## Install the `container` CLI

Either install the signed package from the
[releases page](https://github.com/apple/container/releases) or use Homebrew:

```bash
brew install container
```

Then start the system service once. This registers the `container-apiserver`
with launchd and, on first run, downloads and installs a default Linux kernel:

```bash
container system start --enable-kernel-install
```

> **Do not run `brew services start container`.** The Homebrew formula's service
> definition sets `KeepAlive` on `container system start`, a command that
> registers the service and exits immediately. launchd then treats every exit as
> a crash and relaunches it in a loop. `container system start` already
> registers the apiserver with launchd with `RunAtLoad`, so it starts
> automatically at login without `brew services`.

## Run web-tool

[`scripts/run-web-tool-container.sh`](../scripts/run-web-tool-container.sh)
stops any existing `web-tool` container, pulls the latest image, and starts a
new one:

```bash
scripts/run-web-tool-container.sh
```

The first run calls `container system start --enable-kernel-install --timeout 60`
(idempotent, and it auto-accepts the kernel prompt), then starts the container in
the background. When it finishes:

```
web-tool running at http://localhost:8532
```

Open <http://localhost:8532/> and use the bookmarklets as usual.

Useful commands while it runs:

```bash
container list                    # running containers, with IP and state
container logs web-tool           # application output
container stats --no-stream web-tool
container stop web-tool           # graceful stop
container delete --force web-tool # stop and remove
```

## Configuration

Both run scripts read the same environment variables. The Apple container script
defaults are:

| Variable | Default | Purpose |
|----------|---------|---------|
| `WEB_TOOL_PORT` | `8532` | Host port to publish |
| `WEB_TOOL_DATA_DIR` | `$HOME/docker-data/web-tool` | Host directory persisted as `/data` (favicon cache) |
| `WEB_TOOL_IMAGE` | `docker.io/dockmann/web-tool` | Image reference |

Example:

```bash
WEB_TOOL_PORT=9000 WEB_TOOL_DATA_DIR="$HOME/web-tool-data" scripts/run-web-tool-container.sh
```

If you change `WEB_TOOL_PORT`, update the bookmarklets with the new port (the
host is set automatically from the port in the URL).

### Port publishing

`container run -p` publishes the port **on the loopback interface only**, so the
service is reachable at `http://localhost:<port>` but not from other machines on
your network. This is stricter than Docker, which binds `0.0.0.0` by default,
and it is sufficient for the bookmarklet workflow.

### Data directory

`WEB_TOOL_DATA_DIR` is bind-mounted to `/data` inside the container, where the
favicon cache is stored. The default (`$HOME/docker-data/web-tool`) preserves the
cache location used by the Docker script.

The run script creates the directory as your user before starting the container.
If the container logs permission errors when writing the cache, the runtime may
be exposing the bind mount as owned by `root`; make the directory writable by the
container user (uid 1000):

```bash
chmod 777 "$WEB_TOOL_DATA_DIR"
```

## Automatic start and restart (launchd)

Apple's `container` runtime has **no restart policy** — there is no equivalent of
Docker's `--restart always`. Restart is an
[open upstream feature request](https://github.com/apple/container/issues/286).
Until it ships, [`scripts/web-tool-autostart.sh`](../scripts/web-tool-autostart.sh)
installs a launchd *user agent* that runs the container in the foreground and
relies on launchd's `KeepAlive` to restart it.

### Install

```bash
scripts/web-tool-autostart.sh install
```

This writes `~/Library/LaunchAgents/com.dockmann.web-tool.plist` with your
resolved `WEB_TOOL_PORT`, `WEB_TOOL_DATA_DIR`, and `WEB_TOOL_IMAGE` baked in, then
loads it with `launchctl bootstrap gui/$(id -u)`. The agent:

- starts `run-web-tool-container.sh --foreground` at login (`RunAtLoad`);
- restarts it if it exits with a non-zero status (`KeepAlive` →
  `SuccessfulExit: false`), throttled to one attempt every 30 seconds;
- logs both stdout and stderr to `~/Library/Logs/web-tool.log`.

### Scope and limitations

- The agent is a **user agent**. It starts when you **log in**, not at boot
  before login, and it cannot keep the container alive while you are logged out.
- It restarts the container process when it crashes, but there is no `on-failure`
  backoff beyond the throttle interval and no true boot-level supervision.
- This is the closest available approximation of `--restart always`; it is not
  identical, and it will be unnecessary once Apple ships a restart policy.

### Inspect and manage

```bash
scripts/web-tool-autostart.sh status          # plist, launchd state, containers
launchctl print gui/$(id -u)/com.dockmann.web-tool
tail -f ~/Library/Logs/web-tool.log
```

To verify it survives a real login cycle, log out and back in, then check
`container list` and the log file.

### Uninstall

```bash
scripts/web-tool-autostart.sh uninstall
```

This unloads and deletes the agent but leaves any running container in place.
Stop it with `container stop web-tool`.

## Differences from the Docker setup

| | Docker | Apple `container` |
|---|---|---|
| Isolation | One shared Linux VM for all containers | One lightweight micro-VM per container |
| Restart policy | `--restart always` (built in) | None; use `scripts/web-tool-autostart.sh` (launchd) |
| Port publishing | `0.0.0.0` by default | Loopback only |
| Container names | `docker ...` | `container ...` (`ls` instead of `ps`) |
| Data persistence | `-v` bind mount | Same `-v` syntax |

Both runtimes can be installed side by side. They both name the container
`web-tool`, but they are separate runtimes; do not run both at the same time
because they would contend for the same host port.

## Troubleshooting

**`error: Apple's 'container' CLI not found on PATH`**
Install it (`brew install container` or the signed package) or fix `PATH`.

**`container system start` hangs or fails**
Run it by hand to see the error, and check the service logs:

```bash
container system status
container system logs --last 10m
```

**Container starts but the page does not load**
Check that it is running and read its logs:

```bash
container list
container logs web-tool
```

If the port is already in use, stop the other process or set `WEB_TOOL_PORT`.

**Favicon cache is not persisted / permission errors in the logs**
See [Data directory](#data-directory): the bind mount may be root-owned, so make
`WEB_TOOL_DATA_DIR` writable by uid 1000.

**The agent keeps restarting**
The script exits non-zero if `container system start`, `container image pull`, or
`container run` fails, which triggers a throttled relaunch. Read
`~/Library/Logs/web-tool.log` for the underlying error, then fix it before
letting it retry.

## Manual verification checklist

The Apple container path cannot be exercised on a machine without the `container`
CLI. When you run it for the first time, confirm:

1. `scripts/run-web-tool-container.sh` prints the URL and `container list` shows
   `web-tool` as running.
2. <http://localhost:8532/> loads, and a bookmarklet round-trips.
3. A favicon added via the UI appears in `"$WEB_TOOL_DATA_DIR/favicon.yml"`.
4. `scripts/web-tool-autostart.sh install` loads the agent
   (`launchctl print gui/$(id -u)/com.dockmann.web-tool`).
5. After logging out and back in, `container list` shows `web-tool` running
   again and `~/Library/Logs/web-tool.log` shows the startup.
6. `scripts/web-tool-autostart.sh uninstall` unloads and removes the agent.

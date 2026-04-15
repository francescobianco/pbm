# pbm - Packbase Manager

CLI client for managing the [packbase](https://github.com/yafb/packbase) server.

## Installation

```bash
make build
make install
```

Or download the binary from the [releases page](https://github.com/yafb/pbm/releases).

## Quick Start

1. Start the packbase server with Docker:

```bash
docker run -p 9122:9122 -d yafb/packbase
```

2. Check the server status:

```bash
pbm status
```

Example output:

```
service    packbase  (r0016)
healthy    14/85  (71 unhealthy)
disk       22% used

update     idle
packages   85 total  ·  85 probed  ·  1 synced
source     83 packages
tarballs   0 present  ·  91 created
repos      1 scanned
```

## Commands

| Command | Description |
|---------|-------------|
| `pbm ping` | Check if the server is reachable |
| `pbm status` | Show server status |
| `pbm info [package]` | Show server info or package details |
| `pbm list` | List all available packages |
| `pbm search <query>` | Search packages by name |
| `pbm fetch <git_url>` | Add a new package from git repository |
| `pbm update` | Sync local state with package sources |
| `pbm check <package>` | Check health and metadata of a package |
| `pbm clone <package>` | Git-clone a hosted package |

## Global Options

| Option | Description | Default |
|--------|-------------|---------|
| `--host <host>` | Server host | localhost |
| `--port <port>` | Server port | 9122 |
| `--print-json` | Print raw JSON from server | - |
| `--print-curl` | Print equivalent curl command | - |
| `--timeout <sec>` | Polling timeout for update (default: 10) | 10 |

## Configuration

Options are read in order of precedence:
1. Flags `--host` / `--port`
2. Environment variable `PACKBASE_URL` (e.g. `http://myserver:9122`)
3. File `.pbmrc` in current directory
4. File `.pbmrc` in home directory

For authentication with `fetch`, use the `PACKBASE_TOKEN` environment variable.

## Examples

```bash
# Check connection
pbm ping

# Search packages
pbm search zlib

# Add a package (requires TOKEN)
PACKBASE_TOKEN=xxx pbm fetch https://github.com/example/package

# Update data (with polling)
pbm update --timeout 30

# Curl mode for debugging
pbm --print-curl status
```

## Shell Completion

Bash:
```bash
make completion
# or manually
sudo cp contrib/pbm-completion.bash /etc/bash_completion.d/pbm
```

Zsh:
```bash
sudo cp contrib/pbm-completion.zsh /usr/share/zsh/site-functions/_pbm
```

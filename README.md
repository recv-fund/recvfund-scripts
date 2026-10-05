# recv.fund installer

Installs recv.fund, self-hosted non-custodial stablecoin payment software, on
a server you control. One command writes a Docker Compose project with Caddy,
the recv.fund API and dashboard, Redis and PostgreSQL, runs the database
migrations and starts everything. The images are public on GitHub Container
Registry; nothing is built on your server.

## Install

On a Linux server (Ubuntu, Debian, Linux Mint, CentOS, RHEL, Rocky Linux,
AlmaLinux, Fedora, Arch or Alpine; amd64 or arm64):

```bash
curl -fsSL https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh | sudo bash -s -- --testnet
```

Without flags the script shows a menu and asks for each choice. It installs
Docker if it is missing, then asks for the network (mainnet or testnet), the
database (external or bundled PostgreSQL) and HTTPS (Let's Encrypt with a
domain, or plain HTTP). When it finishes it prints the address of the signup
page where you create the owner account.

Common unattended installs:

```bash
# Test networks, plain HTTP on port 80
curl -fsSL https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh | sudo bash -s -- --testnet --yes

# Mainnet with a domain and Let's Encrypt (DNS must point at the server)
curl -fsSL https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh | sudo bash -s -- \
  --mainnet --domain pay.example.com --email ops@example.com --yes
```

Requirements: 2 CPU cores, 4 GB memory, 20 GB disk recommended (the script
asks before continuing below 5 GB), ports 80 and 443 free for Let's Encrypt
or one free port with `--http-port` behind your own proxy, Bash 4 or newer,
`curl` and `openssl`. macOS with Docker Desktop works for local testing over
plain HTTP; run the script with Homebrew's Bash (`brew install bash`).

## Versions

Every merge to `main` of `recvfund-server` publishes a new version of the
images `ghcr.io/recv-fund/recvfund-api` and `ghcr.io/recv-fund/recvfund-web`
(`X.Y.Z`, the previous patch number plus one). A fresh install and `--update`
look up the newest `X.Y.Z` on GHCR and write it to `.env` as `IMAGE_TAG`;
`--image-tag` chooses another. A released version is never replaced.

The installer has its own version (`install.sh --version`), and every merge to
this repository's `main` publishes a new one. The URL above always serves the
newest installer release; a specific one is at
`https://github.com/recv-fund/recvfund-scripts/releases/download/vX.Y.Z/install.sh`.
Every release also carries `SHA256SUMS`:

```bash
curl -fsSLO https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh
curl -fsSLO https://github.com/recv-fund/recvfund-scripts/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
sudo bash install.sh --testnet
```

## Operate

```bash
# Update to the newest release (keeps .env and data, runs migrations)
curl -fsSL https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh | sudo bash -s -- --update --yes

sudo bash install.sh --status     # containers and API health
sudo bash install.sh --restart    # restart without changing anything
sudo bash install.sh --reset      # delete the installation; asks you to type the directory twice

# Stop and start the containers, keeping all data (there is no installer flag for this)
cd /opt/recvfund && sudo docker compose -p recvfund --profile db stop
cd /opt/recvfund && sudo docker compose -p recvfund --profile db start
```

Leave out `--profile db` with an external database; with the bundled database
it is required, or the Postgres container keeps running.

`--update` moves to the images of the installer you run. It refuses to move a
newer installation back to an older version unless you pass `--image-tag`.
`update.sh` from the same release is a shortcut for `install.sh --update`.

For plain HTTP, the suggested site URL uses the address `api.ipify.org`
reports. Behind a router or in a VM such as Lima, that address doesn't reach
the server. Answer the prompt with an address your browser can reach
(`http://localhost` for Lima), or change it after signup under Installation,
Site URL.
Run `bash install.sh --help` for every flag, including an external database
(`--external-db`, `--pg-*`), `--http-port`, `--image-tag` and `--dir` (default
`/opt/recvfund`).

Back up `/opt/recvfund/.env` and the database together. `AES_ENCRYPTION_KEY`
in `.env` decrypts every stored secret, including hot wallet keys, and cannot
be recovered. Operations and configuration details:
[docs/INSTALLATION.md](docs/INSTALLATION.md). Full documentation:
https://docs.recv.fund.

## Develop and verify

```bash
bash -n install.sh update.sh test/*.sh
shellcheck -x install.sh update.sh test/*.sh
bash test/dry-run.sh                 # prints Docker commands instead of running them
bash test/health-result.sh           # install/update/restart fail when the API is unhealthy
bash test/docker-smoke.sh            # real install from a sibling recvfund-server checkout
RECV_SMOKE_IMAGE_TAG=X.Y.Z bash test/docker-smoke.sh   # real install from the published images
bash test/published-images.sh X.Y.Z  # the images can be pulled without credentials
```

The dry run writes only a temporary directory. With a sibling
`recvfund-server` checkout (or `RECVFUND_SERVER_DIR`) it also checks that the
embedded Compose file, Caddyfile and `.env` layout match the server's
`docker-compose.prod.yml`, `deploy/Caddyfile` and `deploy/.env.example`.
`test/docker-smoke.sh` needs a Docker daemon; it uses a unique Compose
project on loopback port 18090 (`RECV_SMOKE_PORT`), creates no owner, and
removes its containers, volumes and temporary directory on exit.
`--source <recvfund-server checkout>` builds the images locally instead of
pulling them.

GitHub Actions runs the static checks on every push (`ci.yml`) and publishes
releases from version tags (`release.yml`). See [RELEASING.md](RELEASING.md).

## Handover rule

Before finishing: commit small conventional changes as the global git author
without trailers, keep README/docs true, and append a dated handover with
verification, known limitations and the next step to
`../recvfund-planning/PROGRESS.md`. Full rules: `../AGENTS.md`.

## API documentation routing

The generated Caddy configuration sends `/api`, `/api/*`, `/api-json` and
`/api-yaml` to the API container, keeping Swagger and agent discovery on the
same origin as checkout. Dashboard routes go to the web container. Installer
syntax and matching rules are verified locally; install/update/TLS acceptance
must still run against a release image on the target host.

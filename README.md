# recvfund-scripts

Installer and update wrapper for the self-hosted recv.fund stack. The installer
writes Docker Compose, Caddy and environment configuration, starts PostgreSQL
and Redis, runs migrations/seeds, then starts the API, dashboard and checkout.

Requires Bash 4+, Docker Compose 2+, curl and openssl. Linux supports automatic
HTTPS with a domain; macOS supports local HTTP testing with Docker Desktop.
The image-pull path expects published `ghcr.io/recvfund/recvfund-{api,web}` images.
Until release images are available, build the sibling server checkout:

```bash
bash install.sh --yes --testnet --http-port 8080 \
  --dir /absolute/path/to/recvfund-install --source /absolute/path/to/recvfund-server
```

Open `/signup` on the printed site URL to create the installation owner.
Programs and merchant registrations must be configured before accepting payments.
`--testnet` selects Solana devnet and Robinhood testnet; `--mainnet` selects live
networks. Run `bash install.sh --help` for the complete flags.

```bash
bash install.sh --update --yes --dir /absolute/path/to/recvfund-install
bash install.sh --restart --yes --dir /absolute/path/to/recvfund-install
bash install.sh --status --dir /absolute/path/to/recvfund-install
```

`update.sh` forwards to `install.sh --update`, using the adjacent checkout when
available. Existing installations preserve their environment and secrets. Source
build overrides persist across updates. See [operations and configuration](docs/INSTALLATION.md).

Verification:

```bash
bash -n install.sh update.sh test/dry-run.sh
bash test/dry-run.sh
bash test/health-result.sh
shellcheck -x install.sh update.sh test/*.sh
```

The dry-run writes only a unique temporary directory and removes it on exit.
Docker commands are printed. It checks fresh install, update/restart/status,
secret preservation/redaction, permissions, platform restrictions, and embedded
template parity against the sibling server. Set `RECVFUND_SERVER_DIR` to use a
different checkout, `BASH_BIN` to choose Bash, or `RECV_TEST_DIR` to choose the
parent temporary directory. Syntax, dry-run, health-failure regression and
shellcheck pass. Install/update/restart exit nonzero if API health never succeeds.

## Real Docker verification

Run `bash test/docker-smoke.sh` with a running Docker daemon. It builds the
sibling server with the real Dockerfiles, uses a unique Compose project and
loopback port 18090, runs migrations and seeds, checks API health and the signup
page, replaces the API container to check upload persistence, and replays
migrations against the running install. Set `RECV_SMOKE_PORT` to change the
port and `RECVFUND_SERVER_DIR` to build a different checkout. It removes its
containers, volumes and temporary directory on exit. Downloaded base images and
build cache remain reusable. It creates no owner or live payment configuration.

Last passing run: 2026-09-29 on macOS with Docker Desktop, source build of the
sibling server at `e15ae11` (11 migrations, 7 seeds, API healthy in 3 s,
migration replay reported nothing pending). It does not cover interactive
prompts, published release images, TLS issuance, external PostgreSQL, updates
between image tags, or public-network payments.

## Handover rule

Before finishing: commit small conventional changes as the global git author
without trailers, keep README/docs true, and append a dated handover with
verification, known limitations and the next step to
`../recvfund-planning/PROGRESS.md`. Full rules: `../AGENTS.md`.

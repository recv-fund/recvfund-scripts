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
shellcheck install.sh update.sh test/dry-run.sh
```

The dry-run writes only a unique temporary directory and removes it on exit.
Docker commands are printed. It checks fresh install, update/restart/status,
secret preservation/redaction, permissions, platform restrictions, and embedded
template parity against the sibling server. Set `RECVFUND_SERVER_DIR` to use a
different checkout, `BASH_BIN` to choose Bash, or `RECV_TEST_DIR` to choose the
parent temporary directory. Syntax, dry-run and shellcheck pass. Actual Docker
installation verification is underway; these checks alone do not prove startup.

## Handover rule

Before finishing: commit small conventional changes as the global git author
without trailers, keep README/docs true, and append a dated handover with
verification, known limitations and the next step to
`../recvfund-planning/PROGRESS.md`. Full rules: `../AGENTS.md`.

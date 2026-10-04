# Installation and operations

The install directory contains `.env` (mode 600), `docker-compose.yml`,
`Caddyfile`, `install.log`, and an optional `docker-compose.build.yml` for
`--source`. Keep the environment file and database backups together;
`AES_ENCRYPTION_KEY` decrypts stored hot-wallet and integration secrets.

Compose project name is `recvfund`. The bundled database uses profile `db`.
Persistent volumes hold PostgreSQL, Redis, API logs/uploads and Caddy state.
There is no stop operation: `docker compose -p recvfund --profile db stop`
and `start` in the install directory stop and start every container and keep
the data. Without `--profile db`, Compose skips the bundled Postgres service,
so it keeps running. `down -v` deletes the volumes.

The plain-HTTP site URL default is `http://<ip>`, where `<ip>` comes from
`api.ipify.org` (or `localhost` when that fails). Behind NAT or inside a VM it
is the router's address and is not reachable; enter a reachable address at the
prompt or change it under Installation, Site URL after signup.
Reset deletes this installation's volumes and directory and requires typing the
directory twice. `--yes` does not supply those destructive confirmations.

For Linux HTTPS, supply `--domain` and `--email`, with DNS directed to the
server and ports 80/443 available. `--http-port` selects plain HTTP for local
use or a separate reverse proxy; it cannot be combined with `--domain`.
`--http-bind <IPv4>` publishes that port on one address only (the Compose
mapping becomes `'<ip>:<port>:80'`, and updates read it back), for a proxy on
the same host; Docker's published ports are not filtered by `ufw`.
`--site-url <url>` sets `SITE_URL` in plain-HTTP mode without the prompt.

External PostgreSQL uses `--external-db` and `--pg-host`, `--pg-port`,
`--pg-db`, `--pg-user`, optional `--pg-ssl`, and a password prompt. The
`--pg-password` flag is available for automation but is visible in process
arguments. `localhost` inside the API container refers to that container.
The installer uses `pg_isready` for reachability; migration startup is the
actual authentication/schema check.

Environment keys and comments mirror `recvfund-server/deploy/.env.example`:

- Routing: `SITE_DOMAIN`, `ACME_EMAIL`, `SITE_URL`.
- Network and images: `NETWORK_TYPE`, `IMAGE_TAG`.
- Secrets: `AES_ENCRYPTION_KEY`, `ADMIN_API_KEY`, `REDIS_PASSWORD`.
- Database: `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`,
  `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_SSL`.
- Delivery: `SEND_WEBHOOKS`.

Runtime settings, including SMTP, fees, payout and sweep policies, live in the
server's PlatformConfig table. See its `docs/PLATFORM_CONFIG_KEYS.md`; the
installer adds no runtime config keys. Root setup provisions authentication
secrets. Never rotate AES_ENCRYPTION_KEY without migrating encrypted data.

Fresh installs and `--update` write `IMAGE_TAG` as the newest `X.Y.Z` that both
images have on GHCR (`latest_release`: anonymous pull token, tag list, highest
version present for api and web), unless `--image-tag` is given. If the lookup
fails, the installer stops and asks for `--image-tag`. `--update` refuses to
lower a newer installed version, which can only happen if a release was
removed. Installs built with `--source` keep their tag (`local` by default).
`RECV_LATEST_RELEASE` replaces the lookup in tests. `SCRIPT_VERSION` is `dev`
on `main`; the release workflow writes the release version into the
published asset.

Updates preserve `.env`, set `IMAGE_TAG` as above, fetch/build images,
run pending migrations/seeds and restart services. They do not migrate custom
Compose/Caddy templates. Review template changes when upgrading. Native/token
watchers require configured programs and appropriate RPC providers; an installer
health check alone does not establish payment readiness.

The embedded compose and Caddy templates are verified against the server.
HTTP rendering changes port mapping, removes HTTPS ports and the Caddy global
email block. The uploads volume must remain present across container replacement.
The source build override sets the checkout context and public API path.

The installer can be sourced in a disposable Bash process to load template
renderers without parsing flags or running operations. The dry-run uses this
path, so heredoc contents are parsed by Bash rather than extracted as fragments.


Install, update and restart return a failure if the API health wait expires. A
success banner is printed only after that wait succeeds. The regression script
`test/health-result.sh` checks each operation with a failed health response.


The Docker smoke harness (`test/docker-smoke.sh`) calls the real install
operation after loading the installer with isolated fixture state, a loopback
URL/port and a unique Compose project name. It passed end to end on 2026-09-29
against a source build of the sibling server: image build, bundled
PostgreSQL/Redis startup, migrations and seeds, API health, the signup page,
upload persistence across API container replacement, and migration replay.
With `RECV_SMOKE_IMAGE_TAG=X.Y.Z` it skips the source build: it first runs
`test/published-images.sh` (anonymous registry token, multi-arch manifest for
amd64 and arm64) and then installs from the published images. It does not
test interactive prompts, TLS issuance, external PostgreSQL or public-network
payments.

The public command runs the script from a pipe (`curl … | sudo bash -s --`),
where Bash provides no source file. Release 0.1.0 crashed in that case
(`BASH_SOURCE[0]: unbound variable`) and was superseded by 0.1.1; the dry run
now runs both scripts from stdin.

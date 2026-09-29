# Installation and operations

The install directory contains `.env` (mode 600), `docker-compose.yml`,
`Caddyfile`, `install.log`, and an optional `docker-compose.build.yml` for
`--source`. Keep the environment file and database backups together;
`AES_ENCRYPTION_KEY` decrypts stored hot-wallet and integration secrets.

Compose project name is `recvfund`. The bundled database uses profile `db`.
Persistent volumes hold PostgreSQL, Redis, API logs/uploads and Caddy state.
Reset deletes this installation's volumes and directory and requires typing the
directory twice. `--yes` does not supply those destructive confirmations.

For Linux HTTPS, supply `--domain` and `--email`, with DNS directed to the
server and ports 80/443 available. `--http-port` selects plain HTTP for local
use or a separate reverse proxy; it cannot be combined with `--domain`.

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

Updates preserve `.env`, optionally change `IMAGE_TAG`, fetch/build images,
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
It does not test interactive prompts, public release image availability, TLS
issuance, external PostgreSQL or public-network payments.

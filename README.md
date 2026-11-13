# postfix-docker

[![CI](https://github.com/dreitier/postfix-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/dreitier/postfix-docker/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/dreitier/postfix-docker/badge)](https://scorecard.dev/viewer/?uri=github.com/dreitier/postfix-docker)

Postfix as an SMTP relay in a container: applications in your network send mail to it without
authentication, and Postfix forwards everything to an upstream SMTP server (e.g. Mailgun, Amazon SES,
Microsoft 365) with TLS and SASL authentication. Mail that can't be delivered right away stays in the
queue and is retried.

- Images: `dreitier/postfix` (Docker Hub) and `ghcr.io/dreitier/postfix`, linux/amd64 and linux/arm64
- Tags: `x.y.z`, `x.y`, `x`, `latest` (no `v` prefix); changes in [CHANGELOG.md](CHANGELOG.md)
- Helm chart: `postfix` in [dreitier/helm-charts](https://github.com/dreitier/helm-charts)

## Configuration

| Variable | Default | Description |
|---|---|---|
| `TX_SMTP_RELAY_HOST` | – (required) | Upstream server, e.g. `[smtp.mailgun.org]:587`. Brackets: no MX lookup. |
| `TX_SMTP_RELAY_MYHOSTNAME` | – (required) | Host name of the relay (HELO, `Received:` header). |
| `TX_SMTP_RELAY_USERNAME` / `_FILE` | – | SASL user name for the upstream server, or a file containing it. |
| `TX_SMTP_RELAY_PASSWORD` / `_FILE` | – | SASL password, or a file containing it (e.g. a mounted secret). Without user name and password, SASL is disabled. |
| `TX_SMTP_RELAY_NETWORKS` | `127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` | Clients allowed to relay (`mynetworks`). Only add networks you trust; everything in it can send mail with your credentials. |
| `TX_SMTP_TLS_SECURITY_LEVEL` | `encrypt` | `smtp_tls_security_level` towards the upstream server: `encrypt` (TLS required), `secure`/`verify` (TLS with certificate check against the system CAs), `may` (opportunistic, allows a downgrade), `none`. The former name `TX_SMTP_SASL_SECURITY_LEVEL` is still accepted. |
| `TX_SMTP_TLS_WRAPPERMODE` | `no` | `yes` for implicit TLS (port 465), `no` for STARTTLS (ports 587/25). |
| `TX_SMTP_SASL_SECURITY_OPTIONS` | `noanonymous, noplaintext` | `smtp_sasl_security_options` (without TLS: no plain-text passwords). |
| `TX_SMTP_SASL_TLS_SECURITY_OPTIONS` | `noanonymous` | `smtp_sasl_tls_security_options` (with TLS: PLAIN/LOGIN allowed). |
| `POSTFIX_<parameter>` | – | Any other `main.cf` parameter, e.g. `POSTFIX_message_size_limit=52428800`, `POSTFIX_inet_protocols=ipv4`. |

Nothing is delivered locally (`mydestination` is empty); all mail goes to the upstream server. Postfix adds
missing `Message-ID`/`Date` headers, otherwise DKIM checks of some providers fail.

Postfix logs to stdout. The SMTP port is 25; the master process runs as root and drops privileges for its
daemons. Mount a volume at `/var/spool/postfix` to keep queued mail across restarts.

## Run

```bash
docker run -d --name postfix-relay -p 2525:25 \
  -e TX_SMTP_RELAY_HOST='[smtp.mailgun.org]:587' \
  -e TX_SMTP_RELAY_MYHOSTNAME=relay.example.com \
  -e TX_SMTP_RELAY_USERNAME=postmaster@mg.example.com \
  -e TX_SMTP_RELAY_PASSWORD_FILE=/run/secrets/smtp-password \
  -v "$PWD/smtp-password:/run/secrets/smtp-password:ro" \
  -v postfix-queue:/var/spool/postfix \
  dreitier/postfix:1
```

Send a test mail, e.g. with [swaks](https://github.com/jetmore/swaks):

```bash
swaks --server localhost:2525 --from noreply@example.com --to you@example.com
docker logs postfix-relay   # ... status=sent (250 ...)
```

Useful commands inside the container: `postqueue -p` (show the queue), `postqueue -f` (retry now),
`postsuper -d ALL deferred` (drop deferred mail).

## Upgrading from 0.x

1.0.0 runs Postfix in the foreground without supervisord/rsyslog and changes some defaults:

- `TX_SMTP_RELAY_NETWORKS` defaults to the private networks; the old default contained `192.0.0.0/8`
  (public addresses). If you set it explicitly (the Helm chart did), remove `192.0.0.0/8` — the container
  logs a warning while it is configured.
- TLS to the upstream server is required by default (`encrypt` instead of `may`).
- Logs go to stdout only (`/var/log/maillog` is gone), the container stops immediately on SIGTERM and exits
  when Postfix exits.
- Mail to `TX_SMTP_RELAY_MYHOSTNAME` is relayed instead of delivered into the container.

## Verify an image

Images are signed keyless with Sigstore and have build provenance attestations:

```bash
cosign verify dreitier/postfix:<tag> \
  --certificate-identity https://github.com/dreitier/postfix-docker/.github/workflows/release.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify oci://ghcr.io/dreitier/postfix:<tag> --owner dreitier
```

## Development

- `make build` builds `dreitier/postfix:local`, `make e2e` runs the end-to-end test of the CI against
  [Mailpit](https://mailpit.axllent.org/) (needs Docker and python3).
- `make hooks` installs the pre-commit hooks (actionlint, hadolint, shellcheck), `make lint` runs them.
- `make pin-images` pins the base image to its current digest; Dependabot keeps it up to date.

Releases are automated: PRs are squash-merged with a [Conventional Commit](https://www.conventionalcommits.org/)
title, and every merge to `main` runs [release.yml](.github/workflows/release.yml) — semantic-release derives
the version (`fix:`/`build(deps):` → patch, `feat:` → minor, `feat!:`/`BREAKING CHANGE:` → major; `docs:`,
`ci:`, `chore:` → no release), creates the GitHub release and publishes the signed images.
Don't edit CHANGELOG.md or create tags by hand.

## License

MIT, see [LICENSE.md](LICENSE.md).

## Thanks

Based on the examples from [applariat/kubernetes-postfix-relay-host](https://github.com/applariat/kubernetes-postfix-relay-host).

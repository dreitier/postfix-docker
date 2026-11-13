# syntax=docker/dockerfile:1

# Postfix as a pure SMTP relay: accepts mail from the networks in TX_SMTP_RELAY_NETWORKS and forwards
# everything to TX_SMTP_RELAY_HOST (STARTTLS/TLS + SASL). Configured by entrypoint.sh from the environment.
FROM alpine:3.24

LABEL org.opencontainers.image.source="https://github.com/dreitier/postfix-docker" \
      org.opencontainers.image.description="Postfix SMTP relay that forwards mail to an upstream SMTP server with TLS and SASL authentication" \
      org.opencontainers.image.vendor="dreitier GmbH"

# DL3018: distribution packages are not pinned; the image is rebuilt on every release and weekly in CI
# cyrus-sasl-login: AUTH LOGIN for upstream servers without AUTH PLAIN (e.g. Microsoft 365); PLAIN is in libsasl
# hadolint ignore=DL3018
RUN apk add --no-cache \
      postfix \
      cyrus-sasl-login \
      ca-certificates \
      tzdata \
    && newaliases

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# mount a volume here to keep queued mail across restarts
# (deferred mail is lost otherwise, e.g. while the upstream server is unreachable)
EXPOSE 25/tcp

# the Postfix master process runs as root and drops privileges for its daemons
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD ["postfix", "status"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# master in the foreground (PID 1), logging to stdout via postlogd
CMD ["postfix", "start-fg"]

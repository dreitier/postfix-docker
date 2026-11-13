#!/usr/bin/env bash
# End-to-end test of the image (CI and `make e2e`), with Mailpit as the upstream SMTP server:
#  1. a mail from an allowed network is relayed via STARTTLS + SASL (credentials from a file) and gets a Message-ID
#  2. a client outside TX_SMTP_RELAY_NETWORKS can't relay (no open relay)
#  3. Postfix logs to stdout, never logs the password, keeps the credentials root-only and stops quickly on SIGTERM
# Needs Docker and python3. Usage: e2e.sh <image>
set -euo pipefail

image=${1:?usage: e2e.sh <image>}
mailpit_image=${MAILPIT_IMAGE:-axllent/mailpit:v1.33.1}
password=ci-secret-$RANDOM
net=postfix-e2e-$$
tmp=$(mktemp -d)

cleanup() {
    docker rm -f "${net}-relay" "${net}-closed" "${net}-mailpit" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    for c in relay closed mailpit; do
        echo "--- docker logs ${net}-${c}"
        docker logs "${net}-${c}" 2>&1 || true
    done
    exit 1
}

host_port() { docker port "$1" "$2" | head -n 1 | sed 's/.*://'; }

wait_for_postfix() {
    for _ in $(seq 60); do
        docker exec "$1" postfix status >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    fail "postfix in $1 did not start"
}

# sends a mail to the relay on port $1; exit code 3 if the recipient is refused
send_mail() {
    python3 - "$1" <<'PY'
import smtplib, sys
from email.message import EmailMessage

msg = EmailMessage()
msg["From"] = "app@example.org"
msg["To"] = "user@example.com"
msg["Subject"] = "postfix e2e"
msg.set_content("hello from the relay")  # deliberately without Message-ID
try:
    with smtplib.SMTP("127.0.0.1", int(sys.argv[1]), timeout=30) as smtp:
        smtp.send_message(msg)
except smtplib.SMTPRecipientsRefused as e:
    print(f"recipient refused: {e.recipients}")
    sys.exit(3)
PY
}

docker network create "$net" >/dev/null

echo "== upstream SMTP server (Mailpit, STARTTLS required, self-signed certificate, SASL)"
docker run -d --name "${net}-mailpit" --network "$net" --network-alias mailpit \
    -e "MP_SMTP_AUTH=relayuser:${password}" \
    -e MP_SMTP_TLS_CERT=sans:mailpit \
    -e MP_SMTP_TLS_KEY=sans:mailpit \
    -e MP_SMTP_REQUIRE_STARTTLS=true \
    -p 127.0.0.1::8025 \
    "$mailpit_image" >/dev/null
api="http://127.0.0.1:$(host_port "${net}-mailpit" 8025)/api/v1"
curl -fsS --retry 30 --retry-delay 1 --retry-all-errors -o /dev/null "${api}/messages" || fail "Mailpit did not start"

echo "== relay with the defaults (TLS level encrypt, private networks)"
printf '%s\n' "$password" > "${tmp}/password"
chmod 0644 "${tmp}/password"
docker run -d --name "${net}-relay" --network "$net" \
    -e 'TX_SMTP_RELAY_HOST=[mailpit]:1025' \
    -e TX_SMTP_RELAY_MYHOSTNAME=relay.example.org \
    -e TX_SMTP_RELAY_USERNAME=relayuser \
    -e TX_SMTP_RELAY_PASSWORD_FILE=/run/secrets/relay-password \
    -v "${tmp}/password:/run/secrets/relay-password:ro" \
    -p 127.0.0.1::25 \
    "$image" >/dev/null
wait_for_postfix "${net}-relay"
send_mail "$(host_port "${net}-relay" 25)" || fail "relay did not accept the mail"

for _ in $(seq 30); do
    total=$(curl -fsS "${api}/messages" | python3 -c 'import json, sys; print(json.load(sys.stdin)["total"])')
    [ "$total" -ge 1 ] && break
    sleep 1
done
[ "$total" -eq 1 ] || fail "expected 1 mail in Mailpit, got ${total}"
curl -fsS "${api}/messages" | python3 -c '
import json, sys
m = json.load(sys.stdin)["messages"][0]
assert m["Subject"] == "postfix e2e", m
assert m["To"][0]["Address"] == "user@example.com", m
assert m["MessageID"], "no Message-ID added (always_add_missing_headers)"
print("relayed:", m["Subject"], "->", m["To"][0]["Address"], "Message-ID", m["MessageID"])
' || fail "unexpected mail in Mailpit"

logs=$(docker logs "${net}-relay" 2>&1)
grep -q 'TLS connection established to mailpit' <<< "$logs" || fail "no TLS connection to the upstream server in the log"
grep -q 'status=sent' <<< "$logs" || fail "no status=sent in the log (stdout logging)"
if grep -qF "$password" <<< "$logs"; then fail "the password appears in the log"; fi
[ "$(docker exec "${net}-relay" stat -c '%a %U' /etc/postfix/sasl_passwd.lmdb)" = "600 root" ] \
    || fail "credentials map must be readable by root only"
if docker exec "${net}-relay" test -e /etc/postfix/sasl_passwd; then fail "plain-text credentials left in /etc/postfix"; fi

echo "== SIGTERM"
start=$(date +%s)
docker stop -t 20 "${net}-relay" >/dev/null
[ $(($(date +%s) - start)) -lt 10 ] || fail "postfix did not stop on SIGTERM (killed after the timeout)"

echo "== client outside TX_SMTP_RELAY_NETWORKS"
docker run -d --name "${net}-closed" --network "$net" \
    -e 'TX_SMTP_RELAY_HOST=[mailpit]:1025' \
    -e TX_SMTP_RELAY_MYHOSTNAME=relay.example.org \
    -e TX_SMTP_RELAY_NETWORKS=127.0.0.0/8 \
    -p 127.0.0.1::25 \
    "$image" >/dev/null
wait_for_postfix "${net}-closed"
rc=0
send_mail "$(host_port "${net}-closed" 25)" || rc=$?
[ "$rc" -eq 3 ] || fail "relaying from outside TX_SMTP_RELAY_NETWORKS was not refused"

echo "e2e: all checks passed"

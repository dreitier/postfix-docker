#!/bin/sh
# Configures Postfix as an SMTP relay from environment variables (see README.md), then runs the
# command, by default `postfix start-fg`. Other commands (e.g. `sh`) run without configuration.
set -eu

log() { echo "entrypoint: $*"; }
die() { echo "entrypoint: error: $*" >&2; exit 1; }

# Reads a setting from VAR or from the file named in VAR_FILE (Docker/Kubernetes secrets).
file_env() {
    _var=$1
    _value=$(printenv "$_var" || true)
    _file=$(printenv "${_var}_FILE" || true)
    if [ -n "$_value" ] && [ -n "$_file" ]; then
        die "set either ${_var} or ${_var}_FILE, not both"
    fi
    if [ -n "$_file" ]; then
        [ -r "$_file" ] || die "${_var}_FILE: cannot read ${_file}"
        _value=$(cat "$_file")
    fi
    eval "${_var}=\$_value"
}

configure() {
    : "${TX_SMTP_RELAY_HOST:?Missing env var TX_SMTP_RELAY_HOST, e.g. [smtp.example.com]:587}"
    : "${TX_SMTP_RELAY_MYHOSTNAME:?Missing env var TX_SMTP_RELAY_MYHOSTNAME}"
    file_env TX_SMTP_RELAY_USERNAME
    file_env TX_SMTP_RELAY_PASSWORD
    if [ -n "$TX_SMTP_RELAY_USERNAME" ] && [ -z "$TX_SMTP_RELAY_PASSWORD" ]; then
        die "TX_SMTP_RELAY_USERNAME is set, but TX_SMTP_RELAY_PASSWORD is missing"
    fi
    if [ -z "$TX_SMTP_RELAY_USERNAME" ] && [ -n "$TX_SMTP_RELAY_PASSWORD" ]; then
        die "TX_SMTP_RELAY_PASSWORD is set, but TX_SMTP_RELAY_USERNAME is missing"
    fi

    # private networks only (RFC 1918 + loopback); never add public ranges, that makes an open relay
    networks=${TX_SMTP_RELAY_NETWORKS:-127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}
    case ",$(echo "$networks" | tr -d "[:space:]")," in
        *,0.0.0.0/0,* | *,192.0.0.0/8,*)
            # 192.0.0.0/8 was the default of image <= 0.4 and of the Helm chart; it contains public addresses
            log "WARNING: TX_SMTP_RELAY_NETWORKS contains public addresses, anyone there can relay mail: ${networks}" ;;
    esac
    sasl_options=${TX_SMTP_SASL_SECURITY_OPTIONS:-noanonymous, noplaintext}
    sasl_tls_options=${TX_SMTP_SASL_TLS_SECURITY_OPTIONS:-noanonymous}
    # TX_SMTP_SASL_SECURITY_LEVEL is the former name of TX_SMTP_TLS_SECURITY_LEVEL (still set by the Helm chart)
    tls_level=${TX_SMTP_TLS_SECURITY_LEVEL:-${TX_SMTP_SASL_SECURITY_LEVEL:-encrypt}}
    # yes for implicit TLS (port 465), no for STARTTLS (ports 587/25)
    tls_wrappermode=${TX_SMTP_TLS_WRAPPERMODE:-no}

    log "relay host:        ${TX_SMTP_RELAY_HOST}"
    log "myhostname:        ${TX_SMTP_RELAY_MYHOSTNAME}"
    log "networks:          ${networks}"
    log "TLS:               level ${tls_level}, wrapper mode ${tls_wrappermode}"

    postconf \
        "relayhost = ${TX_SMTP_RELAY_HOST}" \
        "myhostname = ${TX_SMTP_RELAY_MYHOSTNAME}" \
        "mynetworks = ${networks}" \
        "smtp_tls_security_level = ${tls_level}" \
        "smtp_tls_wrappermode = ${tls_wrappermode}" \
        'smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt' \
        'smtp_tls_loglevel = 1' \
        'mydestination =' \
        'maillog_file = /dev/stdout' \
        'smtputf8_enable = no' \
        'always_add_missing_headers = yes'
    # mydestination is empty: nothing is delivered locally, all mail goes to the relay host.
    # always_add_missing_headers: adds Message-ID/Date to mail from the networks, otherwise DKIM can fail.

    sasl_map=/etc/postfix/sasl_passwd
    rm -f "${sasl_map}" "${sasl_map}.lmdb"
    if [ -n "$TX_SMTP_RELAY_USERNAME" ]; then
        log "SASL:              user ${TX_SMTP_RELAY_USERNAME}, options '${sasl_options}' / TLS '${sasl_tls_options}'"
        # only root may read the credentials; the plain-text source is removed after building the map
        (
            umask 077
            printf '%s %s:%s\n' "$TX_SMTP_RELAY_HOST" "$TX_SMTP_RELAY_USERNAME" "$TX_SMTP_RELAY_PASSWORD" > "$sasl_map"
            postmap "lmdb:${sasl_map}"
        )
        rm -f "$sasl_map"
        chmod 0600 "${sasl_map}.lmdb"
        postconf \
            'smtp_sasl_auth_enable = yes' \
            "smtp_sasl_password_maps = lmdb:${sasl_map}" \
            "smtp_sasl_security_options = ${sasl_options}" \
            "smtp_sasl_tls_security_options = ${sasl_tls_options}"
    else
        log "SASL:              disabled (no TX_SMTP_RELAY_USERNAME/TX_SMTP_RELAY_PASSWORD)"
        postconf 'smtp_sasl_auth_enable = no'
        postconf -X smtp_sasl_password_maps smtp_sasl_security_options smtp_sasl_tls_security_options
    fi

    # Any other main.cf parameter: POSTFIX_<parameter>=<value>, e.g. POSTFIX_message_size_limit=52428800
    env | sed -n 's/^POSTFIX_\([a-z0-9_]*\)=.*/\1/p' | while read -r param; do
        value=$(printenv "POSTFIX_${param}")
        log "main.cf:           ${param} = ${value}"
        postconf "${param} = ${value}"
    done

    # checks the configuration and creates missing queue directories (e.g. on a freshly mounted volume)
    postfix check
}

if [ "${1:-}" = "postfix" ]; then
    configure
fi

exec "$@"

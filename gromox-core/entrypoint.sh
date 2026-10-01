#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2021 grommunio GmbH
# Interactive grommunio setup

DATADIR="${0%/*}"
if [ "${DATADIR}" = "$0" ]; then
	DATADIR="/home"
else
	DATADIR="$(readlink -f "$0")"
	DATADIR="${DATADIR%/*}"
	DATADIR="$(readlink -f "${DATADIR}")"
fi
if ! test -e "$LOGFILE"; then
	true >"$LOGFILE"
	chmod 0600 "$LOGFILE"
fi
# shellcheck source=common/helpers
. "${DATADIR}/common/helpers"
TMPF=$(mktemp /tmp/grommunio-setup.XXXXXXXX)

memory_check()
{

  local HAVE=$(perl -lne 'print $1 if m{^MemTotal:\s*(\d+)}i' </proc/meminfo)
  # Install the threshold a little lower than what we ask, to account for
  # FW/OS (Vbox with 4194304 KB ends up with MemTotal of about 4020752 KB)
  local THRES=4000000
  local ASK=4096000
  if [ -z "${HAVE}" ] || [ "${HAVE}" -ge "${THRES}" ]; then
    return 0
  fi
  memory_notice $((HAVE/1024)) $((ASK/1024))

}

memory_check

echo "[setup] Starting grommunio initial setup (one-time)..." | tee -a "${LOGFILE}"

# Set repository credentials directly
# shellcheck source=common/repo
INSTALLVALUE="core, chat"

X500_FILE="/etc/gromox/.x500_org"
if [ -n "${X500}" ]; then
  echo "${X500}" > "${X500_FILE}"
elif [ -f "${X500_FILE}" ]; then
  X500="$(cat "${X500_FILE}")"
else
  X500="i$(printf "%llx" "$(date +%s)")"
  echo "${X500}" > "${X500_FILE}"
fi

. "/home/common/ssl_setup"
mkdir -p /etc/grommunio-common/ssl
echo "[setup] Configuring SSL certificates..." | tee -a "${LOGFILE}"
RETCMD=1
if [ "${SSL_INSTALL_TYPE}" = "0" ]; then
  clear
  if ! selfcert; then
  touch ssle
  fi
elif [ "${SSL_INSTALL_TYPE}" = "2" ]; then
  #choose_ssl_letsencrypt
  #this should containe the domain to signed by certbot
  SSL_DOMAINS="$FQDN,autodiscover.$DOMAIN"

if [ -n "$MAIL_DOMAINS" ]; then
  SSL_DOMAINS="$SSL_DOMAINS,autodiscover.$DOMAIN,$MAIL_DOMAINS"
fi

  #This should contain the email
  SSL_EMAIL=admin@$FQDN
  letsencrypt
fi

# Configure config.json of admin-web
cat > /etc/grommunio-admin-common/nginx.d/web-config.conf <<EOF
location /config.json {
  alias /etc/grommunio-admin-common/config.json;
}
EOF

if [[ $INSTALLVALUE == *"chat"* ]] ; then
  echo "[setup] Initializing grommunio-chat database and admin user..." | tee -a "${LOGFILE}"
  . /home/vars/chat_db.env
    echo "drop database if exists ${MARIADB_DATABASE}; \
          create database ${MARIADB_DATABASE};" | mysql -h"${MARIADB_HOST}" -u"${MARIADB_USER}" -p"${MARIADB_PASSWORD}" "${MARIADB_DATABASE}" >/dev/null 2>&1

  CHAT_DB_CON="${MARIADB_USER}:${MARIADB_PASSWORD}@tcp\(${MARIADB_HOST}:3306\)\/${MARIADB_DATABASE}?charset=utf8mb4,utf8\&readTimeout=30s\&writeTimeout=30s"
  unset MARIADB_HOST MARIADB_ROOT_PASSWORD MARIADB_DATABASE MARIADB_USER MARIADB_PASSWORD
  sed -i 's#^.*"DataSource":.*#        "DataSource": "'${CHAT_DB_CON}'",#g' "${CHAT_CONFIG}"
  sed -i 's#^.*"DriverName": "postgres".*#        "DriverName": "mysql",#g' "${CHAT_CONFIG}"
  sed -i 's#^.*"EnableAPIUserDeletion":.*#        "EnableAPIUserDeletion": true,#g' "${CHAT_CONFIG}"
  sed -i 's|"SiteURL": "",|"SiteURL": "https://'${FQDN}'/chat",|g' "${CHAT_CONFIG}"
  touch "/var/log/grommunio-chat/mattermost.log"
  chown -R grochat:grochat "/etc/grommunio-chat/" "/usr/share/grommunio-chat/logs" "/usr/share/grommunio-chat/config" "/var/log/grommunio-chat" "/var/lib/grommunio-chat/"
  chmod 644 ${CHAT_CONFIG}

  # Temporarily start chat in background for admin user creation
  su -s /bin/bash -c "/usr/bin/grommunio-chat --config ${CHAT_CONFIG}" grochat &
  CHAT_PID=$!

  # Wait for the grommunio-chat unix socket
  for n in $(seq 1 20) ; do
    [ -e "/var/tmp/grommunio-chat_local.socket" ] && break
    sleep 3
  done

  pushd /usr/share/grommunio-chat/ || return
    MMCTL_LOCAL_SOCKET_PATH=/var/tmp/grommunio-chat_local.socket bin/grommunio-chat-ctl --local user create --email admin@localhost --username admin --password "${CHAT_ADMIN_PASS}" --system-admin >>"${LOGFILE}" 2>&1
  popd || return

  # Stop temporary chat instance
  kill $CHAT_PID 2>/dev/null || true
  wait $CHAT_PID 2>/dev/null || true
  rm -f /var/tmp/grommunio-chat_local.socket

  generate_admin_chat_conf "/etc/grommunio-admin-api/conf.d/chat.yaml"

  chmod 640 ${CHAT_CONFIG}

fi

echo "[setup] Configuring gromox services..." | tee -a "${LOGFILE}"
setconf /etc/gromox/http.cfg listen_port 10080
setconf /etc/gromox/http.cfg http_support_ssl true
setconf /etc/gromox/http.cfg listen_ssl_port 10443
setconf /etc/gromox/http.cfg host_id ${FQDN}

setconf /etc/gromox/smtp.cfg listen_port 24

echo "# Do not delete this file unless you know what you do!" > /etc/grommunio-common/setup_done

# Set Grommunio admin password
grommunio-admin passwd --password "${ADMIN_PASS}" >>"${LOGFILE}" 2>&1

# Set rspamd password
rspamadm pw -p "${ADMIN_PASS}" | sed -e 's#^#password = "#' -e 's#$#";#' > /etc/grommunio-antispam/local.d/worker-controller.inc

setconf /etc/gromox/http.cfg http_certificate_path "${SSL_BUNDLE_T}"
setconf /etc/gromox/http.cfg http_private_key_path "${SSL_KEY_T}"
setconf /etc/gromox/http.cfg tls_min_proto tls1.2

setconf /etc/gromox/imap.cfg imap_support_starttls true
setconf /etc/gromox/imap.cfg listen_port 143
setconf /etc/gromox/imap.cfg listen_ssl_port 993
setconf /etc/gromox/imap.cfg imap_certificate_path "${SSL_BUNDLE_T}"
setconf /etc/gromox/imap.cfg imap_private_key_path "${SSL_KEY_T}"
setconf /etc/gromox/imap.cfg tls_min_proto tls1.2

setconf /etc/gromox/pop3.cfg pop3_support_stls true
setconf /etc/gromox/pop3.cfg listen_port 110
setconf /etc/gromox/pop3.cfg listen_ssl_port 995
setconf /etc/gromox/pop3.cfg pop3_certificate_path "${SSL_BUNDLE_T}"
setconf /etc/gromox/pop3.cfg pop3_private_key_path "${SSL_KEY_T}"
setconf /etc/gromox/pop3.cfg tls_min_proto tls1.2


# Create gromox.cfg
touch /etc/gromox/gromox.cfg

# Domain and X500
for SERVICE in http midb zcore imap pop3 smtp delivery ; do
  setconf /etc/gromox/${SERVICE}.cfg default_domain "${DOMAIN}"
done
for CFG in gromox.cfg autodiscover.cfg midb.cfg zcore.cfg exmdb_local.cfg exmdb_provider.cfg exchange_emsmdb.cfg exchange_nsp.cfg ; do
  setconf "/etc/gromox/${CFG}" x500_org_name "${X500}"
done


# Keycloak Configuration
if [[ $ENABLE_KEYCLOAK = true ]] ; then
  echo "[setup] Configuring Keycloak SSO integration..." | tee -a "${LOGFILE}"
  # Fetch bearer public key from Keycloak JWKS endpoint
  JWKS_URL="${KEYCLOAK_URL}realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs"
  JWKS_RESPONSE=$(curl -sf "${JWKS_URL}")
  if [ -n "${JWKS_RESPONSE}" ]; then
    echo "${JWKS_RESPONSE}" \
      | jq -r '.keys[] | select(.alg=="RS256") | .x5c[0]' \
      | base64 -d > /tmp/keycloak_cert.der
    BEARER_PUBKEY=$(openssl x509 -inform DER -in /tmp/keycloak_cert.der -pubkey -noout 2>/dev/null)
    rm -f /tmp/keycloak_cert.der
  fi

  if [ -z "${BEARER_PUBKEY}" ]; then
    echo "WARNING: Could not fetch bearer public key from ${JWKS_URL}" >>"${LOGFILE}"
  else
    echo "${BEARER_PUBKEY}" > /etc/gromox/bearer_pubkey
    chmod 644 /etc/gromox/bearer_pubkey
  fi

fi

if [[ $ENABLE_KEYCLOAK = true ]] ; then
  PUBKEY_CLEAN=$(echo "${BEARER_PUBKEY}" | tr -d '\n')
  jq -n \
    --arg realm "${KEYCLOAK_REALM}" \
    --arg url "${KEYCLOAK_URL}" \
    --arg client "${KEYCLOAK_CLIENT_ID}" \
    --arg secret "${KEYCLOAK_CLIENT_SECRET}" \
    --arg pubkey "${PUBKEY_CLEAN}" \
    '{
      "realm": $realm,
      "auth-server-url": $url,
      "resource": $client,
      "credentials": { "secret": $secret },
      "confidential-port": 0,
      "realm-public-key": $pubkey
    }' > /etc/gromox/keycloak.json

  jq --arg client "${KEYCLOAK_CLIENT_ID}" --arg fqdn "${FQDN}" \
    '(.clientId, .name) = $client |
     .description = "Client for \($client) SSO" |
     .rootUrl = "https://\($fqdn):443/" |
     .adminUrl = "https://\($fqdn):443/" |
     .baseUrl = "https://\($fqdn):443/" |
     .redirectUris = ["https://\($fqdn)/*", "https://\($fqdn)/web/*"] |
     .webOrigins = ["https://\($fqdn):443/"] |
     .attributes["post.logout.redirect.uris"] = "https://\($fqdn)/"' \
    /home/config/oidc-import.json > /etc/gromox/oidc-import.json
else
  rm -f /etc/gromox/keycloak.json /etc/gromox/oidc-import.json
fi

echo "[setup] Initial setup complete. All services configured." | tee -a "${LOGFILE}"
setup_done

exit 0

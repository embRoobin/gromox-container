#!/bin/bash
set -e

# Set up logging (for docker-entrypoint phase messages)
LOGFILE="${LOGFILE:-/var/log/grommunio-startup.log}"
mkdir -p "$(dirname "${LOGFILE}")" 2>/dev/null || true
touch "${LOGFILE}" 2>/dev/null || true

# Source environment variables
if [ -f /home/vars/var.env ]; then
  set -a
  . /home/vars/var.env
  set +a
fi

# Source helper functions
. /home/common/helpers

# Apply timezone from var.env (TIMEZONE); falls back to the image default if unset/invalid
if [ -n "${TIMEZONE}" ] && [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  echo "${TIMEZONE}" > /etc/timezone
fi

# Use persistent marker directory (survives restarts with volumes)
MARKER_DIR="/etc/gromox/.setup"
mkdir -p "${MARKER_DIR}"

# Allow forced reconfiguration via environment variable
if [ "${FORCE_RECONFIG}" = "true" ]; then
  rm -f "${MARKER_DIR}/db_done" "${MARKER_DIR}/entry_done"
fi

# Wait for database to be reachable
. /home/vars/gromox_db.env
echo "Waiting for database ${MARIADB_HOST}..."
for i in $(seq 1 30); do
  mysql -u "${MARIADB_USER}" -h "${MARIADB_HOST}" -p"${MARIADB_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1 && break
  echo "  attempt $i/30 - retrying in 2s..."
  sleep 2
done
unset MARIADB_HOST MARIADB_ROOT_PASSWORD MARIADB_DATABASE MARIADB_USER MARIADB_PASSWORD

# Run DB initialization (once)
if [ ! -f "${MARKER_DIR}/db_done" ]; then
  /home/scripts/db.sh
  touch "${MARKER_DIR}/db_done"
fi

# Regenerate admin API database configuration on every start (survives
# container recreation). This must happen before the setup entrypoint runs
# below: on first start, entrypoint.sh calls `grommunio-admin passwd`, which
# connects to the database via this file.
echo "[entrypoint] Regenerating admin API database configuration..." | tee -a "${LOGFILE}"
mkdir -p /etc/grommunio-admin-api/conf.d
. /home/vars/gromox_db.env
generate_admin_db_conf "/etc/grommunio-admin-api/conf.d/database.yaml"
unset MARIADB_HOST MARIADB_ROOT_PASSWORD MARIADB_DATABASE MARIADB_USER MARIADB_PASSWORD

# Run entrypoint configuration (once)
if [ ! -f "${MARKER_DIR}/entry_done" ]; then
  /home/setup.sh
  touch "${MARKER_DIR}/entry_done"
fi

# Ensure SSL files are owned by gromox (runs on every start, critical for Let's Encrypt renewals)
chown -R gromox:gromox /etc/grommunio-common/ssl 2>/dev/null || true

# Regenerate config.json on every start (runs on every start to ensure it's current and survives recreation)
mkdir -p /etc/grommunio-admin-common

config=$(jq -n '{mailWebAddress: "https://'"${FQDN}"'/web"}')
config=$(echo "$config" | jq '.rspamdWebAddress = "https://'"${FQDN}"':8443/antispam/"')

if [[ "${ENABLE_FILES}" = "true" ]]; then
  config=$(echo "$config" | jq '.fileWebAddress = "https://'"${FQDN}"'/files"')
fi
if [[ "${ENABLE_ARCHIVE}" = "true" ]]; then
  config=$(echo "$config" | jq '.archiveWebAddress = "https://'"${FQDN}"'/archive"')
fi

echo "$config" > /etc/grommunio-admin-common/config.json

# Regenerate postfix configuration on every start (survives container recreation)
echo "[entrypoint] Regenerating postfix configuration..." | tee -a "${LOGFILE}"
mkdir -p /etc/postfix
. /home/vars/gromox_db.env
generate_g_cf_files "/etc/postfix/grommunio-virtual-mailbox-domains.cf" "SELECT 1 FROM domains WHERE domain_status=0 AND domainname='%s'"
generate_g_cf_files "/etc/postfix/grommunio-virtual-mailbox-alias-maps.cf" "SELECT mainname FROM aliases WHERE aliasname='%s' UNION select destination FROM forwards WHERE username='%s' AND forward_type = 1"
generate_g_cf_files "/etc/postfix/grommunio-virtual-mailbox-maps.cf" "SELECT 1 FROM users WHERE username='%s'"
generate_g_cf_files "/etc/postfix/grommunio-bcc-forwards.cf" "SELECT destination FROM forwards WHERE username='%s' AND forward_type = 0"
unset MARIADB_HOST MARIADB_ROOT_PASSWORD MARIADB_DATABASE MARIADB_USER MARIADB_PASSWORD

postconf -e \
  myhostname="${FQDN}" \
  virtual_mailbox_domains="mysql:/etc/postfix/grommunio-virtual-mailbox-domains.cf" \
  virtual_mailbox_maps="mysql:/etc/postfix/grommunio-virtual-mailbox-maps.cf" \
  virtual_alias_maps="mysql:/etc/postfix/grommunio-virtual-mailbox-alias-maps.cf" \
  recipient_bcc_maps="mysql:/etc/postfix/grommunio-bcc-forwards.cf" \
  unverified_recipient_reject_code=550 \
  virtual_transport="smtp:[127.0.0.1]:24" \
  relayhost="${RELAYHOST}" \
  inet_interfaces=all \
  smtpd_helo_restrictions=permit_mynetworks,permit_sasl_authenticated,reject_invalid_hostname,reject_non_fqdn_hostname \
  smtpd_sender_restrictions=reject_non_fqdn_sender,permit_sasl_authenticated,permit_mynetworks \
  smtpd_recipient_restrictions=permit_sasl_authenticated,permit_mynetworks,reject_unknown_recipient_domain,reject_non_fqdn_hostname,reject_non_fqdn_sender,reject_non_fqdn_recipient,reject_unauth_destination,reject_unauth_pipelining \
  smtpd_data_restrictions=reject_unauth_pipelining \
  smtpd_discard_ehlo_keywords=chunking \
  smtpd_tls_security_level=may \
  smtpd_tls_auth_only=no \
  smtpd_tls_cert_file="${SSL_BUNDLE_T}" \
  smtpd_tls_key_file="${SSL_KEY_T}" \
  smtpd_tls_received_header=yes \
  smtpd_tls_session_cache_timeout=3600s \
  smtpd_use_tls=yes \
  smtpd_tls_mandatory_protocols="!SSLv2,!SSLv3,!TLSv1,!TLSv1.1" \
  smtpd_tls_protocols="!SSLv2,!SSLv3,!TLSv1,!TLSv1.1" \
  smtpd_tls_exclude_ciphers="aNULL,eNULL,EXP,MD5,RC4,DES,3DES,DHE,EDH,kDHE,kEDH,ADH" \
  smtpd_tls_eecdh_grade=strong \
  tls_preempt_cipherlist=yes \
  tls_random_source=dev:/dev/urandom \
  smtpd_sasl_auth_enable=yes \
  broken_sasl_auth_clients=yes \
  smtpd_sasl_security_options=noanonymous \
  smtpd_sasl_local_domain= \
  smtpd_milters=inet:localhost:11332 \
  milter_default_action=accept \
  smtp_tls_security_level=may \
  smtp_use_tls=yes \
  milter_protocol=6

postconf -M tlsmgr/unix="tlsmgr unix - - n 1000? 1 tlsmgr"
postconf -M submission/inet="submission inet n - n - - smtpd"
postconf -P submission/inet/syslog_name="postfix/submission"
postconf -P submission/inet/smtpd_tls_security_level=encrypt
postconf -P submission/inet/smtpd_tls_mandatory_protocols="!SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
postconf -P submission/inet/smtpd_tls_protocols="!SSLv2,!SSLv3,!TLSv1,!TLSv1.1"
postconf -P submission/inet/smtpd_tls_exclude_ciphers="aNULL,eNULL,EXP,MD5,RC4,DES,3DES,DHE,EDH,kDHE,kEDH,ADH"
postconf -P submission/inet/smtpd_tls_eecdh_grade=strong
postconf -P submission/inet/smtpd_sasl_auth_enable=yes
postconf -P submission/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject
postconf -P submission/inet/milter_macro_daemon_name=ORIGINATING

postmap lmdb:/etc/postfix/relay 2>/dev/null || true
postmap lmdb:/etc/postfix/relay_recipients 2>/dev/null || true

# Archive-specific postfix configuration (regenerates if ENABLE_ARCHIVE changes)
if [[ "${ENABLE_ARCHIVE}" = "true" ]]; then
  echo "/(.*)/   prepend X-Envelope-To: \$1" > /etc/postfix/grommunio-archiver-envelope.cf
  postconf -e "smtpd_recipient_restrictions=permit_sasl_authenticated,permit_mynetworks,check_recipient_access pcre:/etc/postfix/grommunio-archiver-envelope.cf,reject_unknown_recipient_domain,reject_non_fqdn_hostname,reject_non_fqdn_sender,reject_non_fqdn_recipient,reject_unauth_destination,reject_unauth_pipelining"
  postconf -e "always_bcc=archive@${FQDN}"
  echo "archive@${FQDN} smtp:[gromox-archive]:2693" > /etc/postfix/transport
  postmap /etc/postfix/transport 2>/dev/null || true
else
  rm -f /etc/postfix/grommunio-archiver-envelope.cf /etc/postfix/transport /etc/postfix/transport.lmdb
fi

# Regenerate nginx location configurations on every start (survives container recreation)
echo "[entrypoint] Regenerating nginx location and upstream configurations..." | tee -a "${LOGFILE}"
mkdir -p /usr/share/grommunio-common/nginx/locations.d
mkdir -p /usr/share/grommunio-common/nginx/upstreams.d

# Files location (regenerates if ENABLE_FILES changes)
if [[ "${ENABLE_FILES}" = "true" ]]; then
  cat > /usr/share/grommunio-common/nginx/locations.d/grommunio-files.conf <<EOF
location ^~ /files {
	proxy_pass https://${OFFICE_HOST}:8443/files;
	proxy_request_buffering off;
	proxy_buffering off;
	error_log /var/log/nginx/nginx-files-error.log;
	access_log /var/log/nginx/nginx-files-access.log;
}
EOF
else
  rm -f /usr/share/grommunio-common/nginx/locations.d/grommunio-files.conf
fi

# Office location (regenerates if ENABLE_OFFICE changes)
if [[ "${ENABLE_OFFICE}" = "true" ]]; then
  cat > /usr/share/grommunio-common/nginx/locations.d/grommunio-office.conf <<EOF
location  /cache/ {
  rewrite /cache/(.*)$ /office/cache/\$1;
}
location  /office/ {
  proxy_pass         https://${OFFICE_HOST}:8443/office/;
  proxy_http_version 1.1;
  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection \$proxy_connection;
  proxy_set_header X-Forwarded-Host \$the_host/office;
  proxy_set_header X-Forwarded-Proto \$the_scheme;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  access_log /var/log/nginx/nginx-office-access.log;
  error_log /var/log/nginx/nginx-office-error.log;
}
EOF
else
  rm -f /usr/share/grommunio-common/nginx/locations.d/grommunio-office.conf
fi

# Archive upstream (regenerates if ENABLE_ARCHIVE changes)
if [[ "${ENABLE_ARCHIVE}" = "true" ]]; then
  cat > /usr/share/grommunio-common/nginx/upstreams.d/grommunio-archive.conf <<EOF
upstream gromox-archive {
	server ${ARCHIVE_HOST}:8443;
}
EOF

  # configuration file /usr/share/grommunio-common/nginx/locations.d/grommunio-archive.conf:
  cat > /usr/share/grommunio-common/nginx/locations.d/grommunio-archive.conf <<EOF
location /archive {
	proxy_pass https://${ARCHIVE_HOST}/archive;
	proxy_request_buffering off;
	proxy_buffering off;
	error_log /var/log/nginx/nginx-archive-error.log;
	access_log /var/log/nginx/nginx-archive-access.log;
}

location ~* ^/archive/(qr|js|sso|index).php {
	proxy_pass https://${ARCHIVE_HOST};
	proxy_request_buffering off;
	proxy_buffering off;
	error_log /var/log/nginx/nginx-archive-error.log;
	access_log /var/log/nginx/nginx-archive-access.log;
}

location ~* ^/archive/(.+\.php)(/|$)$ {
        rewrite /archive/search.php /archive/index.php?route=search/search&type=simple;
        rewrite /archive/advanced.php /archive/index.php?route=search/search&type=advanced;
        rewrite /archive/expert.php /archive/index.php?route=search/search&type=expert;
        rewrite /archive/search-helper.php /archive/index.php?route=search/helper;
        rewrite /archive/audit-helper.php /archive/index.php?route=audit/helper;
        rewrite /archive/message.php /archive/index.php?route=message/view;
        rewrite /archive/bulkrestore.php /archive/index.php?route=message/bulkrestore;
        rewrite /archive/bulkremove.php /archive/index.php?route=message/bulkremove;
        rewrite /archive/rejectremove.php /archive/index.php?route=message/rejectremove;
        rewrite /archive/bulkpdf.php /archive/index.php?route=message/bulkpdf;
        rewrite /archive/folders.php /archive/index.php?route=folder/list&;
        rewrite /archive/settings.php /archive/index.php?route=user/settings;
        rewrite /archive/login.php /archive/index.php?route=login/login;
        rewrite /archive/logout.php /archive/index.php?route=login/logout;
        rewrite /archive/google.php /archive/index.php?route=login/google;
        rewrite /archive/domain.php /archive/index.php?route=domain/domain;
        rewrite /archive/ldap.php /archive/index.php?route=ldap/list;
        rewrite /archive/customer.php /archive/index.php?route=customer/list;
        rewrite /archive/retention.php /archive/index.php?route=policy/retention;
        rewrite /archive/archiving.php /archive/index.php?route=policy/archiving;
        rewrite /archive/legalhold.php /archive/index.php?route=policy/legalhold;
}

location ~* /archive/view/javascript/piler.js$ {
        rewrite /archive/view/javascript/piler.js /archive/js.php;
}

location ^~ /view {
	proxy_pass https://${ARCHIVE_HOST};
	proxy_request_buffering off;
	proxy_buffering off;
	error_log /var/log/nginx/nginx-archive-error.log;
	access_log /var/log/nginx/nginx-archive-access.log;
}
EOF
  jq '.archiveWebAddress |= "https://'${FQDN}'/archive"' /tmp/config.json > /tmp/config-new.json
  mv /tmp/config-new.json /tmp/config.json
else
  rm -f /usr/share/grommunio-common/nginx/locations.d/grommunio-archive.conf
  rm -f /usr/share/grommunio-common/nginx/upstreams.d/grommunio-archive.conf
fi

# ── Port remapping ─────────────────────────────────────────────────
# Remap nginx to listen on high ports (>1024) so no privileges needed.
# The actual listen directives are in the included files under /usr/share/.

# Grommunio web: 80 -> 8080, 443 -> 8443
# Handle both "listen 80" and "listen [::]:80" formats
for f in /usr/share/grommunio-common/nginx.conf /etc/nginx/nginx.conf; do
  [ -f "$f" ] || continue
  sed -i 's/\blisten\s\+80\b/listen 8080/g; s/\blisten\s\+\[::]\:80\b/listen [::]:8080/g' "$f"
  sed -i 's/\blisten\s\+443\b/listen 8443/g; s/\blisten\s\+\[::]\:443\b/listen [::]:8443/g' "$f"
done

# Admin HTTP: 8080 -> 9080 (avoid conflict with remapped web port)
sed -i 's/\blisten\s\+8080\b/listen 9080/g; s/\blisten\s\+\[::]\:8080\b/listen [::]:9080/g' \
  /usr/share/grommunio-admin-common/nginx.conf

# Admin HTTPS: 8443 -> 9443
sed -i 's/\blisten\s\+8443\b/listen 9443/g; s/\blisten\s\+\[::]\:8443\b/listen [::]:9443/g' \
  /usr/share/grommunio-admin-common/nginx-ssl.conf

# Remap postfix to listen on high ports
postconf -e "smtp_bind_address=" || true
if [ -f /etc/postfix/master.cf ]; then
  # smtp (25->2525), submission (587->2587), smtps (465->2465)
  sed -i 's/^smtp\(\s\+\)inet/2525\1inet/' /etc/postfix/master.cf
  sed -i 's/^submission\(\s\+\)inet/2587\1inet/' /etc/postfix/master.cf
  sed -i 's/^smtps\(\s\+\)inet/2465\1inet/' /etc/postfix/master.cf
fi

# Remap gromox imap/pop3 ports
if [ -f /etc/gromox/imap.cfg ]; then
  sed -i 's/^listen_ssl_port\s*=\s*993/listen_ssl_port=2993/' /etc/gromox/imap.cfg
  sed -i 's/^listen_port\s*=\s*143/listen_port=2143/' /etc/gromox/imap.cfg
fi
if [ -f /etc/gromox/pop3.cfg ]; then
  sed -i 's/^listen_ssl_port\s*=\s*995/listen_ssl_port=2995/' /etc/gromox/pop3.cfg
  sed -i 's/^listen_port\s*=\s*110/listen_port=2110/' /etc/gromox/pop3.cfg
fi

# ── Conditional services ──────────────────────────────────────────

# Enable grommunio-chat if configured (check for chat config file existence)
if [ -f "${CHAT_CONFIG}" ] && [ -f /etc/supervisor.d/grommunio-chat.conf ]; then
  sed -i 's/autostart=false/autostart=true/' /etc/supervisor.d/grommunio-chat.conf
fi

# Set up certbot renewal if Let's Encrypt is enabled
if [ "${SSL_INSTALL_TYPE}" = "2" ]; then
  # On an actual renewal, rebuild the concatenated bundle that nginx and the
  # gromox http/imap/pop3 daemons read (certbot only refreshes the files under
  # /etc/letsencrypt/live, not this bundle) and restart the TLS services.
  # $RENEWED_LINEAGE is set by certbot to the renewed cert's live directory.
  cat > /usr/local/bin/grommunio-cert-deploy <<'DEPLOY'
#!/bin/bash
[ -n "${RENEWED_LINEAGE}" ] || exit 0
cat "${RENEWED_LINEAGE}/cert.pem" "${RENEWED_LINEAGE}/fullchain.pem" > /etc/grommunio-common/ssl/server-bundle.pem
cp -f "${RENEWED_LINEAGE}/privkey.pem" /etc/grommunio-common/ssl/server.key
chown gromox:gromox /etc/grommunio-common/ssl/* 2>/dev/null || true
supervisorctl restart gromox-http gromox-imap gromox-pop3 2>/dev/null || true
DEPLOY
  chmod +x /usr/local/bin/grommunio-cert-deploy

  # Renew on the published HTTP port (host :80 -> container :8080). nginx owns
  # 8080, so free it only while a renewal actually runs: the pre/post hooks
  # fire only when at least one certificate is due.
  echo "0 */12 * * * root certbot renew --quiet --standalone --http-01-port 8080 --pre-hook 'supervisorctl stop nginx' --deploy-hook /usr/local/bin/grommunio-cert-deploy --post-hook 'supervisorctl start nginx'" > /etc/cron.d/certbot-renew
fi

echo "[entrypoint] All configurations regenerated. Starting supervisord..." | tee -a "${LOGFILE}"
exec /usr/local/bin/supervisord -n -c /etc/supervisord.conf

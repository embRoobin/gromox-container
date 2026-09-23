# Container image with openSUSE Leap + supervisord
#
# Description:
#
# This image runs grommunio-core services using supervisord as PID 1,
# eliminating the need for systemd, privileged mode, and sysbox runtime.

FROM opensuse/leap:16.0

ARG GROMMUNIO_REPO=openSUSE_Leap_16.0

RUN zypper -n install -y \
        iptables   \
        iproute2    \
        kmod       \
        curl    \
        patterns-base-apparmor \
        patterns-base-base \
        procps  \
        sudo       \
        cronie     \
        bind-utils \
        timezone   \
        nano       \
        lsof

# Default timezone — can be overridden at runtime via the TIMEZONE env var in var.env
RUN ln -sf /usr/share/zoneinfo/Europe/Vienna /etc/localtime && \
    echo "Europe/Vienna" > /etc/timezone

RUN	curl https://download.grommunio.com/RPM-GPG-KEY-grommunio > gr.key && \
	  rpm --import gr.key && \
	  zypper --non-interactive --quiet ar -C https://download.grommunio.com/community/${GROMMUNIO_REPO} grommunio && \
	  zypper --gpg-auto-import-keys ref && \
	  zypper -n refresh grommunio

# Install grommunio packages (retry up to 3 times for transient download errors)
RUN    zypper --non-interactive install -y vim mysql nginx \
         gromox grommunio-admin-api grommunio-admin-web grommunio-antispam \
         grommunio-common grommunio-web grommunio-sync grommunio-dav postfix postfix-mysql \
         grommunio-chat grommunio-keycloak grommunio-auth cyrus-sasl-saslauthd cyrus-sasl-plain jq redis \
       || { echo "Retry 1..."; zypper clean -a; sleep 5; \
            zypper --non-interactive install -y vim mysql nginx \
              gromox grommunio-admin-api grommunio-admin-web grommunio-antispam \
              grommunio-common grommunio-web grommunio-sync grommunio-dav postfix postfix-mysql \
              grommunio-chat grommunio-keycloak grommunio-auth cyrus-sasl-saslauthd cyrus-sasl-plain jq redis; } \
       || { echo "Retry 2..."; zypper clean -a; sleep 10; \
            zypper --non-interactive install -y vim mysql nginx \
              gromox grommunio-admin-api grommunio-admin-web grommunio-antispam \
              grommunio-common grommunio-web grommunio-sync grommunio-dav postfix postfix-mysql \
              grommunio-chat grommunio-keycloak grommunio-auth cyrus-sasl-saslauthd cyrus-sasl-plain jq redis; }

# Install Certbot from openSUSE 16 packages + iconv modules (iso-2022-jp etc.)
RUN    zypper -n install -y python313-certbot python313-certbot-nginx glibc-gconv-modules-extra

# Install supervisord (Python 3.13 is the system default on openSUSE Leap 16)
RUN zypper -n install -y python313-pip && \
    pip3.13 install --no-cache-dir supervisor

# Create default user if needed
RUN    groupadd 'wheel' &&                         \
    useradd -m -s /bin/bash -G wheel admin && echo "admin:admin" | chpasswd

# Create required socket dirs
# Grant access to all users to access them
RUN mkdir /run/gromox
RUN mkdir /run/grommunio
RUN mkdir /run/php-fpm
RUN chmod a+rw -R /run

RUN if [ -d /etc/php8 ]; then \
    if [ -e /etc/php8/fpm/php-fpm.conf.default ]; then \
      mv /etc/php8/fpm/php-fpm.conf.default /etc/php8/fpm/php-fpm.conf; \
    fi; \
    cp -f /usr/share/gromox/fpm-gromox.conf.sample /etc/php8/fpm/php-fpm.d/gromox.conf; \
  elif [ -d /etc/php7 ]; then \
    if [ -e /etc/php7/fpm/php-fpm.conf.default ]; then \
      mv /etc/php7/fpm/php-fpm.conf.default /etc/php7/fpm/php-fpm.conf; \
    fi; \
    cp -f /usr/share/gromox/fpm-gromox.conf.sample /etc/php7/fpm/php-fpm.d/gromox.conf; \
  fi

COPY gromox-core/scripts /home/scripts
COPY gromox-core/common /home/common
COPY gromox-core/config /home/config

RUN chmod +x /home/scripts/db.sh

COPY gromox-core/config/smtp /etc/pam.d/smtp

RUN mkdir -p /var/lib/grommunio-dav /var/lib/gromox/user && \
    chown grodav:grodav /var/lib/grommunio-dav && \
    chown -R gromox:gromox /var/lib/gromox/user && \
    chmod -R 0770 /var/lib/gromox/user

COPY gromox-core/config/certificate.conf /etc/grommunio-common/nginx/ssl_certificate.conf
RUN ln -sf /etc/grommunio-common/nginx/ssl_certificate.conf /etc/grommunio-admin-common/nginx-ssl.conf

COPY gromox-core/entrypoint.sh /home/entrypoint.sh
RUN chmod +x /home/entrypoint.sh

COPY gromox-core/docker-entrypoint.sh /home/docker-entrypoint.sh
RUN chmod +x /home/docker-entrypoint.sh

COPY gromox-core/supervisord.conf /etc/supervisord.conf
COPY gromox-core/supervisor.d /etc/supervisor.d

ENTRYPOINT ["/home/docker-entrypoint.sh"]

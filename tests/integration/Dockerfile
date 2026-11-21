# AlmaLinux 9 + systemd test host for CECP Panel integration tests.
# Packages mirror install.sh so the in-container install is fast and repeatable.
FROM almalinux/9-init

# Optional extra CA for builds behind a TLS-intercepting egress proxy (run.sh IT_CA_FILE).
RUN --mount=type=secret,id=it_ca if [ -s /run/secrets/it_ca ]; then \
      cp /run/secrets/it_ca /etc/pki/ca-trust/source/anchors/it-proxy.pem && update-ca-trust; fi
# An HTTPS-only proxy cannot reach the plain-http mirrors a mirrorlist hands out: use the
# https origin repos instead (only when run.sh passes IT_HTTPS_PROXY).
RUN if [ -n "${https_proxy:-}" ]; then sed -i -e 's/^mirrorlist=/#mirrorlist=/' \
      -e 's|^# baseurl=https://repo.almalinux.org|baseurl=https://repo.almalinux.org|' /etc/yum.repos.d/almalinux*.repo; fi

RUN dnf -y install epel-release \
 && if [ -n "${https_proxy:-}" ]; then sed -i -e 's/^metalink=/#metalink=/' \
      -e 's|^#baseurl=https\?://download.example/pub/epel|baseurl=https://dl.fedoraproject.org/pub/epel|' /etc/yum.repos.d/epel*.repo; fi \
 && dnf -y install nginx mariadb-server mariadb fail2ban firewalld \
      python3 python3-pip wget tar unzip policycoreutils-python-utils \
      php php-fpm php-mysqlnd php-cli php-gd php-xml php-mbstring php-json php-opcache \
      certbot python3-certbot-nginx restic rclone \
      openssh-server sudo cronie procps-ng which redis rsync \
 && dnf clean all

RUN curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
 && chmod +x /usr/local/bin/wp \
 && systemctl enable sshd crond

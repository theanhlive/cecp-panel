# AlmaLinux 9 + systemd test host for CECP Panel integration tests.
# Packages mirror install.sh so the in-container install is fast and repeatable.
FROM almalinux/9-init

RUN dnf -y install epel-release \
 && dnf -y install nginx mariadb-server mariadb fail2ban firewalld \
      python3 python3-pip wget tar unzip policycoreutils-python-utils \
      php php-fpm php-mysqlnd php-cli php-gd php-xml php-mbstring php-json php-opcache \
      certbot python3-certbot-nginx restic rclone \
      openssh-server sudo cronie procps-ng which redis rsync \
 && dnf clean all

RUN curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
 && chmod +x /usr/local/bin/wp \
 && systemctl enable sshd crond

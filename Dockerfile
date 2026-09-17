# syntax=docker/dockerfile:1
FROM ubuntu:26.04

LABEL org.opencontainers.image.authors="David Tannenbaum <david@celerihealth.com>"

# The application first uses the 8.3 bridge; 8.5 is the final platform target.
ARG PHP_VERSION=8.5
ARG NODE_VERSION=24.21.0
ARG COMPOSER_VERSION=2.10.3
ARG PUPPETEER_VERSION=25.11.0
ARG CHROME_VERSION=153.0.8010.36
ARG HIGHCHARTS_EXPORT_SERVER_VERSION=6.0.0
ARG HIGHCHARTS_VERSION=13.0.0
ARG TARGETARCH

ENV APP_NAME=celeri \
    APP_EMAIL=david@celerihealth.com \
    APP_DOMAIN=celerihealth.com \
    APP_PATH=/var/www/html/app \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=UTC \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome \
    BROWSERSHOT_CHROME=/usr/bin/google-chrome \
    HIGHCHARTS_USE_NPM=true \
    ACCEPT_HIGHCHARTS_LICENSE=yes

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Chrome for Testing publishes a Linux amd64 build. Fail early on other targets.
RUN test "${TARGETARCH}" = amd64 && \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && \
    chmod +x /usr/sbin/policy-rc.d && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        acl awscli build-essential ca-certificates cron curl dos2unix fontconfig \
        fonts-liberation fonts-noto-color-emoji git gnupg locales \
        nginx poppler-utils procps python3 redis-server s3cmd sqlite3 supervisor \
        tzdata unzip wget xz-utils \
        libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
        libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 \
        libgtk-3-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 \
        libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 && \
    locale-gen en_US.UTF-8 && \
    ln -snf /usr/share/zoneinfo/UTC /etc/localtime && \
    rm -rf /var/lib/apt/lists/*

# Signed Sury repository for Ubuntu Resolute (including packaged PECL IMAP for 8.5).
RUN curl -fsSLo /tmp/debsuryorg-archive-keyring.deb \
        https://packages.sury.org/debsuryorg-archive-keyring.deb && \
    dpkg -i /tmp/debsuryorg-archive-keyring.deb && \
    rm /tmp/debsuryorg-archive-keyring.deb && \
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ resolute main' \
        > /etc/apt/sources.list.d/php.list && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-common \
        php${PHP_VERSION}-apcu php${PHP_VERSION}-bcmath php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd php${PHP_VERSION}-imap php${PHP_VERSION}-intl \
        php${PHP_VERSION}-mbstring php${PHP_VERSION}-mysql php${PHP_VERSION}-pgsql \
        php${PHP_VERSION}-readline php${PHP_VERSION}-redis php${PHP_VERSION}-soap \
        php${PHP_VERSION}-sqlite3 php${PHP_VERSION}-xml php${PHP_VERSION}-zip && \
    update-alternatives --set php /usr/bin/php${PHP_VERSION} && \
    update-alternatives --set phar /usr/bin/phar${PHP_VERSION} && \
    update-alternatives --set phar.phar /usr/bin/phar.phar${PHP_VERSION} && \
    ln -s /usr/sbin/php-fpm${PHP_VERSION} /usr/local/sbin/celeri-php-fpm && \
    rm -rf /var/lib/apt/lists/*

# Shared policy for CLI and FPM; never print diagnostics into HTTP/PDF output.
RUN printf '%s\n' \
        'error_reporting = E_ALL' 'display_errors = Off' 'display_startup_errors = Off' \
        'log_errors = On' 'date.timezone = UTC' 'variables_order = "EGPCS"' \
        'cgi.fix_pathinfo = 0' 'upload_max_filesize = 100M' 'post_max_size = 100M' \
        'memory_limit = 512M' 'opcache.enable = 1' 'opcache.enable_cli = 1' \
        'opcache.max_accelerated_files = 4000' 'opcache.memory_consumption = 128' \
        'opcache.revalidate_freq = 240' \
        > /etc/php/${PHP_VERSION}/mods-available/celeri.ini && \
    phpenmod -v ${PHP_VERSION} celeri && \
    printf '%s\n' 'max_execution_time = 300' > /etc/php/${PHP_VERSION}/fpm/conf.d/99-celeri-fpm.ini && \
    printf '%s\n' '[www]' 'listen = /run/php/celeri-fpm.sock' \
        'listen.owner = www-data' 'listen.group = www-data' 'listen.mode = 0660' \
        'clear_env = no' 'catch_workers_output = yes' 'pm.max_children = 75' \
        'pm.start_servers = 15' 'pm.min_spare_servers = 10' 'pm.max_spare_servers = 25' \
        'pm.max_requests = 200' > /etc/php/${PHP_VERSION}/fpm/pool.d/zz-celeri.conf && \
    mkdir -p /run/php /var/log/supervisor /var/cache/nginx ${APP_PATH} && \
    chown www-data:www-data /run/php /var/www/html

# Fixed Node LTS release, checked against the upstream release checksums.
RUN curl -fsSLo /tmp/node.tar.xz https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz && \
    curl -fsSLo /tmp/node-SHASUMS256.txt https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt && \
    awk -v archive="node-v${NODE_VERSION}-linux-x64.tar.xz" '$2 == archive {print $1 "  /tmp/node.tar.xz"}' \
        /tmp/node-SHASUMS256.txt | sha256sum --check --strict - && \
    python3 -c 'import os, shutil, tarfile; tarfile.open("/tmp/node.tar.xz").extractall("/tmp/node", filter="data"); shutil.copytree("/tmp/node/" + os.listdir("/tmp/node")[0], "/usr/local", symlinks=True, dirs_exist_ok=True)' && \
    ln -s /usr/local/bin/node /usr/bin/node && \
    ln -s /usr/local/bin/npm /usr/bin/npm && \
    rm -rf /tmp/node /tmp/node.tar.xz /tmp/node-SHASUMS256.txt

# Exact Composer release, validated with its published SHA-256 checksum.
RUN curl -fsSLo /usr/local/bin/composer https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar && \
    curl -fsSLo /tmp/composer.sha256sum https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar.sha256sum && \
    awk '{print $1 "  /usr/local/bin/composer"}' /tmp/composer.sha256sum | sha256sum --check --strict - && \
    chmod +x /usr/local/bin/composer && rm /tmp/composer.sha256sum

# Matching Chrome for Testing/Puppeteer versions; a shared executable avoids
# hidden browser downloads under root's home or the application's node_modules.
RUN curl -fsSLo /tmp/chrome.zip \
        https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chrome-linux64.zip && \
    unzip -q /tmp/chrome.zip -d /opt && \
    ln -s /opt/chrome-linux64/chrome /usr/bin/google-chrome && \
    ln -s /usr/bin/google-chrome /usr/bin/google-chrome-stable && \
    rm /tmp/chrome.zip && \
    npm install --global --prefix /usr \
        puppeteer@${PUPPETEER_VERSION} \
        highcharts-export-server@${HIGHCHARTS_EXPORT_SERVER_VERSION} && \
    npm install --prefix /usr/lib/node_modules/highcharts-export-server --omit=dev \
        --save-exact highcharts@${HIGHCHARTS_VERSION} puppeteer@${PUPPETEER_VERSION} && \
    npm cache clean --force

# Runtime configuration replaces the old sed patch inside the npm package.
# The exporter is only used by the app over loopback; never expose port 7801.
RUN printf '%s\n' \
    '{"puppeteer":{"args":["--no-sandbox","--disable-setuid-sandbox","--disable-dev-shm-usage"]},"highcharts":{"useNpm":true,"customScripts":[]},"server":{"host":"127.0.0.1"},"other":{"browserShellMode":false}}' \
    > /etc/highcharts-export-server.json

COPY .bash_aliases /root/.bash_aliases
COPY homestead /etc/nginx/sites-available/homestead
COPY fastcgi_params /etc/nginx/fastcgi_params
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY fonts/ /usr/local/share/fonts/celeri/

RUN rm -f /etc/nginx/sites-enabled/default && \
    ln -s /etc/nginx/sites-available/homestead /etc/nginx/sites-enabled/homestead && \
    sed -i 's/keepalive_timeout 65;/keepalive_timeout 2;/' /etc/nginx/nginx.conf && \
    fc-cache -f && \
    php -r '$required = ["apcu", "bcmath", "curl", "gd", "imap", "intl", "mbstring", "mysqli", "pdo_mysql", "pdo_pgsql", "pdo_sqlite", "redis", "soap", "xml", "zip", "Zend OPcache"]; foreach ($required as $extension) { if (!extension_loaded($extension)) { fwrite(STDERR, "Missing extension: $extension\n"); exit(1); } } if (ini_get("display_errors")) { exit(1); }' && \
    celeri-php-fpm --test && nginx -t && \
    node --version && composer --version && google-chrome --version

WORKDIR ${APP_PATH}
VOLUME ["/var/cache/nginx", "/var/log/nginx", "/var/log/supervisor"]
EXPOSE 80 443

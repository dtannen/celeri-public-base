FROM ubuntu:20.04
MAINTAINER David Tannenbaum <david@celerihealth.com>

# set some environment variables
ENV APP_NAME celeri
ENV APP_EMAIL david@celerihealth.com
ENV APP_DOMAIN celerihealth.com
ENV APP_PATH /var/www/html/app
ENV DEBIAN_FRONTEND noninteractive

# upgrade the container
RUN apt-get update && \
    apt-get upgrade -y

# install some prerequisites
RUN apt-get install -y software-properties-common curl build-essential \
    dos2unix gcc git libmcrypt4 libpcre3-dev memcached make \
    python3-pip re2c unattended-upgrades whois vim libnotify-bin nano wget \
    debconf-utils libmcrypt-dev libreadline-dev awscli poppler-utils

RUN apt-get install -y openssl build-essential xorg libssl-dev

# RUN wget -O- -q http://s3tools.org/repo/deb-all/stable/s3tools.key | apt-key add -
# RUN wget -O/etc/apt/sources.list.d/s3tools.list http://s3tools.org/repo/deb-all/stable/s3tools.list
RUN apt-get install apt-transport-https
RUN apt-get update && apt-get install -y s3cmd

RUN apt-get update
RUN apt-get install software-properties-common -y
RUN apt-get install -y language-pack-en-base
RUN LC_ALL=en_US.UTF-8 add-apt-repository ppa:ondrej/php -y
RUN LC_ALL=en_US.UTF-8 apt-add-repository ppa:chris-lea/redis-server -y
# add some repositories
RUN curl --silent --location https://deb.nodesource.com/setup_16.x | bash -

# set the locale
RUN echo "LC_ALL=en_US.UTF-8" >> /etc/default/locale  && \
    locale-gen en_US.UTF-8  && \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# setup bash
COPY .bash_aliases /root

# install nginx
RUN apt-get install -y --force-yes nginx
COPY homestead /etc/nginx/sites-available/
RUN rm -rf /etc/nginx/sites-available/default && \
    rm -rf /etc/nginx/sites-enabled/default && \
    ln -fs "/etc/nginx/sites-available/homestead" "/etc/nginx/sites-enabled/homestead" && \
    sed -i -e"s/keepalive_timeout\s*65/keepalive_timeout 2/" /etc/nginx/nginx.conf && \
    sed -i -e"s/keepalive_timeout 2/keepalive_timeout 2;\n\tclient_max_body_size 100m/" /etc/nginx/nginx.conf && \
    echo "daemon off;" >> /etc/nginx/nginx.conf && \
    usermod -u 1000 www-data && \
    chown -Rf www-data.www-data /var/www/html/ && \
    sed -i -e"s/worker_processes  1/worker_processes 5/" /etc/nginx/nginx.conf
VOLUME ["/var/cache/nginx"]
VOLUME ["/var/log/nginx"]

# install php
RUN apt-get update
RUN apt-get install -y php8.2-fpm php8.2-cli php8.2-dev php8.2-pgsql php8.2-sqlite3 php8.2-gd \
    php8.2-apcu php8.2-curl php8.2-imap php8.2-mysql php8.2-readline php8.2-common \
    php8.2-mbstring php-xml php8.2-zip php8.2-soap
RUN sed -i "s/error_reporting = .*/error_reporting = E_ALL/" /etc/php/8.2/cli/php.ini && \
    sed -i "s/display_errors = .*/display_errors = On/" /etc/php/8.2/cli/php.ini && \
    sed -i "s/variables_order = .*/variables_order = \"EGPCS\"/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/;date.timezone.*/date.timezone = UTC/" /etc/php/8.2/cli/php.ini && \
    sed -i "s/error_reporting = .*/error_reporting = E_ALL/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/display_errors = .*/display_errors = On/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = 100M/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/post_max_size = .*/post_max_size = 100M/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/max_execution_time = .*/max_execution_time = 60/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/memory_limit = .*/memory_limit = 512M/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/;opcache.enable=0*/opcache.enable=1/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/;opcache.enable_cli=0*/opcache.enable_cli=1/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/;opcache.max_accelerated_files=2000*/opcache.max_accelerated_files=4000/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/;opcache.memory_consumption=64*/opcache.memory_consumption=128/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/;opcache.revalidate_freq=2*/opcache.revalidate_freq=240/" /etc/php/8.2/fpm/php.ini && \
    sed -i "s/;date.timezone.*/date.timezone = UTC/" /etc/php/8.2/fpm/php.ini && \
    sed -i -e "s/;daemonize\s*=\s*yes/daemonize = no/g" /etc/php/8.2/fpm/php-fpm.conf && \
    sed -i -e "s/;catch_workers_output\s*=\s*yes/catch_workers_output = yes/g" /etc/php/8.2/fpm/pool.d/www.conf && \
    sed -i -e "s/pm.max_children = 5/pm.max_children = 9/g" /etc/php/8.2/fpm/pool.d/www.conf && \
    sed -i -e "s/pm.start_servers = 2/pm.start_servers = 3/g" /etc/php/8.2/fpm/pool.d/www.conf && \
    sed -i -e "s/pm.min_spare_servers = 1/pm.min_spare_servers = 2/g" /etc/php/8.2/fpm/pool.d/www.conf && \
    sed -i -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 4/g" /etc/php/8.2/fpm/pool.d/www.conf && \
    sed -i -e "s/pm.max_requests = 500/pm.max_requests = 200/g" /etc/php/8.2/fpm/pool.d/www.conf && \
    sed -i -e "s/;listen.mode = 0660/listen.mode = 0750/g" /etc/php/8.2/fpm/pool.d/www.conf && \
    find /etc/php/8.2/cli/conf.d/ -name "*.ini" -exec sed -i -re 's/^(\s*)#(.*)/\1;\2/g' {} \;
COPY fastcgi_params /etc/nginx/
RUN apt-get install -y php-pear php-xml
RUN yes '' | pecl install -f mcrypt-1.0.5
RUN bash -c "echo extension=/usr/lib/php/20220829/mcrypt.so > /etc/php/8.2/cli/conf.d/mcrypt.ini"
RUN bash -c "echo memory_limit = 512M >> /etc/php/8.2/fpm/conf.d/file_size.ini"
RUN bash -c "echo upload_max_filesize = 100M >> /etc/php/8.2/fpm/conf.d/file_size.ini"
RUN bash -c "echo post_max_size = 100M >> /etc/php/8.2/fpm/conf.d/file_size.ini"
RUN bash -c "echo max_execution_time = 300 >> /etc/php/8.2/fpm/conf.d/file_size.ini"
RUN bash -c "echo opcache.enable=1 >> /etc/php/8.2/fpm/conf.d/file_size.ini"
RUN bash -c "echo env[AWS_BUCKET] = '\$AWS_VAPOR_BUCKET' >> /etc/php/8.2/fpm/php-fpm.conf"
RUN bash -c "echo env[AWS_DEFAULT_REGION] = '\$AWS_DEFAULT_REGION' >> /etc/php/8.2/fpm/php-fpm.conf"
RUN bash -c "echo env[AWS_ACCESS_KEY_ID] = '\$AWS_ACCESS_KEY_ID' >> /etc/php/8.2/fpm/php-fpm.conf"
RUN bash -c "echo env[AWS_SECRET_ACCESS_KEY] = '\$AWS_SECRET_ACCESS_KEY' >> /etc/php/8.2/fpm/php-fpm.conf"
RUN phpenmod mcrypt && \
    mkdir -p /run/php/ && chown -Rf www-data.www-data /run/php

# install php-bcmath
RUN apt-get update && \
    apt-get install -y php-bcmath

# install sqlite
RUN apt-get install -y sqlite3 libsqlite3-dev

# install mysql
RUN echo mysql-server mysql-server/root_password password $DB_PASS | debconf-set-selections;\
    echo mysql-server mysql-server/root_password_again password $DB_PASS | debconf-set-selections;\
    apt-get install -y mysql-server && \
    echo "default_password_lifetime = 0" >> /etc/mysql/mysql.conf.d/mysqld.cnf && \
    sed -i '/^bind-address/s/bind-address.*=.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
RUN echo "mysql -e 'GRANT ALL ON *.* TO root@\"0.0.0.0\" IDENTIFIED BY \"secret\" WITH GRANT OPTION; GRANT ALL ON *.* TO \"homestead\"@\"%\" IDENTIFIED BY \"secret\" WITH GRANT OPTION; FLUSH PRIVILEGES;'" >> /tmp/config && \
    echo "mysql -e 'GRANT ALL ON *.* TO \"pinion\"@\"%\" IDENTIFIED BY \"complex-password\"; FLUSH PRIVILEGES;'" >> /tmp/config && \
    echo "mysql -e 'CREATE DATABASE homestead;'" >> /tmp/config
RUN mkdir -p /var/run/mysqld
RUN chown mysql:mysql /var/run/mysqld
VOLUME ["/var/lib/mysql"]

# install composer
RUN curl -sS https://getcomposer.org/installer | php && \
    mv composer.phar /usr/local/bin/composer && \
    printf "\nPATH=\"~/.composer/vendor/bin:\$PATH\"\n" | tee -a ~/.bashrc

# install laravel envoy
RUN composer global require "laravel/envoy"

#install laravel installer
RUN composer global require "laravel/installer"

# install nodejs
# RUN curl -sL https://deb.nodesource.com/setup_12.x | bash -
RUN apt-get install -y nodejs
# RUN npm install sass

# install gulp
RUN /usr/bin/npm install -g gulp

# install bower
RUN /usr/bin/npm install -g bower

# install redis
RUN apt-get install -y redis-server

# install supervisor
RUN apt-get install -y supervisor && \
    mkdir -p /var/log/supervisor
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
VOLUME ["/var/log/supervisor"]

# clean up our mess
RUN apt-get remove --purge -y software-properties-common && \
    apt-get autoremove -y && \
    apt-get clean && \
    apt-get autoclean && \
    echo -n > /var/lib/apt/extended_states && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /usr/share/man/?? && \
    rm -rf /usr/share/man/??_*

COPY . $APP_PATH
WORKDIR $APP_PATH

# update composer
RUN apt-get install -y --force-yes php8.2-curl php8.2-zip
RUN composer self-update

# install puppeteer
RUN npm install puppeteer --global --unsafe-perm
RUN apt-get update && \
    apt-get install -y libnss3-dev libasound2

# install highcharts server
# RUN npm install -g phantomjs-prebuilt@2.1.1 --unsafe-perm
ENV ACCEPT_HIGHCHARTS_LICENSE yes
# RUN npm install highcharts-export-server -g --unsafe-perm
RUN npm install highcharts-export-server@3.0.0-beta.1 -g --unsafe-perm

# add national font for highcharts
RUN cp /var/www/html/app/fonts/*.ttf /usr/share/fonts/truetype/
RUN fc-cache -fv

# install google chrome
RUN apt-get install -y libappindicator1 fonts-liberation
RUN apt-get install -f -y
ARG CHROME_VERSION="91.0.4472.164-1"
# wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
RUN wget --no-verbose -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
  && apt install -y /tmp/chrome.deb \
  && rm /tmp/chrome.deb

RUN apt-get install -y cron

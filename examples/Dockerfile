#
# Dockerfile for Ophal
#
# version: 0.2.0
#

FROM debian:jessie
MAINTAINER Fernando Paredes Garcia <fernando@develcuy.com>

# Update packages
RUN apt-get update
RUN apt-get dist-upgrade -y

# Install package dependencies
RUN apt-get install -y supervisor vim make less git curl lua5.1 libpcre3-dev sqlite3 libsqlite3-dev libssl-dev uuid-dev

# Install luarocks
RUN apt-get install -y luarocks

# Install Ophal
RUN luarocks install lrexlib-pcre PCRE_LIBDIR=/usr/lib/x86_64-linux-gnu/
RUN luarocks install luadbi-sqlite3 SQLITE_INCDIR=/usr/include/
RUN luarocks install lpeg
RUN luarocks install bit32
RUN luarocks install md5
RUN luarocks install luasec OPENSSL_LIBDIR=/usr/lib/x86_64-linux-gnu/
RUN luarocks install dkjson
RUN luarocks install --server=http://rocks.moonscript.org/dev seawolf 1.0-0
RUN luarocks install --server=http://rocks.moonscript.org/dev ophal-cli

# Install Apache
RUN apt-get install -y apache2-mpm-worker

# Configure Apache
RUN echo '[supervisord]\n\
nodaemon=true\n\
\n\
[program:apache2]\n\
command=/usr/bin/pidproxy /var/run/apache2/apache2.pid /bin/bash -c "source /etc/apache2/envvars && /usr/sbin/apache2 -DFOREGROUND"\n\
redirect_stderr=true\n'\
>> /etc/supervisor/conf.d/supervisord.conf
RUN mkdir /var/run/apache2 /var/lock/apache2 && chown www-data: /var/lock/apache2 /var/run/apache2
RUN echo '<VirtualHost *:80>\n\
\n\
        ServerAdmin webmaster@localhost\n\
\n\
        DocumentRoot /var/www\n\
        <Directory />\n\
                Options FollowSymLinks\n\
                AllowOverride None\n\
        </Directory>\n\
        <Directory /var/www/>\n\
                Options Indexes FollowSymLinks MultiViews\n\
                AllowOverride All\n\
                Order allow,deny\n\
                allow from all\n\
        </Directory>\n\
\n\
        ErrorLog ${APACHE_LOG_DIR}/error.log\n\
        CustomLog ${APACHE_LOG_DIR}/access.log combined\n\
\n\
</VirtualHost>'\
> /etc/apache2/sites-available/000-default.conf
RUN a2enmod rewrite
RUN a2enmod cgid
RUN service apache2 restart
VOLUME ["/var/www/"]
EXPOSE 80 443

# Create deploy user
RUN useradd deploy

# Start supervisor
CMD ["/usr/bin/supervisord"]

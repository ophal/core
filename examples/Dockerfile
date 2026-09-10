#
# OpenResty development image for Ophal
#

FROM openresty/openresty:bullseye-fat

LABEL maintainer="Fernando Paredes Garcia <fernando@develcuy.com>"

RUN apt-get update && apt-get install -y \
  git \
  curl \
  make \
  gcc \
  libc-dev \
  libpcre3-dev \
  libssl-dev \
  uuid-dev \
  sqlite3 \
  libsqlite3-dev \
  libpq-dev \
  luarocks \
  && rm -rf /var/lib/apt/lists/*

RUN luarocks install dkjson
RUN luarocks install luafilesystem
# SQLite goes through lsqlite3; `lsqlite3complete` links SQLite statically.
RUN luarocks install lsqlite3complete
# pgmoon serves both the worker and the command line: cosockets under
# OpenResty. luaossl is what it authenticates
# with, and scram-sha-256 is the default on PostgreSQL 14 and later.
RUN luarocks install pgmoon
RUN luarocks install luaossl


WORKDIR /var/www/ophal

EXPOSE 80

CMD ["openresty", "-g", "daemon off;"]

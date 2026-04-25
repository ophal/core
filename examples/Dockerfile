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

RUN luarocks install lpeg
RUN luarocks install dkjson
RUN luarocks install luafilesystem
RUN luarocks install luasocket
RUN luarocks install luuid
RUN luarocks install luadbi-sqlite3 SQLITE_INCDIR=/usr/include
RUN luarocks install luadbi-postgresql PGSQL_INCDIR=/usr/include/postgresql

RUN git clone --depth=1 https://github.com/ophal/seawolf.git /usr/local/share/lua/5.1/seawolf

WORKDIR /var/www/ophal

EXPOSE 80

CMD ["openresty", "-g", "daemon off;"]

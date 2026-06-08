FROM ghcr.io/cloudnative-pg/postgresql:16

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       gnupg \
       ca-certificates \
       lsb-release \
       wget \
    && echo "deb https://packagecloud.io/timescale/timescaledb/debian/ $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/timescaledb.list \
    && wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg \
    && apt-get update \
    && apt-get install -y --no-install-recommends timescaledb-2-postgresql-16 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

USER postgres

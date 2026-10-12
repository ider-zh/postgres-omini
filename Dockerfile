ARG POSTGRES_VERSION=18
ARG DEBIAN_BASE=postgres:${POSTGRES_VERSION}-trixie
ARG PGVECTOR_VERSION=v0.8.4
ARG PGMQ_VERSION=v1.11.1
ARG PG_SEARCH_VERSION=0.24.1
ARG SCWS_VERSION=1.2.3
ARG ZHPARSER_VERSION=v2.3
ARG TIMESCALEDB_VERSION=2.28.2
ARG DEBIAN_CODENAME=trixie

FROM ${DEBIAN_BASE} AS builder

ARG POSTGRES_VERSION
ARG PGVECTOR_VERSION
ARG PGMQ_VERSION
ARG PG_SEARCH_VERSION
ARG SCWS_VERSION
ARG ZHPARSER_VERSION
ARG TIMESCALEDB_VERSION
ARG DEBIAN_CODENAME
ARG TARGETARCH
ARG FETCH_HTTP_PROXY=
ARG FETCH_HTTPS_PROXY=
ARG APT_MIRROR=

ENV DEBIAN_FRONTEND=noninteractive

# This image supports PostgreSQL 18 on Debian trixie. Reject incompatible
# overrides before compiling extensions into the versioned runtime paths.
RUN set -eux; \
    test "${POSTGRES_VERSION}" = 18; \
    test "${DEBIAN_CODENAME}" = trixie; \
    test "${PG_MAJOR}" = "${POSTGRES_VERSION}"; \
    . /etc/os-release; \
    test "${VERSION_CODENAME}" = "${DEBIAN_CODENAME}"; \
    if [ -n "${APT_MIRROR:-}" ]; then \
      sed -i "s|http://deb.debian.org/debian|${APT_MIRROR}|g; s|http://security.debian.org/debian-security|${APT_MIRROR}-security|g" /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      ca-certificates \
      curl \
      file \
      git \
      libtool \
      pkg-config \
      cmake \
      libssl-dev \
      libkrb5-dev \
      libcurl4-openssl-dev \
      libicu-dev \
      postgresql-server-dev-${POSTGRES_VERSION}; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/build

RUN set -eux; \
    export http_proxy="${FETCH_HTTP_PROXY}" https_proxy="${FETCH_HTTPS_PROXY}" \
      HTTP_PROXY="${FETCH_HTTP_PROXY}" HTTPS_PROXY="${FETCH_HTTPS_PROXY}"; \
    git clone --depth 1 --branch "${PGVECTOR_VERSION}" https://github.com/pgvector/pgvector.git; \
    make -C pgvector PG_CONFIG=/usr/bin/pg_config OPTFLAGS=""; \
    make -C pgvector install PG_CONFIG=/usr/bin/pg_config OPTFLAGS=""

RUN set -eux; \
    export http_proxy="${FETCH_HTTP_PROXY}" https_proxy="${FETCH_HTTPS_PROXY}" \
      HTTP_PROXY="${FETCH_HTTP_PROXY}" HTTPS_PROXY="${FETCH_HTTPS_PROXY}"; \
    curl -fsSL --connect-timeout 30 --max-time 300 --retry 5 --retry-delay 5 \
      "https://github.com/hightman/scws/archive/refs/tags/${SCWS_VERSION}.tar.gz" -o scws.tar.gz; \
    tar xzf scws.tar.gz; \
    cd "scws-${SCWS_VERSION}"; \
    chmod +x acprep; \
    ./acprep; \
    ./configure --prefix=/usr/local; \
    make -j"$(nproc)"; \
    make install

RUN set -eux; \
    export http_proxy="${FETCH_HTTP_PROXY}" https_proxy="${FETCH_HTTPS_PROXY}" \
      HTTP_PROXY="${FETCH_HTTP_PROXY}" HTTPS_PROXY="${FETCH_HTTPS_PROXY}"; \
    git clone --depth 1 --branch "${ZHPARSER_VERSION}" https://github.com/amutu/zhparser.git; \
    make -C zhparser SCWS_HOME=/usr/local PG_CONFIG=/usr/bin/pg_config; \
    make -C zhparser install SCWS_HOME=/usr/local PG_CONFIG=/usr/bin/pg_config

RUN set -eux; \
    export http_proxy="${FETCH_HTTP_PROXY}" https_proxy="${FETCH_HTTPS_PROXY}" \
      HTTP_PROXY="${FETCH_HTTP_PROXY}" HTTPS_PROXY="${FETCH_HTTPS_PROXY}"; \
    case "${TARGETARCH}" in \
      amd64) deb_arch=amd64 ;; \
      arm64) deb_arch=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --connect-timeout 30 --max-time 600 --retry 5 --retry-delay 5 \
      "https://github.com/paradedb/paradedb/releases/download/v${PG_SEARCH_VERSION}/postgresql-${POSTGRES_VERSION}-pg-search_${PG_SEARCH_VERSION}-1PARADEDB-${DEBIAN_CODENAME}_${deb_arch}.deb" \
      -o pg_search.deb; \
    test "$(dpkg-deb -f pg_search.deb Architecture)" = "$(dpkg --print-architecture)"; \
    curl -fsSL --connect-timeout 30 --max-time 300 --retry 5 --retry-delay 5 \
      "https://raw.githubusercontent.com/paradedb/paradedb/v${PG_SEARCH_VERSION}/LICENSE" \
      -o pg_search.LICENSE; \
    mkdir -p pg_search_pkg; \
    dpkg-deb -x pg_search.deb pg_search_pkg; \
    install -m 755 "pg_search_pkg/usr/lib/postgresql/${POSTGRES_VERSION}/lib/pg_search.so" "$(pg_config --pkglibdir)/pg_search.so"; \
    cp "pg_search_pkg/usr/share/postgresql/${POSTGRES_VERSION}/extension"/pg_search* "$(pg_config --sharedir)/extension/"; \
    strip --strip-unneeded "$(pg_config --pkglibdir)/pg_search.so"

RUN set -eux; \
    export http_proxy="${FETCH_HTTP_PROXY}" https_proxy="${FETCH_HTTPS_PROXY}" \
      HTTP_PROXY="${FETCH_HTTP_PROXY}" HTTPS_PROXY="${FETCH_HTTPS_PROXY}"; \
    git clone --depth 1 --branch "${PGMQ_VERSION}" https://github.com/pgmq/pgmq.git; \
    make -C pgmq/pgmq-extension PG_CONFIG=/usr/bin/pg_config; \
    make -C pgmq/pgmq-extension install PG_CONFIG=/usr/bin/pg_config

RUN set -eux; \
    export http_proxy="${FETCH_HTTP_PROXY}" https_proxy="${FETCH_HTTPS_PROXY}" \
      HTTP_PROXY="${FETCH_HTTP_PROXY}" HTTPS_PROXY="${FETCH_HTTPS_PROXY}"; \
    git clone --depth 1 --branch "${TIMESCALEDB_VERSION}" https://github.com/timescale/timescaledb.git; \
    cd timescaledb; \
    ./bootstrap -DPG_CONFIG=/usr/bin/pg_config -DCMAKE_BUILD_TYPE=Release -DAPACHE_ONLY=OFF; \
    cd build; \
    make -j"$(nproc)"; \
    make install

RUN set -eux; \
    mkdir -p /opt/omni/lib/postgresql /opt/omni/share/postgresql/extension \
      /opt/omni/share/postgresql/tsearch_data /opt/omni/lib /opt/omni/etc; \
    cp "$(pg_config --pkglibdir)/vector.so" /opt/omni/lib/postgresql/; \
    cp "$(pg_config --pkglibdir)/pg_search.so" /opt/omni/lib/postgresql/; \
    cp "$(pg_config --pkglibdir)/zhparser.so" /opt/omni/lib/postgresql/; \
    cp /usr/local/lib/libscws*.so* /opt/omni/lib/; \
    cp /usr/local/etc/rules*.ini /opt/omni/etc/; \
    cp "$(pg_config --sharedir)/tsearch_data"/* /opt/omni/share/postgresql/tsearch_data/; \
    cp "$(pg_config --sharedir)/extension"/vector* /opt/omni/share/postgresql/extension/; \
    cp "$(pg_config --sharedir)/extension"/pg_search* /opt/omni/share/postgresql/extension/; \
    cp "$(pg_config --sharedir)/extension"/zhparser* /opt/omni/share/postgresql/extension/; \
    cp "$(pg_config --sharedir)/extension"/pgmq* /opt/omni/share/postgresql/extension/; \
    cp "$(pg_config --pkglibdir)"/timescaledb*.so /opt/omni/lib/postgresql/; \
    cp "$(pg_config --sharedir)/extension"/timescaledb* /opt/omni/share/postgresql/extension/; \
    strip --strip-unneeded /opt/omni/lib/postgresql/*.so /opt/omni/lib/libscws.so.*.*.* || true; \
    libscws_target="$(basename "$(find /opt/omni/lib -maxdepth 1 -name 'libscws.so.*.*.*' | sort | head -n 1)")"; \
    ln -sf "${libscws_target}" /opt/omni/lib/libscws.so.1; \
    ln -sf "${libscws_target}" /opt/omni/lib/libscws.so

RUN set -eux; \
    doc_dir=/opt/omni/share/doc/postgres-omini; \
    mkdir -p "${doc_dir}/pgvector" "${doc_dir}/pg_search" "${doc_dir}/pgmq" \
      "${doc_dir}/scws" "${doc_dir}/zhparser" "${doc_dir}/timescaledb"; \
    install -m 644 pgvector/LICENSE "${doc_dir}/pgvector/LICENSE"; \
    install -m 644 pg_search.LICENSE "${doc_dir}/pg_search/LICENSE"; \
    if [ -d pg_search_pkg/usr/share/doc ]; then \
      cp -a pg_search_pkg/usr/share/doc "${doc_dir}/pg_search/debian"; \
    fi; \
    install -m 644 pgmq/LICENSE "${doc_dir}/pgmq/LICENSE"; \
    install -m 644 "scws-${SCWS_VERSION}/COPYING" "${doc_dir}/scws/COPYING"; \
    install -m 644 zhparser/COPYRIGHT "${doc_dir}/zhparser/COPYRIGHT"; \
    install -m 644 timescaledb/LICENSE timescaledb/LICENSE-APACHE timescaledb/NOTICE \
      timescaledb/tsl/LICENSE-TIMESCALE "${doc_dir}/timescaledb/"; \
    printf '%s\n' \
      'This image includes the full TimescaleDB build, including Timescale-licensed (TSL) components.' \
      'LicenseRef-Timescale refers to timescaledb/LICENSE-TIMESCALE in this directory.' \
      'The Apache-only build is not used; consult the included upstream terms for your intended use.' \
      'components.tsv lists the bundled components. Debian package notices remain under /usr/share/doc.' \
      > "${doc_dir}/README.licenses"; \
    printf 'component\tversion\tlicense\tsource\n' > "${doc_dir}/components.tsv"; \
    printf 'pgvector\t%s\tPostgreSQL\thttps://github.com/pgvector/pgvector/tree/%s\n' \
      "${PGVECTOR_VERSION#v}" "${PGVECTOR_VERSION}" >> "${doc_dir}/components.tsv"; \
    printf 'pg_search\t%s\tAGPL-3.0\thttps://github.com/paradedb/paradedb/tree/v%s\n' \
      "${PG_SEARCH_VERSION}" "${PG_SEARCH_VERSION}" >> "${doc_dir}/components.tsv"; \
    printf 'pgmq\t%s\tPostgreSQL\thttps://github.com/pgmq/pgmq/tree/%s\n' \
      "${PGMQ_VERSION#v}" "${PGMQ_VERSION}" >> "${doc_dir}/components.tsv"; \
    printf 'scws\t%s\tBSD-3-Clause\thttps://github.com/hightman/scws/tree/%s\n' \
      "${SCWS_VERSION}" "${SCWS_VERSION}" >> "${doc_dir}/components.tsv"; \
    printf 'zhparser\t%s\tPostgreSQL\thttps://github.com/amutu/zhparser/tree/%s\n' \
      "${ZHPARSER_VERSION#v}" "${ZHPARSER_VERSION}" >> "${doc_dir}/components.tsv"; \
    printf 'timescaledb\t%s\tApache-2.0 AND LicenseRef-Timescale\thttps://github.com/timescale/timescaledb/tree/%s\n' \
      "${TIMESCALEDB_VERSION}" "${TIMESCALEDB_VERSION}" >> "${doc_dir}/components.tsv"

FROM ${DEBIAN_BASE}

ARG APT_MIRROR=

ENV DEBIAN_FRONTEND=noninteractive \
    LD_LIBRARY_PATH=/usr/local/lib

LABEL org.opencontainers.image.title="postgres-omini" \
      org.opencontainers.image.description="PostgreSQL 18 with pgvector, ParadeDB pg_search, PGMQ, TimescaleDB, and Chinese text segmentation preinstalled" \
      org.opencontainers.image.source="https://github.com/ider-zh/postgres-omini" \
      org.opencontainers.image.licenses="PostgreSQL AND AGPL-3.0 AND Apache-2.0 AND BSD-3-Clause AND LicenseRef-Timescale"

RUN set -eux; \
    if [ -n "${APT_MIRROR:-}" ]; then \
      sed -i "s|http://deb.debian.org/debian|${APT_MIRROR}|g; s|http://security.debian.org/debian-security|${APT_MIRROR}-security|g" /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      libssl3 \
      libkrb5-3 \
      libcurl4 \
      liblz4-1 \
      libzstd1 \
      libicu76; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/omni/lib/postgresql/ /usr/lib/postgresql/18/lib/
COPY --from=builder /opt/omni/lib/ /usr/local/lib/
COPY --from=builder /opt/omni/etc/ /usr/local/etc/
COPY --from=builder /opt/omni/share/postgresql/extension/ /usr/share/postgresql/18/extension/
COPY --from=builder /opt/omni/share/postgresql/tsearch_data/ /usr/share/postgresql/18/tsearch_data/
COPY --from=builder /opt/omni/share/doc/postgres-omini/ /usr/share/doc/postgres-omini/
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
COPY --chmod=755 docker-healthcheck.sh /usr/local/bin/docker-healthcheck.sh

RUN set -eux; \
    ldconfig /usr/local/lib; \
    echo "shared_preload_libraries = 'pg_search,timescaledb'" >> /usr/share/postgresql/18/postgresql.conf.sample; \
    printf 'postgresql\t%s\tPostgreSQL\thttps://www.postgresql.org/\n' "$(postgres --version)" \
      >> /usr/share/doc/postgres-omini/components.tsv

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD ["docker-healthcheck.sh"]


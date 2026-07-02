ARG POSTGRES_VERSION=18
ARG DEBIAN_BASE=postgres:${POSTGRES_VERSION}
ARG PGVECTOR_VERSION=v0.8.4
ARG PGMQ_VERSION=v1.11.1
ARG PG_SEARCH_VERSION=0.24.1
ARG SCWS_VERSION=1.2.3
ARG ZHPARSER_VERSION=v2.3
ARG DEBIAN_CODENAME=trixie
ARG TARGETARCH=amd64

FROM ${DEBIAN_BASE} AS builder

ARG POSTGRES_VERSION
ARG PGVECTOR_VERSION
ARG PGMQ_VERSION
ARG PG_SEARCH_VERSION
ARG SCWS_VERSION
ARG ZHPARSER_VERSION
ARG DEBIAN_CODENAME
ARG TARGETARCH
ARG FETCH_HTTP_PROXY=
ARG FETCH_HTTPS_PROXY=
ARG APT_MIRROR=

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
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
      postgresql-server-dev-${POSTGRES_VERSION}; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/build

RUN set -eux; \
    export http_proxy="${FETCH_HTTP_PROXY}" https_proxy="${FETCH_HTTPS_PROXY}" \
      HTTP_PROXY="${FETCH_HTTP_PROXY}" HTTPS_PROXY="${FETCH_HTTPS_PROXY}"; \
    git clone --depth 1 --branch "${PGVECTOR_VERSION}" https://github.com/pgvector/pgvector.git; \
    make -C pgvector PG_CONFIG=/usr/bin/pg_config; \
    make -C pgvector install PG_CONFIG=/usr/bin/pg_config

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
    strip --strip-unneeded /opt/omni/lib/postgresql/*.so /opt/omni/lib/libscws.so.*.*.* || true; \
    libscws_target="$(basename "$(find /opt/omni/lib -maxdepth 1 -name 'libscws.so.*.*.*' | sort | head -n 1)")"; \
    ln -sf "${libscws_target}" /opt/omni/lib/libscws.so.1; \
    ln -sf "${libscws_target}" /opt/omni/lib/libscws.so

FROM ${DEBIAN_BASE}

ARG APT_MIRROR=

ENV DEBIAN_FRONTEND=noninteractive \
    LD_LIBRARY_PATH=/usr/local/lib

LABEL org.opencontainers.image.title="postgres-omini" \
      org.opencontainers.image.description="PostgreSQL 18 with pgvector, ParadeDB pg_search, PGMQ, and Chinese text segmentation preinstalled" \
      org.opencontainers.image.source="https://github.com/ider-zh/postgres-omini" \
      org.opencontainers.image.licenses="PostgreSQL AND AGPL-3.0"

RUN set -eux; \
    if [ -n "${APT_MIRROR:-}" ]; then \
      sed -i "s|http://deb.debian.org/debian|${APT_MIRROR}|g; s|http://security.debian.org/debian-security|${APT_MIRROR}-security|g" /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/omni/lib/postgresql/ /usr/lib/postgresql/18/lib/
COPY --from=builder /opt/omni/lib/ /usr/local/lib/
COPY --from=builder /opt/omni/etc/ /usr/local/etc/
COPY --from=builder /opt/omni/share/postgresql/extension/ /usr/share/postgresql/18/extension/
COPY --from=builder /opt/omni/share/postgresql/tsearch_data/ /usr/share/postgresql/18/tsearch_data/
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

RUN ldconfig /usr/local/lib; \
    echo "shared_preload_libraries = 'pg_search'" >> /usr/share/postgresql/18/postgresql.conf.sample

HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1

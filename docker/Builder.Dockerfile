# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
ARG TRIVY_VERSION=latest

RUN --mount=type=secret,id=host_ca_bundle,target=/tmp/host-ca-bundle.crt,required=false \
    set -eux; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/80inauto-network-retries; \
    if [[ -s /tmp/host-ca-bundle.crt ]]; then \
        install -D -m 0644 /tmp/host-ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; \
        printf 'Acquire::https::CaInfo "/etc/ssl/certs/ca-certificates.crt";\n' \
            > /etc/apt/apt.conf.d/81inauto-custom-ca; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        debootstrap \
        squashfs-tools \
        xorriso \
        binutils \
        zstd \
        jq \
        ca-certificates \
        curl \
        gnupg \
        sudo \
        debian-archive-keyring \
        ubuntu-keyring \
        wget \
        unzip \
        file \
        gettext-base; \
    if [[ -s /tmp/host-ca-bundle.crt ]]; then \
        install -D -m 0644 /tmp/host-ca-bundle.crt /usr/local/share/ca-certificates/inauto-host-ca.crt; \
        update-ca-certificates; \
    fi; \
    curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
        | sh -s -- -b /usr/local/bin "${TRIVY_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

COPY docker/container-entrypoint.sh /container-entrypoint.sh
RUN chmod 0755 /container-entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/container-entrypoint.sh"]
CMD ["./scripts/build.sh", "-"]

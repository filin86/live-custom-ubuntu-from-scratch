# syntax=docker/dockerfile:1.4
FROM ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ARG TRIVY_VERSION=latest

RUN --mount=type=secret,id=host_ca_bundle,target=/tmp/host-ca-bundle.crt,required=false \
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then \
        sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources; \
    fi \
 && printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
    > /etc/apt/apt.conf.d/80inauto-network-retries \
 && if [[ -s /tmp/host-ca-bundle.crt ]]; then \
        install -D -m 0644 /tmp/host-ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; \
        printf 'Acquire::https::CaInfo "/etc/ssl/certs/ca-certificates.crt";\n' \
            > /etc/apt/apt.conf.d/81inauto-custom-ca; \
    else \
        printf 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";\n' \
            > /etc/apt/apt.conf.d/81inauto-insecure-bootstrap; \
    fi \
 && apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    lsb-release \
    debootstrap \
    squashfs-tools \
    xorriso \
    binutils \
    zstd \
    jq \
 && if [[ -s /tmp/host-ca-bundle.crt ]]; then \
        install -D -m 0644 /tmp/host-ca-bundle.crt /usr/local/share/ca-certificates/inauto-host-ca.crt; \
        update-ca-certificates; \
    fi \
 && rm -f /etc/apt/apt.conf.d/81inauto-insecure-bootstrap \
 && curl -kfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
    | sh -s -- -b /usr/local/bin "${TRIVY_VERSION}" \
 && rm -rf /var/lib/apt/lists/*

COPY docker/container-entrypoint.sh /usr/local/bin/livecd-container-entrypoint

RUN chmod 755 /usr/local/bin/livecd-container-entrypoint

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/livecd-container-entrypoint"]
CMD ["./scripts/build.sh", "-"]

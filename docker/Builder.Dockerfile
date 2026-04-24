# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive
# SHA256 values are taken from trivy_0.70.0_checksums.txt published with
# the upstream GitHub release.
ARG TRIVY_VERSION=0.70.0
ARG TRIVY_LINUX_64_SHA256=8b4376d5d6befe5c24d503f10ff136d9e0c49f9127a4279fd110b727929a5aa9
ARG TRIVY_LINUX_ARM_SHA256=12537cc6bf3f45e28e0b6b8bea0382ec9fabb468e0c3372e376474d5002c2ffe
ARG TRIVY_LINUX_ARM64_SHA256=2f6bb988b553a1bbac6bdd1ce890f5e412439564e17522b88a4541b4f364fc8d
ARG RAUC_PINNED_VERSION=1.15.2
ENV RAUC_PINNED_VERSION=${RAUC_PINNED_VERSION}

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
        file \
        gettext-base ; \
    if [[ -s /tmp/host-ca-bundle.crt ]]; then \
        install -D -m 0644 /tmp/host-ca-bundle.crt /usr/local/share/ca-certificates/inauto-host-ca.crt; \
        update-ca-certificates; \
    fi; \
    trivy_version="${TRIVY_VERSION#v}"; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
        amd64|x86_64) trivy_arch="64bit"; trivy_sha256="${TRIVY_LINUX_64_SHA256}" ;; \
        arm|armel|armhf) trivy_arch="ARM"; trivy_sha256="${TRIVY_LINUX_ARM_SHA256}" ;; \
        arm64|aarch64) trivy_arch="ARM64"; trivy_sha256="${TRIVY_LINUX_ARM64_SHA256}" ;; \
        *) echo "unsupported Trivy builder architecture: ${TARGETARCH:-$(dpkg --print-architecture)}" >&2; exit 1 ;; \
    esac; \
    trivy_archive="/tmp/trivy_${trivy_version}_Linux-${trivy_arch}.tar.gz"; \
    curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${trivy_version}/trivy_${trivy_version}_Linux-${trivy_arch}.tar.gz" \
        -o "$trivy_archive"; \
    printf '%s  %s\n' "$trivy_sha256" "$trivy_archive" | sha256sum -c -; \
    tar -xzf "$trivy_archive" -C /usr/local/bin trivy; \
    chmod 0755 /usr/local/bin/trivy; \
    rm -f "$trivy_archive"; \
    rm -rf /var/lib/apt/lists/*

COPY scripts/targets/rauc/install-rauc-source.sh /usr/local/sbin/install-rauc-source.sh
RUN chmod 0755 /usr/local/sbin/install-rauc-source.sh

# RAUC target build-time dependencies.
# Host-side utilities for partition layout, FAT image assembly, bundle signing,
# initramfs generation and UEFI boot-entry management on the installer.
# GRUB and systemd-boot are deliberately NOT installed — RAUC target uses
# EFI-stub kernel + external initrd, with RAUC EFI backend managing boot entries
# through efibootmgr.
RUN apt-get update && apt-get install -y --no-install-recommends \
        rauc \
        dosfstools \
        mtools \
        gdisk \
        parted \
        kmod \
        initramfs-tools \
        efibootmgr \
    && /usr/local/sbin/install-rauc-source.sh \
    && rm -rf /var/lib/apt/lists/*

# u-boot-tools is best-effort: needed only for the tablet (U-Boot) target.
# Skipping it on builder bases where the package is absent keeps PC UEFI builds working.
RUN apt-get update \
    && (apt-get install -y --no-install-recommends u-boot-tools \
         || echo "u-boot-tools unavailable on this builder base; tablet target requires a board-specific builder.") \
    && rm -rf /var/lib/apt/lists/*

COPY docker/container-entrypoint.sh /container-entrypoint.sh
RUN chmod 0755 /container-entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/container-entrypoint.sh"]
CMD ["./scripts/build.sh", "-"]

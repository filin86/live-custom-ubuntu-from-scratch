# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
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
        gettext-base \
        openssl \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key \
        | gpg --dearmor -o /etc/apt/keyrings/trivy.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
        > /etc/apt/sources.list.d/trivy.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends trivy \
    && rm -rf /var/lib/apt/lists/*

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
    && rm -rf /var/lib/apt/lists/*

# u-boot-tools is best-effort: needed only for the tablet (U-Boot) target.
# Skipping it on builder bases where the package is absent keeps PC UEFI builds working.
RUN apt-get update \
    && (apt-get install -y --no-install-recommends u-boot-tools \
         || echo "u-boot-tools unavailable on this builder base; tablet target requires a board-specific builder.") \
    && rm -rf /var/lib/apt/lists/*

ARG HOST_CA_CERT_PATH=
COPY ${HOST_CA_CERT_PATH:-/dev/null} /usr/local/share/ca-certificates/inauto-host-ca.crt
RUN update-ca-certificates || true

COPY docker/container-entrypoint.sh /container-entrypoint.sh
RUN chmod 0755 /container-entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/container-entrypoint.sh"]
CMD ["./scripts/build.sh", "-"]

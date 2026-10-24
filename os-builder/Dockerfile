# Reproducible builder image for the airgap OS image.
#
# Base image pinned by digest; the builder toolchain (mmdebstrap, ansible,
# squashfs-tools, genimage, ...) is installed from a frozen snapshot.debian.org
# with version + sha256 hash locks. Pinning mmdebstrap itself matters — it's
# the bootstrapper for the OS contents.
#
# This image only holds the *build tools*; the OS contents come from
# os-builder/airgap-rootfs-packages.list via mmdebstrap at build time.
ARG DEBIAN_HASH
FROM debian@sha256:${DEBIAN_HASH}

# Fixed, build-independent reproducibility settings (same as deb/).
ENV SOURCE_DATE_EPOCH=1 \
    TZ=UTC \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# Copy ONLY what `build-toolchain-pkgs-install` needs at image-build time. Everything else
# in os-builder/ (build-os.sh, genimage.cfg, ansible/, etc/, airgap-rootfs-packages.list
# and the rootfs-* locks) is read at RUN time from the /repo bind mount, so
# copying it here would bake stale duplicates into the image AND make every edit
# to those files invalidate this layer — forcing a full toolchain reinstall.
COPY build-toolchain-packages.list /config/
COPY lock/build-toolchain-debian.sources /config/lock/
COPY lock/build-toolchain-pkgs-version-lock.list /config/lock/
COPY lock/build-toolchain-pkgs-hash-lock.txt /config/lock/
COPY scripts/ /usr/local/bin/
RUN touch /.dockerenv

# Snapshot-pinned, version + hash locked builder toolchain.
# Debian's `ansible` package is the full community bundle, so it already ships
# community.general.chroot (the connection plugin we provision the rootfs with)
# — no unpinned `ansible-galaxy` network fetch needed.
RUN build-toolchain-pkgs-install

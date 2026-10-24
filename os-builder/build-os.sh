#!/usr/bin/env bash
# Build the complete airgap disk image, start to finish, inside the container.
#
#   mmdebstrap  -> Debian rootfs from the pinned live+snapshot sources
#   payload     -> scripts (replaces the old Packer file provisioners)
#   ansible     -> the existing roles, over the chroot connection
#   mksquashfs  -> read-only compressed root
#   ukify/grub  -> boot chain
#   genimage    -> GPT disk with fixed UUIDs
#
# The rootfs and all scratch live in /build — the container's OWN filesystem,
# never a bind mount — so nothing root-owned is ever written to the host. The
# ONLY thing crossing back out is the finished .img, chowned to the caller.


# Pipeline: mmdebstrap -> ansible-chroot -> squashfs -> genimage.
set -euo pipefail

REPO=/repo
WORK=/build
ROOTFS="$WORK/rootfs"
OUT="$REPO/build"
: "${SOURCE_DATE_EPOCH:=1}"
export SOURCE_DATE_EPOCH
# Safety net for any host-side write in this script that doesn't set its
# own mode explicitly (install -m / chmod already do, everywhere below).
umask 022
# Docker containers inherit the stack ulimit from the host/daemon, and it
# varies across machines/CI runners. Pin it so anything that probes
# ARG_MAX/stack size during this build gets the same answer everywhere.
ulimit -s 8192

VERSION="${1:-dev}"
APP_USER="${APP_USER:-airgap}"
IMAGE_HOSTNAME="airgap"
BOOT_TITLE="Airgap v${VERSION}"

# Must match the root partition-uuid in os-builder/genimage-*.cfg.
ROOT_PARTUUID=5c3f5d4f-0000-4000-8000-000000000003

# `rootovl` is what gives the read-only root + tmpfs overlay (reset on reboot).
CMDLINE="root=PARTUUID=${ROOT_PARTUUID} rootfstype=squashfs rootovl quiet splash loglevel=0 console=ttyS0,115200 earlyprintk=ttyS0,115200 nofb"

rm -rf "$WORK"; mkdir -p "$ROOTFS"

# ---------------------------------------------------------------------------
# 1. rootfs
# ---------------------------------------------------------------------------
LOCKFILE="$REPO/os-builder/lock/airgap-rootfs-pkgs-version-lock.list"
HASHLOCK="$REPO/os-builder/lock/airgap-rootfs-pkgs-hash-lock.txt"
SOURCES="$REPO/os-builder/lock/rootfs-debian.sources"
if [ -s "$LOCKFILE" ]; then
	PKG_LIST="$(grep -vE '^\s*(#|$)' "$LOCKFILE" | paste -sd, -)"
	echo "==> using pinned package versions ($(grep -cvE '^\s*(#|$)' "$LOCKFILE") packages)"
else
	echo "ERROR: no rootfs version lock at $LOCKFILE." >&2
	echo "       Run 'make rootfs-update' first — it discovers the package set" >&2
	echo "       with --variant=important and records it for --variant=custom." >&2
	exit 1
fi

# Cache the OS-only rootfs (before payload + ansible) as a tar keyed by a
# hash of the inputs that determine mmdebstrap's output. Not hashed: ansible/,
# scripts/, genimage configs — pure post-package-install configuration.
CACHE_DIR=/rootfs-cache
CACHE_KEY="$({
	mmdebstrap --version
	cat \
		"$REPO/os-builder/Dockerfile" \
		"$REPO/os-builder/lock/build-toolchain-"* \
		"$REPO/os-builder/lock/rootfs-debian.sources" \
		"$LOCKFILE" \
		"$HASHLOCK" \
		"$REPO/os-builder/build-toolchain-packages.list" \
		"$REPO/os-builder/airgap-rootfs-packages.list" \
		"$REPO/os-builder/build-os.sh"
} | sha256sum | cut -d' ' -f1)"
CACHE_TAR="$CACHE_DIR/rootfs-airgap-$CACHE_KEY.tar"

if [ -f "$CACHE_TAR" ] && [ -f "$CACHE_TAR.sha256" ] \
	&& [ "$(sha256sum "$CACHE_TAR" | cut -d' ' -f1)" = "$(cat "$CACHE_TAR.sha256")" ]; then
	echo "==> rootfs cache HIT ($CACHE_KEY): restoring OS-only rootfs, skipping mmdebstrap"
	tar -C "$ROOTFS" --numeric-owner -xf "$CACHE_TAR"
else
	echo "==> rootfs cache MISS ($CACHE_KEY): bootstrapping rootfs with mmdebstrap"
	mmdebstrap \
		--mode=unshare \
		--variant=custom \
		--format=directory \
		--include="$PKG_LIST" \
		--aptopt='APT::Keep-Downloaded-Packages "true"' \
		--extract-hook="/repo/os-builder/scripts/rootfs-verify-deb-pkgs \"\$1\" '$HASHLOCK' rootfs" \
		trixie \
		"$ROOTFS" \
		"$SOURCES"

	# mmdebstrap installs the sources file as 0000<basename>; ship the
	# conventional name instead.
	mv "$ROOTFS/etc/apt/sources.list.d/0000$(basename "$SOURCES")" \
		"$ROOTFS/etc/apt/sources.list.d/debian.sources"

	mkdir -p "$CACHE_DIR"
	CACHE_TMP="$CACHE_DIR/.rootfs-$CACHE_KEY.tmp.tar"
	tar -C "$ROOTFS" --numeric-owner --sort=name -cf "$CACHE_TMP" .
	sha256sum "$CACHE_TMP" | cut -d' ' -f1 > "$CACHE_TMP.sha256"
	rm -f "$CACHE_DIR"/rootfs-airgap-*.tar "$CACHE_DIR"/rootfs-airgap-*.tar.sha256
	mv "$CACHE_TMP" "$CACHE_TAR"
	mv "$CACHE_TMP.sha256" "$CACHE_TAR.sha256"
	chown "${HOST_UID:-0}:${HOST_GID:-0}" "$CACHE_TAR" "$CACHE_TAR.sha256"
fi

"$REPO/os-builder/scripts/rootfs-verify-installed-pkgs" "$ROOTFS" "$LOCKFILE" "" "OS layer, before payload"

# ---------------------------------------------------------------------------
# 2. payload: scripts (replaces the old Packer file provisioners)
# ---------------------------------------------------------------------------
# /dev + /proc are needed by ansible's chroot connection. They belong in the
# image regardless — devtmpfs overmounts /dev at boot.
rm -f "$ROOTFS/dev/null"
mkdir -p "$ROOTFS/dev"
mknod -m 666 "$ROOTFS/dev/null"    c 1 3
mknod -m 666 "$ROOTFS/dev/zero"    c 1 5
mknod -m 666 "$ROOTFS/dev/full"    c 1 7
mknod -m 666 "$ROOTFS/dev/random"  c 1 8
mknod -m 666 "$ROOTFS/dev/urandom" c 1 9
mknod -m 666 "$ROOTFS/dev/tty"     c 5 0
mount -t proc proc "$ROOTFS/proc"

echo "==> copying scripts into the rootfs"
install -d -m 0755 "$ROOTFS/usr/local/bin"
for f in "$REPO"/scripts/gen-hdwallet \
	"$REPO"/scripts/build-bx.sh; do
	[ -f "$f" ] && install -m 0755 "$f" "$ROOTFS/usr/local/bin/"
done

# gpg-provision and gpg-hd are separate projects, vendored as git submodules under repos/ and pinned by commit
# (that is what keeps the build reproducible). An uninitialised submodule must stop the build: skipping it
# silently would ship an image without them.
install_submodule_file() { # <mode> <path inside the repo> <installed name>
	[ -f "$REPO/$2" ] || {
		echo "ERROR: $2 is missing: the submodule is not checked out ('git submodule update --init'), or its pinned" >&2
		echo "       commit predates the file (commit and push the project, then 'git add' its repos/ path)." >&2
		exit 1
	}
	install -m "$1" "$REPO/$2" "$ROOTFS/usr/local/bin/$3"
}
install_submodule_file 0755 repos/gpg-provision/gpg-provision.py gpg-provision
install_submodule_file 0755 repos/gpg-hd/gpg-hd gpg-hd
install_submodule_file 0644 repos/gpg-hd/hmac_drbg.py hmac_drbg.py   # imported by gpg-hd from its own directory
install_submodule_file 0644 repos/gpg-hd/rsa_derive.py rsa_derive.py # likewise: gpg-hd's frozen key derivation

HOME_DIR="$ROOTFS/home/$APP_USER"
install -d -m 0755 "$HOME_DIR"

# Attestation signers' public keys: shipped to ~/gpg-keys and imported into
# the user keyring below, so the box can verify release signatures out of
# the box.
install -d -m 0755 "$HOME_DIR/gpg-keys"
for f in "$REPO"/attestation/signers/*.asc; do
	[ -f "$f" ] && install -m 0644 "$f" "$HOME_DIR/gpg-keys/"
done

# Hardware-wallet / security-key udev rules. Used to be dropped in by a
# packer file provisioner; with Packer gone they are installed from
# os-builder/rootfs/.
install -d -m 0755 "$ROOTFS/etc/udev/rules.d"
install -m 0644 "$REPO"/os-builder/rootfs/etc/udev/rules.d/*.rules "$ROOTFS/etc/udev/rules.d/"

# Ansible's rust-install/npm/get_url-style steps still need network in
# general; this repo's payload has none of those, but keep resolv.conf
# present for the duration of the chroot in case a future role needs it.
if [ -r /etc/resolv.conf ]; then
	cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
fi

# Pin identity BEFORE ansible. gpg / hostname(1) all read the container UTS
# name and /etc/hostname; leaving the random Docker id in place embeds a
# per-build string into keyrings and configs.
hostname "$IMAGE_HOSTNAME" 2>/dev/null || true
echo "$IMAGE_HOSTNAME" > "$ROOTFS/etc/hostname"
# /etc/hosts as mmdebstrap leaves it has no hostname line, and the box has
# no DNS — so sudo (which resolves the local hostname on every run) fails
# with "unable to resolve host airgap" on every invocation. Write the
# standard Debian entry set so the hostname resolves via loopback.
cat > "$ROOTFS/etc/hosts" <<-EOF
	127.0.0.1	localhost
	127.0.1.1	${IMAGE_HOSTNAME}
	::1		localhost ip6-localhost ip6-loopback
	ff02::1		ip6-allnodes
	ff02::2		ip6-allrouters
EOF
rm -f "$ROOTFS/etc/machine-id" "$ROOTFS/var/lib/dbus/machine-id"
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/systemd/random-seed"

# locales is installed but mmdebstrap never runs locale-gen, so man/ssh
# see an empty archive and warn. Ansible's LANG=C.UTF-8 is build-only.
echo "==> generating en_US.UTF-8 locale"
printf '%s\n' 'en_US.UTF-8 UTF-8' > "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen
printf '%s\n' \
	'LANG=en_US.UTF-8' \
	'LC_ALL=en_US.UTF-8' \
	> "$ROOTFS/etc/default/locale"
# Debian's systemd package ships /etc/default/locale as a SYMLINK to
# ../locale.conf (locale.conf is the real file) — the printf above already
# wrote through that symlink, so locale.conf is already current. Only copy
# if the two paths are genuinely different files (e.g. a base image that
# ships them the other way around).
if [ "$(readlink -f "$ROOTFS/etc/default/locale")" != "$(readlink -f "$ROOTFS/etc/locale.conf" 2>/dev/null || echo "$ROOTFS/etc/locale.conf")" ]; then
	cp "$ROOTFS/etc/default/locale" "$ROOTFS/etc/locale.conf"
fi
chmod 0644 "$ROOTFS/etc/default/locale" "$ROOTFS/etc/locale.gen"

# ---------------------------------------------------------------------------
# 3. configuration (ansible over the chroot connection)
# ---------------------------------------------------------------------------
echo "==> ansible: configuring rootfs over the chroot connection"
cd "$REPO"
ansible-playbook \
	-i "$ROOTFS," \
	-c community.general.chroot \
	-e ansible_python_interpreter=/usr/bin/python3 \
	-e user="$APP_USER" \
	--skip-tags packages,bootloader \
	ansible/main.yml

umount "$ROOTFS/proc"
rm -f "$ROOTFS/etc/resolv.conf"

# Drop build-time entropy and caches that change every run even when the
# installed payload is the same (gpg random_seed, ansible tmp). mksquashfs
# -reproducible only normalizes mtimes — content-level churn has to be
# deleted here.
echo "==> stripping non-reproducible build residue"
rm -rf \
	"$ROOTFS/tmp/"* \
	"$ROOTFS/var/tmp/"* \
	"$ROOTFS/var/log" \
	"$ROOTFS/var/cache/apt" \
	"$ROOTFS/var/cache/debconf" \
	"$ROOTFS/var/lib/apt/lists" \
	"$ROOTFS/root/.ansible" \
	"$ROOTFS/root/.cache" \
	"$ROOTFS/home/$APP_USER/.ansible" \
	"$ROOTFS/home/$APP_USER/.cache"
mkdir -p \
	"$ROOTFS/tmp" \
	"$ROOTFS/var/tmp" \
	"$ROOTFS/var/log" \
	"$ROOTFS/var/cache/apt/archives/partial" \
	"$ROOTFS/var/lib/apt/lists/partial"
chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"

# Rebuild $APP_USER's keyring from the committed attestation signer keys
# ($HOME_DIR/gpg-keys), so `gpg --list-keys` on the box shows the signers.
# No SECRET keys are ever baked in — real keys are still generated on the
# booted box (gpg-provision / gpg-hd). Rebuild the keyring from
# scratch, deterministically: import under a frozen clock, then replace
# the keyring file gpg wrote (not byte-stable) with a `gpg --export`
# (stable), selected via no-default-keyring.
echo "==> rebuilding $APP_USER keyring from attestation/signers"
rm -rf "$ROOTFS/home/$APP_USER/.gnupg"
mkdir -m 0700 "$ROOTFS/home/$APP_USER/.gnupg"
chown --reference="$ROOTFS/home/$APP_USER" "$ROOTFS/home/$APP_USER/.gnupg"
chroot "$ROOTFS" env GNUPGHOME="/home/$APP_USER/.gnupg" bash -c '
	set -eu
	gpgdir=/home/'"$APP_USER"'/.gnupg
	keydir=/home/'"$APP_USER"'/gpg-keys
	# Agent config: interactive pinentry-tty on the box (no display, no
	# ssh-agent loopback).
	printf "%s\n" \
		"pinentry-program /usr/bin/pinentry-tty" \
		"allow-loopback-pinentry" \
		> "$gpgdir/gpg-agent.conf"
	chmod 0600 "$gpgdir/gpg-agent.conf"
	# Old-format keyring: the file gpg writes on import is not byte-stable,
	# but a public export is.
	printf "%s\n" \
		"no-default-keyring" \
		"keyring $gpgdir/pubring.gpg" \
		> "$gpgdir/gpg.conf"
	chmod 0600 "$gpgdir/gpg.conf"
	# Frozen epoch-1 clock; without the two --ignore flags GnuPG drops
	# UIDs/subkeys or imports nothing at that clock. "future key" /
	# "unsafe ownership" warnings at epoch 1 are expected. --no-autostart:
	# public-key import needs no agent, so no socket/private-keys-v1.d
	# artifacts land in the image.
	gpgopts="--batch --no-autostart --faked-system-time 1! --ignore-time-conflict --ignore-valid-from"
	find "$keydir" -maxdepth 1 -type f -name "*.asc" -print0 \
		| xargs -0 -r gpg $gpgopts --quiet --import >/dev/null 2>&1 || true
	gpg $gpgopts --export > "$gpgdir/pubring.export"
	[ -s "$gpgdir/pubring.export" ] || { echo "ERROR: signer key import produced no keys" >&2; exit 1; }
	gpgconf --kill gpg-agent
	mv "$gpgdir/pubring.export" "$gpgdir/pubring.gpg"
	rm -f "$gpgdir/pubring.gpg~" \
		"$gpgdir/pubring.kbx" \
		"$gpgdir/pubring.kbx~" \
		"$gpgdir/tofu.db" \
		"$gpgdir/random_seed" \
		"$gpgdir/trustdb.gpg"
	find "$gpgdir" -name "S.gpg-agent*" -delete
'
chown -R --reference="$ROOTFS/home/$APP_USER" "$ROOTFS/home/$APP_USER/.gnupg"
# Root's keyring stays empty — drop any residue defensively (nothing in
# the build should create it anymore).
rm -rf \
	"$ROOTFS/root/.gitconfig" \
	"$ROOTFS/root/.ansible" \
	"$ROOTFS/root/.cache"
find "$ROOTFS/root" -maxdepth 2 -path '*/.gnupg' -prune -exec bash -c '
	rm -f "$1"/pubring.kbx "$1"/pubring.kbx~ "$1"/tofu.db "$1"/random_seed "$1"/trustdb.gpg
	find "$1" -name "S.gpg-agent*" -delete
' _ {} \;
rm -f \
	"$ROOTFS/var/cache/ldconfig/aux-cache" \
	"$ROOTFS/var/lib/dpkg/status-old" \
	"$ROOTFS/var/lib/sgml-base/supercatalog.old"
# install-info's dpkg trigger rebuilds this index by merging every
# installed package's *.info entries in whatever order triggers happened
# to fire in — same entries, different order, not byte-stable. Nothing
# in this repo reads it; `info` regenerates on demand if ever needed.
rm -f "$ROOTFS/usr/share/info/dir"
# pyc caches from ansible's python interpreter runs inside the chroot.
find "$ROOTFS" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$ROOTFS" -name '*.pyc' -o -name '*.pyo' -delete 2>/dev/null || true

echo "$IMAGE_HOSTNAME" > "$ROOTFS/etc/hostname"
rm -f "$ROOTFS/etc/machine-id" "$ROOTFS/var/lib/dbus/machine-id"
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/systemd/random-seed"

# ---------------------------------------------------------------------------
# 4. image assembly
# ---------------------------------------------------------------------------
mapfile -t _kvers < <(ls "$ROOTFS"/lib/modules)
if [ "${#_kvers[@]}" -ne 1 ]; then
	echo "ERROR: expected exactly one kernel under /lib/modules, found ${#_kvers[@]}: ${_kvers[*]}" >&2
	exit 1
fi
KVER="${_kvers[0]}"
echo "==> kernel $KVER"

BOOT_MODE="${AIRGAP_BOOT:-grub}"

cp /usr/lib/shim/shimx64.efi.signed "$WORK/shimx64.efi"
cp /usr/lib/shim/mmx64.efi.signed   "$WORK/mmx64.efi"

case "$BOOT_MODE" in
grub)
	if [ "${AIRGAP_BOOTSIGN:-no}" != "no" ]; then
		echo "ERROR: BOOTSIGN=${AIRGAP_BOOTSIGN} is meaningless with BOOT=grub — nothing of ours is" >&2
		echo "       signed in that mode (shim, GRUB and the kernel are signed by Debian)." >&2
		echo "       Use 'make BOOT=uki BOOTSIGN=yes' to sign, or drop BOOTSIGN." >&2
		exit 1
	fi
	echo "==> boot: Debian shim -> Debian-signed GRUB -> Debian-signed kernel"
	cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed "$WORK/grubx64.efi"
	cp "$ROOTFS/boot/vmlinuz-$KVER"    "$WORK/vmlinuz"
	cp "$ROOTFS/boot/initrd.img-$KVER" "$WORK/initrd.img"
	cat > "$WORK/grub.cfg" <<-EOF
		set default=0
		set timeout=0

		menuentry '$BOOT_TITLE' {
		    linux /vmlinuz $CMDLINE
		    initrd /initrd.img
		}
	EOF
	GENIMAGE_CFG=genimage-grub.cfg
	;;
uki)
	SB_KEY=/secureboot/airgap.key
	SB_CRT=/secureboot/airgap.crt
	BOOTSIGN_MODE="${AIRGAP_BOOTSIGN:-no}"
	if [ "$BOOTSIGN_MODE" = "auto" ]; then
		echo "WARNING: BOOTSIGN=auto is deprecated — use BOOTSIGN=yes." >&2
		BOOTSIGN_MODE=yes
	fi
	if [ "$BOOTSIGN_MODE" = "no" ]; then
		SB_KEY=/nonexistent
		SB_CRT=/nonexistent
	elif [ ! -r "$SB_KEY" ] || [ ! -r "$SB_CRT" ]; then
		echo "ERROR: BOOTSIGN=yes but no readable signing key at /secureboot." >&2
		echo "       Expected airgap.key + airgap.crt (mounted from os-builder/secureboot/)." >&2
		echo "       Run 'make secureboot-key' for a dev pair, or build with BOOTSIGN=no." >&2
		exit 1
	fi
	SIGN_ARGS=()
	if [ -r "$SB_KEY" ] && [ -r "$SB_CRT" ]; then
		echo "==> boot: signed UKI (enroll EFI/airgap.der once per machine via MokManager)"
		SIGN_ARGS=(--signtool=sbsign --secureboot-private-key="$SB_KEY" --secureboot-certificate="$SB_CRT")
	else
		echo "==> boot: UNSIGNED UKI — BOOTSIGN=no (default), key (if any) untouched"
	fi

	echo "==> ukify: kernel + initramfs + cmdline -> EFI-stub binary"
	ukify build \
		--linux="$ROOTFS/boot/vmlinuz-$KVER" \
		--initrd="$ROOTFS/boot/initrd.img-$KVER" \
		--cmdline="$CMDLINE" \
		--stub=/usr/lib/systemd/boot/efi/linuxx64.efi.stub \
		"${SIGN_ARGS[@]}" \
		--output="$WORK/BOOTX64.EFI"

	if [ -r "$SB_CRT" ]; then
		openssl x509 -in "$SB_CRT" -outform DER -out "$WORK/airgap.der"
	else
		: > "$WORK/airgap.der"
	fi
	GENIMAGE_CFG=genimage-uki.cfg
	;;
*)
	echo "ERROR: unknown BOOT mode '$BOOT_MODE' (expected: grub, uki)" >&2
	exit 1
	;;
esac

echo "==> trimming /boot from the rootfs (kernel now lives on the ESP)"
rm -f "$ROOTFS"/boot/vmlinuz-* "$ROOTFS"/boot/initrd.img-*

echo "==> mksquashfs: packing read-only root"
mksquashfs "$ROOTFS" "$WORK/rootfs.squashfs" \
	-noappend -no-progress \
	-comp zstd \
	-reproducible

echo "==> genimage: assembling GPT disk (fixed UUIDs)"
mkdir -p "$WORK/gtmp" "$WORK/groot"
SOURCE_DATE_EPOCH=315561600 \
genimage \
	--config "$REPO/os-builder/$GENIMAGE_CFG" \
	--inputpath "$WORK" \
	--outputpath "$WORK" \
	--rootpath "$WORK/groot" \
	--tmppath "$WORK/gtmp"

# ---------------------------------------------------------------------------
# 5. hand the finished image back (the only thing that leaves the container)
# ---------------------------------------------------------------------------
mkdir -p "$OUT"
chown "${HOST_UID:-0}:${HOST_GID:-0}" "$OUT" 2>/dev/null || true
IMG="$OUT/airgap-v${VERSION}.img"
mv "$WORK/airgap.img" "$IMG"
chown "${HOST_UID:-0}:${HOST_GID:-0}" "$IMG"
sync -f "$IMG" 2>/dev/null || sync

if [ "${KEEP_ROOTFS:-0}" = "1" ]; then
	echo "==> KEEP_ROOTFS=1: exporting rootfs tar for inspection"
	tar -C "$ROOTFS" --numeric-owner -cf "$OUT/rootfs-debug.tar" .
	chown "${HOST_UID:-0}:${HOST_GID:-0}" "$OUT/rootfs-debug.tar"
fi

echo "==> image ready: $IMG"
ls -lh "$IMG"
sha256sum "$IMG"

# Airgap

<https://github.com/Logicwax/airgap>

A live Debian-based reproducible/deterministic distribution for managing secrets
offline on an airgap machine, generating and storing PGP keychains on Yubikeys, and signing
cryptocurrency transactions.

The image is built **reproducibly**: two independent builds of the same
commit produce a byte-identical `.img`. Everything is assembled inside a
pinned Docker builder (mmdebstrap → ansible → squashfs → genimage).

## Use Cases

- Generate GPG keychains, provision them onto a Yubikey
- Sign cryptocurrency transactions
- Generate/backup a BIP39 universal cryptocurrency wallet seed
- Store/restore a BIP39 seed to a hardware wallet (Trezor/Ledger/Keepkey)
- General offline secret management (password stores, backups, RFID tools)

## Building

**`make setup` does host preparation for you.** It is idempotent. Anything
that touches the host prints what it will do and asks first; `FORCE=1 make
setup` answers yes for unattended use.

```bash
make setup
make build                                          # -> build/airgap-v<VERSION>.img
make sign                                           # attest the manifest
DISK=/dev/sdX make flash-disk                       # write the image to a USB stick
make test-boot                                      # boot it in QEMU
```

No prompts, no Yubikey required for the build itself.

### Requirements

- Linux host with Docker
- Your user must be in the `docker` group
- `containerd-snapshotter` enabled in `/etc/docker/daemon.json`
- Buildx `docker-container` driver with BuildKit `moby/buildkit:v0.26.2`

`make setup` configures all of the above.

### Attest and release

```bash
make build          # writes attestation/manifest.txt
make sign           # signs it -> attestation/signatures/manifest.<KEYID>.asc
make verify          # re-checks the signature against the current manifest
```

Signatures are verified in an isolated keyring built only from
`attestation/signers/` (one key: `2BDE9CDB6D0FAD15`). A rebuild that
produces different artifacts rewrites the manifest and **purges the
signatures**.

### Reproducibility

Every input is pinned in a committed lock file:

| What | Where |
|---|---|
| Base image digest | `os-builder/lock/build-toolchain-debian-img-hash-lock.txt` |
| Builder apt sources | `os-builder/lock/build-toolchain-debian.sources` |
| Builder toolchain versions/hashes | `os-builder/lock/build-toolchain-pkgs-*-lock.*` |
| Rootfs apt sources | `os-builder/lock/rootfs-debian.sources` |
| Packages shipped in the image | `os-builder/lock/airgap-rootfs-pkgs-*-lock.*` |

```bash
make update-deps
git diff os-builder/lock/          # ALWAYS review before committing
```

That runs `base-image-update` → `os-builder-update` → `rootfs-update` in
order. After editing `os-builder/airgap-rootfs-packages.list`, run `make
rootfs-update` or the new package silently never appears in the image.

```bash
make build-check     # build twice, compare — proves byte-identical output
```

### Boot chains

| command | boot chain | Secure Boot on a stock laptop | reproducible |
|---|---|---|---|
| `make build` | **grub** (default) | boots, nothing to enroll | yes |
| `make build BOOT=uki` | unsigned UKI | needs a hash enroll | yes |
| `make build BOOT=uki BOOTSIGN=yes` | signed UKI | needs a certificate enroll | no |

## Workflows

### Generate a GPG keychain suitable for a Yubikey

Boot the image, insert a Yubikey, and run:

```
gpg-provision
```

or the older simpler variant:

```
gen-gpgchain "Your Name" "you@example.com" "backup passphrase"
```

Nothing is baked into the image — this repo's convention has always been
to generate/import keys on the booted box, never at build time.

### Generate an HD cryptocurrency wallet

See [docs/HD-Cryptocurrency-Wallet.md](docs/HD-Cryptocurrency-Wallet.md), or
run `gen-hdwallet` directly for a BIP44 wallet dumped as JSON.

### Build libbitcoin-explorer (`bx`)

`scripts/build-bx.sh` builds `bx` and its dependencies from pinned,
hash-verified upstream archives. Not installed by default — run it after
boot if you need it.

For a full list of tools included, see [docs/tools.md](docs/tools.md).

## History

Originally a Packer + Debian preseed build (see git history prior to the
`packer/` removal). Migrated to the pinned mmdebstrap → ansible-chroot →
squashfs → genimage pipeline used here — mmdebstrap replaces
debootstrap+preseed, ansible now runs only as configuration against a
chroot connection (no more live `apt-get` during provisioning; every
package is version+hash locked), and Packer/QEMU-as-installer is gone
entirely. The legacy PGP/wallet-generation scripts, RFID/NFC/backup/
password-management ansible roles, and docs predate that migration and are
carried forward unchanged.

This is a single-flavor personal airgap workstation image only.

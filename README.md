# Airgap #

<https://github.com/Logicwax/airgap>

## About ##

A live debian based distribution designed for managing secrets offline.

Built for those of us that want to be -really- sure our most important secrets
are managed in a clean environment with an "air gap" between us and the
internet.

## Use Cases ##

- Generate GPG keychain
- Store/Restore gpg keychain to security token such as a Yubikey or Nitrokey
- Signing cryptocurrency transactions
- Generate/backup BIP39 universal cryptocurrency wallet seed
- Store/Restore BIP39 seed to a hardware wallet such as a Trezor or Ledger

For a full list of tools included see: [tools](docs/tools.md)

## Requirements ##

### Software ###

* ansible
* packer
* qemu
* ovmf

### Hardware ###

Any x86_64 laptop known to support Linux should work.

Chromebooks are also suitable if they have been placed into developer mode
and setup with Seabios so they can boot traditional linux distributions.

Be sure any Wifi/Bluetooth modules removed before the system is ever powered
on for the first time. You may also want to consider sourcing the machine
from a random retail store in order to avoid supply chain attacks.

## Build ##

```
make
```

## Install ##

Create bootable USB drive:
```
DISK=/dev/sdX make flash-disk
```

Note: The above assumes `/dev/sda` is a flash media device of 8GB or larger.

## Examples ##

* [Generate HD Cryptocurrency Wallet](docs/HD-Cryptocurrency-Wallet.md)

## Development ##

### Build Debugging

```
PACKER_LOG=1 ANSIBLE_ARGS="-vvvv" make
```

### Boot image in qemu

```
gunzip dist/airgap-latest.raw.gz
qemu-system-x86_64 \
  -m 512M \
  -machine type=pc,accel=kvm \
  -net nic -net user,hostfwd=tcp::2222-:22
  -drive format=raw,file=$(ls -1 dist/airgap-*.raw)
```

### Run Ansible against running VM

```
ansible-playbook -k -b -u airgap -i "0.0.0.0:2222," ansible/main.yml
```

Note: Due to fsprotect being enabled, changes will not persist through reboots.

## Notes ##

  Things are still pretty early right now. Please report issues.

  Use at your own risk. You may be eaten by a grue.

  Questions/Comments?

  - IRC: [Logicwax@irc.freenode.net/6697]()
  - Matrix: [@Logicwax:matrix.org]()
  - Email: [*@Logicwax.com](mailto://*@Logicwax.com)

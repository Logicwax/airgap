.PHONY: build clean distclean flash-disk test-boot test-boot-bios

EXECUTABLES = packer ansible qemu-system-x86_64
K := $(foreach exec,$(EXECUTABLES),\
        $(if $(shell which $(exec)),some string,$(error "No $(exec) in PATH)))

SHELL=/bin/bash
export CHECKPOINT_DISABLE := 1
export PACKER_CACHE_DIR := \
	$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))/.packer/cache
export VERSION := $(shell date -u +%Y%m%d%H%M)

default: build/airgap-latest.raw.gz

clean:
	rm -rf build
	rm -rf .packer/build
	rm -rf ansible/main.retry

distclean: clean

	rm -rf .packer

build: build/airgap-latest.raw.gz

build/airgap-latest.raw.gz:

	packer build \
	-var "user=airgap" \
	packer/build.json

build/airgap-latest.raw: build/airgap-latest.raw.gz

	@echo -e "\n\n Decompressing image first, please wait....\n"
	gunzip -c build/airgap-latest.raw.gz > build/airgap-latest.raw

flash-disk: build/airgap-latest.raw.gz

	sudo umount -qf $(DISK)* || true && \
	sync && \
	gunzip -c build/airgap-latest.raw.gz | sudo dd of=$(DISK) status=progress bs=16M conv=fsync status=progress oflag=dsync && \
	sync

test-boot: build/airgap-latest.raw

	qemu-system-x86_64 \
		-m 2048M \
		-machine type=pc,accel=kvm \
		-bios /usr/share/qemu/OVMF.fd \
		-device virtio-scsi-pci,id=scsi0 \
		-device scsi-hd,bus=scsi0.0,drive=drive0 \
		-drive format=raw,if=none,id=drive0,file=build/airgap-latest.raw

test-boot-bios: build/airgap-latest.raw

	qemu-system-x86_64 \
		-m 2048M \
		-machine type=pc,accel=kvm \
		-drive format=raw,file=build/airgap-latest.raw

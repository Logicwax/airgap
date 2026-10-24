# Single-maintainer repo: THRESHOLD=1, one key in attestation/signers/.
# `make sign` IS the release attestation step.

# `make clean build-check` must not run those goals in parallel: clean
# would delete the image the first assemble just wrote.
.NOTPARALLEL:

.PHONY: \
	all \
	base-image-update \
	boot-check \
	build \
	build-check \
	inner-build-check \
	check-buildx-driver \
	clean \
	distclean \
	flash-disk \
	os-builder \
	os-builder-update \
	os-image \
	rootfs-update \
	rootfs-cache-clean \
	secureboot-key \
	setup \
	sign \
	test-boot \
	test-boot-serial \
	update-deps \
	verify

SHELL=/bin/bash
KEEP_ROOTFS ?= 0
THRESHOLD ?= 1
BOOT ?= grub
BOOTSIGN ?= no
CPUSET ?=
DOCKER_CPUSET := $(if $(CPUSET),--cpuset-cpus=$(CPUSET),)

BUILD_VERSION := $(strip $(shell cat VERSION))
OS_BUILDER_IMAGE := airgap-os-builder
OS_DEBIAN_HASH := $(strip $(shell cat os-builder/lock/build-toolchain-debian-img-hash-lock.txt))
APP_USER := airgap
RAW := build/airgap-v$(BUILD_VERSION).img

DOCKER_CACHE_DIR := .cache
OS_BUILDER_TAR := $(DOCKER_CACHE_DIR)/os-builder.tar
OS_BUILDER_STATE := $(DOCKER_CACHE_DIR)/os-builder.state

define stage
	@echo ""
	@echo "=============================================================================="
	@echo "  $(1)"
	@echo "=============================================================================="
	@echo ""
endef

default: all

all: build

build: os-image

# Build the image twice and compare — does it come out byte-identical?
build-check:
	@flock -n /tmp/airgap-build-check.lock -c 'exit 0' \
		|| { echo "ERROR: another build-check is already running"; exit 1; }
	@flock /tmp/airgap-build-check.lock $(MAKE) --no-print-directory inner-build-check

FIRST_IMAGE := /tmp/airgap-build-check-1-$(notdir $(RAW))

inner-build-check:
	$(MAKE) --no-print-directory build
	cp -f attestation/manifest.txt /tmp/airgap-manifest-1.txt
	cp -f $(RAW) $(FIRST_IMAGE)
	$(MAKE) --no-print-directory clean
	$(MAKE) --no-print-directory build
	@echo ""
	@echo "first:"
	@cat /tmp/airgap-manifest-1.txt
	@echo "second:"
	@cat attestation/manifest.txt
	@if cmp -s /tmp/airgap-manifest-1.txt attestation/manifest.txt; then \
		echo "REPRODUCIBLE: the two image builds are byte-identical"; \
		rm -f $(FIRST_IMAGE); \
	else \
		echo "NOT reproducible: the two image builds differ"; \
		diff -u /tmp/airgap-manifest-1.txt attestation/manifest.txt || true; \
		echo "images kept for inspection: $(FIRST_IMAGE) (first build), $(RAW) (second build)"; \
		exit 1; \
	fi

clean:
	rm -rf build ansible/main.retry

distclean: clean
	docker image rm -f airgap-os-builder 2>/dev/null || true
	docker buildx prune --force --builder reproducible-builder 2>/dev/null || true
	rm -rf $(DOCKER_CACHE_DIR)

# ---------------------------------------------------------------------------
# Host setup + pinned builder
# ---------------------------------------------------------------------------
setup:
	@./scripts/setup-host

check-buildx-driver:
	@driver=$$(docker buildx inspect | grep '^Driver:' | awk '{print $$2}'); \
	if [ "$$driver" != "docker-container" ]; then \
		echo "ERROR: buildx driver must be 'docker-container' (found '$$driver')."; \
		echo "Run: make setup"; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# Reproducible OS image
# ---------------------------------------------------------------------------
$(OS_BUILDER_TAR): \
	os-builder/Dockerfile \
	os-builder/build-toolchain-packages.list \
	os-builder/lock/build-toolchain-debian.sources \
	os-builder/lock/build-toolchain-debian-img-hash-lock.txt \
	os-builder/lock/build-toolchain-pkgs-version-lock.list \
	os-builder/lock/build-toolchain-pkgs-hash-lock.txt \
	$(wildcard os-builder/scripts/*) \
	| check-buildx-driver

	$(call stage,STAGE 1/2  Build the OS builder image (airgap-os-builder))
	mkdir -p $(DOCKER_CACHE_DIR)
	SOURCE_DATE_EPOCH=1 docker buildx build \
		--build-arg DEBIAN_HASH=$(OS_DEBIAN_HASH) \
		--build-arg SOURCE_DATE_EPOCH=1 \
		--build-arg BUILDKIT_DOCKERFILE_CHECK=skip=InvalidDefaultArgInFrom \
		--provenance=false \
		--output type=docker,name=$(OS_BUILDER_IMAGE),rewrite-timestamp=true,annotation.org.opencontainers.image.created=1970-01-01T00:00:01Z \
		os-builder
	docker save $(OS_BUILDER_IMAGE) -o $@

$(OS_BUILDER_STATE): $(OS_BUILDER_TAR)
	docker inspect $(OS_BUILDER_IMAGE) > /dev/null 2>&1 || docker load -i $(OS_BUILDER_TAR)
	docker images --no-trunc --quiet $(OS_BUILDER_IMAGE) > $@

os-builder: check-buildx-driver $(OS_BUILDER_STATE)
	@docker inspect $(OS_BUILDER_IMAGE) > /dev/null 2>&1 || docker load -i $(OS_BUILDER_TAR)

boot-check:
	@if [ -n "$(SIGN)" ]; then \
		echo "ERROR: SIGN= was renamed to BOOTSIGN=. Use BOOTSIGN=$(SIGN)."; \
		exit 1; \
	fi
	@case "$(BOOT)" in \
		grub|uki) ;; \
		*) echo "ERROR: BOOT='$(BOOT)' is not valid (expected: grub, uki)"; exit 1 ;; \
	esac
	@case "$(BOOTSIGN)" in \
		yes|no) ;; \
		auto) echo "WARNING: BOOTSIGN=auto is deprecated — use BOOTSIGN=yes" ;; \
		*) echo "ERROR: BOOTSIGN='$(BOOTSIGN)' is not valid (expected: yes, no)"; exit 1 ;; \
	esac
	@if [ "$(BOOT)" = "grub" ] && [ "$(BOOTSIGN)" != "no" ]; then \
		echo "ERROR: BOOTSIGN=$(BOOTSIGN) is meaningless with BOOT=grub."; \
		echo "       Use 'make BOOT=uki BOOTSIGN=yes' to sign, or drop BOOTSIGN."; \
		exit 1; \
	fi

os-image: boot-check os-builder
	$(call stage,STAGE 2/2  Assemble the airgap image (mmdebstrap -> ansible -> squashfs -> boot chain -> genimage))
	mkdir -p build $(DOCKER_CACHE_DIR)
	docker run --rm $(DOCKER_CPUSET) \
		--hostname airgap \
		--cap-add SYS_ADMIN \
		--cap-add MKNOD \
		--security-opt seccomp=unconfined \
		--security-opt apparmor=unconfined \
		-v $(CURDIR):/repo \
		-v $(CURDIR)/os-builder/secureboot:/secureboot \
		-v $(CURDIR)/$(DOCKER_CACHE_DIR):/rootfs-cache \
		-e HOST_UID=$(shell id -u) \
		-e HOST_GID=$(shell id -g) \
		-e KEEP_ROOTFS=$(KEEP_ROOTFS) \
		-e AIRGAP_BOOTSIGN=$(BOOTSIGN) \
		-e AIRGAP_BOOT=$(BOOT) \
		-e APP_USER=$(APP_USER) \
		$(OS_BUILDER_IMAGE) \
		/repo/os-builder/build-os.sh $(BUILD_VERSION)
	@if [ ! -f "$(RAW)" ]; then \
		echo "ERROR: docker finished but $(RAW) is missing on the host"; \
		ls -la build/ || true; \
		exit 1; \
	fi
	@./scripts/attest-manifest $(RAW)
	@{ \
		w=0; while IFS= read -r line; do \
			file=$$(echo "$$line" | awk '{print $$2}'); \
			len=$$(echo -n "$$file" | wc -c); \
			if [ $$len -gt $$w ]; then w=$$len; fi; \
		done < attestation/manifest.txt; \
		sep=$$(printf '%*s' $$((64 + 2 + w)) '' | tr ' ' '='); \
		echo ""; echo "Manifest:"; echo "$$sep"; \
		printf '%-64s  %s\n' "SHA256 Hash" "File"; \
		echo "$$sep"; \
		while IFS= read -r line; do \
			hash=$$(echo "$$line" | awk '{print $$1}'); \
			file=$$(echo "$$line" | awk '{print $$2}'); \
			printf '%-64s  %s\n' "$$hash" "$$file"; \
		done < attestation/manifest.txt; \
		echo "$$sep"; echo ""; \
	}

secureboot-key:
	$(call stage,Generating a Secure Boot signing key + certificate)
	@if [ -e os-builder/secureboot/airgap.key ]; then \
		echo "REFUSING: os-builder/secureboot/airgap.key already exists."; \
		exit 1; \
	fi
	mkdir -p os-builder/secureboot
	docker run --rm \
		-v $(CURDIR)/os-builder/secureboot:/secureboot \
		-e HOST_UID=$(shell id -u) -e HOST_GID=$(shell id -g) \
		$(OS_BUILDER_IMAGE) \
		bash -c 'openssl req -new -x509 -newkey rsa:4096 -nodes -days 3650 \
			-subj "/CN=Airgap Secure Boot/" \
			-keyout /secureboot/airgap.key -out /secureboot/airgap.crt 2>/dev/null && \
			chmod 600 /secureboot/airgap.key && \
			chown $${HOST_UID}:$${HOST_GID} /secureboot/airgap.key /secureboot/airgap.crt'
	@echo "Key written to os-builder/secureboot/ (gitignored)."

rootfs-update: os-builder-update os-builder
	$(call stage,Regenerating rootfs package locks)
	docker run --rm \
		--cap-add SYS_ADMIN \
		--cap-add MKNOD \
		--security-opt seccomp=unconfined \
		--security-opt apparmor=unconfined \
		-v $(CURDIR)/os-builder:/config \
		-e LOCAL_USER=$(shell id -u):$(shell id -g) \
		$(OS_BUILDER_IMAGE) \
		/config/scripts/rootfs-pkgs-update airgap

rootfs-cache-clean:
	rm -f $(DOCKER_CACHE_DIR)/rootfs-*.tar $(DOCKER_CACHE_DIR)/rootfs-*.tar.sha256

os-builder-update:
	docker run --rm \
		-v $(CURDIR)/os-builder:/config \
		-e LOCAL_USER=$(shell id -u):$(shell id -g) \
		debian@sha256:$(OS_DEBIAN_HASH) \
		bash -c "cp /config/scripts/* /usr/local/bin/ && touch /.dockerenv && build-toolchain-pkgs-update"

base-image-update:
	$(call stage,Re-resolving the Debian base image digest (debian:trixie))
	docker pull debian:trixie
	@digest=$$(docker image inspect debian:trixie \
		--format '{{index .RepoDigests 0}}' | cut -d@ -f2 | cut -d: -f2); \
	if [ -z "$$digest" ]; then echo "ERROR: could not resolve digest"; exit 1; fi; \
	echo "$$digest" > os-builder/lock/build-toolchain-debian-img-hash-lock.txt; \
	echo "debian:trixie -> sha256:$$digest"

update-deps:
	$(MAKE) base-image-update
	$(MAKE) os-builder-update
	$(MAKE) rootfs-update
	$(call stage,All dependency locks refreshed — review `git diff os-builder/lock/` before committing)

# ---------------------------------------------------------------------------
# Attestation
# ---------------------------------------------------------------------------
sign: attestation/manifest.txt
	@./scripts/attest-sign

verify:
	@./scripts/attest-verify $(THRESHOLD)

attestation/manifest.txt:
	@echo "ERROR: no attestation/manifest.txt — run 'make build' first." >&2
	@exit 1

# ---------------------------------------------------------------------------
# Flash / boot-test
# ---------------------------------------------------------------------------
flash-disk:
	sudo umount -qf $(DISK)* || true && \
	sync && \
	if [ -e $(RAW) ]; then \
		echo "==> flashing $(RAW)"; \
		sudo dd if=$(RAW) of=$(DISK) status=progress bs=64M conv=fsync oflag=dsync; \
	else \
		echo "ERROR: no image at $(RAW) — run 'make build' first"; \
		exit 1; \
	fi && \
	sync

test-boot:
	qemu-system-x86_64 \
		-m 4096M \
		-machine type=pc,accel=kvm \
		-bios /usr/share/qemu/OVMF.fd \
		-device virtio-scsi-pci,id=scsi0 \
		-device scsi-hd,bus=scsi0.0,drive=drive0 \
		-drive format=raw,if=none,id=drive0,file=$(RAW)

test-boot-serial:
	qemu-system-x86_64 \
		-m 4096M \
		-machine type=pc,accel=kvm \
		-bios /usr/share/qemu/OVMF.fd \
		-device virtio-scsi-pci,id=scsi0 \
		-device scsi-hd,bus=scsi0.0,drive=drive0 \
		-drive format=raw,if=none,id=drive0,file=$(RAW) \
		-display none -serial stdio -no-reboot

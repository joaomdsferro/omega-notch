.PHONY: engine ui run doctor install uninstall dist clean

VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
ARCH := $(shell uname -m)
DIST := omega-notch-$(VERSION)-linux-$(ARCH)

engine:
	cargo build --release -p omega-notch-engine

ui:
	cmake -S ui/plasma -B ui/plasma/build -G Ninja -DCMAKE_BUILD_TYPE=Release
	cmake --build ui/plasma/build

run: engine ui
	chmod +x scripts/run.sh
	./scripts/run.sh

doctor: engine
	./target/release/omega-notch-engine doctor

install:
	chmod +x packaging/install.sh scripts/*.sh
	./packaging/install.sh

uninstall:
	./packaging/uninstall.sh

# The release download: prebuilt binaries plus what install.sh needs.
dist: engine ui
	rm -rf target/dist/$(DIST)
	install -Dm755 target/release/omega-notch-engine target/dist/$(DIST)/bin/omega-notch-engine
	install -Dm755 ui/plasma/build/omega-notch-plasma target/dist/$(DIST)/bin/omega-notch-plasma
	install -Dm755 scripts/claude-hook.sh target/dist/$(DIST)/scripts/claude-hook.sh
	install -Dm755 packaging/install.sh target/dist/$(DIST)/packaging/install.sh
	install -Dm755 packaging/uninstall.sh target/dist/$(DIST)/packaging/uninstall.sh
	install -Dm644 packaging/omega-notch.desktop target/dist/$(DIST)/packaging/omega-notch.desktop
	cp -r packaging/icons target/dist/$(DIST)/packaging/icons
	cp README.md LICENSE target/dist/$(DIST)/
	printf '#!/usr/bin/env bash\nexec "$$(dirname "$$0")/packaging/install.sh" "$$@"\n' > target/dist/$(DIST)/install.sh
	printf '#!/usr/bin/env bash\nexec "$$(dirname "$$0")/packaging/uninstall.sh" "$$@"\n' > target/dist/$(DIST)/uninstall.sh
	chmod +x target/dist/$(DIST)/install.sh target/dist/$(DIST)/uninstall.sh
	tar -C target/dist -czf target/dist/$(DIST).tar.gz $(DIST)
	cd target/dist && sha256sum $(DIST).tar.gz > $(DIST).tar.gz.sha256
	@echo "target/dist/$(DIST).tar.gz"

clean:
	cargo clean
	rm -rf ui/plasma/build

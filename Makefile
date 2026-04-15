BIN     := pbm
INSTALL := $(HOME)/.local/bin

.PHONY: all build install uninstall clean

all: build

build:
	zig build -Doptimize=ReleaseSafe

install: build
	@mkdir -p $(INSTALL)
	cp zig-out/bin/$(BIN) $(INSTALL)/$(BIN)
	@echo "installed $(INSTALL)/$(BIN)"

uninstall:
	rm -f $(INSTALL)/$(BIN)
	@echo "removed $(INSTALL)/$(BIN)"

clean:
	rm -rf zig-out .zig-cache

dev-push:
	@git config credential.helper 'cache --timeout=3600'
	@git add .
	@git commit -am "dev: update" || true
	@git push
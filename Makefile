BIN     := pbm
INSTALL := $(HOME)/.local/bin
PREFIX  ?= /usr/local

.PHONY: all build install uninstall clean completion

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

completion:
	@echo "Installing bash completion to /etc/bash_completion.d/"
	@sudo cp contrib/pbm-completion.bash /etc/bash_completion.d/pbm
	@echo "Installing zsh completion to /usr/share/zsh/site-functions/"
	@sudo cp contrib/pbm-completion.zsh /usr/share/zsh/site-functions/_pbm
	@echo "Done. Restart your shell or run: source ~/.bashrc"

dev-push:
	@git config credential.helper 'cache --timeout=3600'
	@git add .
	@git commit -am "dev: update" || true
	@git push
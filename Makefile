.PHONY: setup dev build test test-all lint fmt clean

setup:
	@echo "Ensure stylua and luacheck are installed"
	@command -v stylua >/dev/null 2>&1 || echo "Install stylua: cargo install stylua"
	@command -v luacheck >/dev/null 2>&1 || echo "Install luacheck: luarocks install luacheck"
	@command -v busted >/dev/null 2>&1 || echo "Install busted: luarocks install busted"

dev:
	@echo "Open Neovim with plugin loaded from this directory"
	nvim --cmd "set rtp+=." test.mx

build:
	@echo "Nothing to build — Lua plugin"

test:
	busted --lpath='lua/?.lua;lua/?/init.lua' tests/

test-all: test

lint:
	luacheck lua/

fmt:
	stylua lua/

clean:
	rm -rf luacov.stats.out luacov.report.out .testcache/

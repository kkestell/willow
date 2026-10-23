LUAJIT_REPO := https://github.com/LuaJIT/LuaJIT.git
LUAJIT_REV  := 634daf2453559fd5e0ec282f3b7aedaa09e9f344
LUAJIT_DIR  := vendor/luajit
LUAJIT      := $(LUAJIT_DIR)/src/luajit
STUB        := runtime/stub
BUILD_DIR   := build
WILLOW      := $(BUILD_DIR)/willow

# LuaJIT's own unwinder throws errors far faster than the system unwinder,
# which takes tens of microseconds per error on macOS.
LUAJIT_FLAGS := XCFLAGS=-DLUAJIT_UNWIND_INTERNAL

ifeq ($(shell uname -s),Darwin)
LUAJIT_FLAGS += MACOSX_DEPLOYMENT_TARGET=11.0
else
STUB_LIBS := -lm -ldl
endif

.PHONY: all test install clean bootstrap bootstrap-test

all: $(LUAJIT) $(STUB)

$(LUAJIT_DIR):
	git clone $(LUAJIT_REPO) $(LUAJIT_DIR)
	git -C $(LUAJIT_DIR) checkout -q $(LUAJIT_REV)

$(LUAJIT): | $(LUAJIT_DIR)
	$(MAKE) -C $(LUAJIT_DIR) $(LUAJIT_FLAGS)

$(STUB): runtime/stub.c $(LUAJIT)
	$(LUAJIT_FLAGS) $(CC) -O2 -I$(LUAJIT_DIR)/src -o $@ runtime/stub.c $(LUAJIT_DIR)/src/libluajit.a $(STUB_LIBS)

$(WILLOW): compiler/bundle.lua $(wildcard compiler/*.lua) $(wildcard runtime/*.lua) $(STUB) $(LUAJIT)
	mkdir -p $(BUILD_DIR)
	$(LUAJIT) compiler/bundle.lua $(STUB) $@
	chmod 755 $@

install: $(WILLOW)
	mkdir -p "$(HOME)/.local/bin"
	cp $(WILLOW) "$(HOME)/.local/bin/.willow.tmp"
	mv -f "$(HOME)/.local/bin/.willow.tmp" "$(HOME)/.local/bin/willow"

test: $(LUAJIT) $(STUB)
	$(LUAJIT) tests/run.lua $(wildcard tests/unit/*_test.lua) $(wildcard tests/programs/*.wlo) $(wildcard tests/modules/*/main.wlo)

bootstrap:
	cargo build --release --manifest-path bootstrap/stage0/Cargo.toml

bootstrap-test: bootstrap
	bootstrap/tests/run.sh
	bootstrap/tests/stage1.sh

clean:
	rm -f $(STUB)
	$(MAKE) -C $(LUAJIT_DIR) $(LUAJIT_FLAGS) clean

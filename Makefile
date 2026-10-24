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

# The bootstrap chain: willow0 builds stage 1, stage 1 builds stage 2, and
# stage 2 builds itself, which must emit the same IL as the stage 2 that
# stage 1 built.
WILLOW0 := bootstrap/stage0/target/release/willow0
STAGE1_SOURCES := $(wildcard bootstrap/stage1/*.wlo) bootstrap/core/core.wlo $(wildcard lib/*.wlo)
STAGE2_SOURCES := $(wildcard compiler/*.wlo) bootstrap/core/core.wlo $(wildcard lib/*.wlo)

bootstrap:
	cargo build --release --manifest-path bootstrap/stage0/Cargo.toml
	$(MAKE) $(BUILD_DIR)/willow2b
	$(BUILD_DIR)/willow2a compile $(BUILD_DIR)/stage2/willow.wlo -o $(BUILD_DIR)/stage2a.ssa
	$(BUILD_DIR)/willow2b compile $(BUILD_DIR)/stage2/willow.wlo -o $(BUILD_DIR)/stage2b.ssa
	cmp $(BUILD_DIR)/stage2a.ssa $(BUILD_DIR)/stage2b.ssa

$(BUILD_DIR)/willow1: $(WILLOW0) $(STAGE1_SOURCES)
	mkdir -p $(BUILD_DIR)
	rm -rf $(BUILD_DIR)/stage1
	bootstrap/prepare.sh bootstrap/stage1 $(BUILD_DIR)/stage1
	$(WILLOW0) build $(BUILD_DIR)/stage1/willow1.wlo -o $@

$(BUILD_DIR)/willow2a: $(BUILD_DIR)/willow1 $(STAGE2_SOURCES)
	rm -rf $(BUILD_DIR)/stage2
	bootstrap/prepare.sh compiler $(BUILD_DIR)/stage2
	$(BUILD_DIR)/willow1 build $(BUILD_DIR)/stage2/willow.wlo -o $@

$(BUILD_DIR)/willow2b: $(BUILD_DIR)/willow2a
	$(BUILD_DIR)/willow2a build $(BUILD_DIR)/stage2/willow.wlo -o $@

bootstrap-test: bootstrap
	bootstrap/tests/run.sh
	bootstrap/tests/stage1.sh
	bootstrap/tests/stage2.sh

clean:
	rm -f $(STUB)
	$(MAKE) -C $(LUAJIT_DIR) $(LUAJIT_FLAGS) clean

BUILD_DIR   := build
WILLOW      := $(BUILD_DIR)/willow

.PHONY: all test install clean bootstrap bootstrap-test

all: $(WILLOW)

install: $(WILLOW)
	mkdir -p "$(HOME)/.local/bin"
	cp $(WILLOW) "$(HOME)/.local/bin/.willow.tmp"
	mv -f "$(HOME)/.local/bin/.willow.tmp" "$(HOME)/.local/bin/willow"

# The conformance programs and willow command cases run through build/willow.
CONFORMANCE := $(wildcard tests/programs/*.wlo) $(wildcard tests/modules/*/main.wlo)
RUNNER := $(BUILD_DIR)/runner

test: $(WILLOW) $(RUNNER)
	$(RUNNER) $(WILLOW) $(CONFORMANCE) $(wildcard bootstrap/tests/commands/*/)

$(RUNNER): $(WILLOW) tests/runner.wlo
	$(WILLOW) build tests/runner.wlo -o $@

# The bootstrap chain: willow0 builds stage 1, stage 1 builds stage 2, and
# stage 2 builds itself, which must emit the same IL as the stage 2 that
# stage 1 built. build/willow is that last stage 2.
WILLOW0 := $(BUILD_DIR)/stage0/willow0
STAGE2_SOURCES := $(wildcard compiler/*.wlo) bootstrap/core/core.wlo $(wildcard lib/*.wlo)
# Stage 1 is the compiler's core modules with the L0 driver in bootstrap/stage1/.
STAGE1_SOURCES := $(wildcard bootstrap/stage1/*.wlo) $(STAGE2_SOURCES)

bootstrap: $(BUILD_DIR)/willow2b
	$(BUILD_DIR)/willow2a compile $(BUILD_DIR)/stage2/willow.wlo -o $(BUILD_DIR)/stage2a.ssa
	$(BUILD_DIR)/willow2b compile $(BUILD_DIR)/stage2/willow.wlo -o $(BUILD_DIR)/stage2b.ssa
	cmp $(BUILD_DIR)/stage2a.ssa $(BUILD_DIR)/stage2b.ssa

$(BUILD_DIR)/stage0/core.inc: bootstrap/core/core.wlo
	mkdir -p $(BUILD_DIR)/stage0
	sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/?/\\?/g' -e 's/^/"/' -e 's/$$/\\n"/' $< > $@

$(WILLOW0): $(wildcard bootstrap/stage0/*.c) bootstrap/stage0/willow0.h $(BUILD_DIR)/stage0/core.inc
	$(CC) -std=c11 -Wall -Wextra -O2 $(wildcard bootstrap/stage0/*.c) -o $@

$(BUILD_DIR)/willow1: $(WILLOW0) bootstrap/prepare.sh $(STAGE1_SOURCES)
	mkdir -p $(BUILD_DIR)
	rm -rf $(BUILD_DIR)/stage1
	bootstrap/prepare.sh compiler $(BUILD_DIR)/stage1
	cp bootstrap/stage1/*.wlo $(BUILD_DIR)/stage1/
	$(WILLOW0) build $(BUILD_DIR)/stage1/willow1.wlo -o $@

$(BUILD_DIR)/willow2a: $(BUILD_DIR)/willow1 bootstrap/prepare.sh $(STAGE2_SOURCES)
	rm -rf $(BUILD_DIR)/stage2
	bootstrap/prepare.sh compiler $(BUILD_DIR)/stage2
	$(BUILD_DIR)/willow1 build $(BUILD_DIR)/stage2/willow.wlo -o $@

$(BUILD_DIR)/willow2b: $(BUILD_DIR)/willow2a
	$(BUILD_DIR)/willow2a build $(BUILD_DIR)/stage2/willow.wlo -o $@

# Copying over the old binary in place makes macOS kill the new one on launch,
# because the kernel keeps the old file's code signature; replace it instead.
$(WILLOW): $(BUILD_DIR)/willow2b
	cp $(BUILD_DIR)/willow2b $@.tmp
	mv -f $@.tmp $@

# Stage 0's L0 programs and core tests, stage 2's own tests, and then make
# test.
bootstrap-test: bootstrap $(RUNNER)
	$(RUNNER) --build $(WILLOW0) $(wildcard bootstrap/tests/programs/*.wlo) $(wildcard bootstrap/tests/core/*.wlo)
	bootstrap/tests/stage2.sh
	$(MAKE) test

clean:
	rm -rf $(BUILD_DIR)

LUAJIT_REPO := https://github.com/LuaJIT/LuaJIT.git
LUAJIT_REV  := 634daf2453559fd5e0ec282f3b7aedaa09e9f344
LUAJIT_DIR  := vendor/luajit
LUAJIT      := $(LUAJIT_DIR)/src/luajit

ifeq ($(shell uname -s),Darwin)
LUAJIT_FLAGS := MACOSX_DEPLOYMENT_TARGET=11.0
endif

.PHONY: all test clean

all: $(LUAJIT)

$(LUAJIT_DIR):
	git clone $(LUAJIT_REPO) $(LUAJIT_DIR)
	git -C $(LUAJIT_DIR) checkout -q $(LUAJIT_REV)

$(LUAJIT): | $(LUAJIT_DIR)
	$(MAKE) -C $(LUAJIT_DIR) $(LUAJIT_FLAGS)

test: $(LUAJIT)
	$(LUAJIT) tests/run.lua $(wildcard tests/unit/*_test.lua) $(wildcard tests/programs/*.wlo)

clean:
	$(MAKE) -C $(LUAJIT_DIR) $(LUAJIT_FLAGS) clean

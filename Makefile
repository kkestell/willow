LUAJIT_REPO := https://github.com/LuaJIT/LuaJIT.git
LUAJIT_REV  := 634daf2453559fd5e0ec282f3b7aedaa09e9f344
LUAJIT_DIR  := vendor/luajit
LUAJIT      := $(LUAJIT_DIR)/src/luajit
STUB        := runtime/stub

ifeq ($(shell uname -s),Darwin)
LUAJIT_FLAGS := MACOSX_DEPLOYMENT_TARGET=11.0
else
STUB_LIBS := -lm -ldl
endif

.PHONY: all test clean

all: $(LUAJIT) $(STUB)

$(LUAJIT_DIR):
	git clone $(LUAJIT_REPO) $(LUAJIT_DIR)
	git -C $(LUAJIT_DIR) checkout -q $(LUAJIT_REV)

$(LUAJIT): | $(LUAJIT_DIR)
	$(MAKE) -C $(LUAJIT_DIR) $(LUAJIT_FLAGS)

$(STUB): runtime/stub.c $(LUAJIT)
	$(LUAJIT_FLAGS) $(CC) -O2 -I$(LUAJIT_DIR)/src -o $@ runtime/stub.c $(LUAJIT_DIR)/src/libluajit.a $(STUB_LIBS)

test: $(LUAJIT) $(STUB)
	$(LUAJIT) tests/run.lua $(wildcard tests/unit/*_test.lua) $(wildcard tests/programs/*.wlo) $(wildcard tests/modules/*/main.wlo)

clean:
	rm -f $(STUB)
	$(MAKE) -C $(LUAJIT_DIR) $(LUAJIT_FLAGS) clean

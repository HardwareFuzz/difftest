#***************************************************************************************
# Copyright (c) 2020-2025 Institute of Computing Technology, Chinese Academy of Sciences
# Copyright (c) 2025 Beijing Institute of Open Source Chip (BOSC)
# Copyright (c) 2020-2021 Peng Cheng Laboratory
#
# DiffTest is licensed under Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#          http://license.coscl.org.cn/MulanPSL2
#
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
# EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
# MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
#
# See the Mulan PSL v2 for more details.
#***************************************************************************************

NOOP_HOME  ?= $(abspath .)
export NOOP_HOME
MILL ?= $(if $(wildcard $(NOOP_HOME)/mill),$(NOOP_HOME)/mill,mill)

SIM_TOP    ?= SimTop
DESIGN_DIR ?= $(NOOP_HOME)

BUILD_DIR  ?= $(DESIGN_DIR)/build

RTL_DIR = $(BUILD_DIR)/rtl
RTL_SUFFIX ?= sv
SIM_TOP_V = $(RTL_DIR)/$(SIM_TOP).$(RTL_SUFFIX)
SIM_TOP_FIR = $(RTL_DIR)/$(SIM_TOP).fir

$(SIM_TOP_V): $(SIM_TOP_FIR)
	@set -e; \
	if [ -f "$@" ]; then exit 0; fi; \
	firtool_bin="${FIRTOOL:-}"; \
	if [ -z "$$firtool_bin" ]; then \
		if [ -x "$$HOME/.cache/llvm-firtool/1.135.0/bin/firtool" ]; then \
			firtool_bin="$$HOME/.cache/llvm-firtool/1.135.0/bin/firtool"; \
		else \
			for p in "$$HOME"/.cache/llvm-firtool/*/bin/firtool; do \
				if [ -x "$$p" ]; then firtool_bin="$$p"; fi; \
			done; \
		fi; \
	fi; \
	if [ -z "$$firtool_bin" ] || [ ! -x "$$firtool_bin" ]; then \
		echo "[error] firtool not found. Set FIRTOOL or install llvm-firtool cache under ~/.cache/llvm-firtool" >&2; \
		exit 1; \
	fi; \
	"$$firtool_bin" "$<" --verilog -o "$@" \
		-O=release \
		--disable-annotation-unknown \
		--lowering-options=explicitBitcast,disallowLocalVariables,disallowPortDeclSharing,locationInfoStyle=none \
		--default-layer-specialization=enable

# generate difftest files for non-chisel design.
.DEFAULT_GOAL := difftest_verilog

MILL_ARGS += --target systemverilog --split-verilog

ifneq ($(PROFILE), )
MILL_ARGS += --profile $(abspath $(PROFILE))
endif
ifneq ($(NUM_CORES), )
MILL_ARGS += --num-cores $(NUM_CORES)
endif
ifneq ($(CONFIG), )
MILL_ARGS += --difftest-config $(CONFIG)
endif
difftest_verilog:
	MILL_WORKSPACE_ROOT="$(NOOP_HOME)" BUILD_DIR="$(BUILD_DIR)" \
		$(MILL) -i difftest.test.runMain difftest.DifftestMain --target-dir $(RTL_DIR) $(MILL_ARGS)

TIMELOG = $(BUILD_DIR)/time.log
TIME_CMD = time -avp -o $(TIMELOG)

# remote machine with more cores to speedup c++ build
REMOTE ?= localhost

# simulation
SIM_CONFIG_DIR = $(abspath ./config)
SIM_CSRC_DIR = $(abspath ./src/test/csrc/common)
SIM_CXXFILES = $(shell find $(SIM_CSRC_DIR) -name "*.cpp") $(shell find $(SIM_CONFIG_DIR) -name "*.cpp")
SIM_CXXFLAGS = -I$(SIM_CSRC_DIR) -I$(SIM_CONFIG_DIR)

SIM_CXXFLAGS += -DNOOP_HOME=\\\"$(NOOP_HOME)\\\"

# generated-src
GEN_CSRC_DIR  = $(BUILD_DIR)/generated-src
NOOP_GEN_CSRC_DIR = $(abspath $(NOOP_HOME)/build/generated-src)
GEN_REQUIRED_FILES = difftest-dpic.cpp difftest-dpic.h difftest-query.h difftest-state.h DifftestMacros.svh
GEN_REQUIRED_PATHS = $(addprefix $(GEN_CSRC_DIR)/,$(GEN_REQUIRED_FILES))
GEN_CSRC_DPIC = $(GEN_CSRC_DIR)/difftest-dpic.cpp
GEN_CSRC_CPP = $(shell find $(GEN_CSRC_DIR) -name "*.cpp" 2> /dev/null)
SIM_CXXFILES += $(GEN_CSRC_DPIC) $(filter-out $(GEN_CSRC_DPIC),$(GEN_CSRC_CPP))
SIM_CXXFLAGS += -I$(GEN_CSRC_DIR)

.PHONY: prepare-generated-src
ifeq ($(NO_DIFF),1)
prepare-generated-src:
	@:
else
prepare-generated-src:
	@set -e; \
	need_gen=0; \
	tmp_gen_dir="$(BUILD_DIR)/.difftest_gen"; \
	for f in $(GEN_REQUIRED_FILES); do \
		if [ ! -f "$(GEN_CSRC_DIR)/$$f" ]; then \
			need_gen=1; \
			break; \
		fi; \
	done; \
	if [ "$$need_gen" = "1" ]; then \
		$(MAKE) BUILD_DIR="$$tmp_gen_dir" difftest_verilog NUM_CORES=$(NUM_CORES) CONFIG="$(CONFIG)" RTL_SUFFIX=$(RTL_SUFFIX); \
		for f in $(GEN_REQUIRED_FILES); do \
			if [ -f "$$tmp_gen_dir/generated-src/$$f" ]; then \
				mkdir -p "$(GEN_CSRC_DIR)"; \
				cp -f "$$tmp_gen_dir/generated-src/$$f" "$(GEN_CSRC_DIR)/$$f"; \
			fi; \
		done; \
	fi; \
	mkdir -p "$(GEN_CSRC_DIR)"; \
	missing=0; \
	for f in $(GEN_REQUIRED_FILES); do \
		if [ ! -f "$(GEN_CSRC_DIR)/$$f" ]; then \
			missing=1; \
			break; \
		fi; \
	done; \
	if [ "$$missing" = "1" ] && [ "$(abspath $(GEN_CSRC_DIR))" != "$(abspath $(NOOP_GEN_CSRC_DIR))" ]; then \
		for f in $(GEN_REQUIRED_FILES); do \
			if [ -f "$(NOOP_GEN_CSRC_DIR)/$$f" ]; then \
				cp -f "$(NOOP_GEN_CSRC_DIR)/$$f" "$(GEN_CSRC_DIR)/$$f"; \
			fi; \
		done; \
	fi; \
	for f in $(GEN_REQUIRED_FILES); do \
		test -f "$(GEN_CSRC_DIR)/$$f"; \
	done
endif

ifneq ($(NO_DIFF),1)
$(GEN_REQUIRED_PATHS): prepare-generated-src
	@test -f "$@"
endif

PLUGIN_CSRC_DIR = $(abspath ./src/test/csrc/plugin)
PLUGIN_INC_DIR  = $(abspath $(PLUGIN_CSRC_DIR)/include)
SIM_CXXFLAGS   += -I$(PLUGIN_INC_DIR)

GEN_VSRC_DIR = $(BUILD_DIR)/generated-src
VSRC_DIR   = $(abspath ./src/test/vsrc/common)
SIM_VSRC = $(shell find $(VSRC_DIR) -name "*.v" -or -name "*.sv")

ifneq ($(NUM_CORES),)
SIM_CXXFLAGS += -DNUM_CORES=$(NUM_CORES)
endif

# DiffTest support
DIFFTEST_CSRC_DIR = $(abspath ./src/test/csrc/difftest)
# FPGA-Difftest support
ifeq ($(FPGA),1)
$(info FPGA is enabled. ChiselDB and ConstantIn are implicitly disabled.)
WITH_CHISELDB = 0
WITH_CONSTANTIN = 0
endif

DIFFTEST_CXXFILES = $(shell find $(DIFFTEST_CSRC_DIR) -name "*.cpp")
ifeq ($(NO_DIFF), 1)
SIM_CXXFLAGS += -DCONFIG_NO_DIFFTEST
else
SIM_CXXFILES += $(DIFFTEST_CXXFILES)
SIM_CXXFLAGS += -I$(DIFFTEST_CSRC_DIR)
SIM_VFLAGS   += +define+DIFFTEST
ifeq ($(DIFFTEST_PERFCNT), 1)
SIM_CXXFLAGS += -DCONFIG_DIFFTEST_PERFCNT
endif
ifeq ($(DIFFTEST_CHECKER_PERF), 1)
SIM_CXXFLAGS += -DCONFIG_DIFFTEST_CHECKER_PERF
endif 
ifeq ($(DIFFTEST_QUERY), 1)
SIM_CXXFLAGS += -DCONFIG_DIFFTEST_QUERY
SIM_LDFLAGS  += -lsqlite3
endif
endif

ifeq ($(SYNTHESIS), 1)
SIM_VFLAGS   += +define+SYNTHESIS +define+TB_NO_DPIC
else  # SYNTHESIS != 1
# DiffTest MemHelper
ifeq ($(DISABLE_DIFFTEST_RAM_DPIC), 1)
SIM_VFLAGS   += +define+DISABLE_DIFFTEST_RAM_DPIC
endif
# DiffTest FlashHelper
ifeq ($(DISABLE_DIFFTEST_FLASH_DPIC), 1)
SIM_VFLAGS   += +define+DISABLE_DIFFTEST_FLASH_DPIC
endif
# SimJTAG
ifeq ($(DISABLE_SIMJTAG_DPIC), 1)
SIM_VFLAGS   += +define+DISABLE_SIMJTAG_DPIC
endif
# Chisel-generated macro for assertion printf
ifneq ($(ASSERT_VERBOSE_COND),)
SIM_VFLAGS   += +define+ASSERT_VERBOSE_COND=$(ASSERT_VERBOSE_COND)
endif
# Chisel-generated macro for SVA
ifneq ($(STOP_COND),)
SIM_VFLAGS   += +define+STOP_COND=$(STOP_COND)
endif
endif # SYNTHESIS

# FPGA DiffTest Simulate Support
ifeq ($(FPGA_SIM), 1)
FPGA_SIM_CSRC_DIR = $(abspath ./src/test/csrc/fpga_sim)
FPGA_SIM_VSRC_DIR = $(abspath ./src/test/vsrc/fpga_sim)
SIM_CXXFILES += $(shell find $(FPGA_SIM_CSRC_DIR) -name "*.cpp")
SIM_CXXFLAGS += -I$(FPGA_SIM_CSRC_DIR) -DFPGA_SIM
SIM_LDFLAGS  += -lrt
SIM_VFLAGS   += +define+FPGA_SIM
SIM_VSRC     += $(shell find $(FPGA_SIM_VSRC_DIR) -name "*.v" -or -name "*.sv")
ifneq ($(ASYNC_CLK_2N), )
SIM_VFLAGS   += +define+ASYNC_CLK_2N=$(ASYNC_CLK_2N)
endif
endif

# Third-party RTL include files
define handle_rtl_include_path
  $(if $(wildcard $1/*), \
    -y $(abspath $1), \
    $(if $(wildcard $1), \
      $(if $(filter %.f,$1), \
        -F $(abspath $1), \
        $(abspath $1) \
      ) \
    ) \
  )
endef
ifneq ($(RTL_INCLUDE),)
SIM_VFLAGS += $(foreach p,$(RTL_INCLUDE),$(call handle_rtl_include_path,$(p)))
endif

# ChiselDB
WITH_CHISELDB ?= 1
ifeq ($(WITH_CHISELDB), 1)
SIM_CXXFILES += $(BUILD_DIR)/chisel_db.cpp
SIM_CXXFLAGS += -I$(BUILD_DIR) -DENABLE_CHISEL_DB
SIM_LDFLAGS  += -lsqlite3
ifneq ($(wildcard $(BUILD_DIR)/perfCCT.cpp),)
SIM_CXXFILES += $(BUILD_DIR)/perfCCT.cpp
endif
endif

# ConstantIn
WITH_CONSTANTIN ?= 1
ifeq ($(WITH_CONSTANTIN), 1)
SIM_CXXFILES += $(BUILD_DIR)/constantin.cpp
SIM_CXXFLAGS += -I$(BUILD_DIR) -DENABLE_CONSTANTIN
endif

ifeq ($(WITH_IPC), 1)
SIM_CXXFLAGS += -I$(BUILD_DIR) -DENABLE_IPC
endif

# REF SELECTION
REF ?= Nemu
ifneq ($(REF),)
ifneq ($(wildcard $(REF)),)
SIM_CXXFLAGS += -DREF_PROXY=LinkedProxy -DLINKED_REFPROXY_LIB=\\\"$(REF)\\\"
SIM_LDFLAGS  += $(REF)
else
SIM_CXXFLAGS += -DREF_PROXY=$(REF)Proxy
REF_HOME_VAR = $(shell echo $(REF)_HOME | tr a-z A-Z)
ifneq ($(origin $(REF_HOME_VAR)), undefined)
SIM_CXXFLAGS += -DREF_HOME=\\\"$(shell echo $$$(REF_HOME_VAR))\\\"
endif
endif
endif

# co-simulation with DRAMsim3
ifeq ($(WITH_DRAMSIM3),1)
ifndef DRAMSIM3_HOME
$(error DRAMSIM3_HOME is not set)
endif
SIM_CXXFLAGS += -I$(DRAMSIM3_HOME)/src
SIM_CXXFLAGS += -DWITH_DRAMSIM3 -DDRAMSIM3_CONFIG=\\\"$(DRAMSIM3_HOME)/configs/XiangShan.ini\\\" -DDRAMSIM3_OUTDIR=\\\"$(BUILD_DIR)\\\"
SIM_LDFLAGS  += -L$(DRAMSIM3_HOME)/build -ldramsim3
endif

# out ipc info on temporary txt file, mainly applied to support qemu multi-core sampled data
ifneq ($(OUTPUT_CPI_TO_FILE),)
SIM_CXXFLAGS += -DOUTPUT_CPI_TO_FILE=$(OUTPUT_CPI_TO_FILE)
endif

ifeq ($(PMEM_CHECK),1)
SIM_CXXFLAGS += -DPMEM_CHECK
endif

ifeq ($(RELEASE),1)
SIM_CXXFLAGS += -DBASIC_DIFFTEST_ONLY
endif

# VGA support
ifeq ($(SHOW_SCREEN),1)
SIM_CXXFLAGS += $(shell sdl2-config --cflags) -DSHOW_SCREEN
SIM_LDFLAGS  += -lSDL2
endif

# GZ image support
IMAGE_GZ_COMPRESS ?= 1
ifeq ($(IMAGE_GZ_COMPRESS),0)
SIM_CXXFLAGS += -DNO_GZ_COMPRESSION
else
SIM_LDFLAGS  += -lz
endif

# ZSTD image support
ifneq ($(NO_ZSTD_COMPRESSION),)
SIM_CXXFLAGS += -DNO_ZSTD_COMPRESSION
else
SIM_LDFLAGS  += -lzstd
endif

# Elf image support
IMAGE_ELF ?= 1
ifeq ($(IMAGE_ELF),0)
SIM_CXXFLAGS += -DNO_IMAGE_ELF
endif

# spike-dasm plugin
WITH_SPIKE_DASM ?= 1
ifeq ($(WITH_SPIKE_DASM),1)
SIM_CXXFLAGS += -I$(abspath $(PLUGIN_CSRC_DIR)/spikedasm)
SIM_CXXFILES += $(shell find $(PLUGIN_CSRC_DIR)/spikedasm -name "*.cpp")
endif

# runahead support
ifeq ($(WITH_RUNAHEAD),1)
SIM_CXXFLAGS += -I$(abspath $(PLUGIN_CSRC_DIR)/runahead)
SIM_CXXFILES += $(shell find $(PLUGIN_CSRC_DIR)/runahead -name "*.cpp")
endif

# SimFrontend plugin
ifeq ($(ENABLE_SIMFRONTEND), 1)
TRACE_CSR_DIR = $(abspath ./src/test/csrc/plugin/simfrontend)
SIM_CXXFILES += $(shell find $(TRACE_CSR_DIR) -name "*.cpp")
SIM_CXXFLAGS += -I$(TRACE_CSR_DIR) -DPLUGIN_SIMFRONTEND
endif


# Check if XFUZZ is set
ifeq ($(XFUZZ), 1)
XFUZZ_HOME_VAR = XFUZZ_HOME
ifeq ($(origin $(XFUZZ_HOME_VAR)), undefined)
$(error $(XFUZZ_HOME_VAR) is not set)
endif
FUZZER_LIB   = $(shell echo $$$(XFUZZ_HOME_VAR))/target/release/libfuzzer.a
SIM_LDFLAGS += -lrt -lpthread
endif

# Link fuzzer libraries
ifneq ($(FUZZER_LIB), )
SIM_CXXFLAGS += -DFUZZER_LIB
SIM_LDFLAGS  += $(abspath $(FUZZER_LIB))
FUZZING       = 1
endif

# Fuzzer support
ifeq ($(FUZZING),1)
SIM_CXXFLAGS += -DFUZZING
endif

# FIRRTL Coverage support
ifneq ($(FIRRTL_COVER),)
SIM_CXXFLAGS += -DFIRRTL_COVER
endif

# LLVM Sanitizer Coverage support
ifneq ($(LLVM_COVER),)
SIM_CXXFLAGS += -DLLVM_COVER
SIM_LDFLAGS  += -fsanitize-coverage=trace-pc-guard -fsanitize-coverage=pc-table
endif

ifeq ($(IOTRACE_ZSTD),1)
SIM_CXXFLAGS += -DCONFIG_IOTRACE_ZSTD
endif

# Do not allow compiler warnings
ifeq ($(CXX_NO_WARNING),1)
SIM_CXXFLAGS += -Werror
endif

include emu.mk
include vcs.mk
include galaxsim.mk
include palladium.mk
include libso.mk
include fpga.mk
include pdb.mk

clean: vcs-clean pldm-clean fpga-clean
	rm -rf $(BUILD_DIR)

format: scala-format clang-format

scala-format:
	$(MILL) -i mill.scalalib.scalafmt.ScalafmtModule/reformatAll __.sources

CLANG_FORMAT_VER = 18.1.4
clang-format:
ifeq ($(shell clang-format --version 2> /dev/null| cut -f3 -d' ' | tr '.' '_'), $(shell echo $(CLANG_FORMAT_VER) | tr '.' '_'))
	clang-format -i $(shell find ./src/test/csrc -name "*.cpp" -or -name "*.h" -or -name "*.inc")
else
	@echo "Required clang-format Version: $(CLANG_FORMAT_VER)"
	@echo "Your Version: $(shell clang-format --version)"
	@echo "Please run \"pip install --user clang-format==$(CLANG_FORMAT_VER)\", then set PATH manually"
endif

.PHONY: sim-verilog emu difftest_verilog clean format scala-format clang-format

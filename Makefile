# =============================================================================
# Makefile – FIR Filter FPGA Project
# =============================================================================
# Targets:
#   make all       – Full flow: coeffs → compile → simulate → verify
#   make coeffs    – Generate Python signal + design coefficients
#   make compile   – GHDL compile all VHDL sources
#   make sim       – Run all GHDL testbenches
#   make sim-fir   – Run only the FIR filter unit testbench
#   make sim-rx    – Run only the UART RX unit testbench
#   make sim-tx    – Run only the UART TX unit testbench
#   make sim-top   – Run only the integration testbench
#   make verify    – Run Python verification + plot generation
#   make wave      – Open GTKWave with the FIR testbench VCD
#   make clean     – Remove all generated files
# =============================================================================

PYTHON    := python3
GHDL      := ghdl
GTKWAVE   := gtkwave

GHDL_STD  := --std=08
GHDL_OPTS := --ieee=synopsys -frelaxed-rules

# ── Directories ───────────────────────────────────────────────────────────────
SRC_VHDL  := src/vhdl
SIM_VHDL  := sim/vhdl
DATA_DIR  := data
OUT_DIR   := output
WORK_DIR  := $(OUT_DIR)/ghdl_work
PLOTS_DIR := $(OUT_DIR)/plots
PY_DIR    := src/python

# ── VHDL source files (in dependency order) ────────────────────────────────
VHDL_SRCS := \
    $(SRC_VHDL)/coefficients.vhd \
    $(SRC_VHDL)/fir_filter.vhd \
    $(SRC_VHDL)/uart_rx.vhd \
    $(SRC_VHDL)/uart_tx.vhd \
    $(SRC_VHDL)/uart_framing.vhd \
    $(SRC_VHDL)/clock_divider.vhd \
    $(SRC_VHDL)/fir_top.vhd

# ── Testbench files ───────────────────────────────────────────────────────────
TB_FIR    := $(SIM_VHDL)/tb_fir_filter.vhd
TB_RX     := $(SIM_VHDL)/tb_uart_rx.vhd
TB_TX     := $(SIM_VHDL)/tb_uart_tx.vhd
TB_TOP    := $(SIM_VHDL)/tb_fir_top.vhd

# ── VCD output files ──────────────────────────────────────────────────────────
VCD_FIR   := $(OUT_DIR)/tb_fir_filter.vcd
VCD_RX    := $(OUT_DIR)/tb_uart_rx.vcd
VCD_TX    := $(OUT_DIR)/tb_uart_tx.vcd
VCD_TOP   := $(OUT_DIR)/tb_fir_top.vcd

# ── Default target ─────────────────────────────────────────────────────────────
.PHONY: all
all: coeffs compile sim verify
	@echo ""
	@echo "============================================"
	@echo "  BUILD COMPLETE"
	@echo "  Plots saved to: $(PLOTS_DIR)/"
	@echo "  VCD files in:   $(OUT_DIR)/"
	@echo "  View waveforms: make wave"
	@echo "============================================"

# ── Step 1: Generate Python signal + coefficients ─────────────────────────────
.PHONY: coeffs
coeffs: $(DATA_DIR)/input_signal.txt $(SRC_VHDL)/coefficients.vhd

$(DATA_DIR)/input_signal.txt: $(PY_DIR)/generate_signal.py
	@mkdir -p $(DATA_DIR)
	$(PYTHON) $<

$(SRC_VHDL)/coefficients.vhd $(DATA_DIR)/coefficients.txt: $(PY_DIR)/design_coefficients.py
	@mkdir -p $(DATA_DIR) $(SRC_VHDL)
	$(PYTHON) $<

# ── Step 2: GHDL Compilation ──────────────────────────────────────────────────
.PHONY: compile
compile: $(DATA_DIR)/input_signal.txt $(SRC_VHDL)/coefficients.vhd
	@mkdir -p $(WORK_DIR)
	@echo "--- Compiling VHDL sources ---"
	@for src in $(VHDL_SRCS) $(TB_FIR) $(TB_RX) $(TB_TX) $(TB_TOP); do \
	    echo "  $(GHDL) -a $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) $$src"; \
	    $(GHDL) -a $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) $$src || exit 1; \
	done
	@echo "--- Compilation complete ---"

# ── Step 3: GHDL Simulation ───────────────────────────────────────────────────
.PHONY: sim
sim: sim-fir sim-rx sim-tx sim-top

.PHONY: sim-fir
sim-fir: compile
	@mkdir -p $(OUT_DIR)
	@echo "--- Simulating tb_fir_filter ---"
	$(GHDL) -e $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) tb_fir_filter
	$(GHDL) -r $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) tb_fir_filter \
	    --vcd=$(VCD_FIR) --stop-time=5ms
	@echo "VCD → $(VCD_FIR)"

.PHONY: sim-rx
sim-rx: compile
	@mkdir -p $(OUT_DIR)
	@echo "--- Simulating tb_uart_rx ---"
	$(GHDL) -e $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) tb_uart_rx
	$(GHDL) -r $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) tb_uart_rx \
	    --vcd=$(VCD_RX) --stop-time=2ms
	@echo "VCD → $(VCD_RX)"

.PHONY: sim-tx
sim-tx: compile
	@mkdir -p $(OUT_DIR)
	@echo "--- Simulating tb_uart_tx ---"
	$(GHDL) -e $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) tb_uart_tx
	$(GHDL) -r $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) tb_uart_tx \
	    --vcd=$(VCD_TX) --stop-time=2ms
	@echo "VCD → $(VCD_TX)"

.PHONY: sim-top
sim-top: compile
	@mkdir -p $(OUT_DIR)
	@echo "--- Simulating tb_fir_top (integration) ---"
	$(GHDL) -e $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) tb_fir_top
	$(GHDL) -r $(GHDL_STD) $(GHDL_OPTS) --workdir=$(WORK_DIR) tb_fir_top \
	    --vcd=$(VCD_TOP) --stop-time=200ms
	@echo "VCD → $(VCD_TOP)"

# ── Step 4: Python verification + plots ──────────────────────────────────────
.PHONY: verify
verify:
	@mkdir -p $(PLOTS_DIR)
	$(PYTHON) $(PY_DIR)/verify_output.py

# ── Open GTKWave ──────────────────────────────────────────────────────────────
.PHONY: wave
wave: $(VCD_FIR)
	$(GTKWAVE) $(VCD_FIR) &

.PHONY: wave-top
wave-top: $(VCD_TOP)
	$(GTKWAVE) $(VCD_TOP) &

# ── UART simulator self-test ──────────────────────────────────────────────────
.PHONY: uart-test
uart-test:
	$(PYTHON) $(PY_DIR)/uart_sim.py

# ── Install Python dependencies ───────────────────────────────────────────────
.PHONY: install
install:
	pip install -r requirements.txt

# ── Clean ─────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -rf $(OUT_DIR)
	rm -f $(SRC_VHDL)/coefficients.vhd
	rm -f $(DATA_DIR)/input_signal.txt
	rm -f $(DATA_DIR)/output_signal.txt
	rm -f $(DATA_DIR)/coefficients.txt
	rm -f e~*.o *.o work-*.cf
	@echo "--- Clean complete ---"

.PHONY: clean-all
clean-all: clean
	rm -rf __pycache__ src/python/__pycache__

# ── Help ──────────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "FIR Filter FPGA Project – Available targets:"
	@echo "  make all       Full simulation flow"
	@echo "  make coeffs    Generate signal + FIR coefficients"
	@echo "  make compile   GHDL compile all VHDL files"
	@echo "  make sim       Run all GHDL testbenches"
	@echo "  make sim-fir   FIR filter unit test only"
	@echo "  make sim-rx    UART RX unit test only"
	@echo "  make sim-tx    UART TX unit test only"
	@echo "  make sim-top   Integration testbench only"
	@echo "  make verify    Python verification + plots"
	@echo "  make wave      Open GTKWave (FIR testbench)"
	@echo "  make wave-top  Open GTKWave (integration testbench)"
	@echo "  make uart-test Run UART simulator self-test"
	@echo "  make install   Install Python dependencies"
	@echo "  make clean     Remove generated files"

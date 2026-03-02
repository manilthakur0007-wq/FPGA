# =============================================================================
# fir_top.xdc – Xilinx Artix-7 Pin Constraints
# Target Board: Digilent Basys 3 (xc7a35tcpg236-1)
# =============================================================================
# This constraints file shows how fir_top.vhd would map to a real FPGA board.
# For simulation-only use, this file is informational only.
# To use with Vivado: add to project constraints and run Implementation.
# =============================================================================

# ── System Clock (100 MHz oscillator) ─────────────────────────────────────────
set_property PACKAGE_PIN W5  [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports sys_clk]

# ── Reset Button (active-high, BTNC on Basys 3) ───────────────────────────────
set_property PACKAGE_PIN U18 [get_ports rst_btn]
set_property IOSTANDARD LVCMOS33 [get_ports rst_btn]

# ── UART (USB-UART bridge on Basys 3 – FTDI FT2232H) ─────────────────────────
# RX: data coming FROM the PC (UART RX on FPGA side = UART TX on PC side)
set_property PACKAGE_PIN B18 [get_ports uart_rx_pin]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_pin]

# TX: data going TO the PC
set_property PACKAGE_PIN A18 [get_ports uart_tx_pin]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_pin]

# ── Status LEDs (LD0..LD3 on Basys 3) ────────────────────────────────────────
# LD0: RX activity
set_property PACKAGE_PIN U16 [get_ports led_rx]
set_property IOSTANDARD LVCMOS33 [get_ports led_rx]

# LD1: TX activity
set_property PACKAGE_PIN E19 [get_ports led_tx]
set_property IOSTANDARD LVCMOS33 [get_ports led_tx]

# LD2: Locked (out of reset)
set_property PACKAGE_PIN U19 [get_ports led_locked]
set_property IOSTANDARD LVCMOS33 [get_ports led_locked]

# LD3: Overflow / checksum error
set_property PACKAGE_PIN V19 [get_ports led_overflow]
set_property IOSTANDARD LVCMOS33 [get_ports led_overflow]

# =============================================================================
# Timing Constraints
# =============================================================================

# False paths on asynchronous inputs (reset button, UART RX)
# These cross into the synchronised clock domain via the 2-FF synchronisers
set_false_path -from [get_ports rst_btn]
set_false_path -from [get_ports uart_rx_pin]

# UART TX output (asynchronous relative to receiver clock)
set_false_path -to [get_ports uart_tx_pin]

# LED outputs (no tight timing requirement)
set_false_path -to [get_ports led_*]

# =============================================================================
# Configuration settings
# =============================================================================
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

# Enable bitstream compression
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# =============================================================================
# Deployment Notes
# =============================================================================
# 1. Open Vivado → Create Project → RTL Project
# 2. Add source files:
#      src/vhdl/*.vhd (including auto-generated coefficients.vhd)
# 3. Add constraints: fir_top.xdc
# 4. Set top-level entity: fir_top
# 5. Run Synthesis → Implementation → Generate Bitstream
# 6. Program the device via Vivado Hardware Manager
#
# Expected resource utilization on Artix-7 xc7a35t:
#   LUTs:        ~150 (FIR filter + UART + framing)
#   FFs:         ~200
#   DSP48E1:     ~16  (one per FIR tap, for multiply-accumulate)
#   BRAM:        0    (all registers)
#   Fmax:        >100 MHz (comfortably meets timing at 100 MHz)
# =============================================================================

# FPGA Digital FIR Filter with UART Interface

A production-quality, simulation-ready FIR low-pass filter implemented in VHDL, with a Python testbench that generates noisy sine wave input, sends it through a simulated UART interface, and plots the filtered vs unfiltered output.

**Runs entirely in simulation — no physical FPGA hardware required.**

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Python Layer                                     │
│                                                                         │
│  generate_signal.py  →  50 Hz sine + AWGN noise (SNR=10 dB), 256 smpls │
│  design_coefficients.py  →  16-tap Hamming LP FIR, Q1.15 fixed-point    │
│  uart_sim.py          →  Software UART reference model (encode/decode)   │
│  verify_output.py     →  SNR comparison, RMSE, 4 diagnostic plots        │
└──────────────────┬───────────────────────────────────────┬──────────────┘
                   │  data/input_signal.txt                │  data/output_signal.txt
                   ▼                                       ▲
┌─────────────────────────────────────────────────────────────────────────┐
│                         VHDL Simulation (GHDL)                          │
│                                                                         │
│  tb_fir_top.vhd                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                      fir_top.vhd                                 │   │
│  │                                                                  │   │
│  │  uart_rx ──► uart_framing_rx ──► fir_filter ──► uart_framing_tx ──► uart_tx │
│  │                                                                  │   │
│  │  clock_divider   reset_sync   status LEDs                        │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  Testbenches: tb_fir_filter, tb_uart_rx, tb_uart_tx, tb_fir_top        │
│  Waveforms:   output/*.vcd  (view in GTKWave)                           │
└─────────────────────────────────────────────────────────────────────────┘
```

### Full Data Path

```
[Python]                    [VHDL Simulation]                    [Python]
  │                               │                                 │
  │  50Hz + noise (int16)         │                                 │
  ├─► input_signal.txt ──────────►│                                 │
  │                          uart_rx (deserialize 8N1)             │
  │                               │ rx_done pulse                   │
  │                          uart_framing_rx (frame→sample)        │
  │                               │ sample_valid + signed(15:0)     │
  │                          fir_filter (16-tap MAC)               │
  │                               │ valid_out + signed(15:0)        │
  │                          uart_framing_tx (sample→frame)        │
  │                               │ 4 bytes: AA|MSB|LSB|CS         │
  │                          uart_tx (serialize 8N1)               │
  │                               │                                 │
  │                          output_signal.txt ────────────────────►│
  │                                                                 │
  │                                                           verify_output.py
  │                                                           • SNR before/after
  │                                                           • RMSE vs SciPy ref
  │                                                           • 4 diagnostic plots
```

---

## FIR Filter Theory

### What is a FIR Filter?

A **Finite Impulse Response (FIR)** filter computes its output as a weighted sum of the current and past N-1 input samples:

```
y[n] = h[0]·x[n] + h[1]·x[n-1] + h[2]·x[n-2] + ... + h[N-1]·x[n-N+1]
     = Σ_{k=0}^{N-1} h[k] · x[n-k]
```

This is the **discrete-time convolution** of the input signal x[n] with the impulse response h[k].

### Why FIR over IIR?

| Property | FIR | IIR |
|----------|-----|-----|
| Stability | Always stable (finite coefficients) | Can become unstable |
| Phase response | Linear phase possible | Non-linear |
| FPGA implementation | Simple shift register + MACs | Feedback paths (more complex) |
| Impulse response | Finite duration | Infinite (recursive) |

### Frequency Response

The frequency response is the Discrete-Time Fourier Transform of h[k]:

```
H(e^jω) = Σ_{k=0}^{N-1} h[k] · e^{-jωk}
```

For a **Hamming-windowed** low-pass filter, the ideal sinc function is multiplied by the Hamming window:

```
w[n] = 0.54 - 0.46 · cos(2πn / (N-1))    (Hamming window)
h[n] = w[n] · sinc(2·fc/fs · (n - (N-1)/2))
```

This reduces the passband ripple to < 0.02 dB and achieves > 40 dB stopband attenuation.

### This Project's Filter

- **16 taps**, Hamming window
- **Cutoff frequency**: 500 Hz
- **Sample rate**: 8,000 Hz (Nyquist = 4,000 Hz)
- **Signal frequency**: 50 Hz (well within passband)
- **Noise**: broadband (passes through the entire spectrum)
- **Effect**: passes 50 Hz signal, rejects noise above 500 Hz → SNR improves ≥ 15 dB

---

## Fixed-Point Arithmetic (Q1.15 Format)

### Why Fixed-Point?

FPGAs do not have native floating-point hardware (without IP cores). Fixed-point arithmetic uses integer DSP blocks (DSP48E1 on Xilinx) for efficient multiply-accumulate.

### Q1.15 Format

**Q-format** notation: Q(integer bits).(fractional bits)

```
Q1.15: 1 sign bit + 0 integer bits + 15 fractional bits
Range: [-1.0, +1.0 - 2^-15]  =  [-1.0, +0.999969]
Resolution: 2^-15 ≈ 3.05 × 10^-5
```

A coefficient value `h` is stored as the integer `round(h × 32768)`:

```python
h_float  =  0.053671          # float coefficient
h_q115   =  round(0.053671 × 32768)  =  1759   # stored in 16-bit signed int
# To recover: 1759 / 32768 = 0.053680  (tiny quantization error)
```

### Multiply-Accumulate in VHDL

```
Product width = DATA_WIDTH + COEFF_WIDTH = 16 + 16 = 32 bits
Accumulator  = 32 + 5 guard bits = 37 bits (prevents overflow for 16 taps)

After summing all taps:
  accumulated_result = Σ x[n-k] × h[k]   (in Q(DATA-1).(COEFF-1) format)

Output (Q1.15 → Q0.15): right-shift by 15 bits, clip to 16 bits
```

### Overflow Handling

For a unity-gain LP filter:
- Sum of coefficients ≈ 1.0 in float → ≈ 32768 in Q1.15
- Maximum output magnitude ≤ maximum input magnitude
- 5 guard bits support up to 2^5 = 32 simultaneous full-scale inputs

The VHDL implementation uses **saturating arithmetic** in the output stage to prevent wrap-around if overflow does occur.

---

## UART Framing Protocol

### 8N1 Bit Protocol

```
Idle: ─────────────────────────────────────────────────
        _____
Start:       |                                         |
             |_______                         _________|
             S   D0   D1   D2   D3   D4   D5   D6   D7   P

Each bit period = 1/baud_rate seconds
  At 115200 baud: 8.68 µs per bit, 86.8 µs per byte
```

### Frame Format (4 bytes per 16-bit sample)

```
Byte 0:  0xAA         ← Start/sync byte (constant)
Byte 1:  sample[15:8] ← MSB of signed 16-bit sample
Byte 2:  sample[7:0]  ← LSB of signed 16-bit sample
Byte 3:  checksum     ← 0xAA XOR MSB XOR LSB

Total: 4 × 10 bits = 40 bit-periods per sample
At 115200 baud: 40 × 8.68 µs = 347 µs per sample
Maximum sample rate: 1/347µs ≈ 2,882 samples/sec
```

### Checksum Calculation

```python
checksum = 0xAA ^ msb ^ lsb   # simple XOR checksum
```

The XOR checksum detects any single-byte corruption within the frame.

### Example Frame for Sample = 1000 (0x03E8)

```
Byte 0: 0xAA  = 10101010b  ← sync
Byte 1: 0x03  = 00000011b  ← MSB
Byte 2: 0xE8  = 11101000b  ← LSB
Byte 3: 0xAA ^ 0x03 ^ 0xE8 = 0x41 = 01000001b  ← checksum
```

---

## Project Structure

```
fir_filter_fpga/
├── src/
│   ├── vhdl/
│   │   ├── fir_filter.vhd       Direct-Form I FIR, parameterized, pipelined
│   │   ├── uart_rx.vhd          8N1 UART receiver with 2-FF synchroniser
│   │   ├── uart_tx.vhd          8N1 UART transmitter
│   │   ├── uart_framing.vhd     16-bit sample ↔ 4-byte frame encode/decode
│   │   ├── fir_top.vhd          Top-level: full RX→FIR→TX pipeline
│   │   ├── clock_divider.vhd    Clock enable generator
│   │   └── coefficients.vhd    [AUTO-GENERATED by design_coefficients.py]
│   └── python/
│       ├── generate_signal.py   50Hz + AWGN, quantized to int16
│       ├── design_coefficients.py  firwin → Q1.15 → VHD/TXT output
│       ├── verify_output.py     SNR/RMSE comparison + 4 plots
│       ├── uart_sim.py          Python UART frame encode/decode reference
│       └── run_simulation.py    Master orchestration script
├── sim/
│   └── vhdl/
│       ├── tb_fir_filter.vhd    Unit test: impulse/step/noisy-sine
│       ├── tb_uart_rx.vhd       Unit test: 8N1 deserialization
│       ├── tb_uart_tx.vhd       Unit test: 8N1 serialization
│       └── tb_fir_top.vhd       Integration: full UART→FIR→UART pipeline
├── data/                        [AUTO-GENERATED]
│   ├── input_signal.txt         256 noisy sine samples
│   ├── coefficients.txt         Q1.15 coefficient values
│   └── output_signal.txt        VHDL simulation output
├── output/                      [AUTO-GENERATED]
│   ├── plots/                   PNG diagnostic plots
│   └── *.vcd                   GTKWave waveform files
├── fir_top.xdc                  Xilinx Artix-7 pin constraints
├── Makefile                     Build automation
├── requirements.txt             Python dependencies
└── .gitignore
```

---

## Quick Start

### Prerequisites

**1. GHDL** (free, open-source VHDL simulator):
```bash
# Ubuntu/Debian
sudo apt install ghdl

# macOS (Homebrew)
brew install ghdl

# Windows: download from https://github.com/ghdl/ghdl/releases
# Extract and add to PATH

# Verify installation
ghdl --version
```

**2. GTKWave** (optional, for waveform viewing):
```bash
# Ubuntu/Debian
sudo apt install gtkwave

# macOS
brew install gtkwave
```

**3. Python 3.8+ with dependencies**:
```bash
pip install -r requirements.txt
# Installs: numpy, scipy, matplotlib
```

### Run the Full Simulation

```bash
# Clone / navigate to project
cd fir_filter_fpga

# Full flow: generate → design → compile → simulate → verify → plot
make all

# Or step by step:
make coeffs      # Generate signal + FIR coefficients
make compile     # GHDL compile all VHDL files
make sim         # Run all testbenches
make verify      # Compare output + generate plots
```

### Run Without GHDL (Python-only mode)

```bash
python src/python/run_simulation.py --skip-ghdl
# Generates plots using SciPy reference filter (no VHDL simulation)
```

### View Waveforms

```bash
make wave        # Open GTKWave with FIR filter testbench VCD
make wave-top    # Open GTKWave with integration testbench VCD
```

### Test Individual Components

```bash
make sim-fir     # FIR filter unit test
make sim-rx      # UART RX unit test
make sim-tx      # UART TX unit test
make sim-top     # Full integration test

# Python UART reference model self-test
make uart-test
```

---

## Expected Results

### SNR Improvement

| Metric | Value |
|--------|-------|
| Input SNR (noisy 50 Hz) | ~10 dB |
| Output SNR (filtered) | ≥25 dB |
| SNR improvement | **≥15 dB** |
| VHDL vs SciPy RMSE | < 5 ADC counts |

### Filter Specifications

| Parameter | Value |
|-----------|-------|
| Filter type | FIR low-pass |
| Window | Hamming |
| Number of taps | 16 |
| Cutoff frequency | 500 Hz |
| Sample rate | 8,000 Hz |
| Passband ripple | < 0.02 dB |
| Stopband attenuation | > 40 dB |
| Group delay | 7.5 samples (linear phase) |

### Output Plots

| Plot | Description |
|------|-------------|
| `time_domain.png` | Input (noisy) vs SciPy ref vs VHDL output |
| `spectrum.png` | FFT before/after filtering |
| `filter_response.png` | Bode plot: magnitude (dB) + phase |
| `impulse_response.png` | Float coefficients vs Q1.15 quantized |

---

## VHDL Module Details

### fir_filter.vhd

**Architecture:** Direct-Form I (shift register + MAC)

```
Input x[n] ──► [z^-1] ──► [z^-1] ──► ... ──► [z^-1]
               h[0] ×      h[1] ×              h[N-1] ×
                  \          \                    /
                   └──────────┴────────────── Σ ──► y[n]
```

**Pipeline stages:**
1. **Shift register** (1 clock): insert new sample, shift history
2. **Multiply** (combinatorial): compute all N products simultaneously
3. **Accumulate** (1 clock): sum all products with adder tree
4. **Round/truncate** (1 clock): Q1.15 → Q0.0, saturating clip

**Latency:** 3 clock cycles (after all N taps filled)
**Throughput:** 1 sample per clock

### uart_rx.vhd

**FSM states:**
```
IDLE ──(falling edge)──► START_BIT ──(mid-point OK)──► DATA_BITS
                                    └──(glitch)──► IDLE
DATA_BITS ──(8 bits done)──► STOP_BIT ──(stop=1)──► DONE ──► IDLE
                                        └──(stop=0, framing error)──► IDLE
```

**2-FF synchroniser** prevents metastability on the asynchronous RX input.
**Sampling point:** centre of each bit period (CLKS_PER_BIT/2 offset, then CLKS_PER_BIT intervals).

### uart_framing.vhd

**TX path (uart_framing_tx):**
```
sample_valid ──► [latch sample] ──► send 0xAA ──► send MSB ──► send LSB ──► send CS ──► frame_done
```

**RX path (uart_framing_rx):**
```
rx_done bytes ──► HUNT(0xAA) ──► MSB ──► LSB ──► CHECKSUM ──► sample_valid
                 └──(wrong byte: sync_err)
                                               └──(bad CS: checksum_err)
```

---

## Baud Rate Configuration

The UART baud rate is set via the `CLKS_PER_BIT` generic:

| Baud Rate | CLKS_PER_BIT (100 MHz) | CLKS_PER_BIT (50 MHz) |
|-----------|------------------------|------------------------|
| 9,600     | 10,417                 | 5,208                  |
| 115,200   | 868                    | 434                    |
| 1,000,000 | 100                    | 50                     |

To change baud rate in the top-level:
```vhdl
-- In fir_top.vhd generic map or via the BAUD_RATE generic:
generic map (
    SYS_CLK_HZ => 100_000_000,
    BAUD_RATE  => 9_600         -- change this
)
```

---

## Hardware Deployment (Xilinx Artix-7)

### Resource Estimate (post-synthesis)

| Resource | Used | Available (xc7a35t) | % |
|----------|------|---------------------|---|
| LUT | ~150 | 20,800 | 0.7% |
| FF | ~200 | 41,600 | 0.5% |
| DSP48E1 | 16 | 90 | 18% |
| BRAM | 0 | 50 | 0% |

Each FIR tap uses one DSP48E1 for the multiply-accumulate operation.

### Deployment Steps

1. **Generate coefficients** (only needed once per filter design):
   ```bash
   make coeffs
   # This creates src/vhdl/coefficients.vhd
   ```

2. **Open Vivado**, create a new RTL project targeting `xc7a35tcpg236-1`

3. **Add source files:**
   - All `.vhd` files from `src/vhdl/`
   - Constraints: `fir_top.xdc`
   - Set top-level entity: `fir_top`

4. **Run Synthesis → Implementation → Generate Bitstream**

5. **Program via Vivado Hardware Manager** (USB cable to FPGA board)

6. **Test with a terminal emulator** (e.g., PuTTY or minicom) at 115200 baud,
   or use the `uart_sim.py` Python script to encode/decode samples.

### Pin Mapping (Basys 3 Board)

| Signal | FPGA Pin | Location |
|--------|----------|----------|
| `sys_clk` | W5 | 100 MHz oscillator |
| `rst_btn` | U18 | BTNC (center button) |
| `uart_rx_pin` | B18 | USB-UART RX |
| `uart_tx_pin` | A18 | USB-UART TX |
| `led_rx` | U16 | LD0 |
| `led_tx` | E19 | LD1 |
| `led_locked` | U19 | LD2 |
| `led_overflow` | V19 | LD3 |

---

## Design Decisions & Trade-offs

### Direct-Form I vs. Transposed Direct-Form II

This project uses **Direct-Form I** for clarity and teachability. Transposed Direct-Form II has better numerical properties (smaller intermediate values) and is sometimes preferred in IIR filters. For a 16-tap FIR, the difference is negligible.

### Combinatorial Multiply vs. Pipelined

All 16 multiplications are done combinatorially in a single clock cycle and summed in the next. For 16 taps at 100 MHz on Artix-7, this comfortably meets timing. For >64 taps or very high clock frequencies, a pipelined adder tree would be necessary.

### Clock Enable vs. Divided Clock

The `clock_divider.vhd` generates a **clock enable** (one pulse per sample period) rather than an actual divided clock. This is the recommended FPGA design practice:
- No clock domain crossing issues
- Works with vendor timing analysis tools
- Synthesizes more efficiently than BUFG-based clock division

### Why GHDL over ModelSim?

GHDL is free, open-source, and supports VHDL-2008. ModelSim requires a license for full functionality. GHDL produces identical simulation results and integrates seamlessly with GTKWave for waveform viewing.

---

## Troubleshooting

### GHDL compilation errors

```
# If you see: "fir_coefficients_pkg not found"
# Run: make coeffs  (to generate coefficients.vhd first)
make coeffs && make compile
```

### Python import errors

```bash
pip install -r requirements.txt
# If scipy not found:
pip install scipy numpy matplotlib
```

### Output file not found

```
# data/output_signal.txt missing after simulation?
# The VHDL testbench writes it. Run:
make sim-fir    # or make sim-top
# Then verify:
make verify
```

### GHDL segfault on Windows

Install the MSYS2-based GHDL release or use WSL2 (Ubuntu):
```bash
# WSL2
wsl --install -d Ubuntu
# Inside WSL:
sudo apt install ghdl gtkwave python3-pip
pip3 install -r requirements.txt
make all
```

---

## References

- Proakis & Manolakis, *Digital Signal Processing* (4th ed.) — FIR filter design
- Oppenheim & Schafer, *Discrete-Time Signal Processing* — Windowing methods
- IEEE Std 1076-2008 — VHDL Language Reference Manual
- Xilinx UG901 — Vivado Design Suite User Guide: HDL Coding Guidelines
- GHDL documentation: https://ghdl.github.io/ghdl/
- SciPy `signal.firwin`: https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.firwin.html

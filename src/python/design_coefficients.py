#!/usr/bin/env python3
"""
design_coefficients.py
----------------------
Designs a 16-tap Hamming-windowed FIR low-pass filter (cutoff 500 Hz, fs 8 kHz)
using scipy.signal.firwin, quantizes coefficients to Q1.15 fixed-point format,
and writes:
  • src/vhdl/coefficients.vhd  – VHDL constant array (auto-generated)
  • data/coefficients.txt      – Plain text for reference / Python verification
"""

import os
import numpy as np
from scipy.signal import firwin, freqz

# ── Filter parameters ─────────────────────────────────────────────────────────
NUM_TAPS     = 16
FS           = 8_000          # Sample rate (Hz)
F_CUTOFF     = 500            # Cutoff frequency (Hz)
COEFF_WIDTH  = 16             # Bit width (Q1.15 → range [-1, 1))
Q_SCALE      = 2 ** (COEFF_WIDTH - 1)   # 32768 (Q1.15 scale factor)

# ── Output paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
VHD_FILE     = os.path.join(PROJECT_ROOT, "src", "vhdl", "coefficients.vhd")
TXT_FILE     = os.path.join(PROJECT_ROOT, "data", "coefficients.txt")


def design_filter(num_taps: int, f_cutoff: float, fs: float) -> np.ndarray:
    """Design Hamming-windowed FIR LP filter, return float coefficients."""
    nyq = fs / 2.0
    h = firwin(num_taps, f_cutoff / nyq, window="hamming")
    print(f"[design_coefficients] Filter: {num_taps} taps, fc={f_cutoff} Hz, fs={fs} Hz")
    print(f"[design_coefficients] Float coefficient sum = {np.sum(h):.6f} (should be ≈1.0)")
    return h


def quantize_q115(h: np.ndarray, q_scale: int) -> np.ndarray:
    """Quantize float coefficients to Q1.15 signed integers."""
    # Clip to [-1, 1) before quantization
    h_clipped = np.clip(h, -1.0, 1.0 - 1.0 / q_scale)
    h_q = np.round(h_clipped * q_scale).astype(np.int32)
    # Verify no overflow
    assert np.all(np.abs(h_q) < q_scale), "Q1.15 overflow detected!"
    quant_error = np.max(np.abs(h - h_q / q_scale))
    print(f"[design_coefficients] Max quantization error = {quant_error:.2e}")
    return h_q


def compute_frequency_response(h: np.ndarray, fs: float):
    """Return (frequencies_hz, magnitude_dB) for the filter."""
    w, H = freqz(h, worN=1024, fs=fs)
    mag_db = 20 * np.log10(np.abs(H) + 1e-12)
    return w, mag_db


def write_vhdl(h_q: np.ndarray, h_float: np.ndarray, filepath: str) -> None:
    """Write a self-contained VHDL package with the coefficient array."""
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    n = len(h_q)

    lines = [
        "-- ============================================================",
        "-- coefficients.vhd  (AUTO-GENERATED – do not edit manually)",
        "-- FIR LP filter coefficients in Q1.15 signed fixed-point",
        f"-- NUM_TAPS={n}, fc={F_CUTOFF} Hz, fs={FS} Hz, window=Hamming",
        "-- ============================================================",
        "library ieee;",
        "use ieee.std_logic_1164.all;",
        "use ieee.numeric_std.all;",
        "",
        "package fir_coefficients_pkg is",
        "",
        f"    constant NUM_TAPS   : integer := {n};",
        f"    constant COEFF_WIDTH : integer := {COEFF_WIDTH};",
        "",
        f"    type coeff_array_t is array (0 to {n - 1}) of",
        "        signed(COEFF_WIDTH - 1 downto 0);",
        "",
        "    -- Coefficients in Q1.15 format (divide by 32768 for float value)",
        "    constant FIR_COEFFS : coeff_array_t := (",
    ]

    for i, (cq, cf) in enumerate(zip(h_q, h_float)):
        comma = "," if i < n - 1 else " "
        lines.append(
            f"        {i:2d} => to_signed({int(cq):7d}, COEFF_WIDTH){comma}"
            f"  -- {cf:+.6f}"
        )

    lines += [
        "    );",
        "",
        "end package fir_coefficients_pkg;",
        "",
    ]

    with open(filepath, "w") as f:
        f.write("\n".join(lines))
    print(f"[design_coefficients] VHDL coefficients → {filepath}")


def write_txt(h_q: np.ndarray, h_float: np.ndarray, filepath: str) -> None:
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, "w") as f:
        f.write("# FIR Filter Coefficients (Q1.15 format)\n")
        f.write(f"# NUM_TAPS={NUM_TAPS}, fc={F_CUTOFF} Hz, fs={FS} Hz\n")
        f.write("# Columns: index  Q1.15_integer  float_value\n")
        for i, (cq, cf) in enumerate(zip(h_q, h_float)):
            f.write(f"{i:2d}  {int(cq):7d}  {cf:+.8f}\n")
    print(f"[design_coefficients] Text coefficients → {filepath}")


def main():
    h_float = design_filter(NUM_TAPS, F_CUTOFF, FS)
    h_q     = quantize_q115(h_float, Q_SCALE)
    write_vhdl(h_q, h_float, VHD_FILE)
    write_txt(h_q, h_float, TXT_FILE)
    return h_float, h_q


if __name__ == "__main__":
    main()

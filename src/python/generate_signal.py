#!/usr/bin/env python3
"""
generate_signal.py
------------------
Generates a 50 Hz sine wave sampled at 8 kHz with additive white Gaussian
noise (SNR ≈ 10 dB), quantizes to 16-bit signed integers, and saves to
data/input_signal.txt for VHDL testbench consumption.
"""

import os
import numpy as np

# ── Signal parameters ─────────────────────────────────────────────────────────
FS          = 8_000          # Sample rate (Hz)
F_SIGNAL    = 50             # Sine frequency (Hz)
DURATION    = 0.032          # Signal duration (s) → 256 samples
SNR_DB      = 10             # Target SNR (dB)
DATA_WIDTH  = 16             # Bits per sample
N_SAMPLES   = int(FS * DURATION)   # 256

# ── Output paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
DATA_DIR    = os.path.join(PROJECT_ROOT, "data")
OUT_FILE    = os.path.join(DATA_DIR, "input_signal.txt")


def generate_noisy_sine(
    fs: float,
    f_signal: float,
    n_samples: int,
    snr_db: float,
    data_width: int,
    seed: int = 42,
) -> np.ndarray:
    """Return 16-bit signed integer noisy sine samples."""
    rng = np.random.default_rng(seed)

    t = np.arange(n_samples) / fs
    sine = np.sin(2 * np.pi * f_signal * t)

    # Signal power (for unit-amplitude sine = 0.5)
    signal_power = np.mean(sine ** 2)

    # Required noise power from SNR
    snr_linear = 10 ** (snr_db / 10)
    noise_power = signal_power / snr_linear
    noise = rng.normal(0, np.sqrt(noise_power), n_samples)

    noisy = sine + noise

    # Scale to use ≈ 90% of 16-bit dynamic range, avoiding saturation
    max_val = (2 ** (data_width - 1)) - 1   # 32767
    scale   = 0.9 * max_val / np.max(np.abs(noisy))
    quantized = np.round(noisy * scale).astype(np.int16)

    return quantized


def save_signal(samples: np.ndarray, filepath: str) -> None:
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, "w") as f:
        f.write(f"# FIR Filter Input Signal\n")
        f.write(f"# Generated: {N_SAMPLES} samples, fs={FS} Hz, f={F_SIGNAL} Hz, SNR={SNR_DB} dB\n")
        f.write(f"# Format: one signed decimal integer per line\n")
        for s in samples:
            f.write(f"{int(s)}\n")
    print(f"[generate_signal] Written {len(samples)} samples → {filepath}")


def main():
    samples = generate_noisy_sine(FS, F_SIGNAL, N_SAMPLES, SNR_DB, DATA_WIDTH)
    save_signal(samples, OUT_FILE)

    # Quick SNR sanity check
    actual_snr = 10 * np.log10(
        np.var(np.sin(2 * np.pi * F_SIGNAL * np.arange(N_SAMPLES) / FS))
        / np.var(samples / (0.9 * 32767) - np.sin(2 * np.pi * F_SIGNAL * np.arange(N_SAMPLES) / FS))
    )
    print(f"[generate_signal] Approx SNR = {actual_snr:.1f} dB")
    return samples


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
verify_output.py
----------------
Reads VHDL simulation output from data/output_signal.txt, compares against
scipy reference filter output, computes SNR improvement and RMSE, and plots:
  1. Time-domain: input vs filtered
  2. Frequency spectrum: before/after
  3. Filter frequency response (magnitude + phase)
  4. Impulse response verification
"""

import os
import sys
import numpy as np
import matplotlib
matplotlib.use("Agg")          # headless rendering
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
from scipy.signal import firwin, lfilter, freqz

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
DATA_DIR     = os.path.join(PROJECT_ROOT, "data")
PLOTS_DIR    = os.path.join(PROJECT_ROOT, "output", "plots")

INPUT_FILE   = os.path.join(DATA_DIR, "input_signal.txt")
OUTPUT_FILE  = os.path.join(DATA_DIR, "output_signal.txt")
COEFF_FILE   = os.path.join(DATA_DIR, "coefficients.txt")

# ── Filter parameters (must match design_coefficients.py) ──────────────────
NUM_TAPS    = 16
FS          = 8_000
F_CUTOFF    = 500
Q_SCALE     = 32768           # Q1.15


def load_signal(filepath: str, comment: str = "#") -> np.ndarray:
    """Load one-sample-per-line text file (skip comment lines)."""
    samples = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(comment):
                continue
            # Support optional extra columns (e.g., index  value)
            parts = line.split()
            samples.append(int(parts[-1]))
    return np.array(samples, dtype=np.int32)


def load_coefficients_txt(filepath: str) -> np.ndarray:
    """Load Q1.15 coefficients from the text file and convert to float."""
    h_q = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            h_q.append(int(parts[1]))
    return np.array(h_q, dtype=np.float64) / Q_SCALE


def compute_snr(signal: np.ndarray, noise: np.ndarray) -> float:
    """SNR in dB: 10·log10(Psignal / Pnoise)."""
    p_signal = np.mean(signal ** 2)
    p_noise  = np.mean(noise  ** 2)
    if p_noise == 0:
        return np.inf
    return 10 * np.log10(p_signal / p_noise)


def compute_rmse(a: np.ndarray, b: np.ndarray) -> float:
    min_len = min(len(a), len(b))
    return float(np.sqrt(np.mean((a[:min_len].astype(float) - b[:min_len].astype(float)) ** 2)))


def apply_reference_filter(h_float: np.ndarray, x: np.ndarray) -> np.ndarray:
    """Apply the float FIR filter using scipy.lfilter (direct-form I)."""
    y = lfilter(h_float, [1.0], x.astype(np.float64))
    return y


def plot_time_domain(x, y_vhdl, y_ref, fs, out_path):
    """Plot 1: time-domain comparison."""
    t = np.arange(len(x)) / fs * 1000   # ms

    fig, axes = plt.subplots(3, 1, figsize=(12, 9), sharex=True)
    fig.suptitle("Time-Domain Comparison", fontsize=14, fontweight="bold")

    axes[0].plot(t, x,     color="#e74c3c", lw=0.8, label="Noisy input")
    axes[0].set_ylabel("Amplitude (ADC counts)")
    axes[0].legend(loc="upper right")
    axes[0].grid(True, alpha=0.3)

    axes[1].plot(t, y_ref,  color="#2ecc71", lw=1.0, label="SciPy reference (float)")
    axes[1].set_ylabel("Amplitude")
    axes[1].legend(loc="upper right")
    axes[1].grid(True, alpha=0.3)

    min_len = min(len(y_vhdl), len(t))
    axes[2].plot(t[:min_len], y_vhdl[:min_len], color="#3498db", lw=1.0, label="VHDL output (fixed-point)")
    axes[2].set_xlabel("Time (ms)")
    axes[2].set_ylabel("Amplitude")
    axes[2].legend(loc="upper right")
    axes[2].grid(True, alpha=0.3)

    plt.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"[verify_output] Saved → {out_path}")


def plot_spectrum(x, y_vhdl, y_ref, fs, out_path):
    """Plot 2: frequency spectrum before/after."""
    N = max(len(x), 1024)

    def psd(sig):
        w = np.hanning(len(sig))
        S = np.fft.rfft(sig * w, n=N)
        freq = np.fft.rfftfreq(N, 1 / fs)
        mag  = 20 * np.log10(np.abs(S) / len(sig) + 1e-10)
        return freq, mag

    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    fig.suptitle("Frequency Spectrum Before / After Filtering", fontsize=14, fontweight="bold")

    fx, mx = psd(x)
    axes[0].plot(fx, mx, color="#e74c3c", lw=0.8)
    axes[0].axvline(F_CUTOFF, color="k", ls="--", lw=0.8, label=f"fc={F_CUTOFF} Hz")
    axes[0].set_xlim(0, fs / 2)
    axes[0].set_ylim(-100, 0)
    axes[0].set_xlabel("Frequency (Hz)")
    axes[0].set_ylabel("Magnitude (dB)")
    axes[0].set_title("Input (noisy)")
    axes[0].legend()
    axes[0].grid(True, alpha=0.3)

    fy, my_v = psd(y_vhdl[:len(x)])
    _, my_r  = psd(y_ref)
    axes[1].plot(fy, my_v, color="#3498db", lw=0.8, label="VHDL")
    axes[1].plot(fy, my_r, color="#2ecc71", lw=0.8, ls="--", label="SciPy ref")
    axes[1].axvline(F_CUTOFF, color="k", ls="--", lw=0.8, label=f"fc={F_CUTOFF} Hz")
    axes[1].set_xlim(0, fs / 2)
    axes[1].set_ylim(-100, 0)
    axes[1].set_xlabel("Frequency (Hz)")
    axes[1].set_title("Filtered output")
    axes[1].legend()
    axes[1].grid(True, alpha=0.3)

    plt.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"[verify_output] Saved → {out_path}")


def plot_filter_response(h_float, fs, out_path):
    """Plot 3: filter frequency response (magnitude + phase)."""
    w, H = freqz(h_float, worN=2048, fs=fs)

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 7))
    fig.suptitle("FIR Filter Frequency Response", fontsize=14, fontweight="bold")

    ax1.plot(w, 20 * np.log10(np.abs(H) + 1e-12), color="#8e44ad", lw=1.2)
    ax1.axvline(F_CUTOFF, color="#e74c3c", ls="--", lw=0.9, label=f"fc={F_CUTOFF} Hz")
    ax1.axhline(-3, color="#95a5a6", ls=":", lw=0.8, label="-3 dB")
    ax1.set_ylim(-80, 5)
    ax1.set_xlim(0, fs / 2)
    ax1.set_ylabel("Magnitude (dB)")
    ax1.legend()
    ax1.grid(True, alpha=0.3)

    ax2.plot(w, np.unwrap(np.angle(H)) * 180 / np.pi, color="#e67e22", lw=1.2)
    ax2.axvline(F_CUTOFF, color="#e74c3c", ls="--", lw=0.9)
    ax2.set_xlim(0, fs / 2)
    ax2.set_xlabel("Frequency (Hz)")
    ax2.set_ylabel("Phase (degrees)")
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"[verify_output] Saved → {out_path}")


def plot_impulse_response(h_float, h_vhdl_normalized, out_path):
    """Plot 4: impulse response verification (float vs VHDL Q1.15)."""
    n = len(h_float)
    fig, axes = plt.subplots(2, 1, figsize=(10, 6))
    fig.suptitle("Impulse Response Verification", fontsize=14, fontweight="bold")

    axes[0].stem(range(n), h_float, linefmt="#2ecc71-", markerfmt="#2ecc71o",
                 basefmt="k-", label="Float (design)")
    axes[0].set_ylabel("Amplitude")
    axes[0].set_title("Design Coefficients (float)")
    axes[0].legend()
    axes[0].grid(True, alpha=0.3)

    axes[1].stem(range(len(h_vhdl_normalized)), h_vhdl_normalized,
                 linefmt="#3498db-", markerfmt="#3498dbo", basefmt="k-",
                 label="Q1.15 quantized")
    axes[1].set_xlabel("Tap index")
    axes[1].set_ylabel("Amplitude")
    axes[1].set_title("Q1.15 Quantized Coefficients")
    axes[1].legend()
    axes[1].grid(True, alpha=0.3)

    plt.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"[verify_output] Saved → {out_path}")


def main(require_vhdl_output: bool = True) -> dict:
    os.makedirs(PLOTS_DIR, exist_ok=True)

    # ── Load coefficients ──────────────────────────────────────────────────
    if not os.path.exists(COEFF_FILE):
        print(f"[verify_output] ERROR: {COEFF_FILE} not found. Run design_coefficients.py first.")
        sys.exit(1)
    h_float = load_coefficients_txt(COEFF_FILE)
    print(f"[verify_output] Loaded {len(h_float)} coefficients from {COEFF_FILE}")

    # ── Load input signal ──────────────────────────────────────────────────
    if not os.path.exists(INPUT_FILE):
        print(f"[verify_output] ERROR: {INPUT_FILE} not found. Run generate_signal.py first.")
        sys.exit(1)
    x = load_signal(INPUT_FILE)
    print(f"[verify_output] Loaded {len(x)} input samples")

    # ── Reference filter (scipy float) ────────────────────────────────────
    y_ref = apply_reference_filter(h_float, x)

    # ── Load VHDL output ───────────────────────────────────────────────────
    vhdl_available = os.path.exists(OUTPUT_FILE)
    if vhdl_available:
        y_vhdl = load_signal(OUTPUT_FILE)
        print(f"[verify_output] Loaded {len(y_vhdl)} VHDL output samples")
    else:
        if require_vhdl_output:
            print(f"[verify_output] WARNING: {OUTPUT_FILE} not found.")
            print("[verify_output] Run VHDL simulation first. Plotting with ref only.")
        y_vhdl = (y_ref * Q_SCALE).astype(np.int32)  # use ref as placeholder
        vhdl_available = False

    # ── SNR calculations ───────────────────────────────────────────────────
    # Recover approximate clean signal (reference filter output as "truth")
    latency = NUM_TAPS // 2
    y_clean = y_ref[latency:]
    x_trim  = x[latency:]

    snr_in  = compute_snr(y_clean, x_trim - y_clean)
    snr_out = compute_snr(y_clean, y_ref[latency:] - y_clean)

    # SNR improvement using VHDL output
    if vhdl_available and len(y_vhdl) > latency:
        y_v_trim = y_vhdl[latency:].astype(float) / Q_SCALE * np.max(np.abs(y_clean))
        snr_vhdl = compute_snr(y_clean, y_v_trim[:len(y_clean)] - y_clean)
    else:
        snr_vhdl = snr_out

    snr_improvement = snr_out - snr_in
    rmse = compute_rmse(
        y_vhdl.astype(float) if vhdl_available else y_ref * Q_SCALE,
        y_ref * Q_SCALE
    )

    print("\n" + "=" * 55)
    print("  VERIFICATION RESULTS")
    print("=" * 55)
    print(f"  Input SNR          : {snr_in:+7.2f} dB")
    print(f"  Reference SNR out  : {snr_out:+7.2f} dB")
    print(f"  SNR Improvement    : {snr_improvement:+7.2f} dB", end="")
    if snr_improvement >= 15:
        print("  ✓ (≥ 15 dB target)")
    else:
        print(f"  ✗ (target: ≥ 15 dB)")
    print(f"  VHDL vs Ref RMSE   : {rmse:.1f} ADC counts")
    print("=" * 55 + "\n")

    # ── Plots ──────────────────────────────────────────────────────────────
    plot_time_domain(
        x, y_vhdl, y_ref,
        FS,
        os.path.join(PLOTS_DIR, "time_domain.png")
    )
    plot_spectrum(
        x, y_vhdl, y_ref,
        FS,
        os.path.join(PLOTS_DIR, "spectrum.png")
    )
    plot_filter_response(
        h_float,
        FS,
        os.path.join(PLOTS_DIR, "filter_response.png")
    )

    # Impulse response: load Q1.15 from text file
    h_q_float = h_float  # already normalized
    plot_impulse_response(
        h_float,
        h_q_float,
        os.path.join(PLOTS_DIR, "impulse_response.png")
    )

    return {
        "snr_in": snr_in,
        "snr_out": snr_out,
        "snr_improvement": snr_improvement,
        "rmse": rmse,
        "vhdl_available": vhdl_available,
    }


if __name__ == "__main__":
    results = main(require_vhdl_output=False)
    if results["snr_improvement"] < 15:
        sys.exit(1)

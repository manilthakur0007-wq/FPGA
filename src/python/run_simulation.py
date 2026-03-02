#!/usr/bin/env python3
"""
run_simulation.py
-----------------
Master script that orchestrates the full simulation flow:

  1. generate_signal.py   – Create noisy sine input
  2. design_coefficients.py – Design + quantize FIR coefficients
  3. GHDL compilation     – Compile all VHDL sources
  4. GHDL simulation      – Run testbenches, dump VCD + output files
  5. verify_output.py     – Compare VHDL vs SciPy, plot results

Usage:
  python run_simulation.py [--skip-ghdl] [--tb {all,fir,uart_rx,uart_tx,top}]

Options:
  --skip-ghdl   Skip GHDL steps (useful if GHDL is not installed)
  --tb NAME     Run only the specified testbench (default: all)
"""

import os
import sys
import subprocess
import argparse
import shutil
from pathlib import Path

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR   = Path(__file__).parent.resolve()
PROJECT_ROOT = (SCRIPT_DIR / ".." / "..").resolve()
SRC_VHDL     = PROJECT_ROOT / "src" / "vhdl"
SIM_VHDL     = PROJECT_ROOT / "sim" / "vhdl"
DATA_DIR     = PROJECT_ROOT / "data"
OUTPUT_DIR   = PROJECT_ROOT / "output"
WORK_DIR     = OUTPUT_DIR / "ghdl_work"

# ── VHDL source order (dependency order matters for GHDL) ──────────────────
VHDL_SOURCES = [
    SRC_VHDL / "coefficients.vhd",      # generated package – must be first
    SRC_VHDL / "fir_filter.vhd",
    SRC_VHDL / "uart_rx.vhd",
    SRC_VHDL / "uart_tx.vhd",
    SRC_VHDL / "uart_framing.vhd",
    SRC_VHDL / "clock_divider.vhd",
    SRC_VHDL / "fir_top.vhd",
]

TESTBENCHES = {
    "fir":     SIM_VHDL / "tb_fir_filter.vhd",
    "uart_rx": SIM_VHDL / "tb_uart_rx.vhd",
    "uart_tx": SIM_VHDL / "tb_uart_tx.vhd",
    "top":     SIM_VHDL / "tb_fir_top.vhd",
}

TB_TOPS = {
    "fir":     "tb_fir_filter",
    "uart_rx": "tb_uart_rx",
    "uart_tx": "tb_uart_tx",
    "top":     "tb_fir_top",
}

GHDL_STD = "--std=08"
GHDL_OPTS = ["--ieee=synopsys", "-frelaxed-rules"]


def run(cmd, cwd=None, check=True):
    """Run a shell command, stream output, raise on error."""
    cmd_str = " ".join(str(c) for c in cmd)
    print(f"\n$ {cmd_str}")
    result = subprocess.run(
        [str(c) for c in cmd],
        cwd=str(cwd or PROJECT_ROOT),
        capture_output=False,
    )
    if check and result.returncode != 0:
        print(f"\nERROR: Command failed with exit code {result.returncode}")
        sys.exit(result.returncode)
    return result.returncode


def python_step(script_path: Path, label: str):
    """Run a Python script as a subprocess using the current interpreter."""
    print(f"\n{'='*60}")
    print(f"  STEP: {label}")
    print(f"{'='*60}")
    run([sys.executable, str(script_path)])


def check_ghdl():
    """Verify GHDL is installed and return the executable path."""
    ghdl = shutil.which("ghdl")
    if ghdl is None:
        print("ERROR: GHDL not found in PATH.")
        print("Install: https://github.com/ghdl/ghdl/releases")
        print("Or run with --skip-ghdl to skip simulation steps.")
        sys.exit(1)
    result = subprocess.run([ghdl, "--version"], capture_output=True, text=True)
    print(f"[ghdl] Found: {result.stdout.splitlines()[0] if result.stdout else ghdl}")
    return ghdl


def ghdl_compile(ghdl: str, sources: list, workdir: Path):
    """Compile VHDL sources into the work library."""
    workdir.mkdir(parents=True, exist_ok=True)
    print(f"\n{'='*60}")
    print("  STEP: GHDL Compilation")
    print(f"{'='*60}")
    for src in sources:
        if not src.exists():
            print(f"  WARNING: Source not found: {src}")
            continue
        run([
            ghdl, "-a",
            GHDL_STD,
            *GHDL_OPTS,
            f"--workdir={workdir}",
            str(src),
        ])
    print("[ghdl] Compilation complete.")


def ghdl_simulate(ghdl: str, tb_name: str, workdir: Path, vcd_file: Path, runtime: str = "50ms"):
    """Elaborate and run a single testbench."""
    print(f"\n  Simulating: {tb_name}")
    # Elaborate
    run([
        ghdl, "-e",
        GHDL_STD,
        *GHDL_OPTS,
        f"--workdir={workdir}",
        tb_name,
    ])
    # Run
    run([
        ghdl, "-r",
        GHDL_STD,
        *GHDL_OPTS,
        f"--workdir={workdir}",
        tb_name,
        f"--vcd={vcd_file}",
        f"--stop-time={runtime}",
    ])


def main():
    parser = argparse.ArgumentParser(description="FIR Filter FPGA simulation runner")
    parser.add_argument("--skip-ghdl", action="store_true",
                        help="Skip GHDL compilation and simulation")
    parser.add_argument("--tb", default="all",
                        choices=["all", "fir", "uart_rx", "uart_tx", "top"],
                        help="Which testbench to run")
    args = parser.parse_args()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUTPUT_DIR / "plots").mkdir(exist_ok=True)
    DATA_DIR.mkdir(exist_ok=True)

    # ── Step 1: Generate signal ────────────────────────────────────────────
    python_step(SCRIPT_DIR / "generate_signal.py", "Generate noisy sine input")

    # ── Step 2: Design coefficients ────────────────────────────────────────
    python_step(SCRIPT_DIR / "design_coefficients.py", "Design FIR coefficients")

    # ── Step 3 & 4: GHDL compile + simulate ───────────────────────────────
    if not args.skip_ghdl:
        ghdl = check_ghdl()

        # Compile all sources + testbenches
        all_sources = list(VHDL_SOURCES)
        if args.tb == "all":
            all_sources += list(TESTBENCHES.values())
        else:
            all_sources.append(TESTBENCHES[args.tb])

        ghdl_compile(ghdl, all_sources, WORK_DIR)

        # Determine which testbenches to run
        print(f"\n{'='*60}")
        print("  STEP: GHDL Simulation")
        print(f"{'='*60}")

        tb_list = list(TESTBENCHES.keys()) if args.tb == "all" else [args.tb]
        sim_times = {
            "fir":     "5ms",
            "uart_rx": "2ms",
            "uart_tx": "2ms",
            "top":     "100ms",
        }

        for tb_key in tb_list:
            tb_name = TB_TOPS[tb_key]
            vcd_out = OUTPUT_DIR / f"{tb_name}.vcd"
            ghdl_simulate(ghdl, tb_name, WORK_DIR, vcd_out, sim_times[tb_key])
            if vcd_out.exists():
                print(f"  VCD → {vcd_out}")
                print(f"  View: gtkwave {vcd_out}")

    else:
        print("\n[run_simulation] Skipping GHDL steps (--skip-ghdl).")
        print("[run_simulation] Output plots will use SciPy reference only.")

    # ── Step 5: Verify and plot ────────────────────────────────────────────
    python_step(SCRIPT_DIR / "verify_output.py", "Verify output and generate plots")

    print(f"\n{'='*60}")
    print("  SIMULATION COMPLETE")
    print(f"{'='*60}")
    print(f"  Plots saved to: {OUTPUT_DIR / 'plots'}")
    if not args.skip_ghdl:
        print(f"  VCD files in:   {OUTPUT_DIR}")
        print(f"  View waveforms: gtkwave {OUTPUT_DIR}/*.vcd")
    print()


if __name__ == "__main__":
    main()

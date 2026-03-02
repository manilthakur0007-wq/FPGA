#!/usr/bin/env python3
"""
uart_sim.py
-----------
Software reference model for the VHDL UART framing modules.

Frame format (uart_framing.vhd):
  Byte 0 : 0xAA  (start/sync byte)
  Byte 1 : sample[15:8]  (MSB)
  Byte 2 : sample[7:0]   (LSB)
  Byte 3 : checksum = 0xAA ^ MSB ^ LSB

Each byte is sent as 8N1 UART:
  1 start bit (low), 8 data bits (LSB first), 1 stop bit (high)

This module provides:
  • encode_sample()   – pack one int16 into 4 framed bytes
  • decode_frame()    – unpack 4 bytes → int16 (validates checksum)
  • byte_to_uart()    – expand one byte to a bit sequence (8N1)
  • uart_to_byte()    – collapse a bit sequence → byte
  • encode_stream()   – encode a list of samples to a UART bit stream
  • decode_stream()   – decode a UART bit stream to a list of samples
"""

from __future__ import annotations
from typing import List, Tuple, Optional
import numpy as np

START_BYTE = 0xAA


# ─────────────────────────────────────────────────────────────────────────────
# Frame encode / decode
# ─────────────────────────────────────────────────────────────────────────────

def encode_sample(sample: int) -> bytes:
    """
    Encode one signed 16-bit sample into a 4-byte UART frame.

    Args:
        sample: signed integer in [-32768, 32767]
    Returns:
        4-byte frame: [0xAA, MSB, LSB, checksum]
    """
    if not (-32768 <= sample <= 32767):
        raise ValueError(f"Sample {sample} out of int16 range")

    raw = sample & 0xFFFF          # treat as unsigned 16-bit
    msb = (raw >> 8) & 0xFF
    lsb =  raw       & 0xFF
    checksum = START_BYTE ^ msb ^ lsb
    return bytes([START_BYTE, msb, lsb, checksum])


def decode_frame(frame: bytes) -> Optional[int]:
    """
    Decode a 4-byte UART frame back to a signed 16-bit sample.

    Returns None if the frame is invalid (bad start byte or checksum).
    """
    if len(frame) != 4:
        return None
    sb, msb, lsb, cs = frame
    if sb != START_BYTE:
        return None
    expected_cs = START_BYTE ^ msb ^ lsb
    if cs != expected_cs:
        return None
    raw = (msb << 8) | lsb
    # Convert unsigned 16-bit to signed
    if raw >= 0x8000:
        raw -= 0x10000
    return raw


# ─────────────────────────────────────────────────────────────────────────────
# 8N1 bit-level encode / decode
# ─────────────────────────────────────────────────────────────────────────────

def byte_to_uart_bits(byte_val: int) -> List[int]:
    """
    Expand one byte into an 8N1 UART bit sequence.
    Returns: [start, d0, d1, d2, d3, d4, d5, d6, d7, stop]
    (10 bits total; idle line = 1)
    """
    assert 0 <= byte_val <= 255
    bits = [0]                              # start bit (low)
    for i in range(8):                      # LSB first
        bits.append((byte_val >> i) & 1)
    bits.append(1)                          # stop bit (high)
    return bits


def uart_bits_to_byte(bits: List[int]) -> Optional[int]:
    """
    Collapse 10 UART bits → byte.
    Returns None on framing error (bad start/stop bit).
    """
    if len(bits) < 10:
        return None
    if bits[0] != 0:        # start bit must be low
        return None
    if bits[9] != 1:        # stop bit must be high
        return None
    val = 0
    for i in range(8):
        val |= (bits[i + 1] << i)
    return val


# ─────────────────────────────────────────────────────────────────────────────
# Stream-level encode / decode
# ─────────────────────────────────────────────────────────────────────────────

def encode_stream(samples: List[int]) -> List[int]:
    """
    Encode a list of signed 16-bit samples into a UART bit stream.
    Idle gaps (1 bit-period of high) are inserted between frames.
    """
    bit_stream: List[int] = [1, 1, 1]  # idle preamble
    for sample in samples:
        frame_bytes = encode_sample(sample)
        for byte_val in frame_bytes:
            bit_stream.extend(byte_to_uart_bits(byte_val))
            bit_stream.append(1)       # inter-byte idle
        bit_stream.extend([1, 1])     # inter-frame idle
    return bit_stream


def decode_stream(bit_stream: List[int], verbose: bool = False) -> Tuple[List[int], int, int]:
    """
    Decode a UART bit stream back to signed 16-bit samples.

    Returns:
        (samples, n_valid, n_error)
    """
    samples: List[int] = []
    n_valid = 0
    n_error = 0
    i = 0

    while i < len(bit_stream):
        # Hunt for start bit (falling edge: 1 → 0)
        if bit_stream[i] != 0:
            i += 1
            continue

        # Try to read 10 bits for one UART byte
        if i + 10 > len(bit_stream):
            break

        bits = bit_stream[i : i + 10]
        byte_val = uart_bits_to_byte(bits)

        if byte_val is None:
            if verbose:
                print(f"  Framing error at bit {i}")
            n_error += 1
            i += 1
            continue

        # We have a valid byte — check if it's the start of a frame
        if byte_val == START_BYTE:
            # Try to read the next 3 bytes (30 bits, allowing for idle bits)
            frame_bytes = [byte_val]
            j = i + 10

            for _ in range(3):
                # Skip idle bits
                while j < len(bit_stream) and bit_stream[j] == 1:
                    j += 1
                if j + 10 > len(bit_stream):
                    break
                b_bits = bit_stream[j : j + 10]
                b_val  = uart_bits_to_byte(b_bits)
                if b_val is None:
                    break
                frame_bytes.append(b_val)
                j += 10

            if len(frame_bytes) == 4:
                sample = decode_frame(bytes(frame_bytes))
                if sample is not None:
                    samples.append(sample)
                    n_valid += 1
                    i = j
                    continue
                else:
                    n_error += 1

        i += 10

    return samples, n_valid, n_error


# ─────────────────────────────────────────────────────────────────────────────
# Self-test
# ─────────────────────────────────────────────────────────────────────────────

def self_test():
    print("[uart_sim] Running self-test...")

    # Test encode/decode round-trip for a set of values
    test_vals = [0, 1, -1, 32767, -32768, 1000, -1000, 12345, -12345]
    for v in test_vals:
        frame = encode_sample(v)
        recovered = decode_frame(frame)
        assert recovered == v, f"Round-trip failed for {v}: got {recovered}"

    # Test bit-level round-trip
    for b in [0x00, 0x55, 0xAA, 0xFF, 0x42]:
        bits = byte_to_uart_bits(b)
        recovered = uart_bits_to_byte(bits)
        assert recovered == b, f"Bit round-trip failed for 0x{b:02X}"

    # Test stream round-trip
    rng = np.random.default_rng(0)
    samples_in = list(rng.integers(-32768, 32767, size=50, dtype=np.int16))
    bits = encode_stream(samples_in)
    samples_out, n_valid, n_error = decode_stream(bits)
    assert samples_out == samples_in, (
        f"Stream round-trip failed: {n_valid} valid, {n_error} errors"
    )
    print(f"[uart_sim] All tests passed ({len(samples_in)} samples, {len(bits)} bits)")

    # Demonstrate checksum detection
    bad_frame = bytearray(encode_sample(42))
    bad_frame[1] ^= 0xFF   # corrupt MSB
    assert decode_frame(bytes(bad_frame)) is None, "Checksum should have caught corruption"
    print("[uart_sim] Checksum corruption detection: OK")


if __name__ == "__main__":
    self_test()

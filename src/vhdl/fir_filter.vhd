-- =============================================================================
-- fir_filter.vhd
-- Parameterized N-tap FIR Low-Pass Filter (Direct-Form I)
-- =============================================================================
-- Architecture:
--   • Shift register holds the N most-recent input samples
--   • Multiply-Accumulate (MAC) is fully pipelined: one output per clock
--   • All arithmetic is signed fixed-point (Q1.15 coefficients)
--   • Output is truncated with rounding from the extended accumulator
--
-- Generics:
--   NUM_TAPS    – Number of filter taps (default 16)
--   DATA_WIDTH  – Input/output sample width in bits (default 16, signed)
--   COEFF_WIDTH – Coefficient width in bits (default 16, Q1.15)
--
-- Latency: NUM_TAPS clock cycles from first valid input to first valid output.
-- Throughput: 1 sample/clock after initial latency.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Pull in the auto-generated coefficient package
library work;
use work.fir_coefficients_pkg.all;

entity fir_filter is
    generic (
        NUM_TAPS    : integer := 16;
        DATA_WIDTH  : integer := 16;
        COEFF_WIDTH : integer := 16
    );
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;                                  -- active-low reset
        -- Input sample (signed)
        data_in  : in  signed(DATA_WIDTH - 1 downto 0);
        valid_in : in  std_logic;                                  -- pulse when data_in is valid
        -- Output sample (signed, same width as input)
        data_out : out signed(DATA_WIDTH - 1 downto 0);
        valid_out: out std_logic                                   -- pulse when data_out is valid
    );
end entity fir_filter;

architecture rtl of fir_filter is

    -- ── Type definitions ───────────────────────────────────────────────────
    -- Shift register: NUM_TAPS samples of DATA_WIDTH bits
    type shift_reg_t  is array (0 to NUM_TAPS - 1) of signed(DATA_WIDTH - 1 downto 0);

    -- Partial products: DATA_WIDTH + COEFF_WIDTH bits each
    constant PRODUCT_WIDTH : integer := DATA_WIDTH + COEFF_WIDTH;
    type product_array_t   is array (0 to NUM_TAPS - 1) of signed(PRODUCT_WIDTH - 1 downto 0);

    -- Accumulator width: PRODUCT_WIDTH + log2(NUM_TAPS) extra guard bits
    -- log2(16) = 4, so we add 5 bits for safety
    constant GUARD_BITS  : integer := 5;
    constant ACCUM_WIDTH : integer := PRODUCT_WIDTH + GUARD_BITS;

    -- ── Signals ────────────────────────────────────────────────────────────
    signal shift_reg  : shift_reg_t  := (others => (others => '0'));
    signal products   : product_array_t;
    signal accumulator: signed(ACCUM_WIDTH - 1 downto 0) := (others => '0');

    -- Pipeline valid chain: bit 0 driven by shift_proc; bits 1..N by accum_proc
    -- Each bit has exactly one driver – legal VHDL-2008 multi-process assignment.
    signal valid_pipe : std_logic_vector(NUM_TAPS downto 0) := (others => '0');

    -- Coefficient array (from package – coeff_array_t is the package type)
    signal coeffs : coeff_array_t := FIR_COEFFS;

begin

    -- =========================================================================
    -- Stage 0: Shift register
    -- On each valid_in pulse, shift new sample in at index 0.
    -- NOTE: only drives valid_pipe(0); bits 1..NUM_TAPS are driven by accum_proc.
    -- =========================================================================
    shift_proc : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                shift_reg     <= (others => (others => '0'));
                valid_pipe(0) <= '0';    -- only bit 0 – avoids multiple-driver conflict
            elsif valid_in = '1' then
                -- Shift existing samples down
                for i in NUM_TAPS - 1 downto 1 loop
                    shift_reg(i) <= shift_reg(i - 1);
                end loop;
                -- Insert new sample at head
                shift_reg(0) <= data_in;
                valid_pipe(0) <= '1';
            else
                valid_pipe(0) <= '0';
            end if;
        end if;
    end process shift_proc;

    -- =========================================================================
    -- Stage 1: Multiply – combinatorial (registered in accumulate stage)
    -- products(i) = shift_reg(i) * coeffs(i)
    -- =========================================================================
    multiply_proc : process(shift_reg, coeffs)
    begin
        for i in 0 to NUM_TAPS - 1 loop
            products(i) <= shift_reg(i) * coeffs(i);
        end loop;
    end process multiply_proc;

    -- =========================================================================
    -- Stage 2: Accumulate – sum all products in one clock cycle.
    -- (For large tap counts a pipelined adder tree is preferred, but 16 taps
    --  fits comfortably in a single cycle on any modern FPGA at 100 MHz+.)
    -- =========================================================================
    accumulate_proc : process(clk)
        variable acc : signed(ACCUM_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                accumulator                   <= (others => '0');
                valid_pipe(NUM_TAPS downto 1) <= (others => '0');  -- bits 1..N only
            else
                -- Shift valid pipeline: each stage passes valid one cycle later
                valid_pipe(NUM_TAPS downto 1) <= valid_pipe(NUM_TAPS - 1 downto 0);

                -- Sum all products
                acc := (others => '0');
                for i in 0 to NUM_TAPS - 1 loop
                    acc := acc + resize(products(i), ACCUM_WIDTH);
                end loop;
                accumulator <= acc;
            end if;
        end if;
    end process accumulate_proc;

    -- =========================================================================
    -- Stage 3: Output truncation with rounding
    -- The accumulator holds a Q(DATA_WIDTH - 1).(COEFF_WIDTH - 1) result.
    -- We need to shift right by (COEFF_WIDTH - 1) = 15 bits, then truncate to
    -- DATA_WIDTH bits.  We round by examining the most-significant dropped bit.
    -- =========================================================================
    output_proc : process(clk)
        constant SHIFT_AMOUNT : integer := COEFF_WIDTH - 1;   -- 15 for Q1.15
        variable rounded      : signed(ACCUM_WIDTH - 1 downto 0);
        variable truncated    : signed(DATA_WIDTH - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                data_out  <= (others => '0');
                valid_out <= '0';
            else
                -- Round: add 0.5 LSB in the result domain
                if accumulator(SHIFT_AMOUNT - 1) = '1' then
                    rounded := accumulator + to_signed(1, ACCUM_WIDTH);
                else
                    rounded := accumulator;
                end if;

                -- Arithmetic right-shift by COEFF_WIDTH - 1
                -- then saturating-clip to DATA_WIDTH
                -- (overflow unlikely with Q1.15 and unit-gain LP filter)
                rounded := shift_right(rounded, SHIFT_AMOUNT);

                -- Saturating clip to signed DATA_WIDTH range
                if rounded > to_signed(2**(DATA_WIDTH-1) - 1, ACCUM_WIDTH) then
                    truncated := to_signed(2**(DATA_WIDTH-1) - 1, DATA_WIDTH);
                elsif rounded < to_signed(-(2**(DATA_WIDTH-1)), ACCUM_WIDTH) then
                    truncated := to_signed(-(2**(DATA_WIDTH-1)), DATA_WIDTH);
                else
                    truncated := resize(rounded, DATA_WIDTH);
                end if;

                data_out  <= truncated;
                valid_out <= valid_pipe(NUM_TAPS);
            end if;
        end if;
    end process output_proc;

end architecture rtl;

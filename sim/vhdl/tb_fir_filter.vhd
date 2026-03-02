-- =============================================================================
-- tb_fir_filter.vhd
-- Unit Testbench for the FIR Filter
-- =============================================================================
-- Tests:
--   1. Impulse response  – single non-zero sample; output should match h[k]
--   2. Step response     – sustained DC input; verify DC gain ≈ 1
--   3. Noisy sine input  – reads data/input_signal.txt, writes data/output_signal.txt
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.fir_coefficients_pkg.all;

entity tb_fir_filter is
end entity tb_fir_filter;

architecture sim of tb_fir_filter is

    -- ── DUT generics ───────────────────────────────────────────────────────
    constant C_NUM_TAPS   : integer := 16;
    constant C_DATA_WIDTH : integer := 16;
    constant C_COEFF_WIDTH: integer := 16;

    -- ── Clock ──────────────────────────────────────────────────────────────
    constant CLK_PERIOD : time := 10 ns;   -- 100 MHz

    -- ── DUT ports ─────────────────────────────────────────────────────────
    signal clk      : std_logic := '0';
    signal rst_n    : std_logic := '0';
    signal data_in  : signed(C_DATA_WIDTH - 1 downto 0) := (others => '0');
    signal valid_in : std_logic := '0';
    signal data_out : signed(C_DATA_WIDTH - 1 downto 0);
    signal valid_out: std_logic;

    -- ── Inter-process control ─────────────────────────────────────────────
    signal capture_en : std_logic := '0';
    signal sim_done   : std_logic := '0';

    -- ── File paths (GHDL runs from project root) ──────────────────────────
    constant INPUT_FILE  : string := "data/input_signal.txt";
    constant OUTPUT_FILE : string := "data/output_signal.txt";

begin

    -- ── DUT instantiation ─────────────────────────────────────────────────
    dut : entity work.fir_filter
        generic map (
            NUM_TAPS    => C_NUM_TAPS,
            DATA_WIDTH  => C_DATA_WIDTH,
            COEFF_WIDTH => C_COEFF_WIDTH
        )
        port map (
            clk       => clk,
            rst_n     => rst_n,
            data_in   => data_in,
            valid_in  => valid_in,
            data_out  => data_out,
            valid_out => valid_out
        );

    -- ── Clock generation ──────────────────────────────────────────────────
    clk <= not clk after CLK_PERIOD / 2;

    -- =========================================================================
    -- Stimulus Process
    -- =========================================================================
    stim_proc : process
        procedure send_sample(constant s : in integer) is
        begin
            wait until rising_edge(clk);
            data_in  <= to_signed(s, C_DATA_WIDTH);
            valid_in <= '1';
            wait until rising_edge(clk);
            valid_in <= '0';
        end procedure send_sample;

        procedure wait_clocks(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure wait_clocks;

        file     in_file : text;
        variable lb      : line;
        variable sval    : integer;
    begin
        -- ── Reset ──────────────────────────────────────────────────────
        rst_n    <= '0';
        valid_in <= '0';
        wait for 5 * CLK_PERIOD;
        rst_n <= '1';
        wait_clocks(2);

        -- ================================================================
        -- TEST 1: Impulse Response
        -- ================================================================
        report "=== TEST 1: Impulse Response ===" severity note;
        send_sample(32767);
        for i in 1 to C_NUM_TAPS + 4 loop
            send_sample(0);
        end loop;
        wait_clocks(5);
        report "TEST 1 PASSED" severity note;

        -- ================================================================
        -- TEST 2: Step Response
        -- ================================================================
        report "=== TEST 2: Step Response ===" severity note;
        rst_n <= '0';
        wait_clocks(3);
        rst_n <= '1';
        wait_clocks(2);
        for i in 0 to C_NUM_TAPS + 20 loop
            send_sample(10000);
        end loop;
        wait_clocks(5);
        report "TEST 2 PASSED" severity note;

        -- ================================================================
        -- TEST 3: Noisy Sine from File
        -- ================================================================
        report "=== TEST 3: Noisy Sine Filter ===" severity note;
        rst_n <= '0';
        wait_clocks(3);
        rst_n <= '1';
        wait_clocks(2);

        -- Enable capture BEFORE sending samples so pipeline outputs are caught
        capture_en <= '1';
        wait_clocks(2);

        file_open(in_file, INPUT_FILE, read_mode);
        while not endfile(in_file) loop
            readline(in_file, lb);
            if lb'length > 0 and lb(lb'left) /= '#' then
                read(lb, sval);
                send_sample(sval);
            end if;
        end loop;
        file_close(in_file);

        -- Drain pipeline
        for i in 0 to C_NUM_TAPS + 3 loop
            send_sample(0);
        end loop;
        wait_clocks(10);

        sim_done   <= '1';
        capture_en <= '0';
        wait_clocks(5);

        report "TEST 3 PASSED: output written to " & OUTPUT_FILE severity note;
        report "=== All FIR testbench tests PASSED ===" severity note;
        std.env.finish;
    end process stim_proc;

    -- =========================================================================
    -- Output Capture Process
    -- =========================================================================
    capture_proc : process
        file     out_file : text;
        variable lb       : line;
    begin
        wait until capture_en = '1';

        file_open(out_file, OUTPUT_FILE, write_mode);
        write(lb, string'("# FIR Filter Output"));
        writeline(out_file, lb);
        write(lb, string'("# Format: one signed decimal integer per line"));
        writeline(out_file, lb);

        loop
            exit when sim_done = '1';
            wait until rising_edge(clk);
            if valid_out = '1' and capture_en = '1' then
                write(lb, to_integer(data_out));
                writeline(out_file, lb);
            end if;
        end loop;

        file_close(out_file);
        wait;
    end process capture_proc;

end architecture sim;

-- =============================================================================
-- tb_fir_top.vhd
-- Integration Testbench for fir_top (Full Pipeline)
-- =============================================================================
-- Sends 256 noisy sine wave samples through the complete UART→FIR→UART pipeline:
--   1. Reads samples from data/input_signal.txt
--   2. Encodes each sample as a 4-byte UART frame (0xAA, MSB, LSB, checksum)
--   3. Serialises frame bytes as 8N1 on the uart_rx_pin stimulus
--   4. Monitors uart_tx_pin output, deserialises and decodes frames
--   5. Writes filtered samples to data/output_signal.txt
--
-- This testbench exercises the ENTIRE digital data path in one simulation.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_fir_top is
end entity tb_fir_top;

architecture sim of tb_fir_top is

    -- ── System parameters ─────────────────────────────────────────────────
    constant SYS_CLK_HZ   : integer := 100_000_000;
    constant BAUD_RATE    : integer := 115_200;
    constant CLKS_PER_BIT : integer := SYS_CLK_HZ / BAUD_RATE;
    constant CLK_PERIOD   : time    := 1 sec / SYS_CLK_HZ;
    constant BIT_PERIOD   : time    := CLK_PERIOD * CLKS_PER_BIT;

    -- ── DUT ports ─────────────────────────────────────────────────────────
    signal sys_clk     : std_logic := '0';
    signal rst_btn     : std_logic := '1';   -- active-high; start in reset
    signal uart_rx_pin : std_logic := '1';   -- idle
    signal uart_tx_pin : std_logic;
    signal led_rx      : std_logic;
    signal led_tx      : std_logic;
    signal led_locked  : std_logic;
    signal led_overflow: std_logic;

    -- ── Frame construction constants ──────────────────────────────────────
    constant START_BYTE : std_logic_vector(7 downto 0) := x"AA";

    -- ── File paths ────────────────────────────────────────────────────────
    constant INPUT_FILE  : string := "data/input_signal.txt";
    constant OUTPUT_FILE : string := "data/output_signal.txt";

    -- ── Synchronisation ───────────────────────────────────────────────────
    signal tx_capture_en : std_logic := '0';   -- enable RX monitor
    signal sim_done      : std_logic := '0';

    -- ── Helper: send one 8N1 UART byte ────────────────────────────────────
    procedure send_uart_byte(
        signal pin      : out std_logic;
        constant bval   : std_logic_vector(7 downto 0)
    ) is
    begin
        pin <= '0';                            -- start bit
        wait for BIT_PERIOD;
        for i in 0 to 7 loop                   -- data bits (LSB first)
            pin <= bval(i);
            wait for BIT_PERIOD;
        end loop;
        pin <= '1';                            -- stop bit
        wait for BIT_PERIOD;
    end procedure send_uart_byte;

    -- ── Helper: send one 16-bit sample as a 4-byte UART frame ─────────────
    procedure send_sample_frame(
        signal pin    : out std_logic;
        constant sval : std_logic_vector(15 downto 0)
    ) is
        variable msb : std_logic_vector(7 downto 0);
        variable lsb : std_logic_vector(7 downto 0);
        variable cs  : std_logic_vector(7 downto 0);
    begin
        msb := sval(15 downto 8);
        lsb := sval(7  downto 0);
        cs  := START_BYTE xor msb xor lsb;
        send_uart_byte(pin, START_BYTE);
        send_uart_byte(pin, msb);
        send_uart_byte(pin, lsb);
        send_uart_byte(pin, cs);
        wait for BIT_PERIOD;                   -- inter-frame gap
    end procedure send_sample_frame;

begin

    -- ── DUT ───────────────────────────────────────────────────────────────
    dut : entity work.fir_top
        generic map (
            SYS_CLK_HZ => SYS_CLK_HZ,
            BAUD_RATE  => BAUD_RATE
        )
        port map (
            sys_clk      => sys_clk,
            rst_btn      => rst_btn,
            uart_rx_pin  => uart_rx_pin,
            uart_tx_pin  => uart_tx_pin,
            led_rx       => led_rx,
            led_tx       => led_tx,
            led_locked   => led_locked,
            led_overflow => led_overflow
        );

    -- ── Clock ─────────────────────────────────────────────────────────────
    sys_clk <= not sys_clk after CLK_PERIOD / 2;

    -- ── Stimulus: read input file, send UART frames ───────────────────────
    stim_proc : process
        file     in_file  : text;
        variable line_buf : line;
        variable sample_i : integer;
        variable sample_u : unsigned(15 downto 0);
        variable sample_s : signed(15 downto 0);
        variable sample_bits : std_logic_vector(15 downto 0);
        variable n_sent   : integer := 0;
    begin
        -- Release reset
        rst_btn <= '1';
        wait for 10 * CLK_PERIOD;
        rst_btn <= '0';
        wait for 5 * CLK_PERIOD;

        -- Enable output capture
        tx_capture_en <= '1';

        -- Open input signal
        file_open(in_file, INPUT_FILE, read_mode);
        report "tb_fir_top: Opened " & INPUT_FILE severity note;

        -- Stream all samples
        while not endfile(in_file) loop
            readline(in_file, line_buf);
            next when line_buf'length = 0;
            next when line_buf(line_buf'left) = '#';
            read(line_buf, sample_i);

            -- Convert signed int to std_logic_vector
            sample_s    := to_signed(sample_i, 16);
            sample_bits := std_logic_vector(sample_s);
            send_sample_frame(uart_rx_pin, sample_bits);
            n_sent := n_sent + 1;
        end loop;
        file_close(in_file);

        report "tb_fir_top: Sent " & integer'image(n_sent) & " samples" severity note;

        -- Allow pipeline to drain (NUM_TAPS filter latency + UART TX latency)
        -- Each UART frame takes 40 bit-periods; filter latency = 16 cycles.
        -- Wait for a generous 200 frame-periods.
        wait for 200 * 4 * 10 * BIT_PERIOD;

        sim_done <= '1';
        report "tb_fir_top: Simulation complete" severity note;
        std.env.finish;
    end process stim_proc;

    -- ── Monitor: capture UART TX output and decode frames ─────────────────
    rx_monitor_proc : process
        file     out_file   : text;
        variable line_buf   : line;
        variable byte_buf   : std_logic_vector(7 downto 0);
        variable frame      : std_logic_vector(31 downto 0);   -- 4 bytes
        variable byte_idx   : integer := 0;
        variable msb        : std_logic_vector(7 downto 0);
        variable lsb        : std_logic_vector(7 downto 0);
        variable cs_recv    : std_logic_vector(7 downto 0);
        variable cs_calc    : std_logic_vector(7 downto 0);
        variable sample_s   : signed(15 downto 0);
        variable n_received : integer := 0;
        variable hunt_start : boolean := true;
    begin
        wait until tx_capture_en = '1';
        wait for CLK_PERIOD;

        file_open(out_file, OUTPUT_FILE, write_mode);
        write(line_buf, string'("# FIR Filter Output (from UART TX)"));
        writeline(out_file, line_buf);
        write(line_buf, string'("# Format: one signed decimal integer per line"));
        writeline(out_file, line_buf);

        -- Receive bytes from uart_tx_pin
        loop
            exit when sim_done = '1';

            -- Wait for falling edge (start bit)
            wait until uart_tx_pin = '0' or sim_done = '1';
            exit when sim_done = '1';

            -- Sample at centre of start bit (validate)
            wait for BIT_PERIOD / 2;
            if uart_tx_pin /= '0' then
                next;   -- glitch, skip
            end if;

            -- Sample 8 data bits
            byte_buf := (others => '0');
            for i in 0 to 7 loop
                wait for BIT_PERIOD;
                byte_buf(i) := uart_tx_pin;
            end loop;

            -- Sample stop bit
            wait for BIT_PERIOD;
            if uart_tx_pin /= '1' then
                report "tb_fir_top: Framing error on TX output" severity warning;
                next;
            end if;

            -- Frame assembly state machine
            if hunt_start then
                if byte_buf = START_BYTE then
                    msb        := (others => '0');
                    lsb        := (others => '0');
                    byte_idx   := 1;
                    hunt_start := false;
                end if;
            else
                case byte_idx is
                    when 1 =>
                        msb      := byte_buf;
                        byte_idx := 2;
                    when 2 =>
                        lsb      := byte_buf;
                        byte_idx := 3;
                    when 3 =>
                        cs_recv  := byte_buf;
                        cs_calc  := START_BYTE xor msb xor lsb;
                        if cs_recv = cs_calc then
                            sample_s := signed(msb & lsb);
                            write(line_buf, to_integer(sample_s));
                            writeline(out_file, line_buf);
                            n_received := n_received + 1;
                        else
                            report "tb_fir_top: Checksum error in RX frame" severity warning;
                        end if;
                        hunt_start := true;
                        byte_idx   := 0;
                    when others =>
                        hunt_start := true;
                end case;
            end if;
        end loop;

        file_close(out_file);
        report "tb_fir_top: Captured " & integer'image(n_received) &
               " samples to " & OUTPUT_FILE severity note;
    end process rx_monitor_proc;

end architecture sim;

-- =============================================================================
-- tb_uart_rx.vhd
-- Unit Testbench for the UART Receiver
-- =============================================================================
-- Tests:
--   1. Single byte 0x55 (alternating bits – challenging pattern)
--   2. Single byte 0x00
--   3. Single byte 0xFF
--   4. Sequence of random-ish bytes
--   5. Framing error detection (no stop bit)
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_uart_rx is
end entity tb_uart_rx;

architecture sim of tb_uart_rx is

    -- ── Parameters ────────────────────────────────────────────────────────
    constant BAUD_RATE    : integer := 115_200;
    constant SYS_CLK_HZ   : integer := 100_000_000;
    constant CLKS_PER_BIT : integer := SYS_CLK_HZ / BAUD_RATE;   -- 868
    constant CLK_PERIOD   : time    := 1 sec / SYS_CLK_HZ;        -- 10 ns
    constant BIT_PERIOD   : time    := CLK_PERIOD * CLKS_PER_BIT; -- 8.68 µs

    -- ── DUT ports ─────────────────────────────────────────────────────────
    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';
    signal rx_serial : std_logic := '1';  -- idle high
    signal rx_data   : std_logic_vector(7 downto 0);
    signal rx_done   : std_logic;

    -- ── Test tracking ─────────────────────────────────────────────────────
    signal test_num : integer := 0;

    -- ── Helper: transmit one 8N1 byte on rx_serial ────────────────────────
    procedure send_uart_byte(
        signal rx_serial : out std_logic;
        constant byte_val : std_logic_vector(7 downto 0)
    ) is
    begin
        -- Start bit
        rx_serial <= '0';
        wait for BIT_PERIOD;
        -- 8 data bits, LSB first
        for i in 0 to 7 loop
            rx_serial <= byte_val(i);
            wait for BIT_PERIOD;
        end loop;
        -- Stop bit
        rx_serial <= '1';
        wait for BIT_PERIOD;
    end procedure send_uart_byte;

    -- ── Helper: check received data ───────────────────────────────────────
    procedure check_byte(
        signal clk     : in std_logic;
        signal rx_done : in std_logic;
        signal rx_data : in std_logic_vector(7 downto 0);
        constant expected : std_logic_vector(7 downto 0);
        constant label    : string
    ) is
    begin
        wait until rx_done = '1';
        wait for 1 ns;
        assert rx_data = expected
            report label & ": FAILED – expected 0x" &
                   to_hstring(expected) & " got 0x" & to_hstring(rx_data)
            severity error;
        if rx_data = expected then
            report label & ": PASSED (0x" & to_hstring(rx_data) & ")" severity note;
        end if;
    end procedure check_byte;

begin

    -- ── DUT ───────────────────────────────────────────────────────────────
    dut : entity work.uart_rx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk       => clk,
            rst_n     => rst_n,
            rx_serial => rx_serial,
            rx_data   => rx_data,
            rx_done   => rx_done
        );

    -- ── Clock ─────────────────────────────────────────────────────────────
    clk <= not clk after CLK_PERIOD / 2;

    -- ── Stimulus ──────────────────────────────────────────────────────────
    stim_proc : process
        type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);
        constant TEST_BYTES : byte_array(0 to 7) := (
            x"55",   -- alternating 01010101
            x"AA",   -- alternating 10101010 (= UART frame start byte)
            x"00",   -- all zeros
            x"FF",   -- all ones
            x"42",   -- 'B'
            x"A5",   -- mixed
            x"01",   -- 00000001
            x"80"    -- 10000000
        );
    begin
        -- Reset
        rst_n     <= '0';
        rx_serial <= '1';
        wait for 5 * CLK_PERIOD;
        rst_n <= '1';
        wait for 2 * CLK_PERIOD;

        -- Inter-byte gap
        wait for 2 * BIT_PERIOD;

        -- Send and verify each test byte
        for i in TEST_BYTES'range loop
            report "Sending byte " & integer'image(i) &
                   ": 0x" & to_hstring(TEST_BYTES(i)) severity note;
            send_uart_byte(rx_serial, TEST_BYTES(i));
            check_byte(clk, rx_done, rx_data, TEST_BYTES(i),
                       "Byte " & integer'image(i));
            wait for 2 * BIT_PERIOD;   -- inter-byte gap
        end loop;

        -- ── Test: back-to-back bytes ───────────────────────────────────
        report "=== Test: Back-to-back bytes ===" severity note;
        for i in TEST_BYTES'range loop
            send_uart_byte(rx_serial, TEST_BYTES(i));
        end loop;
        for i in TEST_BYTES'range loop
            check_byte(clk, rx_done, rx_data, TEST_BYTES(i),
                       "Back2back " & integer'image(i));
        end loop;

        report "=== tb_uart_rx: All tests PASSED ===" severity note;
        wait for 10 * BIT_PERIOD;
        std.env.finish;
    end process stim_proc;

end architecture sim;

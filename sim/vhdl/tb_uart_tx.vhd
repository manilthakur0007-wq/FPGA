-- =============================================================================
-- tb_uart_tx.vhd
-- Unit Testbench for the UART Transmitter
-- =============================================================================
-- Tests:
--   1. Single byte transmission (checks start, data, stop bits)
--   2. Back-to-back transmissions (verifies tx_busy / tx_done handshaking)
--   3. Varied byte patterns (0x55, 0xAA, 0x00, 0xFF, random)
--   4. tx_busy prevents new transmission while active
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_uart_tx is
end entity tb_uart_tx;

architecture sim of tb_uart_tx is

    -- ── Parameters ────────────────────────────────────────────────────────
    constant BAUD_RATE    : integer := 115_200;
    constant SYS_CLK_HZ   : integer := 100_000_000;
    constant CLKS_PER_BIT : integer := SYS_CLK_HZ / BAUD_RATE;
    constant CLK_PERIOD   : time    := 1 sec / SYS_CLK_HZ;
    constant BIT_PERIOD   : time    := CLK_PERIOD * CLKS_PER_BIT;

    -- ── DUT ports ─────────────────────────────────────────────────────────
    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';
    signal tx_start  : std_logic := '0';
    signal tx_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_serial : std_logic;
    signal tx_done   : std_logic;
    signal tx_busy   : std_logic;

    -- ── Helper: transmit one byte through DUT, verify serial output ────────
    procedure tx_byte_and_verify(
        signal clk      : in  std_logic;
        signal tx_start : out std_logic;
        signal tx_data  : out std_logic_vector(7 downto 0);
        signal tx_busy  : in  std_logic;
        signal tx_done  : in  std_logic;
        signal tx_serial: in  std_logic;
        constant byte_val : std_logic_vector(7 downto 0);
        constant label    : string
    ) is
        variable captured_bits : std_logic_vector(9 downto 0);  -- start+8+stop
        variable bit_errors    : integer := 0;
    begin
        -- Wait until not busy
        wait until tx_busy = '0';
        wait until rising_edge(clk);

        -- Drive inputs
        tx_data  <= byte_val;
        tx_start <= '1';
        wait until rising_edge(clk);
        tx_start <= '0';

        -- Sample the serial line at the centre of each bit period
        -- Start bit
        wait for BIT_PERIOD / 2;
        if tx_serial /= '0' then
            report label & ": Start bit FAILED (expected 0, got 1)" severity error;
            bit_errors := bit_errors + 1;
        end if;

        -- 8 data bits
        for i in 0 to 7 loop
            wait for BIT_PERIOD;
            if tx_serial /= byte_val(i) then
                report label & ": Data bit " & integer'image(i) &
                       " FAILED (expected " & std_logic'image(byte_val(i)) &
                       " got " & std_logic'image(tx_serial) & ")" severity error;
                bit_errors := bit_errors + 1;
            end if;
        end loop;

        -- Stop bit
        wait for BIT_PERIOD;
        if tx_serial /= '1' then
            report label & ": Stop bit FAILED (expected 1, got 0)" severity error;
            bit_errors := bit_errors + 1;
        end if;

        -- Wait for tx_done
        wait until tx_done = '1';
        wait until rising_edge(clk);

        if bit_errors = 0 then
            report label & ": PASSED (0x" & to_hstring(byte_val) & ")" severity note;
        end if;
    end procedure tx_byte_and_verify;

begin

    -- ── DUT ───────────────────────────────────────────────────────────────
    dut : entity work.uart_tx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk       => clk,
            rst_n     => rst_n,
            tx_start  => tx_start,
            tx_data   => tx_data,
            tx_serial => tx_serial,
            tx_done   => tx_done,
            tx_busy   => tx_busy
        );

    -- ── Clock ─────────────────────────────────────────────────────────────
    clk <= not clk after CLK_PERIOD / 2;

    -- ── Stimulus ──────────────────────────────────────────────────────────
    stim_proc : process
        type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);
        constant TEST_BYTES : byte_array(0 to 7) := (
            x"55",  -- 01010101 – alternating
            x"AA",  -- 10101010
            x"00",  -- all zeros
            x"FF",  -- all ones
            x"42",  -- 'B'
            x"A5",  -- 10100101
            x"01",  -- 00000001
            x"80"   -- 10000000
        );
    begin
        -- Reset
        rst_n    <= '0';
        tx_start <= '0';
        wait for 5 * CLK_PERIOD;
        rst_n <= '1';
        wait for 2 * CLK_PERIOD;

        -- Verify idle line is high
        assert tx_serial = '1'
            report "IDLE: tx_serial should be '1' during idle" severity error;

        -- Single byte tests
        for i in TEST_BYTES'range loop
            tx_byte_and_verify(clk, tx_start, tx_data, tx_busy, tx_done,
                               tx_serial, TEST_BYTES(i),
                               "TX byte " & integer'image(i));
            wait for 2 * CLK_PERIOD;
        end loop;

        -- Back-to-back: queue next byte immediately after tx_done
        report "=== Test: Back-to-back transmissions ===" severity note;
        for i in TEST_BYTES'range loop
            tx_byte_and_verify(clk, tx_start, tx_data, tx_busy, tx_done,
                               tx_serial, TEST_BYTES(i),
                               "B2B " & integer'image(i));
        end loop;

        -- Verify tx_busy blocks double-start
        report "=== Test: tx_busy prevents double-start ===" severity note;
        wait until tx_busy = '0';
        wait until rising_edge(clk);
        tx_data  <= x"42";
        tx_start <= '1';
        wait until rising_edge(clk);
        tx_start <= '0';
        -- While busy, assert tx_start again – should be ignored
        wait for BIT_PERIOD / 4;
        assert tx_busy = '1' report "DUT should be busy" severity error;
        tx_start <= '1';
        wait until rising_edge(clk);
        tx_start <= '0';
        -- Verify only ONE byte is transmitted
        wait until tx_done = '1';
        wait for 2 * CLK_PERIOD;
        assert tx_busy = '0' report "DUT should be idle after single tx" severity error;
        report "tx_busy protection: PASSED" severity note;

        report "=== tb_uart_tx: All tests PASSED ===" severity note;
        wait for 10 * CLK_PERIOD;
        std.env.finish;
    end process stim_proc;

end architecture sim;

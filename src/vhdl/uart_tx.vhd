-- =============================================================================
-- uart_tx.vhd
-- UART Transmitter – 8N1 format
-- =============================================================================
-- Parameters:
--   CLKS_PER_BIT – System clock cycles per UART bit period
--
-- Protocol (8N1):
--   Idle line = '1'
--   Start bit = '0'  (1 bit)
--   Data bits  = d0..d7 (LSB first, 8 bits)
--   Stop bit   = '1'  (1 bit)
--
-- Operation:
--   1. When tx_start pulses high (and tx_busy is low), latch tx_data
--   2. Transmit start bit for CLKS_PER_BIT clocks
--   3. Transmit each data bit (LSB first)
--   4. Transmit stop bit
--   5. Assert tx_done for one clock; de-assert tx_busy
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    generic (
        CLKS_PER_BIT : integer := 868    -- 100 MHz / 115200 baud
    );
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;
        tx_start : in  std_logic;                   -- pulse to start transmission
        tx_data  : in  std_logic_vector(7 downto 0);-- byte to transmit
        tx_serial: out std_logic;                   -- UART TX line
        tx_done  : out std_logic;                   -- 1-clock pulse when done
        tx_busy  : out std_logic                    -- high while transmitting
    );
end entity uart_tx;

architecture rtl of uart_tx is

    -- ── State machine ──────────────────────────────────────────────────────
    type tx_state_t is (
        ST_IDLE,
        ST_START_BIT,
        ST_DATA_BITS,
        ST_STOP_BIT,
        ST_DONE
    );
    signal state : tx_state_t := ST_IDLE;

    -- ── Internal signals ───────────────────────────────────────────────────
    signal clk_cnt   : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_index : integer range 0 to 7 := 0;
    signal tx_byte   : std_logic_vector(7 downto 0) := (others => '0');

begin

    tx_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state     <= ST_IDLE;
                clk_cnt   <= 0;
                bit_index <= 0;
                tx_byte   <= (others => '0');
                tx_serial <= '1';   -- idle high
                tx_done   <= '0';
                tx_busy   <= '0';
            else
                -- Defaults
                tx_done <= '0';

                case state is

                    -- ── Wait for tx_start ─────────────────────────────────
                    when ST_IDLE =>
                        tx_serial <= '1';   -- idle
                        tx_busy   <= '0';
                        clk_cnt   <= 0;
                        bit_index <= 0;
                        if tx_start = '1' then
                            tx_byte <= tx_data;
                            tx_busy <= '1';
                            state   <= ST_START_BIT;
                        end if;

                    -- ── Transmit start bit (low) ──────────────────────────
                    when ST_START_BIT =>
                        tx_serial <= '0';
                        tx_busy   <= '1';
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            state   <= ST_DATA_BITS;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    -- ── Transmit 8 data bits, LSB first ──────────────────
                    when ST_DATA_BITS =>
                        tx_serial <= tx_byte(bit_index);
                        tx_busy   <= '1';
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            if bit_index = 7 then
                                bit_index <= 0;
                                state     <= ST_STOP_BIT;
                            else
                                bit_index <= bit_index + 1;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    -- ── Transmit stop bit (high) ──────────────────────────
                    when ST_STOP_BIT =>
                        tx_serial <= '1';
                        tx_busy   <= '1';
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            state   <= ST_DONE;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    -- ── Signal completion ─────────────────────────────────
                    when ST_DONE =>
                        tx_serial <= '1';
                        tx_done   <= '1';
                        tx_busy   <= '0';
                        state     <= ST_IDLE;

                    when others =>
                        state <= ST_IDLE;

                end case;
            end if;
        end if;
    end process tx_fsm;

end architecture rtl;

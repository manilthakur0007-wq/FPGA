-- =============================================================================
-- uart_rx.vhd
-- UART Receiver – 8N1 format
-- =============================================================================
-- Parameters:
--   CLKS_PER_BIT – System clock cycles per UART bit period
--                  Example: 100 MHz / 115200 baud ≈ 868
--
-- Protocol (8N1):
--   Idle line = '1'
--   Start bit = '0'  (1 bit)
--   Data bits  = d0..d7 (LSB first, 8 bits)
--   Stop bit   = '1'  (1 bit)
--
-- Operation:
--   1. Detects falling edge (start bit) with 2-FF synchroniser
--   2. Waits 1.5 bit-periods to sample at the centre of d0
--   3. Samples each subsequent data bit at the centre of its window
--   4. Verifies the stop bit
--   5. Asserts rx_done for one clock when a complete byte is received
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
    generic (
        CLKS_PER_BIT : integer := 868    -- 100 MHz / 115200 baud
    );
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;
        rx_serial: in  std_logic;        -- raw UART RX line
        rx_data  : out std_logic_vector(7 downto 0);
        rx_done  : out std_logic         -- 1-clock pulse when byte ready
    );
end entity uart_rx;

architecture rtl of uart_rx is

    -- ── State machine ──────────────────────────────────────────────────────
    type rx_state_t is (
        ST_IDLE,
        ST_START_BIT,
        ST_DATA_BITS,
        ST_STOP_BIT,
        ST_DONE
    );
    signal state : rx_state_t := ST_IDLE;

    -- ── 2-FF synchroniser for metastability on async RX pin ────────────────
    signal rx_sync0, rx_sync1 : std_logic := '1';

    -- ── Internal signals ───────────────────────────────────────────────────
    signal clk_cnt   : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_index : integer range 0 to 7 := 0;
    signal rx_byte   : std_logic_vector(7 downto 0) := (others => '0');

begin

    -- ── Two-flip-flop synchroniser ─────────────────────────────────────────
    sync_proc : process(clk)
    begin
        if rising_edge(clk) then
            rx_sync0 <= rx_serial;
            rx_sync1 <= rx_sync0;
        end if;
    end process sync_proc;

    -- ── Main FSM ───────────────────────────────────────────────────────────
    rx_fsm : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state     <= ST_IDLE;
                clk_cnt   <= 0;
                bit_index <= 0;
                rx_byte   <= (others => '0');
                rx_data   <= (others => '0');
                rx_done   <= '0';
            else
                -- Default outputs
                rx_done <= '0';

                case state is

                    -- ── Wait for start bit (falling edge on RX) ──────────
                    when ST_IDLE =>
                        clk_cnt   <= 0;
                        bit_index <= 0;
                        if rx_sync1 = '0' then          -- start bit detected
                            state <= ST_START_BIT;
                        end if;

                    -- ── Verify start bit at mid-point ────────────────────
                    -- Sample at CLKS_PER_BIT/2 – 1 to land in the centre
                    when ST_START_BIT =>
                        if clk_cnt = (CLKS_PER_BIT / 2) - 1 then
                            clk_cnt <= 0;
                            if rx_sync1 = '0' then      -- valid start bit
                                state <= ST_DATA_BITS;
                            else
                                state <= ST_IDLE;        -- glitch – abort
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    -- ── Sample 8 data bits, LSB first ────────────────────
                    when ST_DATA_BITS =>
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            -- Shift bit into MSB; bits fill from right
                            rx_byte(bit_index) <= rx_sync1;
                            if bit_index = 7 then
                                bit_index <= 0;
                                state     <= ST_STOP_BIT;
                            else
                                bit_index <= bit_index + 1;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    -- ── Verify stop bit ───────────────────────────────────
                    when ST_STOP_BIT =>
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            if rx_sync1 = '1' then      -- valid stop bit
                                state <= ST_DONE;
                            else
                                state <= ST_IDLE;       -- framing error
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    -- ── Output the received byte ──────────────────────────
                    when ST_DONE =>
                        rx_data <= rx_byte;
                        rx_done <= '1';
                        state   <= ST_IDLE;

                    when others =>
                        state <= ST_IDLE;

                end case;
            end if;
        end if;
    end process rx_fsm;

end architecture rtl;

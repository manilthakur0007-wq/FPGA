-- =============================================================================
-- uart_framing.vhd
-- UART Sample Framing – encodes/decodes 16-bit signed samples
-- =============================================================================
-- Frame format (4 bytes):
--   Byte 0: 0xAA  (start/sync byte)
--   Byte 1: sample[15:8]  (MSB)
--   Byte 2: sample[7:0]   (LSB)
--   Byte 3: checksum = 0xAA XOR MSB XOR LSB
--
-- This module provides TWO sub-modules:
--   1. uart_framing_tx – takes a 16-bit sample and drives the UART TX pipe
--   2. uart_framing_rx – receives framed bytes from UART RX and reconstructs samples
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- TX Framer: Sample → 4 UART bytes
-- =============================================================================
entity uart_framing_tx is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        -- Input sample (signed 16-bit)
        sample_in    : in  signed(15 downto 0);
        sample_valid : in  std_logic;           -- pulse to start transmission
        -- UART TX interface (connects to uart_tx)
        tx_data      : out std_logic_vector(7 downto 0);
        tx_start     : out std_logic;
        tx_busy      : in  std_logic;
        -- Status
        frame_done   : out std_logic            -- all 4 bytes sent
    );
end entity uart_framing_tx;

architecture rtl of uart_framing_tx is

    constant START_BYTE : std_logic_vector(7 downto 0) := x"AA";

    type tx_state_t is (ST_IDLE, ST_BYTE0, ST_BYTE1, ST_BYTE2, ST_BYTE3, ST_DONE);
    signal state : tx_state_t := ST_IDLE;

    signal msb      : std_logic_vector(7 downto 0);
    signal lsb      : std_logic_vector(7 downto 0);
    signal checksum : std_logic_vector(7 downto 0);

    -- Wait one idle cycle before asserting tx_start to allow tx_busy to settle
    signal send_req : std_logic := '0';
    signal byte_buf : std_logic_vector(7 downto 0) := (others => '0');

begin

    tx_proc : process(clk)
        variable raw : std_logic_vector(15 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state      <= ST_IDLE;
                tx_data    <= (others => '0');
                tx_start   <= '0';
                frame_done <= '0';
                send_req   <= '0';
            else
                -- Default
                tx_start   <= '0';
                frame_done <= '0';

                case state is

                    when ST_IDLE =>
                        if sample_valid = '1' and tx_busy = '0' then
                            raw       := std_logic_vector(sample_in);
                            msb       <= raw(15 downto 8);
                            lsb       <= raw(7  downto 0);
                            checksum  <= START_BYTE xor raw(15 downto 8) xor raw(7 downto 0);
                            state     <= ST_BYTE0;
                        end if;

                    -- ── Send 0xAA (start byte) ────────────────────────────
                    when ST_BYTE0 =>
                        if tx_busy = '0' then
                            tx_data  <= START_BYTE;
                            tx_start <= '1';
                            state    <= ST_BYTE1;
                        end if;

                    -- ── Send MSB ──────────────────────────────────────────
                    when ST_BYTE1 =>
                        if tx_busy = '0' then
                            tx_data  <= msb;
                            tx_start <= '1';
                            state    <= ST_BYTE2;
                        end if;

                    -- ── Send LSB ──────────────────────────────────────────
                    when ST_BYTE2 =>
                        if tx_busy = '0' then
                            tx_data  <= lsb;
                            tx_start <= '1';
                            state    <= ST_BYTE3;
                        end if;

                    -- ── Send checksum ─────────────────────────────────────
                    when ST_BYTE3 =>
                        if tx_busy = '0' then
                            tx_data  <= checksum;
                            tx_start <= '1';
                            state    <= ST_DONE;
                        end if;

                    when ST_DONE =>
                        if tx_busy = '0' then
                            frame_done <= '1';
                            state      <= ST_IDLE;
                        end if;

                    when others =>
                        state <= ST_IDLE;

                end case;
            end if;
        end if;
    end process tx_proc;

end architecture rtl;


-- =============================================================================
-- RX Deframer: 4 UART bytes → reconstructed 16-bit sample
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_framing_rx is
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        -- UART RX interface (connects to uart_rx)
        rx_data       : in  std_logic_vector(7 downto 0);
        rx_done       : in  std_logic;
        -- Output sample
        sample_out    : out signed(15 downto 0);
        sample_valid  : out std_logic;           -- pulse when sample ready
        -- Status
        checksum_err  : out std_logic;           -- pulse on checksum mismatch
        sync_err      : out std_logic            -- pulse on bad start byte
    );
end entity uart_framing_rx;

architecture rtl of uart_framing_rx is

    constant START_BYTE : std_logic_vector(7 downto 0) := x"AA";

    type rx_state_t is (ST_HUNT, ST_MSB, ST_LSB, ST_CHECKSUM);
    signal state : rx_state_t := ST_HUNT;

    signal msb_reg : std_logic_vector(7 downto 0) := (others => '0');
    signal lsb_reg : std_logic_vector(7 downto 0) := (others => '0');

begin

    rx_proc : process(clk)
        variable expected_cs : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state        <= ST_HUNT;
                msb_reg      <= (others => '0');
                lsb_reg      <= (others => '0');
                sample_out   <= (others => '0');
                sample_valid <= '0';
                checksum_err <= '0';
                sync_err     <= '0';
            else
                -- Defaults
                sample_valid <= '0';
                checksum_err <= '0';
                sync_err     <= '0';

                if rx_done = '1' then
                    case state is

                        -- ── Hunt for sync byte 0xAA ───────────────────────
                        when ST_HUNT =>
                            if rx_data = START_BYTE then
                                state <= ST_MSB;
                            else
                                sync_err <= '1';  -- unexpected byte
                            end if;

                        -- ── Receive MSB ───────────────────────────────────
                        when ST_MSB =>
                            msb_reg <= rx_data;
                            state   <= ST_LSB;

                        -- ── Receive LSB ───────────────────────────────────
                        when ST_LSB =>
                            lsb_reg <= rx_data;
                            state   <= ST_CHECKSUM;

                        -- ── Validate checksum and output sample ───────────
                        when ST_CHECKSUM =>
                            expected_cs := START_BYTE xor msb_reg xor lsb_reg;
                            if rx_data = expected_cs then
                                sample_out   <= signed(msb_reg & lsb_reg);
                                sample_valid <= '1';
                            else
                                checksum_err <= '1';
                            end if;
                            state <= ST_HUNT;   -- back to hunting for next frame

                        when others =>
                            state <= ST_HUNT;

                    end case;
                end if;
            end if;
        end if;
    end process rx_proc;

end architecture rtl;

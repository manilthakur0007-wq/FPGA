-- =============================================================================
-- fir_top.vhd
-- Top-Level Entity: UART RX → FIR Filter → UART TX Pipeline
-- =============================================================================
-- Data flow:
--   1. External UART stream arrives on uart_rx_pin
--   2. uart_rx deserializes bytes → uart_framing_rx reassembles 16-bit samples
--   3. Samples are fed into the FIR low-pass filter
--   4. Filtered samples are packed by uart_framing_tx → uart_tx serializes
--   5. Filtered UART stream exits on uart_tx_pin
--
-- Additional features:
--   • clock_divider generates an 8 kHz sample-rate clock enable
--   • Reset synchroniser provides a clean reset across clock domains
--   • Status LEDs for monitoring (map to real GPIO on physical FPGA)
--
-- Target: Xilinx Artix-7 (xc7a35tcpg236-1) but portable to any FPGA
-- System clock: 100 MHz (standard Artix-7 oscillator)
-- UART: 115200 baud (configurable via CLKS_PER_BIT generic)
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.fir_coefficients_pkg.all;

entity fir_top is
    generic (
        SYS_CLK_HZ   : integer := 100_000_000;  -- system clock frequency
        BAUD_RATE    : integer := 115_200;        -- UART baud rate
        DATA_WIDTH   : integer := 16;             -- sample width
        NUM_TAPS     : integer := 16              -- FIR filter taps
    );
    port (
        -- System
        sys_clk      : in  std_logic;             -- 100 MHz system clock
        rst_btn      : in  std_logic;             -- active-high reset button

        -- UART
        uart_rx_pin  : in  std_logic;             -- UART RX (from host)
        uart_tx_pin  : out std_logic;             -- UART TX (to host)

        -- Status LEDs (active-high, maps to FPGA I/O)
        led_rx       : out std_logic;             -- blinks on RX activity
        led_tx       : out std_logic;             -- blinks on TX activity
        led_locked   : out std_logic;             -- high when reset released
        led_overflow : out std_logic              -- high on checksum error
    );
end entity fir_top;

architecture rtl of fir_top is

    -- ── Clocks-per-bit ─────────────────────────────────────────────────────
    constant CLKS_PER_BIT : integer := SYS_CLK_HZ / BAUD_RATE;

    -- ── Reset synchroniser ─────────────────────────────────────────────────
    signal rst_sync0, rst_sync1 : std_logic := '1';
    signal rst_n : std_logic;   -- active-low synchronised reset

    -- ── UART RX ────────────────────────────────────────────────────────────
    signal rx_data_byte : std_logic_vector(7 downto 0);
    signal rx_done      : std_logic;

    -- ── RX Deframer ────────────────────────────────────────────────────────
    signal rx_sample      : signed(DATA_WIDTH - 1 downto 0);
    signal rx_sample_valid: std_logic;
    signal checksum_err   : std_logic;
    signal sync_err       : std_logic;

    -- ── FIR Filter ─────────────────────────────────────────────────────────
    signal fir_out        : signed(DATA_WIDTH - 1 downto 0);
    signal fir_valid      : std_logic;

    -- ── TX Framer ──────────────────────────────────────────────────────────
    signal tx_data_byte : std_logic_vector(7 downto 0);
    signal tx_start     : std_logic;
    signal tx_busy      : std_logic;
    signal tx_done      : std_logic;
    signal frame_done   : std_logic;

    -- ── LED stretch counters (≈0.1s at 100 MHz = 10M cycles) ───────────────
    constant LED_STRETCH : integer := 10_000_000;
    signal led_rx_cnt    : integer range 0 to LED_STRETCH := 0;
    signal led_tx_cnt    : integer range 0 to LED_STRETCH := 0;
    signal led_err_cnt   : integer range 0 to LED_STRETCH := 0;

begin

    -- =========================================================================
    -- Reset Synchroniser
    -- Synchronises the asynchronous button to the system clock domain
    -- =========================================================================
    rst_sync_proc : process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            rst_sync0 <= not rst_btn;   -- button is active-high; invert to active-low
            rst_sync1 <= rst_sync0;
        end if;
    end process rst_sync_proc;

    rst_n      <= rst_sync1;
    led_locked <= rst_sync1;   -- LED on when out of reset

    -- =========================================================================
    -- UART Receiver
    -- =========================================================================
    u_uart_rx : entity work.uart_rx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk       => sys_clk,
            rst_n     => rst_n,
            rx_serial => uart_rx_pin,
            rx_data   => rx_data_byte,
            rx_done   => rx_done
        );

    -- =========================================================================
    -- RX Frame Decoder
    -- =========================================================================
    u_rx_deframer : entity work.uart_framing_rx
        port map (
            clk          => sys_clk,
            rst_n        => rst_n,
            rx_data      => rx_data_byte,
            rx_done      => rx_done,
            sample_out   => rx_sample,
            sample_valid => rx_sample_valid,
            checksum_err => checksum_err,
            sync_err     => sync_err
        );

    -- =========================================================================
    -- FIR Low-Pass Filter
    -- =========================================================================
    u_fir : entity work.fir_filter
        generic map (
            NUM_TAPS    => NUM_TAPS,
            DATA_WIDTH  => DATA_WIDTH,
            COEFF_WIDTH => fir_coefficients_pkg.COEFF_WIDTH   -- from package
        )
        port map (
            clk       => sys_clk,
            rst_n     => rst_n,
            data_in   => rx_sample,
            valid_in  => rx_sample_valid,
            data_out  => fir_out,
            valid_out => fir_valid
        );

    -- =========================================================================
    -- TX Frame Encoder
    -- =========================================================================
    u_tx_framer : entity work.uart_framing_tx
        port map (
            clk          => sys_clk,
            rst_n        => rst_n,
            sample_in    => fir_out,
            sample_valid => fir_valid,
            tx_data      => tx_data_byte,
            tx_start     => tx_start,
            tx_busy      => tx_busy,
            frame_done   => frame_done
        );

    -- =========================================================================
    -- UART Transmitter
    -- =========================================================================
    u_uart_tx : entity work.uart_tx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk       => sys_clk,
            rst_n     => rst_n,
            tx_start  => tx_start,
            tx_data   => tx_data_byte,
            tx_serial => uart_tx_pin,
            tx_done   => tx_done,
            tx_busy   => tx_busy
        );

    -- =========================================================================
    -- Status LED Stretch Logic
    -- Each LED is held on for ≈0.1 s after the triggering event
    -- =========================================================================
    led_proc : process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if rst_n = '0' then
                led_rx_cnt  <= 0;
                led_tx_cnt  <= 0;
                led_err_cnt <= 0;
                led_rx      <= '0';
                led_tx      <= '0';
                led_overflow<= '0';
            else
                -- RX activity
                if rx_done = '1' then
                    led_rx_cnt <= LED_STRETCH;
                elsif led_rx_cnt > 0 then
                    led_rx_cnt <= led_rx_cnt - 1;
                end if;
                led_rx <= '1' when led_rx_cnt > 0 else '0';

                -- TX activity
                if tx_done = '1' then
                    led_tx_cnt <= LED_STRETCH;
                elsif led_tx_cnt > 0 then
                    led_tx_cnt <= led_tx_cnt - 1;
                end if;
                led_tx <= '1' when led_tx_cnt > 0 else '0';

                -- Error (checksum or sync)
                if checksum_err = '1' or sync_err = '1' then
                    led_err_cnt <= LED_STRETCH;
                elsif led_err_cnt > 0 then
                    led_err_cnt <= led_err_cnt - 1;
                end if;
                led_overflow <= '1' when led_err_cnt > 0 else '0';
            end if;
        end if;
    end process led_proc;

end architecture rtl;

-- =============================================================================
-- clock_divider.vhd
-- Counter-based clock divider
-- =============================================================================
-- Generates a slower clock enable (not a real clock) from the system clock.
-- Using a clock enable rather than a divided clock avoids CDC issues and
-- is the recommended approach for FPGA design.
--
-- Generics:
--   CLK_IN_HZ  – Input clock frequency in Hz
--   CLK_OUT_HZ – Desired output frequency in Hz
--
-- Output:
--   clk_en – pulses high for one system clock cycle at CLK_OUT_HZ rate
--
-- NOTE: On a real FPGA, if you genuinely need a divided clock (e.g., for I/O),
-- use the vendor's PLL/MMCM primitive instead of this module.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity clock_divider is
    generic (
        CLK_IN_HZ  : integer := 100_000_000;   -- 100 MHz
        CLK_OUT_HZ : integer :=   8_000_000    -- 8 MHz (or any lower value)
    );
    port (
        clk    : in  std_logic;
        rst_n  : in  std_logic;
        clk_en : out std_logic   -- clock enable, 1 cycle wide at CLK_OUT_HZ
    );
end entity clock_divider;

architecture rtl of clock_divider is

    -- Number of system clocks per output period (integer division)
    constant DIVISOR : integer := CLK_IN_HZ / CLK_OUT_HZ;

    -- Counter width: log2(DIVISOR) + 1 bits
    -- We use a natural integer range; synthesis tool handles the width.
    signal counter : integer range 0 to DIVISOR - 1 := 0;

begin

    -- Sanity check at elaboration time
    assert DIVISOR >= 2
        report "CLK_OUT_HZ must be less than CLK_IN_HZ / 2"
        severity failure;

    div_proc : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                counter <= 0;
                clk_en  <= '0';
            else
                if counter = DIVISOR - 1 then
                    counter <= 0;
                    clk_en  <= '1';
                else
                    counter <= counter + 1;
                    clk_en  <= '0';
                end if;
            end if;
        end if;
    end process div_proc;

end architecture rtl;

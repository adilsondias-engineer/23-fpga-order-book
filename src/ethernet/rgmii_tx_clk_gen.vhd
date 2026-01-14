----------------------------------------------------------------------------------
-- RGMII TX Clock Generation
-- Description: Generates 125 MHz clock and 90-degree phase-shifted clock for RGMII TX
-- Uses MMCM to generate synchronized clocks from 200 MHz system clock
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity rgmii_tx_clk_gen is
    Port (
        clk_in_200mhz  : in  STD_LOGIC;  -- 200 MHz system clock
        reset          : in  STD_LOGIC;

        clk_125mhz     : out STD_LOGIC;  -- 125 MHz clock for RGMII TX data
        clk_125mhz_90  : out STD_LOGIC;  -- 125 MHz clock with 90-degree phase shift for TXC
        locked         : out STD_LOGIC   -- PLL lock indicator
    );
end rgmii_tx_clk_gen;

architecture Behavioral of rgmii_tx_clk_gen is

    signal clk_125mhz_unbuf : STD_LOGIC;
    signal clk_125mhz_90_unbuf : STD_LOGIC;
    signal clk_feedback : STD_LOGIC;
    signal locked_int : STD_LOGIC;

begin

    locked <= locked_int;

    -- MMCME2_BASE: Mixed Mode Clock Manager
    -- 7 Series
    -- Xilinx HDL Libraries Guide, version 2019.1
    mmcm_inst : MMCME2_BASE
        generic map (
            BANDWIDTH => "OPTIMIZED",   -- Jitter programming (OPTIMIZED, HIGH, LOW)
            CLKFBOUT_MULT_F => 5.0,     -- 200 MHz * 5 = 1000 MHz (VCO)
            CLKFBOUT_PHASE => 0.0,      -- Phase offset in degrees of CLKFB (-360.000-360.000)
            CLKIN1_PERIOD => 5.0,       -- Input clock period in ns (200 MHz = 5 ns)

            -- CLKOUT0: 125 MHz (1000 MHz / 8 = 125 MHz)
            CLKOUT0_DIVIDE_F => 8.0,    -- Divide amount for CLKOUT0 (1.000-128.000)
            CLKOUT0_DUTY_CYCLE => 0.5,
            CLKOUT0_PHASE => 0.0,

            -- CLKOUT1: 125 MHz with 90-degree phase shift
            CLKOUT1_DIVIDE => 8,
            CLKOUT1_DUTY_CYCLE => 0.5,
            CLKOUT1_PHASE => 90.0,      -- 90-degree phase shift for center-aligned TXC

            CLKOUT4_CASCADE => FALSE,   -- Cascade CLKOUT4 counter with CLKOUT6 (FALSE, TRUE)
            DIVCLK_DIVIDE => 1,         -- Master division value (1-106)
            REF_JITTER1 => 0.0,         -- Reference input jitter in UI (0.000-0.999)
            STARTUP_WAIT => FALSE       -- Delays DONE until MMCM is locked (FALSE, TRUE)
        )
        port map (
            -- Clock Outputs
            CLKOUT0 => clk_125mhz_unbuf,
            CLKOUT0B => open,
            CLKOUT1 => clk_125mhz_90_unbuf,
            CLKOUT1B => open,
            CLKOUT2 => open,
            CLKOUT2B => open,
            CLKOUT3 => open,
            CLKOUT3B => open,
            CLKOUT4 => open,
            CLKOUT5 => open,
            CLKOUT6 => open,

            -- Feedback Clocks
            CLKFBOUT => clk_feedback,
            CLKFBOUTB => open,

            -- Status Ports
            LOCKED => locked_int,

            -- Clock Inputs
            CLKIN1 => clk_in_200mhz,

            -- Control Ports
            PWRDWN => '0',
            RST => reset,

            -- Feedback
            CLKFBIN => clk_feedback
        );

    -- Buffer output clocks
    bufg_125mhz : BUFG
        port map (
            I => clk_125mhz_unbuf,
            O => clk_125mhz
        );

    bufg_125mhz_90 : BUFG
        port map (
            I => clk_125mhz_90_unbuf,
            O => clk_125mhz_90
        );

end Behavioral;

----------------------------------------------------------------------------------
-- RGMII Transmitter
-- Description: RGMII TX interface with DDR output for Gigabit Ethernet
-- Generates RGMII TX signals (TXC, TXCTL, TXD) from byte stream
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;

-- IDELAYCTRL component declaration for delay calibration
-- Note: IDELAYCTRL is instantiated in ethernet_top.vhd

entity rgmii_tx is
    Port (
        -- System clock (125 MHz for RGMII)
        clk_125mhz    : in  STD_LOGIC;
        clk_125mhz_90 : in  STD_LOGIC;  -- 90-degree phase shift for DDR alignment
        reset         : in  STD_LOGIC;

        -- Byte stream input (125 MHz domain)
        tx_data       : in  STD_LOGIC_VECTOR(7 downto 0);
        tx_valid      : in  STD_LOGIC;  -- Data valid
        tx_error      : in  STD_LOGIC;  -- TX error

        -- RGMII outputs
        rgmii_txc     : out STD_LOGIC;
        rgmii_txctl   : out STD_LOGIC;
        rgmii_txd     : out STD_LOGIC_VECTOR(3 downto 0);

        -- Debug outputs
        dbg_tx_byte_count : out STD_LOGIC_VECTOR(31 downto 0);  -- Total bytes transmitted
        dbg_tx_valid_seen : out STD_LOGIC;                      -- Sticky: tx_valid was asserted
        dbg_last_tx_byte  : out STD_LOGIC_VECTOR(7 downto 0)    -- Last byte transmitted
    );
end rgmii_tx;

architecture Behavioral of rgmii_tx is

    -- Pipeline registers (vendor uses 2 stages before ODDRs)
    -- Stage 1: First register
    signal tx_data_r1    : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal tx_valid_r1   : STD_LOGIC := '0';
    signal tx_error_r1   : STD_LOGIC := '0';
    -- Stage 2: Second register (feeds ODDRs)
    signal tx_data_r2    : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal tx_valid_r2   : STD_LOGIC := '0';
    signal tx_error_r2   : STD_LOGIC := '0';

    -- DDR signals (D1 = rising edge, D2 = falling edge)
    signal txd_d1 : STD_LOGIC_VECTOR(3 downto 0);  -- Rising edge data
    signal txd_d2 : STD_LOGIC_VECTOR(3 downto 0);  -- Falling edge data
    signal txctl_d1 : STD_LOGIC;  -- Rising edge control
    signal txctl_d2 : STD_LOGIC;  -- Falling edge control

    -- Debug signals
    signal tx_byte_counter : unsigned(31 downto 0) := (others => '0');
    signal tx_valid_seen_reg : STD_LOGIC := '0';
    signal last_tx_byte_reg : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

begin

    -- Debug logic: track bytes transmitted
    process(clk_125mhz)
    begin
        if rising_edge(clk_125mhz) then
            if reset = '1' then
                tx_byte_counter <= (others => '0');
                tx_valid_seen_reg <= '0';
                last_tx_byte_reg <= (others => '0');
            elsif tx_valid = '1' then
                tx_byte_counter <= tx_byte_counter + 1;
                tx_valid_seen_reg <= '1';  -- Sticky flag
                last_tx_byte_reg <= tx_data;
            end if;
        end if;
    end process;

    -- Debug output assignments
    dbg_tx_byte_count <= std_logic_vector(tx_byte_counter);
    dbg_tx_valid_seen <= tx_valid_seen_reg;
    dbg_last_tx_byte <= last_tx_byte_reg;

    -- Two-stage pipeline registers before ODDRs (matches vendor implementation)
    -- This ensures stable setup/hold times at ODDR inputs
    process(clk_125mhz)
    begin
        if rising_edge(clk_125mhz) then
            -- Stage 1: Register inputs
            tx_data_r1  <= tx_data;
            tx_valid_r1 <= tx_valid;
            tx_error_r1 <= tx_error;
            -- Stage 2: Second register (feeds ODDRs)
            tx_data_r2  <= tx_data_r1;
            tx_valid_r2 <= tx_valid_r1;
            tx_error_r2 <= tx_error_r1;
        end if;
    end process;

    -- Split byte into two nibbles for DDR transmission
    -- RGMII spec: Low nibble on rising edge (D1), High nibble on falling edge (D2)
    -- Use stage 2 registered data for stable ODDR inputs
    txd_d1 <= tx_data_r2(3 downto 0);  -- D1 = low nibble (rising edge)
    txd_d2 <= tx_data_r2(7 downto 4);  -- D2 = high nibble (falling edge)

    -- TXCTL encoding per RGMII spec:
    -- Rising edge (D1): TX_EN
    -- Falling edge (D2): TX_EN XOR TX_ER
    -- Use stage 2 registered control for stable ODDR inputs
    txctl_d1 <= tx_valid_r2;                   -- Rising edge: TX_EN
    txctl_d2 <= tx_valid_r2 xor tx_error_r2;   -- Falling edge: TX_EN XOR TX_ER

    -- RGMII TXC - DDR output of 125 MHz clock
    -- Note: No reset on TXC (vendor uses R=0) - clock should always run
    txc_oddr: ODDR
        generic map (
           DDR_CLK_EDGE => "SAME_EDGE",
           INIT => '0',
           SRTYPE => "ASYNC"
        )
        port map (
            Q  => rgmii_txc,
            C  => clk_125mhz_90,  -- 90-degree phase shift for center alignment
            CE => '1',
            D1 => '1',
            D2 => '0',
            R  => '0',   -- No reset - clock always runs (matches vendor)
            S  => '0'
        );

    -- RGMII TXCTL - DDR output
    txctl_oddr: ODDR
        generic map (
           DDR_CLK_EDGE => "SAME_EDGE",
           INIT => '0',
           SRTYPE => "ASYNC"
        )
        port map (
            Q  => rgmii_txctl,
            C  => clk_125mhz,
            CE => '1',
            D1 => txctl_d1,
            D2 => txctl_d2,
            R  => reset,
            S  => '0'
        );

    -- RGMII TXD[0] - DDR output
    txd0_oddr: ODDR
        generic map (
           DDR_CLK_EDGE => "SAME_EDGE",
           INIT => '0',
           SRTYPE => "ASYNC"
        )
        port map (
            Q  => rgmii_txd(0),
            C  => clk_125mhz,
            CE => '1',
            D1 => txd_d1(0),
            D2 => txd_d2(0),
            R  => reset,
            S  => '0'
        );

    -- RGMII TXD[1] - DDR output
    txd1_oddr: ODDR
        generic map (
           DDR_CLK_EDGE => "SAME_EDGE",
           INIT => '0',
           SRTYPE => "ASYNC"
        )
        port map (
            Q  => rgmii_txd(1),
            C  => clk_125mhz,
            CE => '1',
            D1 => txd_d1(1),
            D2 => txd_d2(1),
            R  => reset,
            S  => '0'
        );

    -- RGMII TXD[2] - DDR output
    txd2_oddr: ODDR
        generic map (
            DDR_CLK_EDGE => "SAME_EDGE",
           INIT => '0',
           SRTYPE => "ASYNC"
        )
        port map (
            Q  => rgmii_txd(2),
            C  => clk_125mhz,
            CE => '1',
            D1 => txd_d1(2),
            D2 => txd_d2(2),
            R  => reset,
            S  => '0'
        );

    -- RGMII TXD[3] - DDR output
    txd3_oddr: ODDR
        generic map (
           DDR_CLK_EDGE => "SAME_EDGE",
           INIT => '0',
           SRTYPE => "ASYNC"
        )
        port map (
            Q  => rgmii_txd(3),
            C  => clk_125mhz,
            CE => '1',
            D1 => txd_d1(3),
            D2 => txd_d2(3),
            R  => reset,
            S  => '0'
        );

end Behavioral;

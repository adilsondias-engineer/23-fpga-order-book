--------------------------------------------------------------------------------
-- MDIO JL2121 PHY Configurator
-- Configures JLSemi JL2121-N040I PHY on startup
--------------------------------------------------------------------------------
-- Initialization sequence (per vendor reference phy_reg_config.v):
-- 1. Read PHY ID registers (0x02, 0x03) to verify communication
-- 2. Power down PHY (Register 0x00 = 0x1900)
-- 3. Wait 10ms for power down to complete
-- 4. Power up and enable autonegotiation (Register 0x00 = 0x1100)
-- Note: Uses power cycle instead of soft reset to properly enable TX path
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mdio_jl2121_config is
    generic (
        CLK_FREQ_HZ : integer := 200_000_000;
        PHY_ADDR    : std_logic_vector(4 downto 0) := "00001"  -- JL2121 default address
    );
    port (
        clk               : in  std_logic;
        reset             : in  std_logic;

        -- MDIO controller interface
        mdio_start        : out std_logic;
        mdio_busy         : in  std_logic;
        mdio_done         : in  std_logic;
        mdio_rw           : out std_logic;  -- '0' = read, '1' = write
        mdio_phy_addr     : out std_logic_vector(4 downto 0);
        mdio_reg_addr     : out std_logic_vector(4 downto 0);
        mdio_write_data   : out std_logic_vector(15 downto 0);
        mdio_read_data    : in  std_logic_vector(15 downto 0);

        -- Status
        config_done       : out std_logic;  -- Configuration complete
        phy_id            : out std_logic_vector(31 downto 0)  -- PHY ID (for debugging)
    );
end mdio_jl2121_config;

architecture rtl of mdio_jl2121_config is

    -- State machine
    type state_t is (
        INIT,
        WAIT_DELAY,
        -- Read PHY ID
        READ_PHY_ID_HIGH,
        WAIT_READ_HIGH,
        STORE_ID_HIGH,
        READ_PHY_ID_LOW,
        WAIT_READ_LOW,
        STORE_ID_LOW,
        -- Power cycle (per vendor reference)
        WRITE_POWERDOWN,
        WAIT_WRITE_POWERDOWN,
        WAIT_POWERDOWN_DELAY,
        -- Configure basic control (power up)
        WRITE_BASIC_CONTROL,
        WAIT_WRITE_CONTROL,
        -- Configuration complete
        CONFIG_COMPLETE
    );
    signal state : state_t := INIT;

    -- PHY ID storage
    signal phy_id_high : std_logic_vector(15 downto 0) := (others => '0');
    signal phy_id_low : std_logic_vector(15 downto 0) := (others => '0');

    -- Delay counter
    signal delay_counter : integer range 0 to CLK_FREQ_HZ - 1 := 0;
    constant INITIAL_DELAY : integer := CLK_FREQ_HZ / 10;  -- 100ms before first operation
    constant POWERDOWN_DELAY : integer := CLK_FREQ_HZ / 100;   -- 10ms after power down (matches vendor)

    -- Register addresses
    constant REG_BASIC_CONTROL : std_logic_vector(4 downto 0) := "00000";  -- 0x00
    constant REG_PHY_ID_HIGH   : std_logic_vector(4 downto 0) := "00010";  -- 0x02
    constant REG_PHY_ID_LOW    : std_logic_vector(4 downto 0) := "00011";  -- 0x03

    -- Register values
    -- Basic Control Register (0x00):
    -- Bit 15: Reset (1 = reset)
    -- Bit 14: Loopback (0 = normal)
    -- Bit 13: Speed select (0/1 with bit 6 for speed)
    -- Bit 12: Autonegotiation enable (1 = enable)
    -- Bit 11: Power down (0 = normal, 1 = power down)
    -- Bit 10: Isolate (0 = normal)
    -- Bit 9: Restart autonegotiation (1 = restart)
    -- Bit 8: Duplex mode (0 = half, 1 = full)
    -- Bit 6: Speed select bit 1
    -- Use power cycle instead of soft reset (per vendor reference phy_reg_config.v)
    constant POWERDOWN_VALUE : std_logic_vector(15 downto 0) := x"1900";  -- Autoneg + Power down + Full duplex
    constant CONTROL_VALUE : std_logic_vector(15 downto 0) := x"1100";  -- Autoneg + Full duplex (power up)

begin

    -- Output PHY ID
    phy_id <= phy_id_high & phy_id_low;

    -- Output PHY address
    mdio_phy_addr <= PHY_ADDR;

    -- Configuration status
    config_done <= '1' when state = CONFIG_COMPLETE else '0';

    -- Main state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= INIT;
                mdio_start <= '0';
                mdio_rw <= '0';
                mdio_reg_addr <= (others => '0');
                mdio_write_data <= (others => '0');
                phy_id_high <= (others => '0');
                phy_id_low <= (others => '0');
                delay_counter <= 0;
            else
                -- Default: clear start pulse
                mdio_start <= '0';

                case state is
                    when INIT =>
                        -- Initial delay to allow PHY to power up
                        delay_counter <= INITIAL_DELAY;
                        state <= WAIT_DELAY;

                    when WAIT_DELAY =>
                        if delay_counter = 0 then
                            state <= READ_PHY_ID_HIGH;
                        else
                            delay_counter <= delay_counter - 1;
                        end if;

                    -- Read PHY ID High (0x02)
                    when READ_PHY_ID_HIGH =>
                        mdio_rw <= '0';  -- Read
                        mdio_reg_addr <= REG_PHY_ID_HIGH;
                        mdio_start <= '1';
                        state <= WAIT_READ_HIGH;

                    when WAIT_READ_HIGH =>
                        if mdio_busy = '1' then
                            mdio_start <= '0';
                        end if;
                        if mdio_done = '1' then
                            state <= STORE_ID_HIGH;
                        end if;

                    when STORE_ID_HIGH =>
                        phy_id_high <= mdio_read_data;
                        state <= READ_PHY_ID_LOW;

                    -- Read PHY ID Low (0x03)
                    when READ_PHY_ID_LOW =>
                        mdio_rw <= '0';  -- Read
                        mdio_reg_addr <= REG_PHY_ID_LOW;
                        mdio_start <= '1';
                        state <= WAIT_READ_LOW;

                    when WAIT_READ_LOW =>
                        if mdio_busy = '1' then
                            mdio_start <= '0';
                        end if;
                        if mdio_done = '1' then
                            state <= STORE_ID_LOW;
                        end if;

                    when STORE_ID_LOW =>
                        phy_id_low <= mdio_read_data;
                        state <= WRITE_POWERDOWN;

                    -- Write power down to Basic Control Register (per vendor reference)
                    when WRITE_POWERDOWN =>
                        mdio_rw <= '1';  -- Write
                        mdio_reg_addr <= REG_BASIC_CONTROL;
                        mdio_write_data <= POWERDOWN_VALUE;
                        mdio_start <= '1';
                        state <= WAIT_WRITE_POWERDOWN;

                    when WAIT_WRITE_POWERDOWN =>
                        if mdio_busy = '1' then
                            mdio_start <= '0';
                        end if;
                        if mdio_done = '1' then
                            delay_counter <= POWERDOWN_DELAY;
                            state <= WAIT_POWERDOWN_DELAY;
                        end if;

                    when WAIT_POWERDOWN_DELAY =>
                        -- Wait after power down before power up
                        if delay_counter = 0 then
                            state <= WRITE_BASIC_CONTROL;
                        else
                            delay_counter <= delay_counter - 1;
                        end if;

                    -- Write basic configuration
                    when WRITE_BASIC_CONTROL =>
                        mdio_rw <= '1';  -- Write
                        mdio_reg_addr <= REG_BASIC_CONTROL;
                        mdio_write_data <= CONTROL_VALUE;
                        mdio_start <= '1';
                        state <= WAIT_WRITE_CONTROL;

                    when WAIT_WRITE_CONTROL =>
                        if mdio_busy = '1' then
                            mdio_start <= '0';
                        end if;
                        if mdio_done = '1' then
                            state <= CONFIG_COMPLETE;
                        end if;

                    when CONFIG_COMPLETE =>
                        -- Configuration complete, stay here
                        null;

                    when others =>
                        state <= INIT;
                end case;
            end if;
        end if;
    end process;

end rtl;

----------------------------------------------------------------------------------
-- Direct RGMII Receiver
-- Receives Ethernet frames directly from RGMII interface (no wrapper)
-- Based on AX7203 demo code structure
--
-- RGMII Specifications:
-- - 4-bit data bus (nibbles)
-- - DDR (Double Data Rate) - data on both clock edges
-- - 25 MHz clock for 100 Mbps mode
-- - 125 MHz clock for 1000 Mbps mode
-- - RX_CTL = RX_DV XOR RX_ER
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity rgmii_rx is
    Port (
        -- Clock from PHY (25 MHz for 100 Mbps, 125 MHz for 1000 Mbps)
        rgmii_rxc     : in  STD_LOGIC;
        reset         : in  STD_LOGIC;
        
        -- RGMII Interface (from PHY)
        rgmii_rxd     : in  STD_LOGIC_VECTOR(3 downto 0);   -- 4-bit data
        rgmii_rx_ctl  : in  STD_LOGIC;                      -- RX_DV XOR RX_ER
        
        -- Byte-level output
        rx_data       : out STD_LOGIC_VECTOR(7 downto 0);   -- Assembled byte
        rx_valid      : out STD_LOGIC;                      -- Byte valid
        rx_error      : out STD_LOGIC;                      -- Error detected
        
        -- Frame control
        frame_start   : out STD_LOGIC;                      -- Start of frame (after SFD)
        frame_end     : out STD_LOGIC                       -- End of frame

    );
end rgmii_rx;

architecture Behavioral of rgmii_rx is

    -- Inverted clock for IDDR2 C1 port (must be a signal, not expression)
    signal rgmii_rxc_inv : STD_LOGIC;
    
    -- DDR capture signals (using IDDR2 for each bit)
    signal rgmii_rxd_rising  : STD_LOGIC_VECTOR(3 downto 0);
    signal rgmii_rxd_falling : STD_LOGIC_VECTOR(3 downto 0);
    signal rgmii_rx_ctl_rising  : STD_LOGIC;
    signal rgmii_rx_ctl_falling : STD_LOGIC;

    -- Pipelined signals to align rising/falling edge data
    signal rgmii_rxd_rising_reg  : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal rgmii_rx_ctl_rising_reg : STD_LOGIC := '0';

    -- Frame validation state machine (simplified for timing)
    type state_t is (IDLE, CHECK_SFD, OUTPUT_FRAME);
    signal state : state_t := IDLE;


    -- Preamble/SFD detection (simplified)
    constant SFD_BYTE : STD_LOGIC_VECTOR(7 downto 0) := x"D5";
    signal prev_byte_was_55 : STD_LOGIC := '0';  -- Track if previous byte was 0x55


begin

    -- Invert clock for IDDR2 C1 port
    rgmii_rxc_inv <= not rgmii_rxc;

    -- =========================================================================
    -- DDR Capture: Use IDDR2 to capture data on both clock edges
    -- =========================================================================
    gen_ddr_capture: for i in 0 to 3 generate
        iddr2_rxd : IDDR2
            generic map (
                DDR_ALIGNMENT => "NONE",  -- No alignment - Q0 is manually pipelined
                INIT_Q0 => '0',
                INIT_Q1 => '0',
                SRTYPE => "SYNC"
            )
            port map (
                Q0 => rgmii_rxd_rising(i),   -- Rising edge data
                Q1 => rgmii_rxd_falling(i),  -- Falling edge data
                C0 => rgmii_rxc,             -- Clock
                C1 => rgmii_rxc_inv,         -- Inverted clock (signal)
                CE => '1',
                D  => rgmii_rxd(i),
                R  => reset,
                S  => '0'
            );
    end generate;
    
    -- Capture RX_CTL on both edges
    iddr2_rx_ctl : IDDR2
        generic map (
            DDR_ALIGNMENT => "NONE",  -- No alignment - Q0 is manually pipelined
            INIT_Q0 => '0',
            INIT_Q1 => '0',
            SRTYPE => "SYNC"
        )
        port map (
            Q0 => rgmii_rx_ctl_rising,
            Q1 => rgmii_rx_ctl_falling,
            C0 => rgmii_rxc,
            C1 => rgmii_rxc_inv,  -- Inverted clock (signal)
            CE => '1',
            D  => rgmii_rx_ctl,
            R  => reset,
            S  => '0'
        );

    -- =========================================================================
    -- Byte Assembly and Frame Validation with SFD Detection (Timing-Optimized)
    -- =========================================================================
    -- Strategy (simplified to meet timing):
    -- 1. Use shift register to buffer last 8 bytes while checking for SFD
    -- 2. When SFD (0xD5) found after 0x55, output buffered preamble
    -- 3. Then output rest of frame directly
    -- =========================================================================
    process(rgmii_rxc)
        variable byte_data_var : STD_LOGIC_VECTOR(7 downto 0);
    begin
        if rising_edge(rgmii_rxc) then
            if reset = '1' then
                rx_data <= (others => '0');
                rx_valid <= '0';
                rx_error <= '0';
                frame_start <= '0';
                frame_end <= '0';
                state <= IDLE;
                prev_byte_was_55 <= '0';
            else
                -- Assemble byte from IDDR2 outputs
                byte_data_var := rgmii_rxd_falling & rgmii_rxd_rising;

                -- Default: clear pulse signals
                frame_start <= '0';
                frame_end <= '0';
               
                case state is
                    -- =============================================================
                    -- IDLE: Wait for RX_CTL to start
                    -- =============================================================
                    when IDLE =>
                        rx_valid <= '0';
                         prev_byte_was_55 <= '0';
                        if rgmii_rx_ctl_rising = '1' then
                            state <= CHECK_SFD;
                        end if;

                    -- =============================================================
                    -- CHECK_SFD: Shift register buffering while looking for SFD
                    -- =============================================================
                    when CHECK_SFD =>

                            if byte_data_var = SFD_BYTE and prev_byte_was_55 = '1' then
                                -- Valid SFD found! 
                                state <= OUTPUT_FRAME;
                                frame_start <= '1';
                            end if;

                            if byte_data_var = x"55" then
                                prev_byte_was_55 <= '1';
                            else
                                prev_byte_was_55 <= '0';
                            end if;
                       
                            
                    -- =============================================================
                    -- OUTPUT_FRAME: Output bytes directly from IDDR2
                    -- =============================================================
                    when OUTPUT_FRAME =>
                        if rgmii_rx_ctl_rising = '1' then
                            -- Assemble and output current byte
                            rx_data <= byte_data_var;
                            rx_valid <= '1';
                        else
                            -- RX_CTL dropped - end of frame
                            rx_valid <= '0';
                            frame_end <= '1';
                            state <= IDLE;
                        end if;

                end case;

                -- Error detection (for future use)
                rx_error <= '0';

            end if;
        end if;
    end process;

end Behavioral;

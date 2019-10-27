-- Design Name: openxenium
-- Module Name: openxenium - Behavioral
-- Project Name: OpenXenium. Open Source Xenius modchip CPLD replacement project
-- Target Devices: XC9572XL-10VQ64
--
-- Revision 0.01 - File Created - Ryan Wendland
--
-- Additional Comments:
--
-- OpenXenium is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see .
--
----------------------------------------------------------------------------------
--
-- The following notes section the IO registers for XeniumOS (The register is address used when perform IO read or writes)
--
--**BANK SELECTION**
--Bank selection is controlled by the lower nibble of address REG_00EF.
--A20,A19,A18 are address lines to the parallel flash memory.
--lines marked X means it is not forced by the CPLD for banking purposes.
--This is how is works:
--REGISTER 0xEF Bank Commands:
--BANK IO WRITE CMD A20|A19|A18 ADDRESS OFFSET
--TSOP XXXX 0000 X |X |X N/A. (This locks up the Xenium to force it to boot from TSOP.)
--XeniumOS(c.well loader) XXXX 0001 1 |1 |0 0x180000 (This is the default boot state. Contains Cromwell bootloader)
--XeniumOS XXXX 0010 1 |0 |X 0x100000 (This is a 512kb bank and contains XeniumOS)
--BANK1 (USER BIOS 256kB) XXXX 0011 0 |0 |0 0x000000
--BANK2 (USER BIOS 256kB) XXXX 0100 0 |0 |1 0x040000
--BANK3 (USER BIOS 256kB) XXXX 0101 0 |1 |0 0x080000
--BANK4 (USER BIOS 256kB) XXXX 0110 0 |1 |1 0x0C0000
--BANK1 (USER BIOS 512kB) XXXX 0111 0 |0 |X 0x000000
--BANK2 (USER BIOS 512kB) XXXX 1000 0 |1 |X 0x080000
--BANK1 (USER BIOS 1MB) XXXX 1001 0 |X |X 0x000000
--RECOVERY (NOTE 1) XXXX 1010 1 |1 |1 0x1C0000 
-- 
--
--NOTE 1: The RECOVERY bank can also be actived by the physical switch on the Xenium. This forces bank ten (0b1010) on power up.
--This bank also contains non-volatile storage of settings an EEPROM backup in the smaller sectors at the end of the flash memory.
--The memory map is shown below:
-- (1C0000 to 1DFFFF PROTECTED AREA 128kbyte recovery bios)
-- (1E0000 to 1FBFFF Additional XeniumOS Data)
-- (1FC000 to 1FFFFF Contains eeprom backup, XeniumOS settings)
--
--
--**XENIUM CONTROL WRITE/READ REGISTERS**
--Bits marked 'X' either have no function or an unknown function.
--**0xEF WRITE:**
--X,SCK,CS,MOSI,BANK[3:0]
--
--**0xEF READ:**
--RECOV SWITCH POSITION (0=ACTIVE),X,MISO(Pin 1),MISO (Pin 4),BANK[3:0] 
--
--**0xEE (WRITE)**
--X,X,X,X X,B,G,R (DEFAULT LED ON POWER UP IS RED)
--
--**0xEE (READ)**
--Just returns 0x55 on a real xenium?
-- 
 
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;
ENTITY openxenium IS
   PORT (
      HEADER_1 : IN STD_LOGIC;
      HEADER_4 : IN STD_LOGIC;
      HEADER_CS : OUT STD_LOGIC;
      HEADER_SCK : OUT STD_LOGIC;
      HEADER_MOSI : OUT STD_LOGIC;
      HEADER_LED_R : OUT STD_LOGIC;
      HEADER_LED_G : OUT STD_LOGIC;
      HEADER_LED_B : OUT STD_LOGIC;

      FLASH_WE : OUT STD_LOGIC;
      FLASH_OE : OUT STD_LOGIC;
      FLASH_ADDRESS : OUT STD_LOGIC_VECTOR (20 DOWNTO 0);
      FLASH_DQ : INOUT STD_LOGIC_VECTOR (7 DOWNTO 0);

      LPC_LAD : INOUT STD_LOGIC_VECTOR (3 DOWNTO 0);
      LPC_CLK : IN STD_LOGIC;
      LPC_RST : IN STD_LOGIC;

      XENIUM_RECOVERY : IN STD_LOGIC; -- Recovery is active low and requires an external Pull-up to 3.3V
      XENIUM_D0 : OUT STD_LOGIC
   );

END openxenium;

ARCHITECTURE Behavioral OF openxenium IS

   TYPE LPC_STATE_MACHINE IS (
   WAIT_START, 
   CYCTYPE_DIR, 
   ADDRESS, 
   WRITE_DATA0, 
   WRITE_DATA1, 
   READ_DATA0, 
   READ_DATA1, 
   TAR1, 
   TAR2, 
   SYNCING, 
   SYNC_COMPLETE, 
   TAR_EXIT
   );
 
   TYPE CYC_TYPE IS (
   IO_READ, --Default state
   IO_WRITE, 
   MEM_READ, 
   MEM_WRITE
   );

   SIGNAL LPC_CURRENT_STATE : LPC_STATE_MACHINE;
   SIGNAL CYCLE_TYPE : CYC_TYPE;

   SIGNAL LPC_ADDRESS : STD_LOGIC_VECTOR (20 DOWNTO 0); --LPC Address is actually 32bits for memory IO, but we only need 20.

   --XENIUM IO REGISTERS. BITS MARKED 'X' HAVE AN UNKNOWN FUNCTION OR ARE UNUSED. NEEDS MORE RE.
   --Bit masks are all shown upper nibble first.
 
   --IO WRITE/READ REGISTERS SIGNALS
   CONSTANT XENIUM_00EE : STD_LOGIC_VECTOR (7 DOWNTO 0) := x"EE"; --CONSTANT (RGB LED Control Register)
   CONSTANT XENIUM_00EF : STD_LOGIC_VECTOR (7 DOWNTO 0) := x"EF"; --CONSTANT (SPI and Banking Control Register)
   SIGNAL REG_00EE : STD_LOGIC_VECTOR (7 DOWNTO 0) := "00000001"; --X,X,X,X X,B,G,R. Red is default LED colour
   SIGNAL REG_00EF : STD_LOGIC_VECTOR (7 DOWNTO 0) := "00000001"; --X,SCK,CS,MOSI, BANKCONTROL[3:0]. Bank 1 is default.
   SIGNAL REG_00EF_READ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "01010101"; --Input signal
   SIGNAL REG_00EE_READ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "01010101"; --Input signal
   SIGNAL READBUFFER : STD_LOGIC_VECTOR (7 DOWNTO 0); --I buffer Memory and IO reads to reduce pin to pin delay in CPLD which caused issues
 
   --R/W SIGNAL FOR FLASH MEMORY
   SIGNAL sFLASH_DQ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "ZZZZZZZZ";
 
   --TSOPBOOT IS SET TO '1' WHEN YOU REQUEST TO BOOT FROM TSOP. THIS PREVENTS THE CPLD FROM DRIVING D0.
   --D0LEVEL is inverted and connected to the D0 output pad. This allows the CPLD to latch/release the D0/LFRAME signal.
   SIGNAL TSOPBOOT : STD_LOGIC := '0';
   SIGNAL D0LEVEL : STD_LOGIC := '0';
 
   --GENERIC COUNTER USED TO TRACK ADDRESS AND SYNC COUNTERS.
   SIGNAL COUNT : INTEGER RANGE 0 TO 7;

BEGIN
   --ASSIGN THE IO TO SIGNALS BASED ON REQUIRED BEHAVIOUR
   --HEADER_CS <= REG_00EF(5);
   HEADER_SCK <= REG_00EF(6);
   HEADER_MOSI <= REG_00EF(4);

   HEADER_LED_R <= REG_00EE(0);
   HEADER_LED_G <= REG_00EE(1);
   HEADER_LED_B <= REG_00EE(2);

   FLASH_ADDRESS <= LPC_ADDRESS;

   --LAD lines can be either input or output
   --The output values depend on variable states of the LPC transaction
   --Refer to the Intel LPC Specification Rev 1.1
   LPC_LAD <= "0000" WHEN LPC_CURRENT_STATE = SYNC_COMPLETE ELSE
              "0101" WHEN LPC_CURRENT_STATE = SYNCING ELSE
              "1111" WHEN LPC_CURRENT_STATE = TAR2 ELSE
              "1111" WHEN LPC_CURRENT_STATE = TAR_EXIT ELSE
              READBUFFER(3 DOWNTO 0) WHEN LPC_CURRENT_STATE = READ_DATA0 ELSE --This has to be lower nibble first!
              READBUFFER(7 DOWNTO 4) WHEN LPC_CURRENT_STATE = READ_DATA1 ELSE 
              "ZZZZ";

   --FLASH_DQ is mapped to the data byte sent by the Xbox in MEM_WRITE mode, else its just an input
   FLASH_DQ <= sFLASH_DQ WHEN CYCLE_TYPE = MEM_WRITE ELSE "ZZZZZZZZ";
   --Active low signals, Write Enable for Flash Memory Write
   --Minimum pulse width 90ns.
   --Address is latched on the falling edge of WE.
   --Data is latched on the rising edge of WE.
   FLASH_WE <= '0' WHEN CYCLE_TYPE = MEM_WRITE AND
               (LPC_CURRENT_STATE = TAR1 OR
               LPC_CURRENT_STATE = TAR2 OR
               LPC_CURRENT_STATE = SYNCING) ELSE '1';
   --Active low signals, Output Enable for Flash Memory Read
   --Output Enable must be pulled low for 50ns before data is valid for reading
   FLASH_OE <= '0' WHEN CYCLE_TYPE = MEM_READ AND
               (LPC_CURRENT_STATE = TAR1 OR
               LPC_CURRENT_STATE = TAR2 OR
               LPC_CURRENT_STATE = SYNCING OR
               LPC_CURRENT_STATE = SYNC_COMPLETE OR
               LPC_CURRENT_STATE = READ_DATA0 OR
               LPC_CURRENT_STATE = READ_DATA1 OR
               LPC_CURRENT_STATE = TAR_EXIT) ELSE '1';
   --D0 has the following behaviour
   --Held low on boot to ensure it boots from the LPC then released when definitely booting from modchip.
   --When soldered to LFRAME it will simulate LPC transaction aborts for 1.6.
   --Released for TSOP booting.
   --NOTE: XENIUM_D0 is an output to a mosfet driver. '0' turns off the MOSFET releasing D0
   --and a value of '1' turns on the MOSFET forcing it to ground. This is why I invert D0LEVEL before mapping it.
   XENIUM_D0 <= '0' WHEN TSOPBOOT = '1' ELSE
                '1' WHEN CYCLE_TYPE = MEM_READ ELSE
                '1' WHEN CYCLE_TYPE = MEM_WRITE ELSE
                NOT D0LEVEL; 
 
   --RECOVERY SWITCH POSITION (0=ACTIVE), X, PIN_4, PIN_1, BANK[3:0]
   REG_00EF_READ <= XENIUM_RECOVERY & '0' & HEADER_4 & HEADER_1 & REG_00EF(3 DOWNTO 0);

   PROCESS (LPC_CLK, LPC_RST) BEGIN

   IF (LPC_RST = '0') THEN

      --LPC_RST goes low during boot up or hard reset. We need to set DO only if not TSOP booting.
      D0LEVEL <= TSOPBOOT;
      LPC_CURRENT_STATE <= WAIT_START;
      CYCLE_TYPE <= IO_READ;
 
      --If the recovery jumper is set, it will set the banking register to Bank ten on boot.
      --Forcing it to boot the recovery bios.
      IF XENIUM_RECOVERY = '0' AND TSOPBOOT = '0' THEN
         REG_00EF(3 DOWNTO 0) <= "1010";
      END IF;
 
   ELSIF (rising_edge(LPC_CLK)) THEN 
      CASE LPC_CURRENT_STATE IS
         WHEN WAIT_START => 
            IF LPC_LAD = "0000" AND TSOPBOOT = '0' THEN
               LPC_CURRENT_STATE <= CYCTYPE_DIR;
            END IF;
         WHEN CYCTYPE_DIR => 
            IF LPC_LAD(3 DOWNTO 1) = "000" THEN
               CYCLE_TYPE <= IO_READ;
               COUNT <= 3;
               LPC_CURRENT_STATE <= ADDRESS; 
            ELSIF LPC_LAD(3 DOWNTO 1) = "001" THEN
               CYCLE_TYPE <= IO_WRITE;
               COUNT <= 3;
               LPC_CURRENT_STATE <= ADDRESS;
            ELSIF LPC_LAD(3 DOWNTO 1) = "010" THEN
               CYCLE_TYPE <= MEM_READ;
               COUNT <= 7;
               LPC_CURRENT_STATE <= ADDRESS;
            ELSIF LPC_LAD(3 DOWNTO 1) = "011" THEN
               CYCLE_TYPE <= MEM_WRITE;
               COUNT <= 7;
               LPC_CURRENT_STATE <= ADDRESS;
            ELSE
               LPC_CURRENT_STATE <= WAIT_START; -- Unsupported, reset state machine.
            END IF;
 
            --ADDRESS GATHERING
         WHEN ADDRESS => 
            IF COUNT = 5 THEN
               LPC_ADDRESS(20) <= LPC_LAD(0);
            ELSIF COUNT = 4 THEN
               LPC_ADDRESS(19 DOWNTO 16) <= LPC_LAD;
               --BANK CONTROL
               CASE REG_00EF(3 DOWNTO 0) IS
                  WHEN "0001" => 
                     LPC_ADDRESS(20 DOWNTO 18) <= "110"; --256kb bank
                  WHEN "0010" => 
                     LPC_ADDRESS(20 DOWNTO 19) <= "10"; --512kb bank
                  WHEN "0011" => 
                     LPC_ADDRESS(20 DOWNTO 18) <= "000"; --256kb bank
                  WHEN "0100" => 
                     LPC_ADDRESS(20 DOWNTO 18) <= "001"; --256kb bank
                  WHEN "0101" => 
                     LPC_ADDRESS(20 DOWNTO 18) <= "010"; --256kb bank
                  WHEN "0110" => 
                     LPC_ADDRESS(20 DOWNTO 18) <= "011"; --256kb bank
                  WHEN "0111" => 
                     LPC_ADDRESS(20 DOWNTO 19) <= "00"; --512kb bank
                  WHEN "1000" => 
                     LPC_ADDRESS(20 DOWNTO 19) <= "01"; --512kb bank
                  WHEN "1001" => 
                     LPC_ADDRESS(20) <= '0'; --1mb bank
                  WHEN "1010" => 
                     LPC_ADDRESS(20 DOWNTO 18) <= "111"; --256kb bank
                  WHEN "0000" => 
                     --Bank zero will disable modchip and release D0 and reset state machine.
                     LPC_CURRENT_STATE <= WAIT_START;
                     TSOPBOOT <= '1';
                  WHEN OTHERS => 
               END CASE;
            ELSIF COUNT = 3 THEN
               LPC_ADDRESS(15 DOWNTO 12) <= LPC_LAD; 
            ELSIF COUNT = 2 THEN
               LPC_ADDRESS(11 DOWNTO 8) <= LPC_LAD;
            ELSIF COUNT = 1 THEN
               LPC_ADDRESS(7 DOWNTO 4) <= LPC_LAD;
            ELSIF COUNT = 0 THEN
               LPC_ADDRESS(3 DOWNTO 0) <= LPC_LAD;
               IF CYCLE_TYPE = IO_READ OR CYCLE_TYPE = MEM_READ THEN
                  LPC_CURRENT_STATE <= TAR1;
               ELSIF CYCLE_TYPE = IO_WRITE OR CYCLE_TYPE = MEM_WRITE THEN
                  LPC_CURRENT_STATE <= WRITE_DATA0;
               END IF;
            END IF;
            COUNT <= COUNT - 1; 
 
            --MEMORY OR IO WRITES. These all happen lower nibble first. (Refer to Intel LPC spec)
         WHEN WRITE_DATA0 => 
            IF CYCLE_TYPE = IO_WRITE AND LPC_ADDRESS(7 DOWNTO 0) = XENIUM_00EE THEN
               REG_00EE(3 DOWNTO 0) <= LPC_LAD;
            ELSIF CYCLE_TYPE = IO_WRITE AND LPC_ADDRESS(7 DOWNTO 0) = XENIUM_00EF THEN
               REG_00EF(3 DOWNTO 0) <= LPC_LAD;
            ELSIF CYCLE_TYPE = MEM_WRITE THEN
               sFLASH_DQ(3 DOWNTO 0) <= LPC_LAD;
            END IF;
            LPC_CURRENT_STATE <= WRITE_DATA1;
         WHEN WRITE_DATA1 => 
            IF CYCLE_TYPE = IO_WRITE AND LPC_ADDRESS(7 DOWNTO 0) = XENIUM_00EE THEN
               REG_00EE(7 DOWNTO 4) <= LPC_LAD;
            ELSIF CYCLE_TYPE = IO_WRITE AND LPC_ADDRESS(7 DOWNTO 0) = XENIUM_00EF THEN
               REG_00EF(7 DOWNTO 4) <= LPC_LAD;
            ELSIF CYCLE_TYPE = MEM_WRITE THEN
               sFLASH_DQ(7 DOWNTO 4) <= LPC_LAD;
            END IF;
            LPC_CURRENT_STATE <= TAR1;

            --MEMORY OR IO READS
         WHEN READ_DATA0 => 
            LPC_CURRENT_STATE <= READ_DATA1;
         WHEN READ_DATA1 => 
            LPC_CURRENT_STATE <= TAR_EXIT; 
 

            --TURN BUS AROUND (HOST TO PERIPHERAL)
         WHEN TAR1 => 
            LPC_CURRENT_STATE <= TAR2;
         WHEN TAR2 => 
            LPC_CURRENT_STATE <= SYNCING;
            COUNT <= 4;
         WHEN SYNCING => 
            --Sync for 4 clocks to ensure sufficient time for
            --flash memory
            IF COUNT = 4 THEN
               COUNT <= 3;
            ELSIF COUNT = 3 THEN
               COUNT <= 2; 
            ELSIF COUNT = 2 THEN
               COUNT <= 1;
            ELSIF COUNT = 1 THEN
               COUNT <= 0;
            ELSE
               LPC_CURRENT_STATE <= SYNC_COMPLETE;
            END IF;
 
         WHEN SYNC_COMPLETE => 
            IF CYCLE_TYPE = MEM_READ THEN
               READBUFFER <= FLASH_DQ;
               LPC_CURRENT_STATE <= READ_DATA0;
            ELSIF CYCLE_TYPE = IO_READ THEN
               --Buffer memory and IO reads during Sync.
               --This improved timing for the data output states helping reliability.
               IF LPC_ADDRESS(7 DOWNTO 0) = XENIUM_00EF THEN
                  READBUFFER <= REG_00EF_READ;
               ELSIF LPC_ADDRESS(7 DOWNTO 0) = XENIUM_00EE THEN
                  READBUFFER <= REG_00EE_READ;
               ELSE
                  --Unsupported registers should return 0xFF
                  READBUFFER <= "11111111";
               END IF;
               LPC_CURRENT_STATE <= READ_DATA0;
            ELSE
               LPC_CURRENT_STATE <= TAR_EXIT;
            END IF;
 
            --TURN BUS AROUND (PERIPHERAL TO HOST)
         WHEN TAR_EXIT => 
            --D0 is held low until a few memory reads
            --This ensures it is booting from the modchip. Genuine Xenium arbitrarily
            --releases after the 5th read. This is always address 0x74
            IF LPC_ADDRESS(7 DOWNTO 0) = x"74" THEN
               D0LEVEL <= '1';
            END IF;
            CYCLE_TYPE <= IO_READ;
            LPC_CURRENT_STATE <= WAIT_START;
      END CASE;
   END IF;
END PROCESS;
END Behavioral;
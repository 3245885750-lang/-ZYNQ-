/* Project-owned replacement for the lwIP PHY speed hooks, Zynq ENET0 only.
 * YT8521 ID/status register definitions checked against Linux v6.12
 * drivers/net/phy/motorcomm.c (reference only; no Linux code linked).
 * Initial bring-up uses power-on strap delay/AN configuration unchanged.
 * Supports only 1000/full with the XSA's 125 MHz GEM reference clock.
 */
#include "xemacps.h"
#include "xemacps_hw.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "sleep.h"
#include "lwip/arch.h"

u32_t phymapemac0[32];
u32_t phymapemac1[32];
static XEmacPs *board_gem;
static unsigned selected, matches;
static int started;

static int mdio_idle(UINTPTR base)
{
    unsigned n;
    for (n = 0; n < 1000U; ++n) {
        if (XEmacPs_ReadReg(base, XEMACPS_NWSR_OFFSET) & XEMACPS_NWSR_MDIOIDLE_MASK)
            return 0;
        usleep(100U);
    }
    return -1;
}

static int phy_read(XEmacPs *gem, unsigned address, unsigned reg, u16 *value)
{
    UINTPTR base = gem->Config.MdioProducerBaseAddr;
    if (base != XPAR_XEMACPS_0_BASEADDR || mdio_idle(base) != 0)
        return -1;
    XEmacPs_WriteReg(base, XEMACPS_PHYMNTNC_OFFSET,
                    XEMACPS_PHYMNTNC_OP_MASK | XEMACPS_PHYMNTNC_OP_R_MASK |
                    (address << XEMACPS_PHYMNTNC_PHAD_SHFT_MSK) |
                    (reg << XEMACPS_PHYMNTNC_PREG_SHFT_MSK));
    if (mdio_idle(base) != 0) return -1;
    *value = (u16)XEmacPs_ReadReg(base, XEMACPS_PHYMNTNC_OFFSET);
    return 0;
}

void detect_phy(XEmacPs *gem)
{
    unsigned addr;
    board_gem = gem;
    matches = 0U;
    started = 0;
    for (addr = 0; addr < 32U; ++addr) {
        phymapemac0[addr] = phymapemac1[addr] = 0U;
    }
    if (gem->Config.BaseAddress != XPAR_XEMACPS_0_BASEADDR) return;
    for (addr = 0; addr < 32U; ++addr) {
        u16 id1 = 0, id2 = 0;
        if (phy_read(gem, addr, 2U, &id1) || phy_read(gem, addr, 3U, &id2)) {
            xil_printf("PHY_MDIO_TIMEOUT addr=%u\r\n", addr);
            matches = 0;
            return;
        }
        if (id1 == 0U && id2 == 0x011AU) {
            ++matches;
            selected = addr;
            xil_printf("YT8521_CANDIDATE addr=%u id=0000011a\r\n", addr);
        }
    }
    /* YT8521 address 0 responds as broadcast alias; prefer the sole nonzero PHY. */
    if (matches == 2U && selected != 0U) {
        u16 id1 = 0, id2 = 0;
        if (!phy_read(gem, 0U, 2U, &id1) && !phy_read(gem, 0U, 3U, &id2) &&
            id1 == 0U && id2 == 0x011AU) matches = 1U;
    }
    if (matches == 1U) {
        phymapemac0[selected] = 1U;
        /* Adapter fallback invokes address 0 when its scan loop skips 0. */
    } else {
        xil_printf("PHY_REJECT expected_one_YT8521 count=%u\r\n", matches);
    }
}

int radar_phy_poll(void)
{
    u16 bmsr, status;
    if (!board_gem || matches != 1U) return -1;
    if (phy_read(board_gem, selected, 1U, &bmsr) ||
        phy_read(board_gem, selected, 1U, &bmsr) ||
        phy_read(board_gem, selected, 0x11U, &status)) return -1;
    if (!(bmsr & 0x0004U) || !(status & 0x0400U)) return 0;
    /* Require AN complete, resolved speed, 1000 Mb/s and full duplex. */
    if (!(bmsr & 0x0020U) || !(status & 0x0800U)) return 0;
    if ((status & 0xC200U) != 0x8000U || !(status & 0x2000U)) return -2;
    return 1;
}

u32_t phy_setup_emacps(XEmacPs *gem, u32_t address)
{
    unsigned n;
    if (gem != board_gem || matches != 1U || address != selected)
        return XST_FAILURE;
    for (n = 0; n < 100U; ++n) {
        int ready = radar_phy_poll();
        if (ready == 1) {
            started = 1;
            xil_printf("YT8521_1000_FULL; use design 125MHz; strap delays still require board verification\r\n");
            return 1000U;
        }
        if (ready < 0) {
            xil_printf("PHY_NOT_SUPPORTED status=%d (1000/full only)\r\n", ready);
            return XST_FAILURE;
        }
        usleep(100000U);
    }
    xil_printf("PHY_LINK_WAIT_TIMEOUT; connect gigabit peer and restart\r\n");
    return XST_FAILURE;
}

int radar_phy_started(void) { return started; }

/* This XSA uses RGMII, not SGMII/PCS. The adapter still calls this hook. */
void MacConfig_SgmiiPcs(XEmacPs *gem, u32_t address)
{
    (void)gem;
    (void)address;
}

int isphy_pcspma_external(XEmacPs *gem, u32_t address)
{
    (void)gem;
    (void)address;
    return 0;
}

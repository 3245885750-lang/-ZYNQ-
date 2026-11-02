#include "radar_network.h"
#include "radar_network_config.h"
#include "radar_audio_v2.h"
#include "radar_activity_policy.h"
#include "radar_wire.h"
#include "radar_udp_lwip.h"
#include "radar_phy_hooks.h"
#include "xparameters.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "netif/xadapter.h"
#include "lwip/init.h"
#include "lwip/etharp.h"
#include "lwip/timeouts.h"

#if !NO_SYS || !LWIP_UDP || LWIP_TCP || LWIP_DHCP || LWIP_IPV6
#error Expected standalone static IPv4 UDP BSP
#endif

/* Fresh random nonce is injected by the explicit JTAG launcher. */
volatile uint32_t g_network_boot_nonce[2] = {0x4e4f4e43U, 0x454e4f4eU};
volatile uint32_t g_network_header[32];
static struct netif interface;
static radar_udp_sender sender;
static char session[17], payload[RADAR_WIRE_MAX];
static uint32_t doa_seq, class_seq, previous_mvdr_pl, seen_mvdr;
static uint32_t last_service, last_class_ms, last_model, last_activity = 255U;
static int ready, stopped;

static uint64_t uptime_us(void)
{
    XTime t; XTime_GetTime(&t);
    return (t / COUNTS_PER_SECOND) * 1000000U +
        (t % COUNTS_PER_SECOND) * 1000000U / COUNTS_PER_SECOND;
}
u32_t sys_now(void) { return (u32_t)(uptime_us() / 1000U); }

static void diagnostics(void)
{
    g_network_header[0] = 0x4e455432U;
    g_network_header[1] = ready ? (stopped ? 3U : 2U) : 1U;
    g_network_header[2] = sender.sent;
    g_network_header[3] = sender.failed;
    g_network_header[7] = doa_seq;
    g_network_header[8] = class_seq;
    g_network_header[9] = COUNTS_PER_SECOND;
    __asm__ volatile("dsb sy" ::: "memory");
}
static void send_payload(size_t n)
{
    XTime begin, end; XTime_GetTime(&begin);
    if (n) {
        err_t e = radar_udp_send(&sender, payload, n);
        g_network_header[6] = (uint32_t)(int32_t)e;
    } else ++g_network_header[10];
    XTime_GetTime(&end);
    if (end - begin > g_network_header[5])
        g_network_header[5] = (uint32_t)(end - begin);
    diagnostics();
}
int radar_network_init(void)
{
    ip_addr_t board, mask, gateway;
    unsigned char mac[6] = {2, 0x52, 0x41, 0x44, 0, 1};
    static const char hex[] = "0123456789abcdef";
    diagnostics();
    if ((g_network_boot_nonce[0] == 0x4e4f4e43U &&
         g_network_boot_nonce[1] == 0x454e4f4eU) ||
        !(g_network_boot_nonce[0] | g_network_boot_nonce[1])) {
        g_network_header[11] = 1U; return -1;
    }
    for (unsigned i = 0; i < 16; ++i)
        session[i] = hex[(g_network_boot_nonce[i / 8] >> (28 - 4 * (i % 8))) & 15];
    if (!ipaddr_aton(RADAR_BOARD_IP, &board) ||
        !ipaddr_aton(RADAR_NETMASK, &mask) || !ipaddr_aton("0.0.0.0", &gateway)) {
        g_network_header[11] = 2U; return -2;
    }
    lwip_init();
    if (!xemac_add(&interface, &board, &mask, &gateway, mac, XPAR_XEMACPS_0_BASEADDR)) {
        g_network_header[11] = 3U; return -3;
    }
    if (!radar_phy_started()) {
        netif_set_down(&interface);
        g_network_header[11] = 4U; return -4;
    }
    netif_set_default(&interface); netif_set_up(&interface);
    netif_set_link_up(&interface); Xil_ExceptionEnable();
    if (radar_udp_open(&sender, RADAR_PC_IP, RADAR_PC_PORT) != ERR_OK) {
        g_network_header[11] = 5U; return -5;
    }
    ready = 1;
    xil_printf("NET_READY board=%s pc=%s:%u session=%s\r\n",
        RADAR_BOARD_IP, RADAR_PC_IP, RADAR_PC_PORT, session);
    diagnostics(); return 0;
}
/* Send only precise MVDR azimuth to PC. DAS remains PL-side for LED use. */
static void publish_mvdr(void)
{
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        uint32_t a = Xil_In32(RADAR_V2_BASE + RADAR_V2_MVDR_SEQ);
        int32_t angle = (int32_t)Xil_In32(RADAR_V2_BASE +
            RADAR_V2_MVDR_DOA);
        uint32_t power = Xil_In32(RADAR_V2_BASE + RADAR_V2_POWER);
        uint32_t b = Xil_In32(RADAR_V2_BASE + RADAR_V2_MVDR_SEQ);
        if (a != b) continue;
        if ((!seen_mvdr && !a) || (seen_mvdr && previous_mvdr_pl == a)) return;
        seen_mvdr = 1; previous_mvdr_pl = a;
        radar_doa_message m = {0};
        m.seq = ++doa_seq; m.pl_seq = a; m.t_us = uptime_us();
        m.method = 1U; /* MVDR */
        m.signal = radar_signal_active(power) ? 1U : 2U;
        m.valid = (m.signal == 1U) && angle >= -180 && angle <= 180;
        m.angle_mdeg = m.valid ? angle * 1000 : 0;
        send_payload(radar_encode_doa(payload, sizeof payload, session, &m));
        return;
    }
    ++g_network_header[12];
}
void radar_network_service(void)
{
    if (!ready || stopped) return;
    uint32_t now = sys_now();
    if ((uint32_t)(now - last_service) < 1U) return;
    last_service = now;
    XTime begin, end; XTime_GetTime(&begin);
    xemacif_input(&interface);
#if LWIP_TIMERS
    sys_check_timeouts();
#else
    static uint32_t last_arp;
    if ((uint32_t)(now - last_arp) >= ARP_TMR_INTERVAL) {
        etharp_tmr(); last_arp = now;
    }
#endif
    /* Do not run the blocking PHY poll in the audio capture path. */
    publish_mvdr();
    XTime_GetTime(&end);
    if (end - begin > g_network_header[4]) g_network_header[4] = (uint32_t)(end - begin);
    diagnostics();
}
void radar_network_publish(const RadarClassification *r)
{
    if (!ready || stopped || !r) return;
    uint32_t power = Xil_In32(RADAR_V2_BASE + RADAR_V2_POWER);
    uint8_t activity = radar_class_activity(power, r->sequence, r->valid, r->label);
    g_network_header[14] = power;
    g_network_header[15] = RADAR_V2_MVDR_POWER_THRESHOLD;
    g_network_header[16] = activity;
    uint32_t now = sys_now();
    if (r->sequence == last_model && activity == last_activity &&
        (uint32_t)(now - last_class_ms) < 500U) return;
    radar_class_message m = {0};
    m.seq = ++class_seq; m.model_seq = r->sequence; m.t_us = uptime_us();
    m.end_sample = r->end_sample; m.audio_gaps = r->gap_count;
    m.missed_windows = r->missed_windows; m.activity = activity; m.label = (uint8_t)r->label;
    for (unsigned i = 0; i < RADAR_CLASS_COUNT; ++i) {
        float score = r->scores[i];
        m.scores_ppm[i] = score >= 0.0f && score <= 1.0f ? (uint32_t)(score * 1000000.0f) : 0U;
    }
    send_payload(radar_encode_class(payload, sizeof payload, session, &m));
    last_model = r->sequence; last_activity = activity; last_class_ms = now;
}
void radar_network_stop(uint32_t error)
{
    if (!ready || stopped) return;
    radar_class_message m = {0};
    m.seq = ++class_seq; m.model_seq = last_model;
    m.t_us = uptime_us(); m.activity = RADAR_ERROR;
    send_payload(radar_encode_class(payload, sizeof payload, session, &m));
    g_network_header[13] = error;
    stopped = 1; diagnostics();
}

#ifndef RADAR_UDP_LWIP_H
#define RADAR_UDP_LWIP_H
#include "radar_wire.h"
#include "lwip/udp.h"
typedef struct {
    struct udp_pcb *pcb;
    uint32_t sent, failed;
} radar_udp_sender;
/* Initialize sender with {0}; close before opening again.
 * Call AFTER netif / interrupts / link setup, from lwIP main loop context.
 * IPv4 dotted PC destination; no fixed local port is required. */
err_t radar_udp_open(radar_udp_sender *s,const char *pc_ip,uint16_t port);
err_t radar_udp_send(radar_udp_sender *s,const char *payload,size_t bytes);
void radar_udp_close(radar_udp_sender *s);
#endif

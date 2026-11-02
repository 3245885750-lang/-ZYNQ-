#include "radar_udp_lwip.h"
#include "lwip/pbuf.h"
err_t radar_udp_open(radar_udp_sender *s,const char *pc_ip,uint16_t port) {
    ip_addr_t destination; err_t error;
    if(!s||!pc_ip||!port||s->pcb) return ERR_ARG;
    s->pcb=0;s->sent=0;s->failed=0;
    if(!ipaddr_aton(pc_ip,&destination)||!IP_IS_V4(&destination)) return ERR_ARG;
    s->pcb=udp_new();if(!s->pcb)return ERR_MEM;
    error=udp_connect(s->pcb,&destination,port);
    if(error!=ERR_OK) {udp_remove(s->pcb);s->pcb=0;}
    return error;
}
err_t radar_udp_send(radar_udp_sender *s,const char *payload,size_t bytes) {
    struct pbuf *p;err_t error;
    if(!s||!s->pcb||!payload||!bytes||bytes>RADAR_WIRE_MAX)return ERR_ARG;
    p=pbuf_alloc(PBUF_TRANSPORT,(u16_t)bytes,PBUF_RAM);
    if(!p) {s->failed++;return ERR_MEM;}
    error=pbuf_take(p,payload,(u16_t)bytes);
    if(error==ERR_OK)error=udp_send(s->pcb,p);
    pbuf_free(p);
    if(error==ERR_OK)s->sent++;else s->failed++;
    return error; /* ERR_OK = lwIP accepted, NOT PC acknowledgement */
}
void radar_udp_close(radar_udp_sender *s) {
    if(s&&s->pcb){udp_remove(s->pcb);s->pcb=0;}
}

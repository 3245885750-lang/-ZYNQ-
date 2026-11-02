#include "radar_wire.h"
/* Freestanding test harness only: GCC uses memset for aggregate initialization. */
void *memset(void *dst,int value,size_t n) {
    volatile unsigned char *p=(volatile unsigned char *)dst;
    while(n--)*p++=(unsigned char)value;
    return dst;
}
char test_buffer[1201];
unsigned test_doa(int angle,unsigned mode,unsigned cap) {
    radar_doa_message m={0};
    m.seq=0xffffffffu; m.pl_seq=92; m.t_us=UINT64_C(9007199254740993);
    m.angle_mdeg=angle;m.valid=mode==1?0:1;m.method=1;m.signal=mode==1?2:1;
    if(mode==2)m.signal=2;
    return (unsigned)radar_encode_doa(test_buffer,cap,"0123456789abcdef",&m);
}
unsigned test_class(unsigned label,unsigned activity,unsigned cap) {
    unsigned i;radar_class_message m={0};
    m.seq=12;m.model_seq=999;m.t_us=UINT64_MAX;m.end_sample=UINT64_MAX;
    m.label=(uint8_t)label;m.activity=(uint8_t)activity;
    for(i=0;i<9;i++)m.scores_ppm[i]=10000;
    if(label<9)m.scores_ppm[label]=920000;
    if(label==10)m.scores_ppm[0]=1000001;
    m.audio_gaps=3;m.missed_windows=4;
    return (unsigned)radar_encode_class(test_buffer,cap,"0123456789abcdef",&m);
}
unsigned test_rejection(unsigned top,unsigned runner,unsigned label) {
    radar_class_message m={0};
    m.seq=1;m.model_seq=1;m.activity=RADAR_EVENT;m.label=(uint8_t)label;
    if(label<9)m.scores_ppm[label]=top;
    m.scores_ppm[label==0?1:0]=runner;
    return (unsigned)radar_encode_class(test_buffer,sizeof test_buffer,"0123456789abcdef",&m);
}
unsigned test_session(void) {
    radar_doa_message m={0};
    return (unsigned)radar_encode_doa(test_buffer,sizeof test_buffer,"not-a-session",&m);
}

#include "radar_activity_policy.h"
void *memset(void *dst, int value, size_t n) {
 unsigned char *p=dst; while(n--) *p++=(unsigned char)value; return dst;
}
char test_buffer[1201];
unsigned policy_message(unsigned power, unsigned seq, unsigned packed) {
 radar_class_message m={0};
 m.seq=1; m.model_seq=seq; m.label=packed&255U;
 m.activity=radar_class_activity(power,seq,(packed>>8)&1U,m.label);
 for(unsigned i=0;i<9;++i)m.scores_ppm[i]=i==m.label?920000U:10000U;
 return radar_encode_class(test_buffer,sizeof test_buffer,"0123456789abcdef",&m);
}
unsigned policy_active(unsigned power) { return radar_signal_active(power); }

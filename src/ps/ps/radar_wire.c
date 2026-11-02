#include "radar_wire.h"
typedef struct { char *p; size_t cap,n; int failed; } writer;
static const char *labels[9]={"clap","speech","piano","bird","dog","horn","water","zipper","keyboard"};
static const char *activities[5]={"pending","event","background","uncertain","error"};
static void text(writer *w,const char *s) {
    while(*s) {
        if(w->n+1>=w->cap) { w->failed=1; return; }
        w->p[w->n++]=*s++;
    }
}
static void number(writer *w,uint64_t x) {
    char buf[21]; unsigned n=0;
    do {buf[n++]=(char)('0'+x%10);x/=10;} while(x);
    while(n) {char one[2]={buf[--n],0};text(w,one);}
}
static void quoted_number(writer *w,uint64_t x) {text(w,"\"");number(w,x);text(w,"\"");}
static int session_ok(const char *s) {
    unsigned i;
    if(!s) return 0;
    for(i=0;i<16;i++) if(!s[i] || !((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f'))) return 0;
    return s[16]==0;
}
static void start(writer *w,const char *s,const char *kind,uint32_t seq,uint64_t us) {
    text(w,"{\"v\":3,\"kind\":\"");text(w,kind);
    text(w,"\",\"origin\":\"board\",\"session\":\"");text(w,s);
    text(w,"\",\"seq\":");number(w,seq);text(w,",\"t_us\":");quoted_number(w,us);
}
static size_t finish(writer *w) {
    if(w->failed || w->n>RADAR_WIRE_MAX) {if(w->cap)w->p[0]=0;return 0;}
    w->p[w->n]=0;return w->n;
}
size_t radar_encode_doa(char *dst,size_t cap,const char *session,const radar_doa_message *m) {
    writer w={dst,cap,0,0};
    if(!dst||!m||!cap||!session_ok(session)||m->method>1||m->signal>2||m->valid>1||
       (m->valid&&(m->angle_mdeg < -180000 || m->angle_mdeg>180000 || m->signal==2))) return 0;
    start(&w,session,"doa",m->seq,m->t_us);
    text(&w,",\"method\":\"");text(&w,m->method?"mvdr":"das");text(&w,"\",\"pl_seq\":");number(&w,m->pl_seq);
    text(&w,",\"valid\":");text(&w,m->valid?"true":"false");text(&w,",\"signal\":\"");
    text(&w,m->signal==1?"active":m->signal==2?"quiet":"unknown");
    text(&w,"\",\"azimuth_mdeg\":");
    if(m->valid) number(&w,(uint32_t)((m->angle_mdeg+360000)%360000)); else text(&w,"null");
    text(&w,"}");return finish(&w);
}
size_t radar_encode_class(char *dst,size_t cap,const char *session,const radar_class_message *m) {
    writer w={dst,cap,0,0};unsigned i;uint8_t activity;
    if(!dst||!m||!cap||!session_ok(session)||m->activity>RADAR_ERROR||
       (m->activity==RADAR_EVENT&&m->label>=9)) return 0;
    for(i=0;i<9;i++) if(m->scores_ppm[i]>1000000) return 0;
    activity=m->activity;
    if(activity==RADAR_EVENT && !radar_class_accept_ppm(m->scores_ppm, m->label)) activity=RADAR_UNCERTAIN;
    start(&w,session,"classification",m->seq,m->t_us);
    text(&w,",\"model_seq\":");number(&w,m->model_seq);
    text(&w,",\"state\":\"");text(&w,activities[activity]);text(&w,"\",\"label\":");
    if(activity==RADAR_EVENT) {text(&w,"\"");text(&w,labels[m->label]);text(&w,"\"");}
    else if(activity==RADAR_BACKGROUND) text(&w,"\"background\"");else text(&w,"null");
    text(&w,",\"confidence_ppm\":");
    if(activity==RADAR_EVENT) number(&w,m->scores_ppm[m->label]);else text(&w,"null");
    text(&w,",\"scores_ppm\":[");
    for(i=0;i<9;i++) {if(i)text(&w,",");number(&w,m->scores_ppm[i]);}
    text(&w,"],\"enabled_mask\":511,\"class_set\":\"radar9_20261028\",\"reject_confidence_ppm\":");
    number(&w,RADAR_REJECT_CONFIDENCE_PPM);text(&w,",\"reject_margin_ppm\":");number(&w,RADAR_REJECT_MARGIN_PPM);text(&w,",\"end_sample\":");quoted_number(&w,m->end_sample);
    text(&w,",\"sample_rate_hz\":16000,\"window_samples\":32000,\"hop_samples\":1600,\"audio_gaps\":");
    number(&w,m->audio_gaps);text(&w,",\"missed_windows\":");number(&w,m->missed_windows);
    text(&w,"}");return finish(&w);
}

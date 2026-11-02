#ifndef RADAR_WIRE_H
#define RADAR_WIRE_H
#include <stdint.h>
#include <stddef.h>
#define RADAR_WIRE_VERSION 3u
#include "radar_class_policy.h"
#define RADAR_WIRE_MAX 1200u
#define RADAR_ENABLED_MASK RADAR_ENABLED_CLASS_MASK
enum radar_activity { RADAR_PENDING, RADAR_EVENT, RADAR_BACKGROUND, RADAR_UNCERTAIN, RADAR_ERROR };
typedef struct {
    uint32_t seq, pl_seq;
    uint64_t t_us;
    int32_t angle_mdeg; /* signed PL angle * 1000: -180000..180000 */
    uint8_t valid, method, signal; /* method:0=DAS,1=MVDR; live board feed uses MVDR; signal:0=unknown,1=active,2=quiet */
} radar_doa_message;
typedef struct {
    uint32_t seq, model_seq;
    uint64_t t_us, end_sample; /* sample index after resampling to 16000Hz */
    uint32_t scores_ppm[9], audio_gaps, missed_windows;
    uint8_t activity, label; /* label used only for EVENT, order documented */
} radar_class_message;
/* session: exactly 16 lowercase hexadecimal characters, NEW for each PS start.
 * Returns payload length without NUL; 0 means invalid input / buffer too small.
 * No malloc, float formatting, BSP or lwIP dependency. */
size_t radar_encode_doa(char *dst,size_t cap,const char *session,const radar_doa_message *m);
size_t radar_encode_class(char *dst,size_t cap,const char *session,const radar_class_message *m);
#endif

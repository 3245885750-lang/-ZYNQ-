#ifndef RADAR_ACTIVITY_POLICY_H
#define RADAR_ACTIVITY_POLICY_H
#include "radar_audio_v2.h"
#include "radar_class_policy.h"
#include "radar_wire.h"

/* PL power decides quiet/active. Background-envelope diagnostics do not veto
 * an active PL signal. Model readiness and disabled classes still apply. */
static inline uint8_t radar_class_activity(uint32_t power, uint32_t model_seq,
                                         uint32_t valid, uint32_t label)
{
    if (!radar_signal_active(power)) return RADAR_BACKGROUND;
    if (!model_seq) return RADAR_PENDING;
    if (!valid || !radar_class_enabled(label)) return RADAR_UNCERTAIN;
    return RADAR_EVENT;
}
#endif

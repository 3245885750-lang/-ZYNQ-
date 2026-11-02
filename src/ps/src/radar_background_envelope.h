#ifndef RADAR_BACKGROUND_ENVELOPE_H
#define RADAR_BACKGROUND_ENVELOPE_H
/* DEVELOPMENT ONLY. Absolute log-Mel dB before classifier normalization.
 * Result: -1 invalid, 0 background, 1 uncertain, 2 activity.
 * Activity alone is not a recognized class or proof of a sound event.
 */
typedef struct {
    unsigned frames, active_frames, capped_frames, invalid;
    float peak_excess_db, total_excess_db, total_gain_db;
} RadarBackgroundEnvelope;
void radar_background_reset(RadarBackgroundEnvelope *s);
int radar_background_frame(RadarBackgroundEnvelope *s, const float logmel[40]);
int radar_background_finish(const RadarBackgroundEnvelope *s);
#endif

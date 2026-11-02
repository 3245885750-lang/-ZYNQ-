#ifndef RADAR_CLASS_POLICY_H
#define RADAR_CLASS_POLICY_H
#include <stdint.h>
/* Generated from validation-only calibration; not a calibrated probability. */
#define RADAR_ENABLED_CLASS_MASK 511U
#define RADAR_REJECT_CONFIDENCE_PPM 800000U
#define RADAR_REJECT_MARGIN_PPM 50000U
static inline int radar_class_enabled(unsigned label) { return label < 9U; }
static inline int radar_class_accept_ppm(const uint32_t *scores, unsigned label)
{
    uint32_t second = 0;
    if (!radar_class_enabled(label)) return 0;
    for (unsigned i=0; i<9U; ++i) {
        if (scores[i]>1000000U || scores[i]>scores[label]) return 0;
        if (i!=label && scores[i]>second) second=scores[i];
    }
    return scores[label]>=RADAR_REJECT_CONFIDENCE_PPM &&
        scores[label]-second>=RADAR_REJECT_MARGIN_PPM;
}
static inline int radar_class_accept_float(const float *scores, unsigned label)
{
    uint32_t ppm[9];
    for (unsigned i=0; i<9U; ++i) {
        if (!(scores[i]>=0.0f && scores[i]<=1.0f)) return 0;
        ppm[i]=(uint32_t)(scores[i]*1000000.0f);
    }
    return radar_class_accept_ppm(ppm,label);
}
#endif

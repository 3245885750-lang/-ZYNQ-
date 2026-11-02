#ifndef RADAR_NETWORK_H
#define RADAR_NETWORK_H
#include <stdint.h>
#include "radar_classifier.h"
/* The launcher supplies a fresh nonce after dow and before con. */
extern volatile uint32_t g_network_boot_nonce[2];
extern volatile uint32_t g_network_header[32];
int radar_network_init(void);
void radar_network_service(void);
void radar_network_publish(const RadarClassification *result);
void radar_network_stop(uint32_t error);
#endif

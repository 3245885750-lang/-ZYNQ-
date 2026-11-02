#ifndef RADAR_PHY_HOOKS_H
#define RADAR_PHY_HOOKS_H
/* +1: verified YT8521 reporting 1000/full/link; 0: down; negative: reject. */
int radar_phy_poll(void);
int radar_phy_started(void);
#endif

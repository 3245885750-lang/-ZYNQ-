# 原代码摘录

这些是来源工程的历史代码证据；行号相对于来源文件，不是新工程的执行指令。

## firmware/deps/audio_bsp/include/xtimer_config.h

来源SHA256：`27c0700fba487080f8872e198d4c5814846568c990859f29ecd091d1b526a093`

```text
10: /* #undef XSLEEPTIMER_BASEADDRESS */
11: /* #undef XSLEEPTIMER_IS_AXITIMER */
12: /* #undef XSLEEPTIMER_IS_TTCPS */
13: /* #undef XSLEEPTIMER_IS_SCUTIMER */
14: #define XSLEEPTIMER_FREQ	     XPAR_CPU_CORE_CLOCK_FREQ_HZ/2
15: #define COUNTS_PER_SECOND       XSLEEPTIMER_FREQ
16: #define XTIMER_IS_DEFAULT_TIMER 1
17: /* #undef XTIMER_DEFAULT_TIMER_IS_MB */
18: /* #undef XTIMER_DEFAULT_TIMER_IS_MB_RISCV */
```

## firmware/ps/radar_network.c

来源SHA256：`b13abeecdf14ddfb4058ec17872309d256a02205a432a82779bbd9cb2ba35f02`

```text
29: static uint32_t doa_seq, class_seq, previous_mvdr_pl, seen_mvdr;
30: static uint32_t last_service, last_class_ms, last_model, last_activity = 255U;
31: static int ready, stopped;
32: 
33: static uint64_t uptime_us(void)
34: {
35:     XTime t; XTime_GetTime(&t);
36:     /* Parenthesize the BSP frequency macro (it expands to CPU_FREQ/2).
37:      * Keep the existing units, polling constants and packet scheduling. */
38:     const uint64_t frequency = (COUNTS_PER_SECOND);
39:     return (t / frequency) * 1000000U +
40:         (t % frequency) * 1000000U / frequency;
41: }
42: u32_t sys_now(void) { return (u32_t)(uptime_us() / 1000U); }
43: 
```

## firmware/src/radar_class_policy.h

来源SHA256：`015ec36aa662e4e99b0553951bf890a098b1200306364512bcd0c924c8b24f17`

```text
1: #ifndef RADAR_CLASS_POLICY_H
2: #define RADAR_CLASS_POLICY_H
3: #include <stdint.h>
4: /* Closed-set top-one mode requested by team. Scores are not calibrated probabilities. */
5: #define RADAR_ENABLED_CLASS_MASK 127U
6: #define RADAR_REJECT_CONFIDENCE_PPM 0U
7: #define RADAR_REJECT_MARGIN_PPM 0U
8: static inline int radar_class_enabled(unsigned label) { return label < 9U && ((RADAR_ENABLED_CLASS_MASK >> label) & 1U); }
9: /* Retain nine protocol slots, disable glass/engine at indices 7/8, condition on seven candidates.
10:  * This is a selection policy over the existing model, not seven-class retraining.
11:  */
12: static inline int radar_class_mask_scores(float *scores)
13: {
14:     float total=0.0f;
15:     for (unsigned i=0;i<9U;++i) {
16:         if (!(scores[i]>=0.0f && scores[i]<=1.0f)) return 0;
17:         if (!radar_class_enabled(i)) scores[i]=0.0f;
18:         total+=scores[i];
19:     }
20:     if (!(total>0.0f)) return 0;
21:     for (unsigned i=0;i<9U;++i) scores[i]/=total;
22:     return 1;
23: }
24: static inline int radar_class_accept_ppm(const uint32_t *scores, unsigned label)
25: {
26:     if (!radar_class_enabled(label)) return 0;
27:     for (unsigned i=0; i<9U; ++i) {
28:         if (scores[i]>1000000U || (!radar_class_enabled(i) && scores[i]) || scores[i]>scores[label]) return 0;
29:     }
30:     return 1; /* Valid finite top class; closed-set mode, no confidence veto. */
```

## hardware/radar_audio_recreate.tcl

来源SHA256：`bd72fd14386cdabdfcc7c76a07e6bd353b87a650cc9067f8750bca358da9fa2a`

```text
490:     CONFIG.C_OPERATION {not} \
491:     CONFIG.C_SIZE {1} \
492:   ] $reset_invert
493: 
494: 
495:   # Create instance: reset_50, and set properties
496:   set reset_50 [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 reset_50 ]
497:   set_property CONFIG.C_AUX_RESET_HIGH {1} $reset_50
498: 
499: 
500:   # Create instance: reset_100, and set properties
501:   set reset_100 [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 reset_100 ]
502:   set_property CONFIG.C_AUX_RESET_HIGH {1} $reset_100
503: 
504: 
505:   # Create instance: dma_rx, and set properties
```

```text
550:   connect_bd_intf_net -intf_net radar_0_m_axis_audio [get_bd_intf_pins radar_0/m_axis_audio] [get_bd_intf_pins audio_fifo/S_AXIS]
551: 
552:   # Create port connections
553:   connect_bd_net -net const_one_dout  [get_bd_pins const_one/dout] \
554:   [get_bd_pins reset_50/dcm_locked] \
555:   [get_bd_pins reset_100/dcm_locked]
556:   connect_bd_net -net const_zero_dout  [get_bd_pins const_zero/dout] \
557:   [get_bd_pins reset_50/aux_reset_in] \
558:   [get_bd_pins reset_50/mb_debug_sys_rst] \
559:   [get_bd_pins reset_100/aux_reset_in] \
560:   [get_bd_pins reset_100/mb_debug_sys_rst]
561:   connect_bd_net -net ps7_FCLK_CLK0  [get_bd_pins ps7/FCLK_CLK0] \
562:   [get_bd_pins ps7/M_AXI_GP0_ACLK] \
```

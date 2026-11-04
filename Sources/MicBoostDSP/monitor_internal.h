#ifndef MB_MONITOR_INTERNAL_H
#define MB_MONITOR_INTERNAL_H
#include "MicBoostDSP.h"
typedef struct mb_ring mb_ring;
double mb_ring_ticks(mb_ring *ring);
mb_ring *mb_ring_create(double rate);
void mb_ring_destroy(mb_ring *ring);
void mb_ring_enable(mb_ring *ring, bool enabled);
void mb_ring_push(mb_ring *ring, const float *left, const float *right,
                  uint32_t frames, uint64_t host);
mb_ring *mb_engine_ring(mb_engine *engine);
#endif

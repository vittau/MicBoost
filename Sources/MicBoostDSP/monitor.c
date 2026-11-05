#include "monitor_internal.h"
#include <mach/mach_time.h>
#include <math.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#define CAPACITY 8192u

typedef struct {
    _Atomic float left, right;
    _Atomic uint64_t host, tag;
} monitor_frame;
struct mb_ring {
    monitor_frame frames[CAPACITY];
    _Atomic uint64_t read, write, overruns_full, resets;
    _Atomic unsigned writers, reset_target, owners, fill_min, fill_max;
    _Atomic bool enabled, wait_for_pull, pulling;
    double ticks;
};
struct mb_monitor {
    mb_ring *ring;
    double rate, gain;
    _Atomic unsigned target, swing, prefill, max_pull, quantum;
    _Atomic bool silent, fading;
    _Atomic uint64_t latency, underruns;
};
static void advance(_Atomic uint64_t *index, uint64_t value) {
    uint64_t old = atomic_load_explicit(index, memory_order_acquire);
    while (old < value && !atomic_compare_exchange_weak_explicit(
        index, &old, value, memory_order_release, memory_order_relaxed)) {
    }
}
static void maximum(_Atomic unsigned *value, unsigned sample) {
    unsigned old = atomic_load(value);
    while (old < sample && !atomic_compare_exchange_weak(value, &old, sample)) {
    }
}
static void minimum(_Atomic unsigned *value, unsigned sample) {
    unsigned old = atomic_load(value);
    while (old > sample && !atomic_compare_exchange_weak(value, &old, sample)) {
    }
}
static unsigned fill(mb_ring *r) {
    uint64_t write = atomic_load_explicit(&r->write, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&r->read, memory_order_acquire);
    return (unsigned)(write > read ? fmin(CAPACITY, write - read) : 0);
}
static void observe_fill(mb_ring *r) {
    unsigned current = fill(r);
    minimum(&r->fill_min, current);
    maximum(&r->fill_max, current);
}
mb_ring *mb_ring_create(double rate) {
    mb_ring *r = calloc(1, sizeof(*r));
    if (!r) {
        return NULL;
    }
    if (!atomic_is_lock_free(&r->frames[0].left)
        || !atomic_is_lock_free(&r->write)
        || !atomic_is_lock_free(&r->writers) || !atomic_is_lock_free(&r->enabled)) {
        free(r);
        return NULL;
    }
    atomic_store(&r->owners, 1);
    mach_timebase_info_data_t time;
    mach_timebase_info(&time);
    r->ticks = 1e9 * time.denom / time.numer / rate;
    return r;
}
double mb_ring_ticks(mb_ring *r) {
    return r->ticks;
}
void mb_ring_destroy(mb_ring *r) {
    // Only the engine queue releases owners; callbacks never release or free storage.
    if (atomic_fetch_sub(&r->owners, 1) == 1) {
        free(r);
    }
}
void mb_ring_enable(mb_ring *r, bool enabled) {
    atomic_store_explicit(&r->enabled, enabled, memory_order_release);
    // Called on the engine queue, never by an audio callback.
    if (!enabled) {
        while (atomic_load_explicit(&r->writers, memory_order_acquire)) {
            sched_yield();
        }
    }
}
void mb_ring_push(mb_ring *r, const float *left, const float *right,
                  uint32_t frames, uint64_t host) {
    atomic_fetch_add_explicit(&r->writers, 1, memory_order_acq_rel);
    if (!atomic_load_explicit(&r->enabled, memory_order_acquire)
        || (atomic_load(&r->wait_for_pull) && !atomic_load(&r->pulling))) {
        atomic_fetch_sub_explicit(&r->writers, 1, memory_order_release);
        return;
    }
    uint64_t write = atomic_load_explicit(&r->write, memory_order_relaxed);
    unsigned reset = atomic_exchange_explicit(&r->reset_target, 0, memory_order_acq_rel);
    if (reset) {
        advance(&r->read, write);
        for (unsigned i = 0; i < reset; i++) {
            monitor_frame *f = &r->frames[(write + i) % CAPACITY];
            atomic_store_explicit(&f->tag, UINT64_MAX, memory_order_release);
            atomic_store(&f->left, 0);
            atomic_store(&f->right, 0);
            atomic_store(&f->host, 0);
            atomic_store_explicit(&f->tag, write + i, memory_order_release);
        }
        atomic_fetch_add(&r->resets, 1);
        write += reset;
        atomic_store_explicit(&r->write, write, memory_order_release);
    }
    uint64_t read = atomic_load_explicit(&r->read, memory_order_acquire);
    if (write + frames - read > CAPACITY) {
        advance(&r->read, write + frames - CAPACITY);
        atomic_fetch_add(&r->overruns_full, 1);
    }
    for (uint32_t i = 0; i < frames; i++) {
        monitor_frame *f = &r->frames[(write + i) % CAPACITY];
        // Atomics also protect an overwritten slot while the consumer discards it.
        atomic_store_explicit(&f->tag, UINT64_MAX, memory_order_release);
        atomic_store(&f->left, isfinite(left[i]) ? left[i] : 0);
        atomic_store(&f->right, isfinite(right[i]) ? right[i] : 0);
        atomic_store(&f->host, host ? host + (uint64_t)(i * r->ticks) : 0);
        atomic_store_explicit(&f->tag, write + i, memory_order_release);
    }
    atomic_store_explicit(&r->write, write + frames, memory_order_release);
    observe_fill(r);
    atomic_fetch_sub_explicit(&r->writers, 1, memory_order_release);
}
mb_monitor *mb_monitor_create(mb_engine *engine, double rate, uint32_t target) {
    if (!isfinite(rate) || rate <= 0 || target == 0 || target >= CAPACITY) {
        return NULL;
    }
    mb_monitor *m = calloc(1, sizeof(*m));
    if (!m) {
        return NULL;
    }
    m->ring = mb_engine_ring(engine);
    atomic_fetch_add(&m->ring->owners, 1);
    m->rate = rate;
    atomic_store(&m->target, target);
    atomic_store(&m->prefill, target);
    mb_ring_enable(m->ring, false);
    atomic_store(&m->ring->read, 0);
    atomic_store(&m->ring->write, target);
    atomic_store(&m->ring->overruns_full, 0);
    atomic_store(&m->ring->resets, 0);
    atomic_store(&m->ring->fill_min, target);
    atomic_store(&m->ring->fill_max, target);
    atomic_store(&m->ring->reset_target, 0);
    atomic_store(&m->ring->wait_for_pull, false);
    atomic_store(&m->ring->pulling, false);
    for (unsigned i = 0; i < CAPACITY; i++) {
        atomic_store(&m->ring->frames[i].left, 0);
        atomic_store(&m->ring->frames[i].right, 0);
        atomic_store(&m->ring->frames[i].host, 0);
        atomic_store(&m->ring->frames[i].tag, i < target ? i : UINT64_MAX);
    }
    return m;
}
void mb_monitor_destroy(mb_monitor *m) {
    mb_ring_destroy(m->ring);
    free(m);
}
void mb_monitor_set_silent(mb_monitor *m, bool silent) {
    atomic_store(&m->silent, silent);
}
void mb_monitor_fade_out(mb_monitor *m) {
    atomic_store(&m->fading, true);
}
void mb_monitor_set_target_base(mb_monitor *m, uint32_t engine_buffer, uint32_t initial_pull) {
    unsigned quantum = (unsigned)fmax(engine_buffer, initial_pull);
    unsigned target = (unsigned)fmin(CAPACITY - 1, ceil(engine_buffer * 0.5 + quantum * 0.25));
    atomic_store(&m->quantum, quantum);
    unsigned swing = engine_buffer + initial_pull;
    unsigned prefill = (unsigned)fmin(CAPACITY - 1, (double)swing + target);
    atomic_store(&m->swing, engine_buffer);
    atomic_store(&m->target, target);
    atomic_store(&m->prefill, prefill);
    atomic_store(&m->ring->wait_for_pull, true);
    atomic_store(&m->ring->pulling, false);
    // Configure only before enabling the producer or starting the output unit.
    atomic_store(&m->ring->read, 0);
    atomic_store(&m->ring->write, prefill);
    atomic_store(&m->ring->fill_min, prefill);
    atomic_store(&m->ring->fill_max, prefill);
    for (unsigned i = 0; i < CAPACITY; i++) {
        atomic_store(&m->ring->frames[i].left, 0);
        atomic_store(&m->ring->frames[i].right, 0);
        atomic_store(&m->ring->frames[i].host, 0);
        atomic_store(&m->ring->frames[i].tag, i < prefill ? i : UINT64_MAX);
    }
}
void mb_monitor_peek(const mb_monitor *m, mb_monitor_stats *stats) {
    stats->fill = fill(m->ring);
    stats->target = atomic_load(&m->target);
    stats->quantum = atomic_load(&m->quantum);
    stats->latency_host = atomic_load(&m->latency);
    stats->underruns = atomic_load(&m->underruns);
    stats->overruns_full = atomic_load(&m->ring->overruns_full);
    stats->resets = atomic_load(&m->ring->resets);
    stats->max_pull = atomic_load(&m->max_pull);
    stats->fill_min = atomic_load(&m->ring->fill_min);
    if (stats->fill_min == UINT32_MAX) {
        stats->fill_min = stats->fill;
    }
    stats->fill_max = (unsigned)fmax(stats->fill, atomic_load(&m->ring->fill_max));
    stats->pulling = atomic_load(&m->ring->pulling);
    stats->correction = 0;
}
void mb_monitor_read(mb_monitor *m, mb_monitor_stats *stats) {
    mb_monitor_peek(m, stats);
    stats->max_pull = atomic_exchange(&m->max_pull, 0);
    stats->fill_min = atomic_exchange(&m->ring->fill_min, stats->fill);
    if (stats->fill_min == UINT32_MAX) {
        stats->fill_min = stats->fill;
    }
    stats->fill_max = (unsigned)fmax(stats->fill, atomic_exchange(&m->ring->fill_max, stats->fill));
}
double mb_monitor_pi_update(mb_monitor_pi *pi, double error, double rate, double seconds,
                            double quantum) {
    if (!isfinite(quantum) || quantum <= 0 || !isfinite(error)
        || !isfinite(rate) || rate <= 0 || !isfinite(seconds) || seconds <= 0) {
        return 0;
    }
    // Observe twenty control ticks; scale bandwidth below four audio callback periods.
    double horizon = fmax(20 * seconds, 4 * quantum / rate);
    pi->minimums[pi->index] = error / rate;
    pi->index = (pi->index + 1) % 20;
    pi->count = pi->count < 20 ? pi->count + 1 : 20;
    double low = pi->minimums[0];
    for (unsigned i = 1; i < pi->count; i++) {
        low = fmin(low, pi->minimums[i]);
    }
    // Ignore block quantization inside one eighth of the measured callback quantum.
    low = copysign(fmax(0, fabs(low) - quantum / rate * 0.125), low);
    pi->filtered += (1 - exp(-seconds / horizon)) * (low - pi->filtered);
    double proportional = 0.25 / horizon * pi->filtered;
    double candidate = pi->integral + 0.025 / (horizon * horizon) * pi->filtered * seconds;
    // Do not wind up against either the amplitude limit or the slew limiter.
    double step = 0.001 * seconds / horizon;
    double excess = proportional + candidate - pi->correction;
    if (fabs(proportional + candidate) < 0.005
        && (fabs(excess) <= step || excess * pi->filtered <= 0)) {
        pi->integral = candidate;
    }
    double desired = fmax(-0.005, fmin(0.005, proportional + pi->integral));
    pi->correction += fmax(-step, fmin(step, desired - pi->correction));
    return pi->correction;
}
OSStatus mb_monitor_render(void *context, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                          AudioBufferList *out) {
    (void)flags;
    (void)bus;
    if (!out) {
        return noErr;
    }
    for (unsigned b = 0; b < out->mNumberBuffers; b++) {
        if (out->mBuffers[b].mData) {
            memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
        }
    }
    if (!context) {
        return noErr;
    }
    mb_monitor *m = context;
    mb_ring *r = m->ring;
    if (frames) {
        atomic_store_explicit(&r->pulling, true, memory_order_release);
    }
    maximum(&m->max_pull, frames);
    unsigned swing = atomic_load(&m->swing);
    if (swing) {
        maximum(&m->quantum, frames);
        unsigned quantum = atomic_load(&m->quantum);
        maximum(&m->target, (unsigned)fmin(CAPACITY - 1, ceil(swing * 0.5 + quantum * 0.25)));
        maximum(&m->prefill, (unsigned)fmin(CAPACITY - 1,
            (double)swing + quantum + atomic_load(&m->target)));
    }
    unsigned target = atomic_load(&m->prefill);
    unsigned excursion = (unsigned)fmax(CAPACITY / 2, target);
    observe_fill(r);
    uint64_t read = atomic_load_explicit(&r->read, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&r->write, memory_order_acquire);
    if (write > read + target + excursion) {
        read = write - target;
        advance(&r->read, read);
        atomic_fetch_add(&r->resets, 1);
    }
    if (write >= read && target >= write - read + excursion) {
        atomic_store_explicit(&r->reset_target, target, memory_order_release);
    }
    bool silent = atomic_load(&m->silent);
    bool fading = atomic_load(&m->fading);
    bool missing = false;
    for (unsigned i = 0; i < frames; i++) {
        float left = 0, right = 0;
        bool real_frame = false;
        if (read < write) {
            monitor_frame *f = &r->frames[read % CAPACITY];
            uint64_t tag = atomic_load_explicit(&f->tag, memory_order_acquire);
            left = atomic_load(&f->left);
            right = atomic_load(&f->right);
            uint64_t host = atomic_load(&f->host);
            bool valid = tag == read
                && atomic_load_explicit(&f->tag, memory_order_acquire) == read;
            if (!valid) {
                left = right = 0;
                missing = true;
            } else {
                real_frame = host != 0 || left != 0 || right != 0;
            }
            if (valid && i == 0 && host
                && (time->mFlags & kAudioTimeStampHostTimeValid) && time->mHostTime >= host) {
                uint64_t delta = time->mHostTime - host;
                uint64_t old = atomic_load(&m->latency);
                atomic_store(&m->latency, old ? (uint64_t)(old * 0.9 + delta * 0.1) : delta);
            }
            read++;
        } else {
            missing = true;
        }
        if (real_frame || fading) {
            m->gain = fmax(0, fmin(1, m->gain + (fading ? -1 : 1) / (m->rate * 0.010)));
        }
        left *= silent ? 0 : m->gain;
        right *= silent ? 0 : m->gain;
        unsigned channel = 0;
        unsigned total = 0;
        for (unsigned b = 0; b < out->mNumberBuffers; b++) {
            total += out->mBuffers[b].mNumberChannels;
        }
        for (unsigned b = 0; b < out->mNumberBuffers; b++) {
            AudioBuffer buffer = out->mBuffers[b];
            for (unsigned c = 0; c < buffer.mNumberChannels; c++, channel++) {
                size_t index = (size_t)i * buffer.mNumberChannels + c;
                if (buffer.mData && index < buffer.mDataByteSize / sizeof(float)) {
                    ((float *)buffer.mData)[index] = total == 1 ? (left + right) * 0.5f
                        : channel == 0 ? left : channel == 1 ? right : 0;
                }
            }
        }
    }
    advance(&r->read, read);
    observe_fill(r);
    if (missing) {
        atomic_fetch_add(&m->underruns, 1);
    }
    return noErr;
}

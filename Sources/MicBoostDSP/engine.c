#include "monitor_internal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    double hz, db, q, b0, b1, b2, a1, a2, z[2][2];
} biquad;

struct mb_engine {
    uint32_t maximum;
    mb_routing routing;
    mb_ring *monitor_ring;
    double monitor_ticks;
    float *scratch;
    _Atomic float gain, bands[9], input_peak, output_peak;
    _Atomic unsigned selection;
    _Atomic bool muted, eq, fading, fade_done, clipped;
    _Atomic uint64_t cycles, missing, nonfinite, oversized, delta;
    double decay;
    double rate, current_gain, gain_decay, release, limiter, wet;
    biquad filters[3];
    _Atomic float gr;
};

mb_engine *mb_engine_create(uint32_t maximum, double rate) {
    if (!maximum || !isfinite(rate) || rate <= 0 || maximum > UINT32_MAX / 66) {
        return NULL;
    }
    mb_engine *e = calloc(1, sizeof(*e));
    if (!e) {
        return NULL;
    }
    e->scratch = calloc((size_t)maximum * 66, sizeof(float));
    if (!e->scratch) {
        free(e);
        return NULL;
    }
    if (!atomic_is_lock_free(&e->gain) || !atomic_is_lock_free(&e->cycles)) {
        free(e->scratch);
        free(e);
        return NULL;
    }
    e->monitor_ring = mb_ring_create(rate);
    if (!e->monitor_ring) {
        free(e->scratch);
        free(e);
        return NULL;
    }
    e->monitor_ticks = mb_ring_ticks(e->monitor_ring);
    e->maximum = maximum;
    e->routing.input_count = 1;
    e->routing.outputs[1].channel = 1;
    e->rate = rate;
    e->current_gain = 1;
    e->limiter = 1;
    e->wet = 1;
    e->gain_decay = exp(-1 / (0.020 * rate));
    e->release = exp(-1 / (0.150 * rate));
    atomic_store(&e->eq, true);
    const double frequencies[3] = {120, 1000, 6000};
    for (unsigned b = 0; b < 3; b++) {
        e->filters[b].hz = log(frequencies[b]);
        e->filters[b].q = 0.9;
        e->filters[b].b0 = 1;
        atomic_store(&e->bands[b * 3], frequencies[b]);
        atomic_store(&e->bands[b * 3 + 2], 0.9);
    }
    e->decay = exp(-1 / (0.003 * rate));
    return e;
}

void mb_engine_destroy(mb_engine *e) {
    mb_ring_destroy(e->monitor_ring);
    free(e->scratch);
    free(e);
}

int mb_engine_configure(mb_engine *e, const mb_routing *r) {
    if (!r->input_count || r->input_count > 64) {
        return -1;
    }
    e->routing = *r;
    return 0;
}

void mb_engine_set_gain_db(mb_engine *e, float db) {
    atomic_store(&e->gain, isfinite(db) ? fmaxf(-12, fminf(24, db)) : 0);
}
mb_ring *mb_engine_ring(mb_engine *e) { return e->monitor_ring; }
void mb_engine_set_monitor_enabled(mb_engine *e, bool enabled) {
    mb_ring_enable(e->monitor_ring, enabled);
}
void mb_monitor_write(mb_engine *e, const float *left, const float *right,
                      uint32_t frames, uint64_t host) {
    mb_ring_push(e->monitor_ring, left, right, frames, host);
}
void mb_engine_set_muted(mb_engine *e, bool value) {
    atomic_store(&e->muted, value);
}
void mb_engine_set_eq_enabled(mb_engine *e, bool value) {
    atomic_store(&e->eq, value);
}
void mb_engine_set_band(mb_engine *e, mb_band band, float hz, float db, float q) {
    if (band < MB_LOW || band > MB_HIGH) {
        return;
    }
    atomic_store(&e->bands[band * 3], isfinite(hz) ? fmaxf(20, hz) : 1000);
    atomic_store(&e->bands[band * 3 + 1], isfinite(db) ? fmaxf(-12, fminf(12, db)) : 0);
    atomic_store(&e->bands[band * 3 + 2], isfinite(q) ? fmaxf(0.3, fminf(4, q)) : 0.9);
}
void mb_engine_set_channel_mode(mb_engine *e, mb_channel_mode mode, uint32_t first) {
    atomic_store(&e->selection, ((first & 63) << 2) | (mode & 3));
}
void mb_engine_begin_fade_out(mb_engine *e) {
    atomic_store(&e->fading, true);
}
static void peak(_Atomic float *target, float value) {
    float previous = atomic_load(target);
    while (previous < value && !atomic_compare_exchange_weak(target, &previous, value)) {
    }
}
void mb_engine_read_meters(mb_engine *e, mb_meters *out) {
    out->input_peak = atomic_exchange(&e->input_peak, 0);
    out->output_peak = atomic_exchange(&e->output_peak, 0);
    out->input_clipped = atomic_exchange(&e->clipped, false);
    out->gr_max_db = atomic_exchange(&e->gr, 0);
    out->fade_done = atomic_load(&e->fade_done);
}
void mb_engine_read_counters(const mb_engine *e, mb_counters *out) {
    out->cycles = atomic_load(&e->cycles);
    out->input_missing = atomic_load(&e->missing);
    out->nonfinite_resets = atomic_load(&e->nonfinite);
    out->frames_over_max = atomic_load(&e->oversized);
    out->io_delta_host = atomic_load(&e->delta);
}
static double smooth(double current, double target, double decay) {
    return fabs(current - target) < 1e-7 ? target : target + decay * (current - target);
}
static void coefficients(biquad *f, unsigned band, double rate) {
    if (f->db == 0) {
        f->b0 = 1;
        f->b1 = f->b2 = f->a1 = f->a2 = 0;
        memset(f->z, 0, sizeof(f->z));
        return;
    }
    double w = 2 * M_PI * fmax(20, fmin(0.45 * rate, exp(f->hz))) / rate;
    double c = cos(w), a = pow(10, f->db / 40), alpha = sin(w) / (2 * f->q);
    double b0, b1, b2, a0, a1, a2;
    if (band == MB_MID) {
        b0 = 1 + alpha * a;
        b1 = -2 * c;
        b2 = 1 - alpha * a;
        a0 = 1 + alpha / a;
        a1 = -2 * c;
        a2 = 1 - alpha / a;
    } else {
        double t = sin(w) * sqrt(2 * a);
        double sign = band == MB_LOW ? 1 : -1;
        b0 = a * ((a + 1) - sign * (a - 1) * c + t);
        b1 = 2 * sign * a * ((a - 1) - sign * (a + 1) * c);
        b2 = a * ((a + 1) - sign * (a - 1) * c - t);
        a0 = (a + 1) + sign * (a - 1) * c + t;
        a1 = -2 * sign * ((a - 1) + sign * (a + 1) * c);
        a2 = (a + 1) + sign * (a - 1) * c - t;
    }
    f->b0 = b0 / a0;
    f->b1 = b1 / a0;
    f->b2 = b2 / a0;
    f->a1 = a1 / a0;
    f->a2 = a2 / a0;
}
static void update_filters(mb_engine *e, uint32_t size) {
    double decay = exp(-(double)size / (0.030 * e->rate));
    for (unsigned b = 0; b < 3; b++) {
        biquad *f = &e->filters[b];
        double hz = log(fmax(20, fmin(0.45 * e->rate, atomic_load(&e->bands[b * 3]))));
        double db = atomic_load(&e->bands[b * 3 + 1]);
        double q = atomic_load(&e->bands[b * 3 + 2]);
        if (hz != f->hz || db != f->db || q != f->q) {
            f->hz = smooth(f->hz, hz, decay);
            f->db = smooth(f->db, db, decay);
            f->q = smooth(f->q, q, decay);
            coefficients(f, b, e->rate);
        }
    }
}
static double filter(biquad *f, unsigned ch, double x) {
    if (f->db == 0) {
        return x;
    }
    double y = f->b0 * x + f->z[ch][0];
    f->z[ch][0] = f->b1 * x - f->a1 * y + f->z[ch][1];
    f->z[ch][1] = f->b2 * x - f->a2 * y;
    return y;
}
static void reset_filters(mb_engine *e) {
    for (unsigned b = 0; b < 3; b++) {
        memset(e->filters[b].z, 0, sizeof(e->filters[b].z));
    }
}
static unsigned process(mb_engine *e, const float *const *in, float *const *out,
                        uint32_t frames) {
    unsigned selection = atomic_load(&e->selection);
    unsigned mode = selection & 3;
    unsigned first = selection >> 2;
    unsigned count = e->routing.input_count;
    bool fading = atomic_load(&e->fading);
    bool invalid = false;
    bool missing = false;

    if (first >= count || (mode == MB_STEREO && first + 1 >= count)) {
        first = 0;
    }
    for (uint32_t base = 0; base < frames;) {
        uint32_t size = frames - base;
        if (size > e->maximum) {
            size = e->maximum;
        }
        update_filters(e, size);
        double target_gain = atomic_load(&e->muted) ? 0 : pow(10, atomic_load(&e->gain) / 20);
        double wet_target = atomic_load(&e->eq) ? 1 : 0;
        bool bad_output = false;
        float input_peak = 0, output_peak = 0, gr = 0;
        bool clipped = false;
        for (uint32_t i = base; i < base + size; i++) {
            float value[2] = {0, 0};
            for (unsigned ch = 0; ch < 2; ch++) {
                unsigned index = mode == MB_AUTO ? 0 : first;
                if (mode == MB_STEREO && count > 1) {
                    index += ch;
                }
                if (mode == MB_MONO_MIX) {
                    double sum = 0;
                    for (unsigned c = 0; c < count; c++) {
                        float x = in[c] ? in[c][i] : 0;
                        missing |= !in[c];
                        invalid |= !isfinite(x);
                        sum += isfinite(x) ? x : 0;
                    }
                    value[ch] = (float)(sum / count);
                } else {
                    missing |= !in[index];
                    value[ch] = in[index] ? in[index][i] : 0;
                    invalid |= !isfinite(value[ch]);
                    if (!isfinite(value[ch])) {
                        value[ch] = 0;
                    }
                }
                input_peak = fmaxf(input_peak, fabsf(value[ch]));
                if (fabsf(value[ch]) >= 0.999f) {
                    clipped = true;
                }
            }
            e->wet += fmax(-1 / (0.020 * e->rate),
                fmin(1 / (0.020 * e->rate), wet_target - e->wet));
            e->current_gain = smooth(e->current_gain, fading ? 0 : target_gain,
                fading ? e->decay : e->gain_decay);
            if (fading && e->current_gain < 0.000031622777) {
                e->current_gain = 0;
                atomic_store(&e->fade_done, true);
            }
            double signal[2];
            unsigned channels = mode == MB_STEREO && count > 1 ? 2 : 1;
            for (unsigned ch = 0; ch < channels; ch++) {
                double y = value[ch];
                for (unsigned b = 0; b < 3; b++) {
                    y = filter(&e->filters[b], ch, y);
                }
                double mixed = y == value[ch] ? value[ch] : value[ch] + e->wet * (y - value[ch]);
                signal[ch] = mixed * e->current_gain;
            }
            if (channels == 1) {
                signal[1] = signal[0];
            }
            double magnitude = fmax(fabs(signal[0]), fabs(signal[1]));
            double target = magnitude > 0.891 ? 0.891 / magnitude : 1;
            e->limiter = fmin(target, 1 + e->release * (e->limiter - 1));
            gr = fmaxf(gr, (float)(-20 * log10(e->limiter)));
            for (unsigned ch = 0; ch < 2; ch++) {
                double y = signal[ch] * e->limiter;
                if (!isfinite(y)) {
                    bad_output = true;
                    y = 0;
                }
                float sample = (float)fmax(-1, fmin(1, y));
                if (out[ch]) {
                    out[ch][i] = sample;
                }
                output_peak = fmaxf(output_peak, fabsf(sample));
            }
        }
        if (bad_output) {
            invalid = true;
            output_peak = 0;
            for (unsigned ch = 0; ch < 2; ch++) {
                if (out[ch]) {
                    memset(out[ch] + base, 0, size * sizeof(float));
                }
            }
        }
        if (invalid) {
            reset_filters(e);
        }
        for (unsigned b = 0; b < 3; b++) {
            for (unsigned ch = 0; ch < 2; ch++) {
                for (unsigned z = 0; z < 2; z++) {
                    if (fabs(e->filters[b].z[ch][z]) < 1e-25) {
                        e->filters[b].z[ch][z] = 0;
                    }
                }
            }
        }
        peak(&e->input_peak, input_peak);
        peak(&e->output_peak, output_peak);
        peak(&e->gr, gr);
        if (clipped) {
            atomic_store(&e->clipped, true);
        }
        base += size;
    }
    return (invalid ? 1u : 0u) | (missing ? 2u : 0u);
}
static void count_cycle(mb_engine *e, unsigned flags, uint32_t frames) {
    if (flags & 1u) {
        atomic_fetch_add(&e->nonfinite, 1);
    }
    if (flags & 2u) {
        atomic_fetch_add(&e->missing, 1);
    }
    if (frames > e->maximum) {
        atomic_fetch_add(&e->oversized, 1);
    }
    atomic_fetch_add(&e->cycles, 1);
}
void mb_engine_process(mb_engine *e, const float *const *in, float *const *out,
                       uint32_t frames) {
    count_cycle(e, process(e, in, out, frames), frames);
}

OSStatus mb_ioproc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *in, const AudioTimeStamp *input_time,
    AudioBufferList *out, const AudioTimeStamp *output_time, void *context) {
    (void)device;
    (void)now;
    mb_engine *e = context;
    for (unsigned b = 0; b < out->mNumberBuffers; b++) {
        if (out->mBuffers[b].mData) {
            memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
        }
    }
    if (!e) {
        return noErr;
    }
    atomic_store(&e->delta, output_time->mHostTime - input_time->mHostTime);
    uint32_t frames = 0;
    for (unsigned c = 0; c < 2; c++) {
        mb_channel map = e->routing.outputs[c];
        if (map.buffer < out->mNumberBuffers) {
            AudioBuffer buffer = out->mBuffers[map.buffer];
            if (buffer.mNumberChannels) {
                uint32_t n = buffer.mDataByteSize / (4 * buffer.mNumberChannels);
                if (n > frames) {
                    frames = n;
                }
            }
        }
    }
    unsigned flags = frames == 0 ? 2u : 0u;
    for (uint32_t base = 0; base < frames;) {
        uint32_t n = frames - base;
        if (n > e->maximum) {
            n = e->maximum;
        }
        const float *inputs[64] = {0};
        float *outputs[2] = {e->scratch + 64 * e->maximum,
                             e->scratch + 65 * e->maximum};
        for (unsigned c = 0; c < e->routing.input_count; c++) {
            mb_channel map = e->routing.inputs[c];
            float *dest = e->scratch + c * e->maximum;
            memset(dest, 0, n * sizeof(float));
            if (map.buffer < in->mNumberBuffers) {
                AudioBuffer buffer = in->mBuffers[map.buffer];
                if (buffer.mData && buffer.mDataByteSize > 0
                    && map.channel < buffer.mNumberChannels) {
                    inputs[c] = dest;
                    for (uint32_t i = 0; i < n; i++) {
                        size_t index = (size_t)(base + i) * buffer.mNumberChannels + map.channel;
                        if (index < buffer.mDataByteSize / sizeof(float)) {
                            dest[i] = ((const float *)buffer.mData)[index];
                        }
                    }
                }
            }
        }
        flags |= process(e, inputs, outputs, n);
        for (unsigned c = 0; c < 2; c++) {
            mb_channel map = e->routing.outputs[c];
            if (map.buffer >= out->mNumberBuffers) {
                continue;
            }
            AudioBuffer buffer = out->mBuffers[map.buffer];
            if (!buffer.mData || map.channel >= buffer.mNumberChannels) {
                continue;
            }
            for (uint32_t i = 0; i < n; i++) {
                size_t index = (size_t)(base + i) * buffer.mNumberChannels + map.channel;
                if (index < buffer.mDataByteSize / sizeof(float)) {
                    ((float *)buffer.mData)[index] = outputs[c][i];
                }
            }
        }
        // Timestamp the first frame of each scratch block using the input clock.
        mb_monitor_write(e, outputs[0], outputs[1], n,
                         input_time->mHostTime + (uint64_t)(base * e->monitor_ticks));
        base += n;
    }
    count_cycle(e, flags, frames);
    return noErr;
}

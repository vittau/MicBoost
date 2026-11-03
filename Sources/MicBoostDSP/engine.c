#include "MicBoostDSP.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

struct mb_engine {
    uint32_t maximum;
    mb_routing routing;
    float *scratch;
    _Atomic float gain, bands[9], input_peak, output_peak;
    _Atomic unsigned selection;
    _Atomic bool muted, eq, fading, fade_done, clipped;
    _Atomic uint64_t cycles, missing, nonfinite, oversized, delta;
    float fade, decay;
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
    e->maximum = maximum;
    e->routing.input_count = 1;
    e->routing.outputs[1].channel = 1;
    e->fade = 1;
    e->decay = (float)exp(-1 / (0.003 * rate));
    return e;
}

void mb_engine_destroy(mb_engine *e) {
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
    atomic_store(&e->gain, db);
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
    atomic_store(&e->bands[band * 3], hz);
    atomic_store(&e->bands[band * 3 + 1], db);
    atomic_store(&e->bands[band * 3 + 2], q);
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
    out->gr_max_db = 0;
    out->fade_done = atomic_load(&e->fade_done);
}
void mb_engine_read_counters(const mb_engine *e, mb_counters *out) {
    out->cycles = atomic_load(&e->cycles);
    out->input_missing = atomic_load(&e->missing);
    out->nonfinite_resets = atomic_load(&e->nonfinite);
    out->frames_over_max = atomic_load(&e->oversized);
    out->io_delta_host = atomic_load(&e->delta);
}
void mb_engine_process(mb_engine *e, const float *const *in, float *const *out,
                       uint32_t frames) {
    unsigned selection = atomic_load(&e->selection);
    unsigned mode = selection & 3;
    unsigned first = selection >> 2;
    unsigned count = e->routing.input_count;
    bool fading = atomic_load(&e->fading);
    bool invalid = false;
    bool missing = false;
    if (frames > e->maximum) {
        atomic_fetch_add(&e->oversized, 1);
    }
    if (first >= count || (mode == MB_STEREO && first + 1 >= count)) {
        first = 0;
    }
    for (uint32_t base = 0; base < frames;) {
        uint32_t size = frames - base;
        if (size > e->maximum) {
            size = e->maximum;
        }
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
                peak(&e->input_peak, fabsf(value[ch]));
                if (fabsf(value[ch]) >= 0.999f) {
                    atomic_store(&e->clipped, true);
                }
            }
            if (fading) {
                e->fade *= e->decay;
                if (e->fade < 0.000031622777f) {
                    e->fade = 0;
                    atomic_store(&e->fade_done, true);
                }
            }
            for (unsigned ch = 0; ch < 2; ch++) {
                float y = fading ? value[ch] * e->fade : value[ch];
                if (out[ch]) {
                    out[ch][i] = y;
                }
                peak(&e->output_peak, fabsf(y));
            }
        }
        base += size;
    }
    if (invalid) {
        atomic_fetch_add(&e->nonfinite, 1);
    }
    if (missing) {
        atomic_fetch_add(&e->missing, 1);
    }
    atomic_fetch_add(&e->cycles, 1);
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
                if (buffer.mData && map.channel < buffer.mNumberChannels) {
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
        mb_engine_process(e, inputs, outputs, n);
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
        base += n;
    }
    return noErr;
}

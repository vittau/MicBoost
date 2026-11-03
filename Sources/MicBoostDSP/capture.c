#include "MicBoostDSP.h"
#include <stdlib.h>

struct mb_capture {
    float *samples;
    size_t capacity;
    unsigned channels;
    _Atomic size_t written;
    _Atomic uint64_t first_host;
};

mb_capture *mb_capture_create(size_t frames, unsigned channels) {
    if (!frames || !channels || frames > SIZE_MAX / channels / sizeof(float)) {
        return NULL;
    }
    mb_capture *c = calloc(1, sizeof(*c));
    if (!c) {
        return NULL;
    }
    c->samples = calloc(frames * channels, sizeof(float));
    if (!c->samples) {
        free(c);
        return NULL;
    }
    c->capacity = frames;
    c->channels = channels;
    atomic_init(&c->written, 0);
    return c;
}

uint64_t mb_capture_host_time(const mb_capture *c) {
    return atomic_load(&c->first_host);
}

void mb_capture_destroy(mb_capture *c) {
    if (c) {
        free(c->samples);
        free(c);
    }
}

size_t mb_capture_frames(const mb_capture *c) {
    return atomic_load_explicit(&c->written, memory_order_acquire);
}

const float *mb_capture_samples(const mb_capture *c) {
    return c->samples;
}

OSStatus mb_capture_ioproc(
    AudioObjectID device,
    const AudioTimeStamp *now,
    const AudioBufferList *input,
    const AudioTimeStamp *inputTime,
    AudioBufferList *output,
    const AudioTimeStamp *outputTime,
    void *context
) {
    mb_capture *c = context;
    if (!input || !input->mNumberBuffers) {
        return noErr;
    }
    size_t frames = SIZE_MAX;
    for (unsigned b = 0; b < input->mNumberBuffers; ++b) {
        const AudioBuffer *buf = &input->mBuffers[b];
        if (buf->mNumberChannels) {
            size_t n = buf->mDataByteSize / sizeof(float) / buf->mNumberChannels;
            if (n < frames) {
                frames = n;
            }
        }
    }
    size_t start = atomic_load_explicit(&c->written, memory_order_relaxed);
    if (frames > c->capacity - start) {
        frames = c->capacity - start;
    }
    if (start == 0 && frames > 0) {
        atomic_store(&c->first_host, inputTime->mHostTime);
    }
    unsigned channel = 0;
    for (unsigned b = 0; b < input->mNumberBuffers; ++b) {
        const AudioBuffer *buf = &input->mBuffers[b];
        const float *src = buf->mData;
        for (unsigned ch = 0; ch < buf->mNumberChannels && channel < c->channels; ++ch, ++channel) {
            for (size_t f = 0; f < frames; ++f) {
                c->samples[(start + f) * c->channels + channel] =
                    src ? src[f * buf->mNumberChannels + ch] : 0;
            }
        }
    }
    atomic_store_explicit(&c->written, start + frames, memory_order_release);
    return noErr;
}

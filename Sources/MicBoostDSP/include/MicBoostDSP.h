#ifndef MICBOOST_DSP_H
#define MICBOOST_DSP_H

#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stddef.h>

/* Diagnostic capture only; no engine or DSP processing. */
typedef struct mb_capture mb_capture;

/* Preallocate interleaved Float32 storage; return NULL for invalid sizes or allocation failure. */
mb_capture * _Nullable mb_capture_create(size_t frames, unsigned channels);

/* Free capture storage after stopping and destroying its IOProc. */
void mb_capture_destroy(mb_capture * _Nonnull capture);

/* Read the number of captured frames with acquire ordering. */
size_t mb_capture_frames(const mb_capture * _Nonnull capture);

/* Borrow interleaved samples; read only after stopping the IOProc, before destroying capture. */
const float * _Nonnull mb_capture_samples(const mb_capture * _Nonnull capture);

/* Copy raw input into preallocated storage; context must point to a live mb_capture. */
OSStatus mb_capture_ioproc(
    AudioObjectID device,
    const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input,
    const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output,
    const AudioTimeStamp * _Nonnull outputTime,
    void * _Nullable context
);

#endif

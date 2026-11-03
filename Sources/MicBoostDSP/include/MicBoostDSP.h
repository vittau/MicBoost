#ifndef MICBOOST_DSP_H
#define MICBOOST_DSP_H
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stddef.h>
/* Diagnostic capture only; no engine or DSP processing. */
typedef struct mb_capture mb_capture;
mb_capture * _Nullable mb_capture_create(size_t frames, unsigned channels);
void mb_capture_destroy(mb_capture * _Nonnull capture);
size_t mb_capture_frames(const mb_capture * _Nonnull capture);
const float * _Nonnull mb_capture_samples(const mb_capture * _Nonnull capture);
OSStatus mb_capture_ioproc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
 const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
 AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#endif

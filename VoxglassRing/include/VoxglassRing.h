#ifndef VOXGLASS_RING_H
#define VOXGLASS_RING_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

/// Lock-free single-producer / single-consumer ring buffer of interleaved
/// mono float PCM samples (spec §7.2, Studio Spec §4.11/§11.3). The producer
/// (audio tap, real-time thread) calls `vgr_push`; the consumer (writer task)
/// calls `vgr_pop`. All index traffic is `_Atomic` with release/acquire
/// ordering: the producer publishes samples before publishing its index, and
/// the consumer publishes its index after consuming. `vgr_push` performs no
/// allocation and never blocks, so it is safe on the real-time audio thread.
///
/// The usable capacity is `capacity - 1` (the classic full/empty ambiguity).
/// When the consumer falls behind, `vgr_push` drops the newest samples that
/// do not fit rather than blocking the producer; the writer task detects the
/// underflow gap and reports it via `vgr_dropped`.
typedef struct {
    float *samples;      // preallocated at create; never reallocated
    size_t capacity;     // allocated length (usable capacity - 1)
    _Atomic size_t writeIndex;
    _Atomic size_t readIndex;
    _Atomic size_t droppedCount; // cumulative dropped-sample counter
} vgr_ring;

/// Allocates a ring of the given capacity. Returns a zeroed ring on OOM.
vgr_ring vgr_create(size_t capacity);

/// Frees the sample buffer and zeroes the struct. Safe to call on a
/// zero-initialized ring.
void vgr_destroy(vgr_ring *ring);

/// The allocated length of the ring's sample buffer.
size_t vgr_capacity(const vgr_ring *ring);

/// Samples currently available to the consumer (0..capacity-1).
size_t vgr_available(const vgr_ring *ring);

/// Total samples dropped by the producer since creation (consumer lag).
size_t vgr_dropped(const vgr_ring *ring);

/// Copies up to `count` samples into the ring, wrapping at the end. Anything
/// that does not fit is dropped and counted in `droppedCount`. Real-time
/// safe: a bounded `memcpy`-style loop with atomic index stores.
void vgr_push(vgr_ring *ring, const float *samples, size_t count);

/// Copies up to `maxCount` samples out of the ring, wrapping at the end.
/// Returns the number of samples copied.
size_t vgr_pop(vgr_ring *ring, float *out, size_t maxCount);

#endif /* VOXGLASS_RING_H */

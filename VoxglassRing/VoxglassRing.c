#include "VoxglassRing.h"
#include <stdlib.h>

vgr_ring vgr_create(size_t capacity) {
    vgr_ring ring = {0};
    if (capacity < 2) {
        return ring; // unusable; caller checks capacity
    }
    ring.samples = (float *)malloc(capacity * sizeof(float));
    if (ring.samples == NULL) {
        return ring;
    }
    ring.capacity = capacity;
    atomic_init(&ring.writeIndex, 0);
    atomic_init(&ring.readIndex, 0);
    atomic_init(&ring.droppedCount, 0);
    return ring;
}

void vgr_destroy(vgr_ring *ring) {
    if (ring->samples != NULL) {
        free(ring->samples);
        ring->samples = NULL;
    }
    ring->capacity = 0;
    atomic_store_explicit(&ring->writeIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->readIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->droppedCount, 0, memory_order_relaxed);
}

size_t vgr_capacity(const vgr_ring *ring) {
    return ring->capacity;
}

size_t vgr_available(const vgr_ring *ring) {
    size_t write = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    size_t read = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    return (write + ring->capacity - read) % ring->capacity;
}

size_t vgr_dropped(const vgr_ring *ring) {
    return atomic_load_explicit(&ring->droppedCount, memory_order_relaxed);
}

void vgr_push(vgr_ring *ring, const float *samples, size_t count) {
    size_t write = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    // The consumer publishes readIndex only after the samples are consumed, so
    // an acquire load here sees every slot the consumer has freed.
    size_t read = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    size_t capacity = ring->capacity;
    // Usable capacity is capacity - 1; never fill the ring completely so a
    // full ring is distinguishable from an empty one.
    size_t freeSlots = (read + capacity - 1 - write) % capacity;
    size_t toWrite = count < freeSlots ? count : freeSlots;
    for (size_t i = 0; i < toWrite; i++) {
        ring->samples[(write + i) % capacity] = samples[i];
    }
    if (toWrite < count) {
        atomic_fetch_add_explicit(&ring->droppedCount, count - toWrite, memory_order_relaxed);
    }
    // Publish the samples before publishing the index.
    atomic_store_explicit(&ring->writeIndex, (write + toWrite) % capacity, memory_order_release);
}

size_t vgr_pop(vgr_ring *ring, float *out, size_t maxCount) {
    size_t read = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    // The producer publishes its index only after the samples are in the
    // buffer, so an acquire load here sees every sample it wrote.
    size_t write = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    size_t capacity = ring->capacity;
    size_t available = (write + capacity - read) % capacity;
    size_t toRead = available < maxCount ? available : maxCount;
    for (size_t i = 0; i < toRead; i++) {
        out[i] = ring->samples[(read + i) % capacity];
    }
    // Publish the read index only after the samples have been consumed.
    atomic_store_explicit(&ring->readIndex, (read + toRead) % capacity, memory_order_release);
    return toRead;
}

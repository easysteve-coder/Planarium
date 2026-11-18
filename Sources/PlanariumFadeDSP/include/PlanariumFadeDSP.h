#ifndef PLANARIUM_FADE_DSP_H
#define PLANARIUM_FADE_DSP_H
#include <stdint.h>
#include <AudioToolbox/AudioToolbox.h>

typedef struct PlanariumFadeState PlanariumFadeState;
PlanariumFadeState *planarium_fade_create(void);
void planarium_fade_destroy(PlanariumFadeState *state);
// Control thread only. Reset requires stopped/deallocated rendering.
void planarium_fade_reset(PlanariumFadeState *state, double sample_rate, int silent);
uint32_t planarium_fade_request(PlanariumFadeState *state, int silent);
int planarium_fade_reached(PlanariumFadeState *state, uint32_t token);
int planarium_fade_lock_free(PlanariumFadeState *state);
// Render thread only: no allocation, lock, object, logging or Swift storage.
void planarium_fade_render(PlanariumFadeState *state, AudioBufferList *buffers, uint32_t frames);
#endif

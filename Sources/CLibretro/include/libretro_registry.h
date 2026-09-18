/* Registry of the statically linked libretro cores.
 *
 * Each core's 25 entry points are linked under a per-core prefix
 * (fceumm_retro_run, snes9x_retro_run, ...; see tools/core-shim.c), so the host
 * can't call retro_* free functions — it looks a core up by name and dispatches
 * through this vtable. Field names mirror the libretro API 1:1.
 *
 * The lookup key is the EmulatorJS core alias the frontend sends (fceumm, snes9x,
 * segaMD, gambatte, pce, ...), kept in tools/cores.json. */
#ifndef LIBRETRO_REGISTRY_H
#define LIBRETRO_REGISTRY_H

#include <stddef.h>
#include "libretro.h"

typedef struct {
  const char *name;

  void (*retro_set_environment)(retro_environment_t);
  void (*retro_set_video_refresh)(retro_video_refresh_t);
  void (*retro_set_audio_sample)(retro_audio_sample_t);
  void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t);
  void (*retro_set_input_poll)(retro_input_poll_t);
  void (*retro_set_input_state)(retro_input_state_t);
  void (*retro_init)(void);
  void (*retro_deinit)(void);
  unsigned (*retro_api_version)(void);
  void (*retro_get_system_info)(struct retro_system_info *);
  void (*retro_get_system_av_info)(struct retro_system_av_info *);
  void (*retro_set_controller_port_device)(unsigned, unsigned);
  void (*retro_reset)(void);
  void (*retro_run)(void);
  size_t (*retro_serialize_size)(void);
  bool (*retro_serialize)(void *, size_t);
  bool (*retro_unserialize)(const void *, size_t);
  void (*retro_cheat_reset)(void);
  void (*retro_cheat_set)(unsigned, bool, const char *);
  bool (*retro_load_game)(const struct retro_game_info *);
  bool (*retro_load_game_special)(unsigned, const struct retro_game_info *, size_t);
  void (*retro_unload_game)(void);
  unsigned (*retro_get_region)(void);
  void *(*retro_get_memory_data)(unsigned);
  size_t (*retro_get_memory_size)(unsigned);
} libretro_core_t;

/* NULL if the name isn't a linked core. The pointer is to static storage. */
const libretro_core_t *libretro_core_lookup(const char *name);
size_t libretro_core_count(void);
/* NULL past the end. */
const char *libretro_core_name(size_t index);

#endif

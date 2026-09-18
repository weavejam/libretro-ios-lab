/* Vtable registry over the statically linked, symbol-prefixed cores.
 *
 * cores_list.h (generated from tools/cores.json) is included twice with different
 * CORE() definitions: first to declare each core's 25 prefixed entry points, then
 * to build one static vtable per core. Because the table references every core's
 * symbols, every core's archive member is always pulled into the final link — the
 * IPA carries all cores by design, nothing is dead-stripped away by accident. */
#include <string.h>
#include "libretro_registry.h"

/* Pass 1: extern prototypes for every prefixed entry point. */
#define CORE(p) \
  void p##_retro_set_environment(retro_environment_t); \
  void p##_retro_set_video_refresh(retro_video_refresh_t); \
  void p##_retro_set_audio_sample(retro_audio_sample_t); \
  void p##_retro_set_audio_sample_batch(retro_audio_sample_batch_t); \
  void p##_retro_set_input_poll(retro_input_poll_t); \
  void p##_retro_set_input_state(retro_input_state_t); \
  void p##_retro_init(void); \
  void p##_retro_deinit(void); \
  unsigned p##_retro_api_version(void); \
  void p##_retro_get_system_info(struct retro_system_info *); \
  void p##_retro_get_system_av_info(struct retro_system_av_info *); \
  void p##_retro_set_controller_port_device(unsigned, unsigned); \
  void p##_retro_reset(void); \
  void p##_retro_run(void); \
  size_t p##_retro_serialize_size(void); \
  bool p##_retro_serialize(void *, size_t); \
  bool p##_retro_unserialize(const void *, size_t); \
  void p##_retro_cheat_reset(void); \
  void p##_retro_cheat_set(unsigned, bool, const char *); \
  bool p##_retro_load_game(const struct retro_game_info *); \
  bool p##_retro_load_game_special(unsigned, const struct retro_game_info *, size_t); \
  void p##_retro_unload_game(void); \
  unsigned p##_retro_get_region(void); \
  void *p##_retro_get_memory_data(unsigned); \
  size_t p##_retro_get_memory_size(unsigned);
#include "cores_list.h"
#undef CORE

/* Pass 2: one vtable per core. */
#define CORE(p) \
  { \
    .name = #p, \
    .retro_set_environment = p##_retro_set_environment, \
    .retro_set_video_refresh = p##_retro_set_video_refresh, \
    .retro_set_audio_sample = p##_retro_set_audio_sample, \
    .retro_set_audio_sample_batch = p##_retro_set_audio_sample_batch, \
    .retro_set_input_poll = p##_retro_set_input_poll, \
    .retro_set_input_state = p##_retro_set_input_state, \
    .retro_init = p##_retro_init, \
    .retro_deinit = p##_retro_deinit, \
    .retro_api_version = p##_retro_api_version, \
    .retro_get_system_info = p##_retro_get_system_info, \
    .retro_get_system_av_info = p##_retro_get_system_av_info, \
    .retro_set_controller_port_device = p##_retro_set_controller_port_device, \
    .retro_reset = p##_retro_reset, \
    .retro_run = p##_retro_run, \
    .retro_serialize_size = p##_retro_serialize_size, \
    .retro_serialize = p##_retro_serialize, \
    .retro_unserialize = p##_retro_unserialize, \
    .retro_cheat_reset = p##_retro_cheat_reset, \
    .retro_cheat_set = p##_retro_cheat_set, \
    .retro_load_game = p##_retro_load_game, \
    .retro_load_game_special = p##_retro_load_game_special, \
    .retro_unload_game = p##_retro_unload_game, \
    .retro_get_region = p##_retro_get_region, \
    .retro_get_memory_data = p##_retro_get_memory_data, \
    .retro_get_memory_size = p##_retro_get_memory_size, \
  },
static const libretro_core_t g_cores[] = {
#include "cores_list.h"
};
#undef CORE

enum { G_CORE_COUNT = sizeof(g_cores) / sizeof(g_cores[0]) };

const libretro_core_t *libretro_core_lookup(const char *name) {
  if (!name) return NULL;
  for (size_t i = 0; i < G_CORE_COUNT; i++) {
    if (strcmp(g_cores[i].name, name) == 0) return &g_cores[i];
  }
  return NULL;
}

size_t libretro_core_count(void) { return G_CORE_COUNT; }

const char *libretro_core_name(size_t index) {
  return index < G_CORE_COUNT ? g_cores[index].name : NULL;
}

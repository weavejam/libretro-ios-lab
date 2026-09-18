/* Per-core symbol-prefix shim. Compiled once per core with -DCORE_PREFIX=<name>
 * and linked into the same `ld -r` partial link as that core's object files.
 *
 * Every libretro core exports the same 25 retro_* entry points, so two cores can't
 * be statically linked into one binary as-is. This shim re-exports each entry point
 * under a prefixed name (fceumm_retro_run → retro_run). The unprefixed originals —
 * and everything else the core defines, including its vendored libretro-common and
 * zlib copies — are then demoted to file-local by nmedit + a second `ld -r`, so the
 * prefixed wrappers below are the ONLY symbols a core contributes to the final link.
 *
 * Wrappers, not linker aliases, on purpose: `ld -r -alias_list` /
 * `-exported_symbols_list` interactions are underdocumented, while one extra tail
 * call per retro_* invocation (60/s for retro_run) is free.
 */
#include "libretro.h"

#ifndef CORE_PREFIX
#error "compile with -DCORE_PREFIX=<core name>"
#endif

#define CAT2(a, b) a##_##b
#define CAT(a, b) CAT2(a, b)
#define W(f) CAT(CORE_PREFIX, f)

void W(retro_set_environment)(retro_environment_t cb) { retro_set_environment(cb); }
void W(retro_set_video_refresh)(retro_video_refresh_t cb) { retro_set_video_refresh(cb); }
void W(retro_set_audio_sample)(retro_audio_sample_t cb) { retro_set_audio_sample(cb); }
void W(retro_set_audio_sample_batch)(retro_audio_sample_batch_t cb) { retro_set_audio_sample_batch(cb); }
void W(retro_set_input_poll)(retro_input_poll_t cb) { retro_set_input_poll(cb); }
void W(retro_set_input_state)(retro_input_state_t cb) { retro_set_input_state(cb); }
void W(retro_init)(void) { retro_init(); }
void W(retro_deinit)(void) { retro_deinit(); }
unsigned W(retro_api_version)(void) { return retro_api_version(); }
void W(retro_get_system_info)(struct retro_system_info *info) { retro_get_system_info(info); }
void W(retro_get_system_av_info)(struct retro_system_av_info *info) { retro_get_system_av_info(info); }
void W(retro_set_controller_port_device)(unsigned port, unsigned device) { retro_set_controller_port_device(port, device); }
void W(retro_reset)(void) { retro_reset(); }
void W(retro_run)(void) { retro_run(); }
size_t W(retro_serialize_size)(void) { return retro_serialize_size(); }
bool W(retro_serialize)(void *data, size_t size) { return retro_serialize(data, size); }
bool W(retro_unserialize)(const void *data, size_t size) { return retro_unserialize(data, size); }
void W(retro_cheat_reset)(void) { retro_cheat_reset(); }
void W(retro_cheat_set)(unsigned index, bool enabled, const char *code) { retro_cheat_set(index, enabled, code); }
bool W(retro_load_game)(const struct retro_game_info *game) { return retro_load_game(game); }
bool W(retro_load_game_special)(unsigned type, const struct retro_game_info *info, size_t num) { return retro_load_game_special(type, info, num); }
void W(retro_unload_game)(void) { retro_unload_game(); }
unsigned W(retro_get_region)(void) { return retro_get_region(); }
void *W(retro_get_memory_data)(unsigned id) { return retro_get_memory_data(id); }
size_t W(retro_get_memory_size)(unsigned id) { return retro_get_memory_size(id); }

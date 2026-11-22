/*
 * Copyright (c) 2013  Brian Paul   All Rights Reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
 * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */


#include "target-helpers/inline_sw_helper.h"
#include "target-helpers/inline_debug_helper.h"

#include "sw/null/null_sw_winsys.h"

#include "frontend/winsys_handle.h"
#include "pipe/p_screen.h"
#include "pipe/p_state.h"

#ifdef GALLIUM_FREEDRENO
#include "freedreno/drm/freedreno_drm_public.h"
#include "util/driconf.h"
#include "util/xmlconfig.h"
#include <xf86drm.h>

static int gpu_fd = -1;

static const driOptionDescription freedreno_options[] = {
#include "freedreno/driinfo_freedreno.h"
};

/* The GPU's driver, where the kernel has a GPU to drive (Darwin on redwood); NULL: none. */
static struct pipe_screen *
osmesa_create_gpu_screen(void)
{
   static driOptionCache info, cache;
   static struct pipe_screen_config config;
   struct pipe_screen *screen;
   int fd;

   if (debug_get_bool_option("OSMESA_SOFTWARE", false))
      return NULL;
   fd = drmOpenWithType("msm", NULL, DRM_NODE_RENDER);
   if (fd < 0)
      return NULL;
   driParseOptionInfo(&info, freedreno_options, ARRAY_SIZE(freedreno_options));
   driParseConfigFiles(&cache, &info, 0, "msm", NULL, NULL, NULL, 0, NULL, 0);
   config.options = &cache;
   config.options_info = &info;
   screen = fd_drm_screen_create_renderonly(fd, NULL, &config);
   if (screen)
      gpu_fd = fd;
   return screen ? debug_screen_wrap(screen) : NULL;
}
#endif


struct pipe_resource *
osmesa_surface_resource(struct pipe_screen *screen, uint32_t surface);

/*
 * The memory of an IOSurface as a texture, to draw into and to draw with (Darwin on redwood):
 * the kernel's GPU driver makes a buffer of the surface. NULL: the screen is not the GPU's, or
 * the surface is not one plane of 32-bit pixels, blue first, in rows the GPU can address.
 */
struct pipe_resource *
osmesa_surface_resource(struct pipe_screen *screen, uint32_t surface)
{
#ifdef GALLIUM_FREEDRENO
   struct redwood_drm_surface s = { .surface = surface };
   struct pipe_resource templ = {
      .target = PIPE_TEXTURE_2D,
      .format = PIPE_FORMAT_B8G8R8A8_UNORM,
      .depth0 = 1,
      .array_size = 1,
      .bind = PIPE_BIND_SAMPLER_VIEW | PIPE_BIND_RENDER_TARGET,
   };
   struct winsys_handle handle = { .type = WINSYS_HANDLE_TYPE_FD };

   if (gpu_fd < 0 || redwood_drm_surface(gpu_fd, &s) != 0)
      return NULL;
   if (s.pixel_format != 0x42475241 /* 'BGRA' */ || s.planes != 0)
      return NULL;
   /* (the surface comes in as Linux's buffers come in by file descriptor: see redwood-drm) */
   templ.width0 = s.width;
   templ.height0 = s.height;
   handle.handle = surface;
   handle.stride = s.row_bytes;
   handle.offset = s.offset;
   handle.size = s.size;
   return screen->resource_from_handle(screen, &templ, &handle, 0);
#else
   return NULL;
#endif
}


struct pipe_screen *
osmesa_create_screen(void);


struct pipe_screen *
osmesa_create_screen(void)
{
   struct sw_winsys *winsys;
   struct pipe_screen *screen;

#ifdef GALLIUM_FREEDRENO
   screen = osmesa_create_gpu_screen();
   if (screen)
      return screen;
#endif

   /* We use a null software winsys since we always just render to ordinary
    * driver resources.
    */
   winsys = null_sw_create();
   if (!winsys)
      return NULL;

   /* Create llvmpipe or softpipe screen */
   screen = sw_screen_create(winsys);
   if (!screen) {
      winsys->destroy(winsys);
      return NULL;
   }

   /* Inject optional trace, debug, etc. wrappers */
   return debug_screen_wrap(screen);
}

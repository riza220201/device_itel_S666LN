// ahbprobe - ask gralloc directly which format/usage combinations it supports,
// via AHardwareBuffer (which goes through IMapper/IAllocator).
//
// This is the same question the Mali driver has to answer to decide
// EGL_WINDOW_BIT and EGL_RECORDABLE_ANDROID on each EGLConfig. If gralloc says
// "no" here, the driver is right and gralloc is the thing to fix; if gralloc
// says "yes", the driver is deciding from its own internal table instead.
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <stdint.h>

typedef struct {
    uint32_t width, height, layers, format;
    uint64_t usage;
    uint32_t stride, rfu0; uint64_t rfu1;
} AHB_Desc;

typedef void AHardwareBuffer;
static int (*p_isSupported)(const AHB_Desc *);
static int (*p_allocate)(const AHB_Desc *, AHardwareBuffer **);
static void (*p_release)(AHardwareBuffer *);

#define F_RGBA8888 1
#define F_RGBX8888 2
#define F_RGB565   4
#define F_FP16     0x16
#define F_1010102  0x2b

#define U_GPU_SAMPLED   (1ULL << 8)
#define U_GPU_COLOR_OUT (1ULL << 9)
#define U_COMPOSER      (1ULL << 11)
#define U_VIDEO_ENCODE  (1ULL << 16)

struct fmt { const char *name; uint32_t f; };
static struct fmt fmts[] = {
    { "RGBA_8888   (visual 1)",  F_RGBA8888 },
    { "RGBX_8888   (visual 2)",  F_RGBX8888 },
    { "RGB_888     (visual 3)",  3 },
    { "RGB_565     (visual 4)",  F_RGB565   },
    { "RGBA_FP16   (visual 22)", F_FP16     },
    { "RGBA_1010102(visual 43)", F_1010102  },
};

struct use { const char *name; uint64_t u; };
static struct use uses[] = {
    { "GPU_COLOR_OUTPUT",                    U_GPU_COLOR_OUT },
    { "GPU_COLOR_OUTPUT|COMPOSER  (window)", U_GPU_COLOR_OUT | U_COMPOSER },
    { "GPU_COLOR_OUTPUT|VIDEO_ENC (record)", U_GPU_COLOR_OUT | U_VIDEO_ENCODE },
    { "VIDEO_ENCODE alone",                  U_VIDEO_ENCODE },
};

int main(void) {
    void *h = dlopen("libandroid.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen libandroid.so: %s\n", dlerror()); return 2; }
    p_isSupported = dlsym(h, "AHardwareBuffer_isSupported");
    p_allocate    = dlsym(h, "AHardwareBuffer_allocate");
    p_release     = dlsym(h, "AHardwareBuffer_release");
    if (!p_allocate) { fprintf(stderr, "no AHardwareBuffer_allocate\n"); return 2; }
    printf("AHardwareBuffer_isSupported present: %s\n\n", p_isSupported ? "yes" : "NO (allocate only)");

    printf("%-24s", "format \\ usage");
    for (unsigned u = 0; u < sizeof(uses)/sizeof(uses[0]); u++) printf(" %-38s", uses[u].name);
    printf("\n");

    for (unsigned f = 0; f < sizeof(fmts)/sizeof(fmts[0]); f++) {
        printf("%-24s", fmts[f].name);
        for (unsigned u = 0; u < sizeof(uses)/sizeof(uses[0]); u++) {
            AHB_Desc d; memset(&d, 0, sizeof d);
            d.width = 640; d.height = 480; d.layers = 1;
            d.format = fmts[f].f; d.usage = uses[u].u;

            int sup = p_isSupported ? p_isSupported(&d) : -1;
            AHardwareBuffer *b = NULL;
            int rc = p_allocate(&d, &b);
            if (b) p_release(b);

            char cell[64];
            snprintf(cell, sizeof cell, "isSupported=%-3s alloc=%s",
                     sup < 0 ? "?" : (sup ? "yes" : "NO"),
                     rc == 0 ? "ok" : "FAIL");
            printf(" %-38s", cell);
        }
        printf("\n");
    }
    return 0;
}

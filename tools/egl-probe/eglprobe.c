// eglprobe - enumerate every EGLConfig the driver offers, and for each one
// report whether an ES2 and an ES3 context can actually be created on it.
//
// Resolves EGL through dlopen/dlsym so it runs against whatever driver
// /vendor is serving at the time, with no link-time dependency.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef void *EGLContext;
typedef void *EGLSurface;
typedef int   EGLint;
typedef unsigned int EGLBoolean;

#define EGL_DEFAULT_DISPLAY   ((void *)0)
#define EGL_NO_CONTEXT        ((EGLContext)0)
#define EGL_FALSE 0
#define EGL_NONE  0x3038

#define EGL_CONFIG_ID         0x3028
#define EGL_BUFFER_SIZE       0x3020
#define EGL_RED_SIZE          0x3024
#define EGL_GREEN_SIZE        0x3023
#define EGL_BLUE_SIZE         0x3022
#define EGL_ALPHA_SIZE        0x3021
#define EGL_DEPTH_SIZE        0x3025
#define EGL_STENCIL_SIZE      0x3026
#define EGL_SAMPLES           0x3031
#define EGL_SURFACE_TYPE      0x3033
#define EGL_RENDERABLE_TYPE   0x3040
#define EGL_CONFORMANT        0x3042
#define EGL_CONFIG_CAVEAT     0x3027
#define EGL_NATIVE_VISUAL_ID  0x302E
#define EGL_COLOR_BUFFER_TYPE 0x303F
#define EGL_RECORDABLE_ANDROID 0x3142
#define EGL_FRAMEBUFFER_TARGET_ANDROID 0x3147
#define EGL_CONTEXT_CLIENT_VERSION 0x3098

static EGLDisplay (*p_eglGetDisplay)(void *);
static EGLBoolean (*p_eglInitialize)(EGLDisplay, EGLint *, EGLint *);
static EGLBoolean (*p_eglGetConfigs)(EGLDisplay, EGLConfig *, EGLint, EGLint *);
static EGLBoolean (*p_eglGetConfigAttrib)(EGLDisplay, EGLConfig, EGLint, EGLint *);
static EGLContext (*p_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
static EGLBoolean (*p_eglDestroyContext)(EGLDisplay, EGLContext);
static EGLint     (*p_eglGetError)(void);
static const char *(*p_eglQueryString)(EGLDisplay, EGLint);

static int attr(EGLDisplay d, EGLConfig c, EGLint a) {
    EGLint v = -1;
    if (!p_eglGetConfigAttrib(d, c, a, &v)) return -1;
    return v;
}

// Try to create a context of the given client version. Returns 0 on success,
// otherwise the EGL error code.
static int try_ctx(EGLDisplay d, EGLConfig c, int ver) {
    EGLint a[] = { EGL_CONTEXT_CLIENT_VERSION, ver, EGL_NONE };
    p_eglGetError();                       // clear
    EGLContext ctx = p_eglCreateContext(d, c, EGL_NO_CONTEXT, a);
    if (ctx) { p_eglDestroyContext(d, ctx); return 0; }
    return p_eglGetError();
}

int main(void) {
    void *h = dlopen("libEGL.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen libEGL.so: %s\n", dlerror()); return 2; }

#define SYM(n) p_##n = dlsym(h, #n); if (!p_##n) { fprintf(stderr, "dlsym %s failed\n", #n); return 2; }
    SYM(eglGetDisplay) SYM(eglInitialize) SYM(eglGetConfigs) SYM(eglGetConfigAttrib)
    SYM(eglCreateContext) SYM(eglDestroyContext) SYM(eglGetError) SYM(eglQueryString)
#undef SYM

    EGLDisplay d = p_eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint maj = 0, min = 0;
    if (!p_eglInitialize(d, &maj, &min)) {
        fprintf(stderr, "eglInitialize failed: 0x%x\n", p_eglGetError());
        return 2;
    }
    printf("# EGL %d.%d\n", maj, min);
    printf("# VENDOR  %s\n", p_eglQueryString(d, 0x3053));
    printf("# VERSION %s\n", p_eglQueryString(d, 0x3054));

    EGLint n = 0;
    if (!p_eglGetConfigs(d, NULL, 0, &n) || n <= 0) {
        fprintf(stderr, "eglGetConfigs count failed\n");
        return 2;
    }
    printf("# TOTAL_CONFIGS %d\n", n);

    EGLConfig *cfgs = calloc(n, sizeof(EGLConfig));
    p_eglGetConfigs(d, cfgs, n, &n);

    // Stable, diffable one line per config.
    printf("#%4s %4s %2s %2s %2s %2s %3s %3s %3s %6s %6s %6s %8s %4s %4s %5s %5s\n",
           "IDX", "ID", "R", "G", "B", "A", "DEP", "STN", "SMP",
           "SURFTY", "RENDTY", "CONFRM", "NATVIS", "REC", "FBT", "ES2", "ES3");

    for (int i = 0; i < n; i++) {
        EGLConfig c = cfgs[i];
        int es2 = try_ctx(d, c, 2);
        int es3 = try_ctx(d, c, 3);
        printf(" %4d %4d %2d %2d %2d %2d %3d %3d %3d 0x%04x 0x%04x 0x%04x %8d %4d %4d %5s %5s\n",
               i,
               attr(d, c, EGL_CONFIG_ID),
               attr(d, c, EGL_RED_SIZE), attr(d, c, EGL_GREEN_SIZE),
               attr(d, c, EGL_BLUE_SIZE), attr(d, c, EGL_ALPHA_SIZE),
               attr(d, c, EGL_DEPTH_SIZE), attr(d, c, EGL_STENCIL_SIZE),
               attr(d, c, EGL_SAMPLES),
               attr(d, c, EGL_SURFACE_TYPE), attr(d, c, EGL_RENDERABLE_TYPE),
               attr(d, c, EGL_CONFORMANT),
               attr(d, c, EGL_NATIVE_VISUAL_ID),
               attr(d, c, EGL_RECORDABLE_ANDROID),
               attr(d, c, EGL_FRAMEBUFFER_TARGET_ANDROID),
               es2 ? "FAIL" : "ok", es3 ? "FAIL" : "ok");
    }

    // Summary: how many configs refuse a context, which is the failure the app hit.
    int bad2 = 0, bad3 = 0;
    for (int i = 0; i < n; i++) {
        if (try_ctx(d, cfgs[i], 2)) bad2++;
        if (try_ctx(d, cfgs[i], 3)) bad3++;
    }
    printf("# ES2_REFUSED %d of %d\n", bad2, n);
    printf("# ES3_REFUSED %d of %d\n", bad3, n);
    return 0;
}

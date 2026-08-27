// eglchoose - run eglChooseConfig with the attribute lists real Android apps
// use, and report how many configs match. A camera/GL pipeline that gets 0
// matches typically passes an uninitialised EGLConfig straight to
// eglCreateContext, which is EGL_BAD_CONFIG (0x3005).
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>

typedef void *EGLDisplay; typedef void *EGLConfig; typedef int EGLint;
typedef unsigned int EGLBoolean;
#define EGL_NONE 0x3038
#define EGL_RED_SIZE 0x3024
#define EGL_GREEN_SIZE 0x3023
#define EGL_BLUE_SIZE 0x3022
#define EGL_ALPHA_SIZE 0x3021
#define EGL_DEPTH_SIZE 0x3025
#define EGL_STENCIL_SIZE 0x3026
#define EGL_SURFACE_TYPE 0x3033
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_CONFIG_ID 0x3028
#define EGL_RECORDABLE_ANDROID 0x3142
#define EGL_OPENGL_ES2_BIT 0x0004
#define EGL_OPENGL_ES3_BIT 0x0040
#define EGL_WINDOW_BIT 0x0004
#define EGL_PBUFFER_BIT 0x0001

static EGLDisplay (*p_eglGetDisplay)(void *);
static EGLBoolean (*p_eglInitialize)(EGLDisplay, EGLint *, EGLint *);
static EGLBoolean (*p_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
static EGLBoolean (*p_eglGetConfigAttrib)(EGLDisplay, EGLConfig, EGLint, EGLint *);

struct tc { const char *name; EGLint a[32]; };

static struct tc cases[] = {
  { "RGBA8888 + ES2                      (default surface type = WINDOW)",
    { EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
      EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT, EGL_NONE } },
  { "RGBA8888 + ES2 + RECORDABLE         <- camera/video GL pipeline",
    { EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
      EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT, EGL_RECORDABLE_ANDROID,1, EGL_NONE } },
  { "RGBA8888 + ES2 + RECORDABLE + WINDOW|PBUFFER",
    { EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
      EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT, EGL_RECORDABLE_ANDROID,1,
      EGL_SURFACE_TYPE,(EGL_WINDOW_BIT|EGL_PBUFFER_BIT), EGL_NONE } },
  { "RGB565 + ES2                        <- common preview config",
    { EGL_RED_SIZE,5, EGL_GREEN_SIZE,6, EGL_BLUE_SIZE,5,
      EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT, EGL_NONE } },
  { "RGB565 + ES2 + RECORDABLE",
    { EGL_RED_SIZE,5, EGL_GREEN_SIZE,6, EGL_BLUE_SIZE,5,
      EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT, EGL_RECORDABLE_ANDROID,1, EGL_NONE } },
  { "RGBX8888 (alpha 0) + ES2",
    { EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,0,
      EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT, EGL_NONE } },
  { "RGBA8888 + ES3",
    { EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
      EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT, EGL_NONE } },
  { "RGBA8888 + ES3 + RECORDABLE",
    { EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
      EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT, EGL_RECORDABLE_ANDROID,1, EGL_NONE } },
  { "RGBA8888 + ES2 + DEPTH16 + RECORDABLE",
    { EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
      EGL_DEPTH_SIZE,16, EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,
      EGL_RECORDABLE_ANDROID,1, EGL_NONE } },
  { "ES2 only, no colour constraints     (control: should always match)",
    { EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT, EGL_NONE } },
};

int main(void) {
    void *h = dlopen("libEGL.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    p_eglGetDisplay      = dlsym(h, "eglGetDisplay");
    p_eglInitialize      = dlsym(h, "eglInitialize");
    p_eglChooseConfig    = dlsym(h, "eglChooseConfig");
    p_eglGetConfigAttrib = dlsym(h, "eglGetConfigAttrib");

    EGLDisplay d = p_eglGetDisplay((void *)0);
    EGLint maj, min;
    if (!p_eglInitialize(d, &maj, &min)) { fprintf(stderr, "init failed\n"); return 2; }

    printf("%-6s %-8s  %s\n", "MATCH", "1st ID", "eglChooseConfig attribute list");
    printf("%-6s %-8s  %s\n", "-----", "------", "------------------------------");
    for (unsigned i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        EGLConfig cfg[64]; EGLint n = 0;
        EGLBoolean ok = p_eglChooseConfig(d, cases[i].a, cfg, 64, &n);
        if (!ok) { printf("%-6s %-8s  %s\n", "ERR", "-", cases[i].name); continue; }
        char idbuf[16] = "-";
        if (n > 0) {
            EGLint id = -1;
            p_eglGetConfigAttrib(d, cfg[0], EGL_CONFIG_ID, &id);
            snprintf(idbuf, sizeof idbuf, "%d", id);
        }
        printf("%-6d %-8s  %s%s\n", n, idbuf, cases[i].name,
               n == 0 ? "   <== ZERO MATCHES" : "");
    }
    return 0;
}

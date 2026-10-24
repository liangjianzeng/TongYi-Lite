// Discriminator for the -1001 seen only inside our CLI harness on Android 16 (830).
// Three calls, same process: (1) dlopen vendor lib, call on main thread; (2) same from a
// worker thread; (3) call the symbol provided by our stub (link-time dependency, as ggml
// sees it) on main thread. Prints rc/nplat for each so a single run pins the variable.
#include <stdio.h>
#include <dlfcn.h>
#include <pthread.h>

typedef int (*gpi_t)(unsigned int, void *, unsigned int *);

extern int clGetPlatformIDs(unsigned int, void *, unsigned int *);   // from libopencl_stub.so

static void report(const char *tag, int rc, unsigned int n) {
    printf("[ocl-linktest] %-28s rc=%d nplat=%u\n", tag, rc, n);
}

static void *worker(void *arg) {
    const char *path = (const char *) arg;
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { printf("[ocl-linktest] worker dlopen NULL: %s\n", dlerror()); return NULL; }
    gpi_t f = (gpi_t) dlsym(h, "clGetPlatformIDs");
    unsigned int n = 0;
    report("vendor lib, worker thread", f ? f(0, NULL, &n) : -9999, n);
    return NULL;
}

int main(void) {
    const char *path = "/vendor/lib64/libOpenCL.so";
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { printf("[ocl-linktest] main dlopen NULL: %s\n", dlerror()); }
    else {
        gpi_t f = (gpi_t) dlsym(h, "clGetPlatformIDs");
        unsigned int n = 0;
        report("vendor lib, main thread", f ? f(0, NULL, &n) : -9999, n);
    }

    unsigned int n2 = 0;
    report("stub symbol, main thread", clGetPlatformIDs(0, NULL, &n2), n2);

    pthread_t t;
    if (pthread_create(&t, NULL, worker, (void *) path) == 0) pthread_join(t, NULL);
    printf("[ocl-linktest] done\n");
    return 0;
}

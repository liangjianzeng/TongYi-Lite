/* [路 A 诊断] LD_PRELOAD 捕手：SIGILL/SIGSEGV/SIGABRT 时打 si_addr 与 /proc/self/maps，
 * 主线拿 pc-maps 偏移对 nm 定位崩溃函数。仅诊断用，不进任何背书腿。 */
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <ucontext.h>

static void handler(int sig, siginfo_t * si, void * ua) {
    char buf[512];
    void * pc = si->si_addr;
    if (ua) {
        ucontext_t * uc = (ucontext_t *) ua;
#if defined(__aarch64__)
        pc = (void *) uc->uc_mcontext.pc;
#elif defined(__x86_64__)
        pc = (void *) uc->uc_mcontext.gregs[REG_RIP];
#endif
    }
    int n = snprintf(buf, sizeof buf,
        "\n[PCATCH] sig=%d code=%d pc=%p addr=%p\n",
        sig, si->si_code, pc, si->si_addr);
    ssize_t r = write(2, buf, n);
    (void) r;
    int fd = open("/proc/self/maps", 0 /*O_RDONLY*/);
    if (fd >= 0) {
        char m[4096]; int rr;
        while ((rr = read(fd, m, sizeof m)) > 0) { ssize_t w = write(2, m, rr); (void) w; }
        close(fd);
    }
    _exit(128 + sig);
}

__attribute__((constructor)) static void install(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    write(2, "[PCATCH] installed\n", 19);
}

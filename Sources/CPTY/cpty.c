#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#else
#include <pty.h>
#include <stdio.h>
#endif

int cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
               unsigned short rows, unsigned short cols,
               unsigned short pixel_width, unsigned short pixel_height,
               int *master_out, pid_t *pid_out) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = pixel_width;
    ws.ws_ypixel = pixel_height;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) return -1;

    if (pid == 0) {
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);
        int maxfd = (int)sysconf(_SC_OPEN_MAX);
        if (maxfd < 0 || maxfd > 4096) maxfd = 4096;
        for (int fd = 3; fd < maxfd; fd++) close(fd);
        if (cwd) (void)chdir(cwd);
        execve(path, argv, envp);
        _exit(127);
    }

    int flags = fcntl(master, F_GETFD);
    if (flags >= 0) fcntl(master, F_SETFD, flags | FD_CLOEXEC);
    *master_out = master;
    *pid_out = pid;
    return 0;
}

int cpty_resize(int master, unsigned short rows, unsigned short cols,
                unsigned short pixel_width, unsigned short pixel_height) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = pixel_width;
    ws.ws_ypixel = pixel_height;
    return ioctl(master, TIOCSWINSZ, &ws);
}

pid_t cpty_foreground_pid(int master, pid_t fallback) {
    pid_t pg = tcgetpgrp(master);
    return pg > 0 ? pg : fallback;
}

#ifdef __APPLE__

int cpty_process_cwd(pid_t pid, char *buf, int len) {
    struct proc_vnodepathinfo info;
    int r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof info);
    if (r != (int)sizeof info) return -1;
    strlcpy(buf, info.pvi_cdir.vip_path, (size_t)len);
    return 0;
}

int cpty_process_path(pid_t pid, char *buf, int len) {
    return proc_pidpath(pid, buf, (uint32_t)len) > 0 ? 0 : -1;
}

double cpty_process_start(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) return 0;
    return (double)info.pbi_start_tvsec + (double)info.pbi_start_tvusec / 1e6;
}

int cpty_process_args(pid_t pid, char *buf, int len) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return -1;
    char *raw = malloc(size);
    if (!raw) return -1;
    if (sysctl(mib, 3, raw, &size, NULL, 0) != 0) { free(raw); return -1; }
    int argc = 0;
    memcpy(&argc, raw, sizeof argc);
    size_t i = sizeof argc;
    while (i < size && raw[i] != 0) i++;
    while (i < size && raw[i] == 0) i++;
    size_t start = i;
    int seen = 0;
    while (i < size && seen < argc) { if (raw[i] == 0) seen++; i++; }
    size_t n = i - start;
    if ((int)n > len) n = (size_t)len;
    memcpy(buf, raw + start, n);
    free(raw);
    return (int)n;
}

#else


static int read_link(const char *what, pid_t pid, char *buf, int len) {
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/%s", (int)pid, what);
    ssize_t n = readlink(path, buf, (size_t)len - 1);
    if (n < 0) return -1;
    buf[n] = 0;
    return 0;
}

int cpty_process_cwd(pid_t pid, char *buf, int len) { return read_link("cwd", pid, buf, len); }

int cpty_process_path(pid_t pid, char *buf, int len) {
    if (read_link("exe", pid, buf, len) != 0) return -1;
    size_t n = strlen(buf);
    const char *tag = " (deleted)";
    size_t t = strlen(tag);
    if (n > t && strcmp(buf + n - t, tag) == 0) buf[n - t] = 0;
    return 0;
}

double cpty_process_start(pid_t pid) {
    char path[64], line[1024];
    snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    size_t n = fread(line, 1, sizeof line - 1, f);
    fclose(f);
    line[n] = 0;
    char *p = strrchr(line, ')');
    if (!p) return 0;
    p++;
    unsigned long long start = 0;
    for (int field = 3; field <= 22 && p; field++) {
        while (*p == ' ') p++;
        if (field == 22) { start = strtoull(p, NULL, 10); break; }
        p = strchr(p, ' ');
    }
    if (!start) return 0;
    double boot = 0;
    f = fopen("/proc/stat", "r");
    if (!f) return 0;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "btime ", 6) == 0) { boot = strtod(line + 6, NULL); break; }
    }
    fclose(f);
    long hz = sysconf(_SC_CLK_TCK);
    if (boot <= 0 || hz <= 0) return 0;
    return boot + (double)start / (double)hz;
}

int cpty_process_args(pid_t pid, char *buf, int len) {
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/cmdline", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    size_t n = fread(buf, 1, (size_t)len, f);
    fclose(f);
    return n > 0 ? (int)n : -1;
}

#endif

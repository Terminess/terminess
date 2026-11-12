#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>
#include <libproc.h>
#include <sys/proc_info.h>

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

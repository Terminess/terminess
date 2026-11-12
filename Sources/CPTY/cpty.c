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

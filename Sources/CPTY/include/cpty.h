#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

int cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
               unsigned short rows, unsigned short cols,
               unsigned short pixel_width, unsigned short pixel_height,
               int *master_out, pid_t *pid_out);

int cpty_resize(int master, unsigned short rows, unsigned short cols,
                unsigned short pixel_width, unsigned short pixel_height);

pid_t cpty_foreground_pid(int master, pid_t fallback);

int cpty_process_cwd(pid_t pid, char *buf, int len);

int cpty_process_path(pid_t pid, char *buf, int len);

double cpty_process_start(pid_t pid);

int cpty_process_args(pid_t pid, char *buf, int len);

#endif

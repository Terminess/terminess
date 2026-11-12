#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

int cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
               unsigned short rows, unsigned short cols,
               unsigned short pixel_width, unsigned short pixel_height,
               int *master_out, pid_t *pid_out);

int cpty_resize(int master, unsigned short rows, unsigned short cols,
                unsigned short pixel_width, unsigned short pixel_height);

#endif

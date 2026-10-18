#include "pty_spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>

pid_t un_pty_spawn(const char *slave, const char *path, char *const argv[], char *const envp[],
                   const char *cwd) {
    pid_t pid = fork();
    if (pid != 0) return pid;

    // Child: only async-signal-safe calls from here on (the parent is multithreaded).
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    for (int sig = 1; sig < NSIG; sig++) {
        if (sig != SIGKILL && sig != SIGSTOP) signal(sig, SIG_DFL);
    }
    if (setsid() < 0) _exit(126);
    int fd = open(slave, O_RDWR);
    if (fd < 0) _exit(126);
    if (ioctl(fd, TIOCSCTTY, 0) < 0) _exit(126);
    dup2(fd, 0);
    dup2(fd, 1);
    dup2(fd, 2);
    // Close everything else the app had open (the PTY master, sockets, ...).
    int max = (int)sysconf(_SC_OPEN_MAX);
    if (max < 0 || max > 65536) max = 65536;
    for (int i = 3; i < max; i++) close(i);
    if (cwd != NULL) chdir(cwd);
    execve(path, argv, envp);
    _exit(127);
}

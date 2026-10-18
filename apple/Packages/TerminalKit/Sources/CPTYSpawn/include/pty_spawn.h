#pragma once
#include <sys/types.h>

/// Forks and execs `path` as a session leader whose controlling terminal is the PTY slave
/// `slave` (stdin/stdout/stderr), with default signal dispositions and an empty signal mask,
/// in `cwd` when non-NULL. Returns the child's pid, or -1 with errno set.
///
/// posix_spawn cannot do this on Darwin: POSIX_SPAWN_SETSID + opening the slave does not make it
/// the controlling terminal (that needs ioctl(TIOCSCTTY)), so ^C/^Z never become signals.
/// Same sequence as Ghostty's Command.zig (MIT).
pid_t un_pty_spawn(const char *slave, const char *path, char *const argv[], char *const envp[],
                   const char *cwd);

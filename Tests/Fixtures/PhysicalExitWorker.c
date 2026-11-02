// Local-only regression fixture: parent exits 0 while a detached child survives.
// The child does no work besides publishing its PID and waiting for a test signal.
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
int main(int argc, char **argv) {
    // Keep the intermediate alive until the host has durably observed its
    // grandchild, then orphan and exec that same unique identity into /bin/sh.
    if (argc == 6 && strcmp(argv[1], "observed") == 0) {
        pid_t child = fork();
        if (child < 0) return 86;
        if (child == 0) {
            if (setsid() < 0) _exit(82);
            close(0); close(1); close(2);
            pid_t nested = fork();
            if (nested < 0) _exit(86);
            if (nested > 0) {
                while (access(argv[3], F_OK) != 0) usleep(1000);
                _exit(0);
            }
            int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (fd < 0) _exit(83);
            char value[32]; int length = snprintf(value, sizeof(value), "%d", getpid());
            if (write(fd, value, length) != length || fsync(fd) != 0) _exit(84);
            close(fd);
            while (getppid() != 1) usleep(1000);
            unsetenv("SILKWIRE_PRIVATE_EXECUTION");
            execl("/bin/sh", "sh", "-c", "echo $$ > \"$1\"; while [ ! -e \"$2\" ]; do /bin/sleep 0.05; done", "sh", argv[4], argv[5], NULL);
            _exit(88);
        }
        waitpid(child, NULL, 0);
        for (int i = 0; i < 20000; ++i) {
            if (access(argv[4], F_OK) == 0) return 0;
            usleep(1000);
        }
        return 89;
    }
    // Real Apple-platform survivors for the shared-lineage cleanup regression.
    // Child execs /bin/sh; grandchild loses its parent AND tag before its exec.
    if (argc == 5 && strcmp(argv[1], "lineage") == 0) {
        int grandchild = strcmp(argv[2], "grandchild") == 0;
        pid_t child = fork();
        if (child < 0) return 86;
        if (child == 0) {
            if (setsid() < 0) _exit(82);
            close(0); close(1); close(2);
            if (grandchild) {
                pid_t nested = fork();
                if (nested < 0) _exit(86);
                if (nested > 0) _exit(0);
                while (getppid() != 1) usleep(1000);
                unsetenv("SILKWIRE_PRIVATE_EXECUTION");
            }
            const char *script = grandchild
                ? "test -z \"$SILKWIRE_PRIVATE_EXECUTION\" || exit 87; echo $$ > \"$1\"; while [ ! -e \"$2\" ]; do /bin/sleep 0.05; done"
                : "test -n \"$SILKWIRE_PRIVATE_EXECUTION\" || exit 87; echo $$ > \"$1\"; while [ ! -e \"$2\" ]; do /bin/sleep 0.05; done";
            execl("/bin/sh", "sh", "-c", script, "sh", argv[3], argv[4], NULL);
            _exit(88);
        }
        if (grandchild) waitpid(child, NULL, 0);
        for (int i = 0; i < 20000; ++i) {
            if (access(argv[3], F_OK) == 0) return 0;
            usleep(1000);
        }
        return 89;
    }
    if (argc != 2 && argc != 3) return 80;
    pid_t child = fork();
    if (child < 0) return 81;
    if (child == 0) {
        if (setsid() < 0) _exit(82);
        // Optional third argument is a parent-exit barrier. This mode leaves
        // the helper's inherited output pipes open to test pre-drain cleanup.
        if (argc == 2) { close(0); close(1); close(2); }
        int fd = open(argv[1], O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0) _exit(83);
        char value[32]; int length = snprintf(value, sizeof(value), "%d", getpid());
        if (write(fd, value, length) != length || fsync(fd) != 0) _exit(84);
        close(fd);
        for (;;) pause();
    }
    for (int i = 0; i < 10000; ++i) {
        if (access(argv[1], F_OK) == 0 && (argc == 2 || access(argv[2], F_OK) == 0)) return 0;
        usleep(1000);
    }
    kill(child, SIGKILL); waitpid(child, NULL, 0); return 85;
}

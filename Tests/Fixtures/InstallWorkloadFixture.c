// Real-process fixtures for the Staging install lineage tests
// (Tests/StagingInstallLineageTests.swift). Every mode ends on its own by a deadline.
//
//   hop <stop-file> <deadline-epoch> <pause-us> <first-pid-file>
//       A chain that keeps handing itself off: each process forks its successor and
//       exits at once, so no process of it lives longer than one fork (plus pause-us).
//       Writes the first process's PID, then stops when stop-file exists or at the deadline.
//   cycle <result-file> <deadline-epoch> <workers> <pid> [<pid> ...]
//       Recycles PIDs: forks and reaps short-lived children (in parallel workers) until a
//       new process holds each target PID. Each such process stays alive (pause) until
//       killed (its worker waits for it, so it is never an orphan). Writes "<pid> <pid> ..." of the targets it holds to result-file (only the
//       ones it got) once all are held or the deadline passes, then waits to be killed.
//   owner <orphan-file> <deadline-epoch> [<trigger-file>]
//       An app-like owner: forks an intermediate that forks the orphan and exits (once
//       trigger-file exists, if given, so the owner can predate an install and the orphan
//       not). Writes the orphan's PID, then both pause until killed (or the deadline).
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void write_text(const char *path, const char *text) {
    char temporary[4096];
    snprintf(temporary, sizeof temporary, "%s.partial", path);
    FILE *file = fopen(temporary, "w");
    if (!file) _exit(70);
    fputs(text, file);
    fclose(file);
    if (rename(temporary, path) != 0) _exit(71);
}

static void wait_until(time_t deadline) {
    while (time(NULL) < deadline) sleep(1);
    _exit(0);
}

static int hop(const char *stop, time_t deadline, useconds_t pause_us, const char *first) {
    char text[32];
    snprintf(text, sizeof text, "%d\n", getpid());
    write_text(first, text);
    for (;;) {
        if (access(stop, F_OK) == 0 || time(NULL) >= deadline) _exit(0);
        if (pause_us) usleep(pause_us);
        pid_t next = fork();
        if (next < 0) { usleep(1000); continue; }
        if (next > 0) _exit(0); // The successor continues; this process is gone.
    }
}

static int cycle(const char *result, time_t deadline, int workers, int count, pid_t *targets) {
    volatile int *held = mmap(NULL, sizeof(int) * (size_t)(count + 1), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    if (held == MAP_FAILED) return 72;
    for (int i = 0; i <= count; i++) held[i] = 0;
    for (int w = 0; w < workers; w++) {
        pid_t worker = fork();
        if (worker < 0) return 73;
        if (worker > 0) continue;
        // A worker outlives the targets it holds, so they are never orphans.
        pid_t mine[64];
        int owned = 0;
        for (;;) {
            int all = 1;
            for (int i = 0; i < count; i++) if (!held[i]) all = 0;
            if (all || time(NULL) >= deadline) {
                for (int i = 0; i < owned; i++) { while (waitpid(mine[i], NULL, 0) < 0 && errno == EINTR) {} }
                _exit(0);
            }
            pid_t child = fork();
            if (child < 0) { usleep(500); continue; }
            if (child == 0) {
                pid_t me = getpid();
                for (int i = 0; i < count; i++) {
                    if (targets[i] == me) {
                        held[i] = 1;
                        for (;;) { if (time(NULL) >= deadline + 600) _exit(0); sleep(1); }
                    }
                }
                _exit(0);
            }
            int matched = 0;
            for (int i = 0; i < count; i++) if (targets[i] == child) matched = 1;
            if (matched && owned < 64) mine[owned++] = child;
            else { while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {} }
        }
    }
    for (;;) {
        int all = 1;
        for (int i = 0; i < count; i++) if (!held[i]) all = 0;
        if (all || time(NULL) >= deadline) break;
        usleep(10000);
    }
    char text[4096] = "";
    for (int i = 0; i < count; i++) {
        if (!held[i]) continue;
        char item[32];
        snprintf(item, sizeof item, "%d ", targets[i]);
        strlcat(text, item, sizeof text);
    }
    strlcat(text, "\n", sizeof text);
    write_text(result, text);
    while (wait(NULL) > 0 || errno == EINTR) {}
    return 0;
}

static int owner(const char *orphan_file, time_t deadline, const char *trigger) {
    while (trigger && access(trigger, F_OK) != 0) {
        if (time(NULL) >= deadline) _exit(0);
        usleep(10000);
    }
    int channel[2];
    if (pipe(channel) != 0) return 74;
    pid_t intermediate = fork();
    if (intermediate < 0) return 75;
    if (intermediate == 0) {
        pid_t orphan = fork();
        if (orphan == 0) { close(channel[0]); close(channel[1]); wait_until(deadline); }
        if (orphan > 0) { (void)!write(channel[1], &orphan, sizeof orphan); }
        _exit(0); // The orphan's parent exits at once.
    }
    close(channel[1]);
    pid_t orphan = 0;
    if (read(channel[0], &orphan, sizeof orphan) != sizeof orphan) return 76;
    while (waitpid(intermediate, NULL, 0) < 0 && errno == EINTR) {}
    char text[32];
    snprintf(text, sizeof text, "%d\n", orphan);
    write_text(orphan_file, text);
    wait_until(deadline);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 6 && strcmp(argv[1], "hop") == 0) return hop(argv[2], (time_t)atoll(argv[3]), (useconds_t)atoi(argv[4]), argv[5]);
    if (argc >= 6 && strcmp(argv[1], "cycle") == 0) {
        int count = argc - 5;
        pid_t targets[64];
        if (count > 64) return 64;
        for (int i = 0; i < count; i++) targets[i] = (pid_t)atoi(argv[5 + i]);
        return cycle(argv[2], (time_t)atoll(argv[3]), atoi(argv[4]), count, targets);
    }
    if (argc >= 4 && strcmp(argv[1], "owner") == 0) return owner(argv[2], (time_t)atoll(argv[3]), argc >= 5 ? argv[4] : NULL);
    fprintf(stderr, "usage: hop|cycle|owner ...\n");
    return 64;
}

// Synthetic subprocess output; no files, simulator or third-party runtime.
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Parent exits only after the descendant has begun writing. The pipe stays busy
// until its reader closes; the alarm bounds even a broken drain implementation.
static int orphan_writer(void) {
    int ready[2];
    if (pipe(ready) != 0) return 3;
    pid_t child = fork();
    if (child < 0) return 3;
    if (child == 0) {
        close(ready[0]);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGALRM, SIG_DFL);
        alarm(3);
        char buffer[16384];
        memset(buffer, 'x', sizeof(buffer));
        if (write(STDOUT_FILENO, buffer, sizeof(buffer)) <= 0) _exit(4);
        if (write(ready[1], "r", 1) != 1) _exit(4);
        close(ready[1]);
        for (;;) {
            ssize_t written = write(STDOUT_FILENO, buffer, sizeof(buffer));
            if (written > 0 || (written < 0 && errno == EINTR)) continue;
            break;
        }
        _exit(0);
    }
    close(ready[1]);
    char started = 0;
    ssize_t count;
    do { count = read(ready[0], &started, 1); } while (count < 0 && errno == EINTR);
    close(ready[0]);
    return count == 1 && started == 'r' ? 0 : 4;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (strcmp(argv[1], "--orphan-writer") == 0) return orphan_writer();
    char *end = NULL;
    errno = 0;
    size_t remaining = strtoull(argv[1], &end, 10);
    if (errno || end == argv[1] || *end || argv[1][0] == '-') return 2;
    char buffer[16384];
    memset(buffer, 'x', sizeof(buffer));
    while (remaining) {
        size_t length = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
        ssize_t written = write(STDOUT_FILENO, buffer, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return 3;
        remaining -= (size_t)written;
    }
    return 0;
}

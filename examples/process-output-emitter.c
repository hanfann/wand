// Synthetic finite subprocess output; no files, simulator or third-party runtime.
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
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

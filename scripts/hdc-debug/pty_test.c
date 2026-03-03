/*
 * PTY capability test for HarmonyOS / ZhuoYiTong container.
 * Cross-compiled with Android NDK, runs as static PIE binary on aarch64.
 *
 * Tests:
 *   1. open("/dev/ptmx")      — get master fd
 *   2. grantpt(master)        — set slave ownership
 *   3. unlockpt(master)       — unlock slave
 *   4. ptsname(master)        — get slave path
 *   5. open(slave_path)       — open slave via /dev/pts/N
 *   6. TIOCGPTPEER ioctl      — get slave fd without /dev/pts access
 *   7. read/write through PTY — verify the fd pair actually works
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <termios.h>

/* TIOCGPTPEER may not be defined in older headers */
#ifndef TIOCGPTPEER
#define TIOCGPTPEER _IO('T', 0x41)
#endif

static void test_result(const char *name, int ok, const char *detail) {
    printf("%s: %s", name, ok ? "OK" : "FAIL");
    if (detail && detail[0])
        printf(" (%s)", detail);
    printf("\n");
    fflush(stdout);
}

int main(void) {
    char detail[256];
    int master_fd = -1;
    int slave_fd = -1;
    char *slave_name = NULL;

    printf("=== PTY capability test ===\n");
    fflush(stdout);

    /* TEST 1: open /dev/ptmx */
    master_fd = open("/dev/ptmx", O_RDWR | O_NOCTTY);
    if (master_fd < 0) {
        snprintf(detail, sizeof(detail), "errno=%d %s", errno, strerror(errno));
        test_result("TEST1_open_ptmx", 0, detail);
        printf("=== Cannot proceed without master fd ===\n");
        return 1;
    }
    snprintf(detail, sizeof(detail), "fd=%d", master_fd);
    test_result("TEST1_open_ptmx", 1, detail);

    /* TEST 2: grantpt */
    if (grantpt(master_fd) < 0) {
        snprintf(detail, sizeof(detail), "errno=%d %s", errno, strerror(errno));
        test_result("TEST2_grantpt", 0, detail);
    } else {
        test_result("TEST2_grantpt", 1, "");
    }

    /* TEST 3: unlockpt */
    if (unlockpt(master_fd) < 0) {
        snprintf(detail, sizeof(detail), "errno=%d %s", errno, strerror(errno));
        test_result("TEST3_unlockpt", 0, detail);
    } else {
        test_result("TEST3_unlockpt", 1, "");
    }

    /* TEST 4: ptsname */
    slave_name = ptsname(master_fd);
    if (!slave_name) {
        snprintf(detail, sizeof(detail), "errno=%d %s", errno, strerror(errno));
        test_result("TEST4_ptsname", 0, detail);
    } else {
        snprintf(detail, sizeof(detail), "path=%s", slave_name);
        test_result("TEST4_ptsname", 1, detail);
    }

    /* TEST 5: open slave via path */
    if (slave_name) {
        slave_fd = open(slave_name, O_RDWR | O_NOCTTY);
        if (slave_fd < 0) {
            snprintf(detail, sizeof(detail), "errno=%d %s path=%s", errno, strerror(errno), slave_name);
            test_result("TEST5_open_slave", 0, detail);
        } else {
            snprintf(detail, sizeof(detail), "fd=%d", slave_fd);
            test_result("TEST5_open_slave", 1, detail);
            close(slave_fd);
            slave_fd = -1;
        }
    } else {
        test_result("TEST5_open_slave", 0, "no slave name");
    }

    /* TEST 6: TIOCGPTPEER ioctl — THE CRITICAL TEST */
    slave_fd = ioctl(master_fd, TIOCGPTPEER, O_RDWR | O_NOCTTY);
    if (slave_fd < 0) {
        snprintf(detail, sizeof(detail), "errno=%d %s", errno, strerror(errno));
        test_result("TEST6_TIOCGPTPEER", 0, detail);
    } else {
        snprintf(detail, sizeof(detail), "slave_fd=%d", slave_fd);
        test_result("TEST6_TIOCGPTPEER", 1, detail);

        /* TEST 7: verify the PTY pair actually works (write slave, read master) */
        /* Slave → Master is the "process output" direction and won't block */
        const char *msg = "HELLO_PTY\n";
        char buf[64] = {0};
        ssize_t nw, nr;

        /* Set master to non-blocking so read won't hang */
        int flags = fcntl(master_fd, F_GETFL);
        fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);

        /* Also disable echo on slave to avoid loopback noise */
        struct termios tio;
        if (tcgetattr(slave_fd, &tio) == 0) {
            tio.c_lflag &= ~(ECHO | ECHONL);
            tcsetattr(slave_fd, TCSANOW, &tio);
        }

        /* Write to slave (simulates process output), read from master */
        nw = write(slave_fd, msg, strlen(msg));
        if (nw > 0) {
            usleep(50000); /* 50ms for data to propagate */
            nr = read(master_fd, buf, sizeof(buf) - 1);
            if (nr > 0) {
                buf[nr] = '\0';
                /* Strip \r\n added by line discipline */
                char *p = buf; while (*p == '\r' || *p == '\n') p++;
                char *end = p + strlen(p);
                while (end > p && (end[-1] == '\r' || end[-1] == '\n')) end--;
                *end = '\0';
                if (strstr(p, "HELLO_PTY")) {
                    test_result("TEST7_pty_rw", 1, "slave->master OK");
                } else {
                    snprintf(detail, sizeof(detail), "got '%s' expected contains 'HELLO_PTY'", p);
                    test_result("TEST7_pty_rw", 0, detail);
                }
            } else {
                snprintf(detail, sizeof(detail), "read failed: errno=%d %s", errno, strerror(errno));
                test_result("TEST7_pty_rw", 0, detail);
            }
        } else {
            snprintf(detail, sizeof(detail), "write failed: errno=%d %s", errno, strerror(errno));
            test_result("TEST7_pty_rw", 0, detail);
        }

        close(slave_fd);
    }

    close(master_fd);

    printf("=== PTY test complete ===\n");
    fflush(stdout);
    return 0;
}

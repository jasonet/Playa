#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static volatile sig_atomic_t pending_signal = 0;

static int executable_path(char *buffer, size_t buffer_size) {
#ifdef __APPLE__
  uint32_t size = (uint32_t)buffer_size;
  char unresolved[PATH_MAX];
  if (_NSGetExecutablePath(unresolved, &size) != 0) {
    return -1;
  }
  if (realpath(unresolved, buffer) == NULL) {
    return -1;
  }
  return 0;
#elif defined(__linux__)
  ssize_t length = readlink("/proc/self/exe", buffer, buffer_size - 1);
  if (length < 0 || (size_t)length >= buffer_size) {
    return -1;
  }
  buffer[length] = '\0';
  return 0;
#else
  (void)buffer;
  (void)buffer_size;
  return -1;
#endif
}

static int dirname_in_place(char *path) {
  char *slash = strrchr(path, '/');
  if (slash == NULL) {
    return -1;
  }
  if (slash == path) {
    slash[1] = '\0';
  } else {
    *slash = '\0';
  }
  return 0;
}

static int join_path(char *buffer, size_t buffer_size, const char *left, const char *right) {
  int written = snprintf(buffer, buffer_size, "%s/%s", left, right);
  if (written < 0 || (size_t)written >= buffer_size) {
    return -1;
  }
  return 0;
}

static void handle_signal(int signal_number) {
  pending_signal = signal_number;
}

static void install_signal_forwarding(void) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = handle_signal;
  sigemptyset(&action.sa_mask);

  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGHUP, &action, NULL);
  sigaction(SIGQUIT, &action, NULL);
}

static void sleep_milliseconds(long milliseconds) {
  struct timespec delay;
  delay.tv_sec = milliseconds / 1000;
  delay.tv_nsec = (milliseconds % 1000) * 1000000L;

  while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
  }
}

static int exit_code_from_status(int status) {
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    return 128 + WTERMSIG(status);
  }
  return 1;
}

static int wait_for_child(pid_t child_pid, int timeout_milliseconds, int *status) {
  int elapsed = 0;
  while (timeout_milliseconds < 0 || elapsed < timeout_milliseconds) {
    pid_t result = waitpid(child_pid, status, WNOHANG);
    if (result == child_pid) {
      return 1;
    }
    if (result < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }

    sleep_milliseconds(50);
    elapsed += 50;
  }
  return 0;
}

static int terminate_child(pid_t child_pid, int signal_number) {
  int status = 0;
  if (kill(child_pid, signal_number) != 0 && errno != ESRCH) {
    return 127;
  }

  int wait_result = wait_for_child(child_pid, 3000, &status);
  if (wait_result == 1) {
    return exit_code_from_status(status);
  }
  if (wait_result < 0) {
    return 127;
  }

  if (kill(child_pid, SIGKILL) != 0 && errno != ESRCH) {
    return 127;
  }
  wait_result = wait_for_child(child_pid, -1, &status);
  return wait_result == 1 ? exit_code_from_status(status) : 127;
}

int main(int argc, char **argv) {
  char exe_path[PATH_MAX];
  char root_dir[PATH_MAX];
  char python_home[PATH_MAX];
  char python_exe[PATH_MAX];

  if (executable_path(exe_path, sizeof(exe_path)) != 0) {
    fprintf(stderr, "failed to resolve executable path: %s\n", strerror(errno));
    return 127;
  }

  strncpy(root_dir, exe_path, sizeof(root_dir));
  root_dir[sizeof(root_dir) - 1] = '\0';
  if (dirname_in_place(root_dir) != 0 || dirname_in_place(root_dir) != 0) {
    fprintf(stderr, "failed to resolve distribution root from %s\n", exe_path);
    return 127;
  }

  if (join_path(python_home, sizeof(python_home), root_dir, "python") != 0 ||
      join_path(python_exe, sizeof(python_exe), python_home, "bin/python3") != 0) {
    fprintf(stderr, "distribution path is too long\n");
    return 127;
  }

  if (setenv("PYTHONHOME", python_home, 1) != 0 ||
      setenv("PYTHONNOUSERSITE", "1", 1) != 0 ||
      setenv("PYTHONDONTWRITEBYTECODE", "1", 1) != 0) {
    fprintf(stderr, "failed to set Python environment: %s\n", strerror(errno));
    return 127;
  }

  char **child_argv = calloc((size_t)argc + 3, sizeof(char *));
  if (child_argv == NULL) {
    fprintf(stderr, "failed to allocate launcher argv\n");
    return 127;
  }

  child_argv[0] = python_exe;
  child_argv[1] = "-m";
  child_argv[2] = "playa_server";
  for (int i = 1; i < argc; i++) {
    child_argv[i + 2] = argv[i];
  }
  child_argv[argc + 2] = NULL;

  pid_t parent_pid = getppid();
  install_signal_forwarding();

  pid_t child_pid = fork();
  if (child_pid < 0) {
    fprintf(stderr, "failed to fork Python child: %s\n", strerror(errno));
    free(child_argv);
    return 127;
  }

  if (child_pid == 0) {
    execv(python_exe, child_argv);
    fprintf(stderr, "failed to exec %s: %s\n", python_exe, strerror(errno));
    _exit(127);
  }

  free(child_argv);

  for (;;) {
    int status = 0;
    pid_t result = waitpid(child_pid, &status, WNOHANG);
    if (result == child_pid) {
      return exit_code_from_status(status);
    }
    if (result < 0) {
      if (errno == EINTR) {
        continue;
      }
      fprintf(stderr, "failed to wait for Python child: %s\n", strerror(errno));
      return 127;
    }

    if (pending_signal != 0) {
      int signal_number = pending_signal;
      pending_signal = 0;
      return terminate_child(child_pid, signal_number);
    }

    if (getppid() != parent_pid) {
      return terminate_child(child_pid, SIGTERM);
    }

    sleep_milliseconds(100);
  }
}

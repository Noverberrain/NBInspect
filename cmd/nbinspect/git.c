/* Native Git transport. Fixed argv, bounded output, 30s timeout, no shell.
 * Status byte: 0 success, 1 Git failure, 2 output limit, 3 timeout, 4 transport.
 * Reference: https://git-scm.com/docs/git and git-diff (raw -z format).
 */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"
#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>
#include <errno.h>
#endif

typedef struct { unsigned char *data; size_t size, capacity, limit; } nb_output;
static int nb_append(nb_output *out, const unsigned char *data, size_t n) {
  if (n > out->limit - out->size) return 2;
  if (out->size + n > out->capacity) {
    size_t capacity = out->capacity ? out->capacity : 16384;
    while (capacity < out->size + n) capacity *= 2;
    if (capacity > out->limit) capacity = out->limit;
    unsigned char *p = realloc(out->data, capacity);
    if (!p) return 4;
    out->data = p; out->capacity = capacity;
  }
  if (n) memcpy(out->data + out->size, data, n);
  out->size += n;
  return 0;
}
static char *nb_argument(moonbit_bytes_t bytes) {
  int32_t n = Moonbit_array_length(bytes);
  if (n < 0 || n > 16384 || memchr(bytes, 0, (size_t)n)) return NULL;
  char *s = malloc((size_t)n + 1);
  if (!s) return NULL;
  memcpy(s, bytes, (size_t)n); s[n] = 0;
  return s;
}

#ifdef _WIN32
/* Quote argv using the Windows C-runtime backslash/quote rules. */
static int nb_quote(wchar_t *line, size_t *used, const wchar_t *arg) {
  size_t need = wcslen(arg) * 2 + 4;
  if (*used + need >= 32767) return 0;
  line[(*used)++] = L'"';
  size_t slashes = 0;
  for (const wchar_t *p = arg; ; p++) {
    if (*p == L'\\') { slashes++; continue; }
    size_t copies = (*p == L'"' || *p == 0) ? slashes * 2 : slashes;
    while (copies--) line[(*used)++] = L'\\';
    slashes = 0;
    if (*p == 0) break;
    if (*p == L'"') line[(*used)++] = L'\\';
    line[(*used)++] = *p;
  }
  line[(*used)++] = L'"'; line[(*used)++] = L' '; line[*used] = 0;
  return 1;
}
static int nb_capture(const char *const *argv, nb_output *out) {
  int status = 4;
  HANDLE reader = NULL, writer = NULL, null_file = INVALID_HANDLE_VALUE, job = NULL;
  PROCESS_INFORMATION process; memset(&process, 0, sizeof(process));
  wchar_t *path = NULL, *exe = NULL, *line = NULL;
  DWORD path_size = GetEnvironmentVariableW(L"PATH", NULL, 0);
  if (!path_size) goto done;
  path = malloc((size_t)path_size * sizeof(wchar_t));
  exe = malloc(32768 * sizeof(wchar_t));
  line = calloc(32768, sizeof(wchar_t));
  if (!path || !exe || !line || !GetEnvironmentVariableW(L"PATH", path, path_size)) goto done;
  DWORD exe_size = SearchPathW(path, L"git.exe", NULL, 32768, exe, NULL);
  if (!exe_size || exe_size >= 32768) goto done;
  size_t used = 0;
  if (!nb_quote(line, &used, exe)) goto done;
  for (int i = 1; argv[i]; i++) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[i], -1, NULL, 0);
    if (!n) goto done;
    wchar_t *arg = malloc((size_t)n * sizeof(wchar_t));
    if (!arg) goto done;
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, argv[i], -1, arg, n)) {
      free(arg); goto done;
    }
    int ok = nb_quote(line, &used, arg); free(arg);
    if (!ok) goto done;
  }
  SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
  if (!CreatePipe(&reader, &writer, &security, 0) ||
      !SetHandleInformation(reader, HANDLE_FLAG_INHERIT, 0)) goto done;
  null_file = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, NULL);
  if (null_file == INVALID_HANDLE_VALUE) goto done;
  job = CreateJobObjectW(NULL, NULL);
  if (!job) goto done;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits; memset(&limits, 0, sizeof(limits));
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) goto done;
  STARTUPINFOW startup; memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdOutput = writer; startup.hStdError = null_file; startup.hStdInput = null_file;
  if (!CreateProcessW(exe, line, NULL, NULL, TRUE,
      CREATE_NO_WINDOW | CREATE_SUSPENDED, NULL, NULL, &startup, &process)) goto done;
  if (!AssignProcessToJobObject(job, process.hProcess)) { TerminateProcess(process.hProcess, 1); goto done; }
  if (ResumeThread(process.hThread) == (DWORD)-1) goto done;
  CloseHandle(writer); writer = NULL;
  ULONGLONG started = GetTickCount64();
  for (;;) {
    if (GetTickCount64() - started >= 30000) { status = 3; break; }
    DWORD available = 0;
    if (!PeekNamedPipe(reader, NULL, 0, NULL, &available, NULL)) {
      if (GetLastError() != ERROR_BROKEN_PIPE) break;
      available = 0;
    }
    if (available) {
      unsigned char chunk[16384]; DWORD n = 0;
      if (!ReadFile(reader, chunk, available < sizeof(chunk) ? available : sizeof(chunk), &n, NULL)) break;
      int result = nb_append(out, chunk, n);
      if (result) { status = result; break; }
    } else if (WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0) {
      DWORD code;
      if (GetExitCodeProcess(process.hProcess, &code)) status = code == 0 ? 0 : 1;
      break;
    } else { Sleep(2); }
  }
done:
  if (job) { CloseHandle(job); job = NULL; }
  if (process.hProcess) { WaitForSingleObject(process.hProcess, 5000); CloseHandle(process.hProcess); }
  if (process.hThread) CloseHandle(process.hThread);
  if (reader) CloseHandle(reader);
  if (writer) CloseHandle(writer);
  if (null_file != INVALID_HANDLE_VALUE) CloseHandle(null_file);
  free(path); free(exe); free(line);
  return status;
}
#else
static int64_t nb_millis(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) return -1;
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static int nb_capture(const char *const *argv, nb_output *out) {
  int descriptors[2];
  if (pipe(descriptors)) return 4;
  int null_file = open("/dev/null", O_RDWR);
  if (null_file < 0) { close(descriptors[0]); close(descriptors[1]); return 4; }
  pid_t child = fork();
  if (child < 0) { close(null_file); close(descriptors[0]); close(descriptors[1]); return 4; }
  if (!child) {
    if (setsid() < 0 || dup2(descriptors[1], STDOUT_FILENO) < 0 ||
        dup2(null_file, STDIN_FILENO) < 0 || dup2(null_file, STDERR_FILENO) < 0) _exit(127);
    close(null_file); close(descriptors[0]); close(descriptors[1]);
    execvp(argv[0], (char *const *)argv); _exit(127);
  }
  close(null_file); close(descriptors[1]);
  int status = 4, exited = 0, code = 0, eof = 0;
  int64_t started = nb_millis();
  if (started < 0 || fcntl(descriptors[0], F_SETFL, O_NONBLOCK) < 0) goto done;
  for (;;) {
    int64_t now = nb_millis();
    if (now < 0) break;
    if (now - started >= 30000) { status = 3; break; }
    struct pollfd pipe_state = {descriptors[0], POLLIN | POLLHUP, 0};
    int ready = poll(&pipe_state, 1, 10);
    if (ready < 0 && errno != EINTR) break;
    if (ready > 0 && !eof) {
      unsigned char chunk[16384];
      ssize_t n = read(descriptors[0], chunk, sizeof(chunk));
      if (n > 0) { int result = nb_append(out, chunk, (size_t)n); if (result) { status = result; break; } }
      else if (n == 0) eof = 1;
      else if (errno != EAGAIN && errno != EINTR) break;
    }
    if (!exited) {
      pid_t waited = waitpid(child, &code, WNOHANG);
      if (waited == child) exited = 1;
      else if (waited < 0 && errno != EINTR) break;
    }
    if (exited && eof) { status = WIFEXITED(code) && WEXITSTATUS(code) == 0 ? 0 : 1; break; }
  }
done:
  kill(-child, SIGKILL);
  if (!exited) { kill(child, SIGKILL); while (waitpid(child, &code, 0) < 0 && errno == EINTR) {} }
  close(descriptors[0]);
  return status;
}
#endif

MOONBIT_FFI_EXPORT moonbit_bytes_t nb_git(int32_t operation, moonbit_bytes_t a,
    moonbit_bytes_t b, int32_t limit) {
  char *first = nb_argument(a), *second = nb_argument(b);
  nb_output out = {NULL, 0, 0, limit > 0 ? (size_t)limit : 0};
  int status = 4;
  const char *argv[24] = {"git", "--no-pager", "--no-replace-objects", "--no-lazy-fetch", "--no-optional-locks"};
  int n = 5;
  if (!first || !second || limit <= 0 || limit > 52428800) goto done;
  if (operation == 0) {
    argv[n++] = "rev-parse"; argv[n++] = "--verify"; argv[n++] = "--end-of-options"; argv[n++] = first;
  } else if (operation == 1) {
    argv[n++] = "diff"; argv[n++] = "--raw"; argv[n++] = "-z"; argv[n++] = "--no-abbrev";
    argv[n++] = "--no-ext-diff"; argv[n++] = "--no-textconv"; argv[n++] = "--no-color";
    argv[n++] = "--no-relative"; argv[n++] = "--ignore-submodules=none";
    argv[n++] = "--find-renames=50%"; argv[n++] = "-l1000";
    argv[n++] = first; argv[n++] = second; argv[n++] = "--";
  } else if (operation == 2) {
    argv[n++] = "cat-file"; argv[n++] = "blob"; argv[n++] = first;
  } else goto done;
  argv[n] = NULL;
  status = nb_capture(argv, &out);
done:
  free(first); free(second);
  size_t size = status == 0 ? out.size : 0;
  moonbit_bytes_t result = moonbit_make_bytes((int32_t)size + 1, 0);
  result[0] = (unsigned char)status;
  if (size) memcpy(result + 1, out.data, size);
  free(out.data);
  return result;
}

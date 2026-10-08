#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"
#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <errno.h>
#endif

/* O followed by NUL-delimited kind/name records. Empty bytes mean failure.
   Names cannot contain NUL; newlines, tabs and Unicode names remain intact. */
typedef struct { char *data; size_t used; int entries; } nb_listing;
static int nb_append(nb_listing *out, char kind, const char *name, size_t length) {
  if (++out->entries > 10000 || out->used > 16777214 || length > 16777216 - out->used - 2) return 0;
  char *grown = realloc(out->data, out->used + length + 2);
  if (!grown) return 0;
  out->data = grown;
  out->data[out->used++] = kind;
  memcpy(out->data + out->used, name, length);
  out->used += length;
  out->data[out->used++] = 0;
  return 1;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t nb_list(moonbit_string_t path, moonbit_bytes_t utf8) {
  nb_listing out = {malloc(1), 1, 0};
  int ok = out.data != NULL;
  if (!ok) return moonbit_make_bytes(0, 0);
  out.data[0] = 'O';
#ifdef _WIN32
  (void)utf8;
  size_t length = (size_t)Moonbit_array_length(path);
  wchar_t *pattern = malloc((length + 3) * sizeof(wchar_t));
  if (!pattern) { free(out.data); return moonbit_make_bytes(0, 0); }
  for (size_t i = 0; i < length; i++) pattern[i] = (wchar_t)path[i];
  pattern[length] = 0;
  DWORD attributes = GetFileAttributesW(pattern);
  if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)
      || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    free(pattern); free(out.data); return moonbit_make_bytes(0, 0);
  }
  if (length && pattern[length - 1] != L'/' && pattern[length - 1] != L'\\')
    pattern[length++] = L'\\';
  pattern[length++] = L'*';
  pattern[length] = 0;
  WIN32_FIND_DATAW entry;
  HANDLE directory = FindFirstFileW(pattern, &entry);
  free(pattern);
  if (directory == INVALID_HANDLE_VALUE) {
    ok = GetLastError() == ERROR_FILE_NOT_FOUND;
  } else {
    do {
      if (wcscmp(entry.cFileName, L".") == 0 || wcscmp(entry.cFileName, L"..") == 0) continue;
      int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, entry.cFileName, -1, NULL, 0, NULL, NULL);
      char *name = bytes > 0 ? malloc((size_t)bytes) : NULL;
      if (!name) { ok = 0; break; }
      if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, entry.cFileName, -1, name, bytes, NULL, NULL)) {
        free(name); ok = 0; break;
      }
      char kind = (entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? 'L'
        : (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 'D' : 'F';
      ok = nb_append(&out, kind, name, (size_t)bytes - 1);
      free(name);
      if (!ok) break;
    } while (FindNextFileW(directory, &entry));
    if (ok && GetLastError() != ERROR_NO_MORE_FILES) ok = 0;
    FindClose(directory);
  }
#else
  (void)path;
  size_t length = (size_t)Moonbit_array_length(utf8);
  char *base = malloc(length + 1);
  if (!base) { free(out.data); return moonbit_make_bytes(0, 0); }
  memcpy(base, utf8, length); base[length] = 0;
  struct stat root;
  DIR *directory = NULL;
  if (lstat(base, &root) == 0 && S_ISDIR(root.st_mode)) directory = opendir(base);
  if (!directory) ok = 0;
  else {
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(directory)) != NULL) {
      if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
      size_t name_length = strlen(entry->d_name);
      char *full = malloc(length + name_length + 2);
      if (!full) { ok = 0; break; }
      memcpy(full, base, length); full[length] = '/';
      memcpy(full + length + 1, entry->d_name, name_length + 1);
      struct stat info;
      if (lstat(full, &info) != 0) { free(full); ok = 0; break; }
      free(full);
      char kind = S_ISLNK(info.st_mode) ? 'L' : S_ISDIR(info.st_mode) ? 'D'
        : S_ISREG(info.st_mode) ? 'F' : 'L';
      if (!nb_append(&out, kind, entry->d_name, name_length)) { ok = 0; break; }
      errno = 0;
    }
    if (errno != 0) ok = 0;
    closedir(directory);
  }
  free(base);
#endif
  moonbit_bytes_t result = moonbit_make_bytes(ok ? (int32_t)out.used : 0, 0);
  if (ok) memcpy(result, out.data, out.used);
  free(out.data);
  return result;
}

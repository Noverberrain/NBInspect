#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#ifdef _WIN32
#include <wchar.h>
#endif
#include "moonbit.h"
static FILE *nb_open(moonbit_string_t path, moonbit_bytes_t utf8, int write) {
#ifdef _WIN32
  int32_t n = Moonbit_array_length(path);
  wchar_t *copy = malloc(((size_t)n+1)*sizeof(wchar_t));
  if (!copy) return NULL;
  for (int32_t i=0;i<n;i++) copy[i]=(wchar_t)path[i];
  copy[n]=0;
  FILE *f = _wfopen(copy, write ? L"wbx" : L"rb");
  free(copy);
  return f;
#else
  int32_t n = Moonbit_array_length(utf8);
  char *copy = malloc((size_t)n+1);
  if (!copy) return NULL;
  for (int32_t i=0;i<n;i++) copy[i]=(char)utf8[i];
  copy[n]=0;
  FILE *f=fopen(copy,write ? "wbx" : "rb");
  free(copy);
  return f;
#endif
}
MOONBIT_FFI_EXPORT moonbit_bytes_t nb_read(moonbit_string_t path, moonbit_bytes_t utf8, int32_t limit) {
  FILE *f=nb_open(path,utf8,0);
  if (!f) return moonbit_make_bytes(0,0);
  if (fseek(f,0,SEEK_END)) {fclose(f);return moonbit_make_bytes(0,0);}
  long size=ftell(f);
  if (size<=0 || size>limit || size>INT32_MAX) {fclose(f);return moonbit_make_bytes(0,0);}
  rewind(f);
  moonbit_bytes_t bytes=moonbit_make_bytes((int32_t)size,0);
  size_t n=fread(bytes,1,(size_t)size,f);
  fclose(f);
  if(n!=(size_t)size) return moonbit_make_bytes(0,0);
  return bytes;
}
MOONBIT_FFI_EXPORT int32_t nb_write(moonbit_string_t path, moonbit_bytes_t utf8, moonbit_bytes_t bytes) {
  FILE *f=nb_open(path,utf8,1);
  if (!f) return 1;
  size_t n=Moonbit_array_length(bytes);
  int failed=fwrite(bytes,1,n,f)!=n;
  if(fclose(f)) failed=1;
  return failed;
}
MOONBIT_FFI_EXPORT void nb_stderr(moonbit_bytes_t bytes) {
  fwrite(bytes,1,(size_t)Moonbit_array_length(bytes),stderr);
}
MOONBIT_FFI_EXPORT void nb_exit(int32_t code) { exit(code); }

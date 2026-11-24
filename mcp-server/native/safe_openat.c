#define NAPI_VERSION 8
#include <errno.h>
#include <fcntl.h>
#include <node_api.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

#ifndef RENAME_SWAP
#define RENAME_SWAP 0x00000002
#endif
#ifndef RENAME_EXCL
#define RENAME_EXCL 0x00000004
#endif

extern int32_t meeting_swift_decode_uint64(const char *token, ptrdiff_t len, uint64_t *out_val);

static const char *errno_to_code(int err) {
  switch (err) {
    case ENOENT: return "ENOENT";
    case ELOOP: return "ELOOP";
    case ENOTDIR: return "ENOTDIR";
    case EISDIR: return "EISDIR";
    case ENXIO: return "ENXIO";
    case EACCES: return "EACCES";
    case EPERM: return "EPERM";
    case EEXIST: return "EEXIST";
    case EINVAL: return "EINVAL";
    case EMFILE: return "EMFILE";
    case ENFILE: return "ENFILE";
    case ENAMETOOLONG: return "ENAMETOOLONG";
    case EROFS: return "EROFS";
    case EBADF: return "EBADF";
    case EWOULDBLOCK: return "EWOULDBLOCK";
    default: return "EIO";
  }
}

static napi_value throw_posix_error(napi_env env, const char *code_str, int err_num, const char *msg) {
  napi_value msg_val = NULL;
  napi_value code_val = NULL;
  napi_value err_obj = NULL;
  napi_value errno_val = NULL;

  napi_create_string_utf8(env, msg, NAPI_AUTO_LENGTH, &msg_val);
  napi_create_string_utf8(env, code_str, NAPI_AUTO_LENGTH, &code_val);
  napi_create_error(env, code_val, msg_val, &err_obj);
  napi_create_int32(env, err_num == 0 ? -EINVAL : -err_num, &errno_val);
  napi_set_named_property(env, err_obj, "errno", errno_val);
  napi_throw(env, err_obj);
  return NULL;
}

static bool copy_nonempty_path(napi_env env, napi_value val, char *buf, size_t cap, size_t *out_len) {
  napi_valuetype t = napi_undefined;
  if (napi_typeof(env, val, &t) != napi_ok || t != napi_string) {
    throw_posix_error(env, "EINVAL", EINVAL, "Path must be a string");
    return false;
  }
  size_t byte_len = 0;
  if (napi_get_value_string_utf8(env, val, NULL, 0, &byte_len) != napi_ok) {
    throw_posix_error(env, "EINVAL", EINVAL, "Failed to measure string path");
    return false;
  }
  if (byte_len == 0 || byte_len >= cap) {
    throw_posix_error(env, "EINVAL", EINVAL, "Invalid path length");
    return false;
  }
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, val, buf, cap, &copied) != napi_ok || copied != byte_len) {
    throw_posix_error(env, "EINVAL", EINVAL, "Failed to copy UTF-8 path");
    return false;
  }
  if (memchr(buf, '\0', byte_len) != NULL) {
    throw_posix_error(env, "EINVAL", EINVAL, "Path must not contain NUL byte");
    return false;
  }
  *out_len = byte_len;
  return true;
}

static napi_value safe_openat(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value argv[4];
  napi_status st = napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (st != napi_ok || argc < 3) {
    return throw_posix_error(env, "EINVAL", EINVAL, "openat(dirfd, name, flags[, mode]) requires at least 3 arguments");
  }

  int32_t dirfd = -1;
  if (napi_get_value_int32(env, argv[0], &dirfd) != napi_ok || dirfd < 0) {
    return throw_posix_error(env, "EBADF", EBADF, "Invalid dirfd");
  }

  char name_buf[1024];
  size_t byte_len = 0;
  if (!copy_nonempty_path(env, argv[1], name_buf, sizeof(name_buf), &byte_len)) {
    return NULL;
  }
  if (memchr(name_buf, '/', byte_len) != NULL) {
    return throw_posix_error(env, "EINVAL", EINVAL, "Component name must not contain '/'");
  }
  if ((byte_len == 1 && name_buf[0] == '.') || (byte_len == 2 && name_buf[0] == '.' && name_buf[1] == '.')) {
    return throw_posix_error(env, "EINVAL", EINVAL, "Component name must not be '.' or '..'");
  }

  int32_t flags = 0;
  if (napi_get_value_int32(env, argv[2], &flags) != napi_ok) {
    return throw_posix_error(env, "EINVAL", EINVAL, "Invalid flags");
  }

  int32_t mode = 0;
  if (argc >= 4) {
    napi_valuetype mode_type = napi_undefined;
    if (napi_typeof(env, argv[3], &mode_type) == napi_ok && mode_type != napi_undefined) {
      if (napi_get_value_int32(env, argv[3], &mode) != napi_ok) {
        return throw_posix_error(env, "EINVAL", EINVAL, "Invalid mode");
      }
    }
  }

  int open_flags = flags | O_CLOEXEC;
  int fd = openat(dirfd, name_buf, open_flags, (mode_t)mode);
  if (fd < 0) {
    int err = errno;
    const char *code_str = errno_to_code(err);
    char msg_buf[1280];
    snprintf(msg_buf, sizeof(msg_buf), "%s: openat '%s': %s", code_str, name_buf, strerror(err));
    return throw_posix_error(env, code_str, err, msg_buf);
  }

  napi_value out_fd = NULL;
  napi_create_int32(env, fd, &out_fd);
  return out_fd;
}

static napi_value native_flock(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) {
    return throw_posix_error(env, "EINVAL", EINVAL, "flock(fd, operation) requires 2 arguments");
  }

  int32_t fd = -1;
  if (napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
    return throw_posix_error(env, "EBADF", EBADF, "Invalid fd");
  }

  int32_t op = 0;
  if (napi_get_value_int32(env, argv[1], &op) != napi_ok) {
    return throw_posix_error(env, "EINVAL", EINVAL, "Invalid flock operation");
  }

  int rc = 0;
  do {
    rc = flock(fd, op);
  } while (rc < 0 && errno == EINTR);

  if (rc < 0) {
    int err = errno;
    const char *code_str = errno_to_code(err);
    char msg_buf[256];
    snprintf(msg_buf, sizeof(msg_buf), "%s: flock: %s", code_str, strerror(err));
    return throw_posix_error(env, code_str, err, msg_buf);
  }

  napi_value undef = NULL;
  napi_get_undefined(env, &undef);
  return undef;
}

static napi_value native_renamex_with_flags(
    napi_env env,
    napi_callback_info info,
    unsigned int flags,
    const char *fn_name
) {
  size_t argc = 2;
  napi_value argv[2];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) {
    char msg_buf[128];
    snprintf(msg_buf, sizeof(msg_buf), "%s(fromPath, toPath) requires 2 arguments", fn_name);
    return throw_posix_error(env, "EINVAL", EINVAL, msg_buf);
  }

  char from_buf[4096];
  char to_buf[4096];
  size_t from_len = 0;
  size_t to_len = 0;
  if (!copy_nonempty_path(env, argv[0], from_buf, sizeof(from_buf), &from_len)) {
    return NULL;
  }
  if (!copy_nonempty_path(env, argv[1], to_buf, sizeof(to_buf), &to_len)) {
    return NULL;
  }

  int rc = renamex_np(from_buf, to_buf, flags);
  if (rc != 0) {
    int err = errno;
    const char *code_str = errno_to_code(err);
    char msg_buf[512];
    snprintf(msg_buf, sizeof(msg_buf), "%s: %s: %s", code_str, fn_name, strerror(err));
    return throw_posix_error(env, code_str, err, msg_buf);
  }

  napi_value undef = NULL;
  napi_get_undefined(env, &undef);
  return undef;
}

static napi_value native_renamex_excl(napi_env env, napi_callback_info info) {
  return native_renamex_with_flags(env, info, RENAME_EXCL, "renamex_excl");
}

static napi_value native_renamex_swap(napi_env env, napi_callback_info info) {
  return native_renamex_with_flags(env, info, RENAME_SWAP, "renamex_swap");
}

static napi_value native_decode_swift_uint64(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1) {
    return throw_posix_error(env, "EINVAL", EINVAL, "decode_swift_uint64(token) requires 1 argument");
  }

  napi_value null_val = NULL;
  napi_get_null(env, &null_val);

  napi_valuetype t = napi_undefined;
  if (napi_typeof(env, argv[0], &t) != napi_ok || t != napi_string) {
    return null_val;
  }

  size_t byte_len = 0;
  if (napi_get_value_string_utf8(env, argv[0], NULL, 0, &byte_len) != napi_ok) {
    return null_val;
  }
  if (byte_len == 0 || byte_len > 16777216) {
    return null_val;
  }

  char stack_buf[4096];
  char *buf = stack_buf;
  bool allocated = false;
  if (byte_len >= sizeof(stack_buf)) {
    buf = (char *)malloc(byte_len + 1);
    if (buf == NULL) {
      return null_val;
    }
    allocated = true;
  }

  size_t copied = 0;
  if (napi_get_value_string_utf8(env, argv[0], buf, byte_len + 1, &copied) != napi_ok ||
      copied != byte_len ||
      memchr(buf, '\0', byte_len) != NULL) {
    if (allocated) free(buf);
    return null_val;
  }

  uint64_t decoded_val = 0;
  int32_t ok = meeting_swift_decode_uint64(buf, (ptrdiff_t)byte_len, &decoded_val);
  if (allocated) free(buf);
  if (ok != 1) {
    return null_val;
  }

  char out_str[32];
  snprintf(out_str, sizeof(out_str), "%llu", (unsigned long long)decoded_val);
  napi_value res = NULL;
  napi_create_string_utf8(env, out_str, NAPI_AUTO_LENGTH, &res);
  return res;
}

static void set_int_const(napi_env env, napi_value obj, const char *name, int32_t value) {
  napi_value v = NULL;
  napi_create_int32(env, value, &v);
  napi_set_named_property(env, obj, name, v);
}

static napi_value init_module(napi_env env, napi_value exports) {
  napi_value openat_fn = NULL;
  napi_create_function(env, "openat", NAPI_AUTO_LENGTH, safe_openat, NULL, &openat_fn);
  napi_set_named_property(env, exports, "openat", openat_fn);

  napi_value flock_fn = NULL;
  napi_create_function(env, "flock", NAPI_AUTO_LENGTH, native_flock, NULL, &flock_fn);
  napi_set_named_property(env, exports, "flock", flock_fn);

  napi_value renamex_fn = NULL;
  napi_create_function(env, "renamex_excl", NAPI_AUTO_LENGTH, native_renamex_excl, NULL, &renamex_fn);
  napi_set_named_property(env, exports, "renamex_excl", renamex_fn);

  napi_value renamex_swap_fn = NULL;
  napi_create_function(env, "renamex_swap", NAPI_AUTO_LENGTH, native_renamex_swap, NULL, &renamex_swap_fn);
  napi_set_named_property(env, exports, "renamex_swap", renamex_swap_fn);

  napi_value swift_u64_fn = NULL;
  napi_create_function(
      env, "decode_swift_uint64", NAPI_AUTO_LENGTH, native_decode_swift_uint64, NULL, &swift_u64_fn);
  napi_set_named_property(env, exports, "decode_swift_uint64", swift_u64_fn);

  set_int_const(env, exports, "O_RDONLY", O_RDONLY);
  set_int_const(env, exports, "O_NOFOLLOW", O_NOFOLLOW);
  set_int_const(env, exports, "O_DIRECTORY", O_DIRECTORY);
  set_int_const(env, exports, "O_NONBLOCK", O_NONBLOCK);
  set_int_const(env, exports, "O_CLOEXEC", O_CLOEXEC);
  set_int_const(env, exports, "LOCK_EX", LOCK_EX);
  set_int_const(env, exports, "LOCK_SH", LOCK_SH);
  set_int_const(env, exports, "LOCK_NB", LOCK_NB);
  set_int_const(env, exports, "LOCK_UN", LOCK_UN);
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init_module)

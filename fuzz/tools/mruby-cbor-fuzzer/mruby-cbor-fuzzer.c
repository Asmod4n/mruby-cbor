#include <mruby.h>
#include <mruby/error.h>
#include <stdlib.h>
#include <string.h>
#include <malloc.h>

static mrb_state *mrb     = NULL;
static size_t     counter = 0;

/* Paths that parse cleanly — used to fuzz path_walk_steps and
 * path_walk_wildcards against arbitrary CBOR bytes. The path parser
 * itself gets a separate fuzz channel (block 7) via the raw input. */
static const char *const VALID_PATHS[] = {
  "$",
  "$.a",
  "$.a.b.c",
  "$[0]",
  "$[-1]",
  "$[*]",
  "$.a[*]",
  "$.items[*].id",
  "$[*][*]",
  "$.a[0][*].b",
  "$[\"weird key\"]",
  "$.a[*].b[*].c",
};
#define VALID_PATHS_N (sizeof(VALID_PATHS) / sizeof(VALID_PATHS[0]))

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {

  if (!mrb) mrb = mrb_open();
  if (!mrb) abort();

  mrb_value input  = mrb_str_new(mrb, (const char *)data, (mrb_int)size);
  mrb_value cbor_m = mrb_obj_value(mrb_module_get_id(mrb, MRB_SYM(CBOR)));

  /* 1. Eager decode → re-encode → decode */
  mrb_value decoded = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode), 1, &input);
  if (!mrb_check_error(mrb)) {
    mrb_value reencoded = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(encode), 1, &decoded);
    if (!mrb_check_error(mrb)) {
      mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode), 1, &reencoded);
      mrb_clear_error(mrb);
    }
    mrb_clear_error(mrb);
  }
  mrb_clear_error(mrb);

  /* 2. Lazy decode → .value → re-encode → decode */
  mrb_value lazy = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode_lazy), 1, &input);
  if (!mrb_check_error(mrb)) {
    mrb_value lazy_val = mrb_funcall_argv(mrb, lazy, MRB_SYM(value), 0, NULL);
    if (!mrb_check_error(mrb)) {
      mrb_value reencoded = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(encode), 1, &lazy_val);
      if (!mrb_check_error(mrb)) {
        mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode), 1, &reencoded);
        mrb_clear_error(mrb);
      }
      mrb_clear_error(mrb);
    }
    mrb_clear_error(mrb);
  }
  mrb_clear_error(mrb);

  /* 3. Fast decode → re-encode-fast → fast decode */
  mrb_value fast_decoded = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode_fast), 1, &input);
  if (!mrb_check_error(mrb)) {
    mrb_value fast_reencoded = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(encode_fast), 1, &fast_decoded);
    if (!mrb_check_error(mrb)) {
      mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode_fast), 1, &fast_reencoded);
      mrb_clear_error(mrb);
    }
    mrb_clear_error(mrb);
  }
  mrb_clear_error(mrb);

  /* 4. Streaming framing — CBOR.doc_end, with and without offset */
  mrb_funcall_argv(mrb, cbor_m, MRB_SYM(doc_end), 1, &input);
  mrb_clear_error(mrb);
  {
    mrb_value off_args[2] = { input, mrb_fixnum_value(1) };
    mrb_funcall_argv(mrb, cbor_m, MRB_SYM(doc_end), 2, off_args);
    mrb_clear_error(mrb);
  }

  /* 5. Diagnostic notation — Ruby-impl byte walker covering every
   *    float bit-pattern, UTF-8 escape, tag chain, and indefinite-length
   *    container marker. Lots of bit arithmetic that's easy to get wrong. */
  mrb_funcall_argv(mrb, cbor_m, MRB_SYM(diagnose), 1, &input);
  mrb_clear_error(mrb);

  /* 6. Lazy navigation — aref with string key, positive and negative
   *    integer indices, plus dig with a 3-key chain. Exercises the
   *    lazy_aref_array / lazy_aref_map paths and their Tag 28/29
   *    resolution logic. */
  mrb_value nav_lazy = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode_lazy), 1, &input);
  if (!mrb_check_error(mrb)) {
    /* Prefix of the input as a string key — usually a KeyError, but on
     * well-shaped inputs occasionally hits something real. */
    mrb_int klen = size > 4 ? 4 : (mrb_int)size;
    mrb_value str_key = mrb_str_new(mrb, (const char *)data, klen);
    mrb_funcall_argv(mrb, nav_lazy, MRB_OPSYM(aref), 1, &str_key);
    mrb_clear_error(mrb);

    mrb_value int_key = mrb_fixnum_value(0);
    mrb_funcall_argv(mrb, nav_lazy, MRB_OPSYM(aref), 1, &int_key);
    mrb_clear_error(mrb);

    mrb_value neg_key = mrb_fixnum_value(-1);
    mrb_funcall_argv(mrb, nav_lazy, MRB_OPSYM(aref), 1, &neg_key);
    mrb_clear_error(mrb);

    mrb_value dig_args[3] = { str_key, int_key, str_key };
    mrb_funcall_argv(mrb, nav_lazy, MRB_SYM(dig), 3, dig_args);
    mrb_clear_error(mrb);
  }
  mrb_clear_error(mrb);

  /* 7. CBOR::Path parser — feed the raw fuzz bytes as a path string.
   *    Hits the hand-written state machine (identifier / bracket /
   *    number / quoted-string / wildcard) with every possible garbage,
   *    including NUL bytes, embedded quotes, and unterminated brackets. */
  struct RClass *path_cls = mrb_class_get_under_id(mrb,
    mrb_module_get_id(mrb, MRB_SYM(CBOR)), MRB_SYM(Path));
  mrb_value path_cls_val  = mrb_obj_value(path_cls);

  mrb_value compiled = mrb_funcall_argv(mrb, path_cls_val,
    MRB_SYM(compile), 1, &input);
  if (!mrb_check_error(mrb)) {
    /* If the input somehow parsed, also run it against a lazy of itself
     * to give the executor something to chew on. */
    mrb_value lz = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode_lazy), 1, &input);
    if (!mrb_check_error(mrb)) {
      mrb_funcall_argv(mrb, compiled, MRB_SYM(at), 1, &lz);
      mrb_clear_error(mrb);
    }
    mrb_clear_error(mrb);
  }
  mrb_clear_error(mrb);

  /* 8. CBOR::Path executor — valid compiled paths against arbitrary
   *    CBOR. Exercises path_walk_steps / path_walk_wildcards /
   *    lazy_resolve_tags against every shape the decoder can build. */
  for (size_t i = 0; i < VALID_PATHS_N; i++) {
    mrb_value pstr = mrb_str_new_static(mrb, VALID_PATHS[i],
                       (mrb_int)strlen(VALID_PATHS[i]));
    mrb_value comp = mrb_funcall_argv(mrb, path_cls_val, MRB_SYM(compile),
                       1, &pstr);
    if (!mrb_check_error(mrb)) {
      mrb_value lz = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode_lazy),
                       1, &input);
      if (!mrb_check_error(mrb)) {
        mrb_funcall_argv(mrb, comp, MRB_SYM(at), 1, &lz);
        mrb_clear_error(mrb);
      }
      mrb_clear_error(mrb);
    }
    mrb_clear_error(mrb);
  }

  mrb_gc_arena_restore(mrb, 0);


  return 0;
}
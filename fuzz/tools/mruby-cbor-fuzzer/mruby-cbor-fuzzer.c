#include <mruby.h>
#include <mruby/error.h>
#include <stdlib.h>

static mrb_state *mrb     = NULL;
static size_t     counter = 0;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {

  if (!mrb) mrb = mrb_open();
  if (!mrb) abort();

  mrb_value input  = mrb_str_new_static(mrb, (const char *)data, (mrb_int)size);
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

  mrb_gc_arena_restore(mrb, 0);
  mrb_incremental_gc(mrb);

  if (++counter > 10000) {
    mrb_close(mrb);
    mrb     = NULL;
    counter = 0;
  }

  return 0;
}
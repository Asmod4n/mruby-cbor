#include <mruby.h>
#include <mruby/error.h>
#include <stdlib.h>
static mrb_state *mrb = NULL;
static size_t counter = 0;
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {

  if (!mrb) mrb = mrb_open();
  if (!mrb) abort();

  mrb_value input  = mrb_str_new_static(mrb, (const char *)data, (mrb_int)size);
  mrb_value cbor_m = mrb_obj_value(mrb_module_get_id(mrb, MRB_SYM(CBOR)));

/* 1. Eager decode */
mrb_value decoded = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode), 1, &input);
if (!mrb_check_error(mrb)) {
  /* 2. Re-encode the decoded value */
  mrb_value reencoded = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(encode), 1, &decoded);
  if (!mrb_check_error(mrb)) {
    /* 3. Decode the re-encoded value and check it matches */
    mrb_value redecoded = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode), 1, &reencoded);
    mrb_clear_error(mrb);
  }
}
mrb_clear_error(mrb);

  /* 2. Lazy decode — force evaluation via .value */
  mrb_value lazy = mrb_funcall_argv(mrb, cbor_m, MRB_SYM(decode_lazy), 1, &input);
  if (!mrb_check_error(mrb))
    mrb_funcall_argv(mrb, lazy, MRB_SYM(value), 0, NULL);
  mrb_clear_error(mrb);

  counter++;

  mrb_gc_arena_restore(mrb, 0);
  mrb_incremental_gc(mrb);

  if (counter > 10000) {
    mrb_close(mrb);
    mrb = NULL;
    counter = 0;
  }

  return 0;
}

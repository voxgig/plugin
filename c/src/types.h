/* Errors, and the raise mechanism (§12).
 *
 * SETJMP/LONGJMP, and the reason is fidelity rather than convenience.
 * The canonical RAISES: a failing call abandons the rest of the
 * function, and the corpus is full of entries that assert exactly what
 * survived a raise mid-sequence (`resource/unwind`, `lifecycle/fail`).
 * Threading an error return through every function would let a missed
 * check silently continue past a failure, which is the one thing the
 * corpus cannot see and the one thing it is trying to pin. `longjmp`
 * abandons the frame the way a `throw` does.
 *
 * THIS IS SAFE HERE BECAUSE OF THE ARENA. `longjmp` past a frame leaks
 * whatever that frame owned; nothing here owns anything, so there is
 * nothing to leak. The two decisions hold each other up.
 *
 * Ports compare by CODE and never by message: wording is a port's own
 * business. The FORMAT is pinned, because a parseable message is what
 * makes a log searchable across twenty languages.
 */

#ifndef VOXGIG_PLUGIN_TYPES_H
#define VOXGIG_PLUGIN_TYPES_H

#include <setjmp.h>
#include <stdbool.h>

#include "value.h"

typedef struct {
  const char *code;
  const char *text;
  Value *details;
  const char *message;
} PluginError;

/* The active catch frame. `plugin_try` pushes one, `plugin_end_try`
 * pops it. A raise with no frame installed aborts loudly rather than
 * returning into a caller that cannot have checked. */
typedef struct CatchFrame {
  jmp_buf jmp;
  struct CatchFrame *prev;
  PluginError *err;
} CatchFrame;

/* Use as:
 *
 *   CatchFrame f;
 *   if (0 == PLUGIN_TRY(&f)) { ... body ... PLUGIN_END(&f); }
 *   else { PluginError *e = f.err; ... }
 *
 * The body MUST reach PLUGIN_END on every non-raising path.
 */
int plugin_try(CatchFrame *f);
void plugin_end(CatchFrame *f);

#define PLUGIN_TRY(f) (plugin_try(f), setjmp((f)->jmp))
#define PLUGIN_END(f) plugin_end(f)

/* Raise. Never returns. */
void fail(const char *code, const char *text, Value *details);

/* §12's detail fields render in a FIXED ORDER — part of the contract,
 * not a formatting preference, because otherwise each port invents its
 * own and message parity is gone. */
const char *format_error(const char *code, const char *text, Value *details);

/* Convenience: a one-key details map. */
Value *details1(const char *k, Value *v);
Value *details2(const char *k1, Value *v1, const char *k2, Value *v2);

/* Deep merge, struct's semantics: maps merge, everything else replaces.
 * §16 permits voxgig/struct for this and C has no port of it. */
Value *plugin_merge(Value *a, Value *b);

/* §11.1's partial match: every leaf in `want` must be present and equal
 * in `have`; keys not mentioned are not checked. */
bool matchvalue(Value *want, Value *have);

#endif

/* Dynamic resolution (§10.2) — name to candidate module ids. Pure: it
 * returns the ids a host WOULD try, in order, and loads nothing. That
 * is what lets the corpus pin resolution in a language with no dynamic
 * loading at all. */

#ifndef VOXGIG_PLUGIN_RESOLVE_H
#define VOXGIG_PLUGIN_RESOLVE_H

#include "types.h"
#include "value.h"

Value *resolvecandidates(Value *name, Value *sources);
Value *resolvefrom(Value *from);

#endif

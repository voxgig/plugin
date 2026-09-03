/* Dependency cardinality, policy, and the restart graph (§11.3). Two
 * axes, both declared by the definition that has the requirement,
 * because only it knows what it can cope with. See depend.c. */

#ifndef VOXGIG_PLUGIN_DEPEND_H
#define VOXGIG_PLUGIN_DEPEND_H

#include <stdbool.h>

#include "types.h"
#include "value.h"

Value *normrequire(Value *r);
Value *requirements(Value *options);

bool restartsonloss(Value *r);
bool gatesactivation(Value *r);
bool restartcausing(Value *r);

/* [{ref, provides:[name], requires:[req]}] -> the cycle, or NULL. */
Value *dependencycycle(Value *nodes);
/* Raise on a cycle, naming it. Separate from the detector so the
 * detector stays pure and corpus-testable. */
void checkcycle(Value *nodes);

#endif

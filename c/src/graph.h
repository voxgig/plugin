/* Whole-graph resolution (§11.4) — a pure function of the registry that
 * answers which instances can be live, and for each blocked one THE
 * SPECIFIC requirement that is unmet, and why. See graph.c. */

#ifndef VOXGIG_PLUGIN_GRAPH_H
#define VOXGIG_PLUGIN_GRAPH_H

#include "types.h"
#include "value.h"

/* [{ref, pos, provides?, requires?}] -> {resolved: [ref], blocked: [...]} */
Value *resolvegraph(Value *nodes);

#endif

/* Whole-graph resolution (§11.4) — a pure function of the registry that
 * answers which instances can be live, and for each blocked one THE
 * SPECIFIC requirement that is unmet, and why. See graph.cpp. */

#ifndef VOXGIG_PLUGIN_GRAPH_HPP
#define VOXGIG_PLUGIN_GRAPH_HPP

#include "types.hpp"
#include "value.hpp"

namespace plugin {

/* [{ref, pos, provides?, requires?}] -> {resolved: [ref], blocked: [...]} */
V resolvegraph(const V& nodes);

}  // namespace plugin

#endif

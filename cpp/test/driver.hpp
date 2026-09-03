/* The driver (DOCS.md §4): the probe catalog, the command interpreter,
 * and the canonical observable. */

#ifndef VOXGIG_PLUGIN_DRIVER_HPP
#define VOXGIG_PLUGIN_DRIVER_HPP

#include <string>

#include "../src/host.hpp"
#include "../src/value.hpp"

namespace plugin {

V driverprobes();
DefinitionPtr driverprobe(const std::string& name);
/* Register the whole probe set into a host's catalog. */
void driverseed(const HostPtr& h);
/* Build host construction options from a `host` command (or a null). */
HostOptions driverhostopts(const V& cmd);

/* Run a command list and return §4.5's observable. Stops at the first
 * raise unless the command carries `catch`. */
V drive(const V& cmds);

}  // namespace plugin

#endif

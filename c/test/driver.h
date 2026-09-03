/* The driver (DOCS.md §4): the probe catalog, the command interpreter,
 * and the canonical observable. */

#ifndef VOXGIG_PLUGIN_DRIVER_H
#define VOXGIG_PLUGIN_DRIVER_H

#include "../src/host.h"
#include "../src/value.h"

Value *driver_probes(void);
Definition *driver_probe(const char *name);
/* Register the whole probe set into a host's catalog. */
void driver_seed(Host *h);
/* Build host construction options from a `host` command (or NULL). */
void driver_hostopts(HostOptions *out, Value *cmd);

/* Run a command list and return §4.5's observable. Stops at the first
 * raise unless the command carries `catch`. */
Value *drive(Value *cmds);

#endif

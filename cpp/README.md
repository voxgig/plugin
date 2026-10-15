# voxgig/plugin — cpp

The cpp port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # compile the library and the runner, -Werror
make test      # the corpus, all 19 sections
make inspect   # compiler version
make clean
```

**No dependencies.** §16 permits one runtime dependency, `voxgig/struct`,
which has no C++ port, so `src/value.cpp` is the JSON reader. `<regex>`
is the standard library, not a package. The build is
`-std=c++17 -Wall -Wextra -Werror`, with the same flags for the test
binary, so a warning fails the build rather than scrolling past.

## Layout

| | |
|---|---|
| `src/value.cpp` | the JSON value, and the only parser this port has |
| `src/types.cpp` | `PluginError`, `fail` and the §12 message format |
| `src/*.cpp` | the library, one file per §-area, each with its header |
| `test/driver.cpp` | the driver (DOCS.md §4) and the probe catalog |
| `test/run.cpp` | the runner: a `main` that counts entries and failures |

## Using it

Everything is in `namespace plugin`. The canonical names keep their
canonical spelling: `makehost`, `makecatalog`, `parseref`,
`normalizeconfig`, `applyenv` and the rest. Hosts, catalogs and
definitions are held by `std::shared_ptr`, and a value is `V`, a
`std::shared_ptr<Value>`.

```cpp
#include "host.hpp"

using namespace plugin;

auto retry = std::make_shared<Definition>();
retry->name = "retry";
retry->define = [](Inst& i) {
  i.bindchain("request",
              [](const Next& next, const V& arg) { return next(arg); },
              nullptr);
};

CatalogPtr catalog = makecatalog();
catalog->add(retry);

V request = vmap();
set(request, "kind", vstr("chain"));

HostOptions opts;
opts.catalog = catalog;
opts.points = vmap();
set(opts.points, "request", request);
opts.bases["request"] = [](const V& arg) { return arg; };
HostPtr host = makehost(opts);

try {
  host->ready("retry$fast");
}
catch (const PluginError& e) {
  std::cout << e.code << "\n";
}
```

A chain base is a function, which a `V` cannot hold, so it rides beside
the point map in `HostOptions::bases`, keyed by point name.

## Not the c port with different syntax

C++ has the three things the c port builds by hand, so this port uses
them, and the difference is the whole port:

| the c port | this port |
|---|---|
| one arena, nothing freed | `std::shared_ptr<Value>`, freed with its last reference |
| `setjmp` and `longjmp` | `throw` and `catch` |
| a function pointer plus `void *ctx` | a capturing `std::function` |
| `volatile` on every local that straddles a try | nothing: unwinding is correct |

There is no `volatile` discipline here, and there must not be one. A
`throw` unwinds the stack properly and a `longjmp` does not, so the
locals c has to protect need no protection in C++. `std::function` is
also what lets a chain binding read like the canonical: it receives
`next` as a callable and writes `next(arg)`, where c walks an explicit
`Chain *`.

## `nullptr` is nothing; a null `Value` is JSON null

Every value helper in `value.hpp` tolerates a `nullptr`, which is why they
are free functions rather than members. The two answers differ and
several places need both: a `bail` binding declining is not one
answering `null`, and a missing export is not an export of `null`. `get`
reads a missing key as null; `has` is the only thing that distinguishes
them, and §9.1's rule that an authored null is not an absent key is why
it exists.

## What the corpus caught

**The regex dialect.** The corpus's `match` patterns are JavaScript
`/.../` literals, so they escape `/` and `$` the way JavaScript does.
POSIX extended syntax leaves `\/` undefined: the GNU C library's
`<regex.h>` tolerates it, which is why the c port gets away with
`REG_EXTENDED`, and libstdc++'s `std::regex::extended` does not. Four
`error/format` and `depend/hold` entries failed on messages that
plainly matched. The dialect is ECMAScript, which is the default for
`std::regex`; the port first had it wrong by copying c.

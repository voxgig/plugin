# The cpp port — agent notes

C++ is a tier-4 static-only language (design §10.3): no dynamic
loading, no runtime plugin discovery. But it is **not** the `c` port
with different syntax, and reading it as one would be the mistake. C++
has the three things `c` had to build by hand, so it uses them.

## What `c` builds by hand, and this port does not

| `c` | `cpp` |
| --- | --- |
| one arena, nothing freed | `std::shared_ptr<Value>`, destructors |
| `setjmp`/`longjmp` | `throw` / `catch` |
| function pointer + `void *ctx` | `std::function`, capturing |
| `volatile` on every local straddling a try | nothing — unwinding is correct |

That table is the whole port. **The consequence worth stating: there is
no `volatile` discipline here and there must not be one.** `-Wclobbered`
found seven locals in `c` that a reader would have missed; the same code
in C++ needs none of them, because a `throw` unwinds properly and a
`longjmp` does not.

`std::function` is what makes a chain binding read like the canonical:
it receives its `next` as a callable and writes `next(arg)`, where `c`
walks an explicit `Chain *` by index. Same composition, same order.

## nullptr is "nothing"; a null Value is "JSON null"

Every accessor in `value.hpp` tolerates a `nullptr`, which is why they
are free functions rather than members. The two answers are different
and several places need both: a `bail` binding declining is not one
answering `null`, and a missing export is not an export of `null`. `get`
collapses them (a missing key reads as null); `has` is the only thing
that tells them apart, and §9.1's "an authored null is not an absent
key" is why it exists.

## What the corpus caught

- **The regex dialect.** The corpus's `match` patterns are JavaScript
  `/.../` literals, so they escape `/` and `$` the way JavaScript does.
  `std::regex::extended` (POSIX ERE) leaves `\/` undefined: glibc
  tolerates it, which is why `c` gets away with `REG_EXTENDED` next
  door, and libstdc++ does not — four `error/format` and `depend/hold`
  entries failed on messages that plainly matched. The dialect is
  ECMAScript, which is `std::regex`'s default; the port had it wrong by
  copying `c`.

## Build

`make build` is a real gate: `-std=c++17 -Wall -Wextra -Werror`.
`<regex>` is the standard library, not a package — §16's one permitted
runtime dependency (voxgig/struct) has no C++ port, so `src/value.cpp`
is the JSON reader and the runner is a `main` that counts.

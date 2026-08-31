# AGENTS.md — the perl port

Read [`../AGENTS.md`](../AGENTS.md) first. The prime directives there are
not negotiable here: **TypeScript is canonical**, **the corpus is the
contract**, **change canonical first then propagate**, and **never weaken
the corpus to make this port pass**.

This file is only what is specific to perl.

## The rule that matters most here

**A disagreement with the corpus is this port's bug — until you have
established it is the canonical's.** Both happen;
[`../doc/plan/handover.md`](../doc/plan/handover.md) §13 has the running
list. But the default is that a port got a coercion or ordering rule
wrong, and the burden is on the change to show otherwise.

## Perl-specific traps

**There are no JSON types.** `Types::jsontype` is the whole answer: SV
flags for number-versus-string, `builtin::is_bool` for the boolean,
`ref` for the containers. Every leaf comparison in the library and in the
runner goes through `Capability::samescalar`, which asks the type first.
Never compare a corpus value with a bare `==` or `eq`.

**Reading the type is destructive if you do it wrong.** A numeric scalar
used in STRING context keeps POK for good and reads as a string
afterwards. So: no interpolation of a corpus value before it is compared,
and in the runner the `jsontype` call comes before the `'__EXISTS__' eq`
sentinel tests, not after. Thirty entries failed on exactly that ordering.

**`foreach` aliases, and aliasing a hash element autovivifies it.**
`for my $x ($h->{k})` creates `$h->{k}` as undef. Assign the list to an
array first when any element is a hash lookup that may be absent —
`Config::normalize_config` says so where it does it.

**A hash has no order.** Every registry walk sorts. `sort` is stable
(`use sort 'stable'`), and `Types::sortstrings` is the one spelling of a
byte-wise sort.

**`$a` and `$b` are the sort globals.** Never `my ($a, $b) = @_` in a
routine a comparator calls; `Types::cmpkey` takes `$ka`/`$kb` and says
why.

**`\A` and `\z`, never `^` and `$`.** Perl's `$` matches before a trailing
newline, and `ref/name#trailing-newline` catches it immediately.

## The runner makes warnings fatal

`$SIG{__WARN__}` dies. Do not remove it to quiet a new warning: a warning
here means the port read something it should not have, and the corpus
cannot always see the difference. The `order_declared` mutation is the
worked example — it survives the entire corpus and shows up only as a
warning.

## What the corpus cannot currently distinguish

Two mutations survive, and both are gaps in the corpus rather than in the
port — the same two the php port found independently:

- `Config::config_pick` with `defined` instead of `exists`: no entry
  writes an explicit `null` for an instance's `active`, `start` or
  `order`, so presence-versus-null is unpinned.
- `Order::order_band` accepting a numeric STRING or a boolean: no entry
  writes a band that is not already an integer.

Neither is a licence to relax the code. If you pin either, pin it in
`spec/plugin.aontu` and propagate — never by loosening this port.

## Local shape

- One package per file under `Voxgig::Plugin::`; `Voxgig/Plugin.pm` is an
  alias block and nothing else, so the canonical surface is visible in one
  place.
- `JSON::PP` and `B` are CORE. Nothing from CPAN, ever (§16).
- `make build` is `perl -c` over every file. Not a no-op: a syntax error in
  a file no test happens to require would otherwise ship.

## Adding a corpus section

Dispatch it explicitly in `test/run.pl`. The runner fails on a *group*
with no subject, and its coverage block fails if a whole SECTION exists in
the corpus and nothing runs it. A section or group silently not run is
worse than a failing one.

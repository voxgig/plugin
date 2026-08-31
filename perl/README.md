# voxgig/plugin — perl

The perl port of [voxgig/plugin](../README.md). It is a **port**, not an
independent implementation: behaviour is defined by `typescript/`, and
`spec/plugin.json` — the same corpus every port runs — is the arbiter.

```bash
make build     # syntax-check every file
make test      # the corpus, all 19 sections
make inspect   # interpreter version
make clean
```

Perl 5.36 or later, for `builtin::is_bool` — see below, it is not a
convenience. **No CPAN modules**: `JSON::PP` and `B` are core, and the
suite is a plain runner rather than `Test::More`, because a conformance
suite whose only job is to run one corpus and report which entries
disagree does not need TAP between a disagreement and the line that names
it.

## Layout

| | |
|---|---|
| `lib/Voxgig/Plugin/` | the library, one package per file |
| `lib/Voxgig/Plugin.pm` | the public surface — an alias block, nothing else |
| `test/` | the driver (DOCS.md §4), the corpus runner, and `run.pl` |

## Using it

```perl
use Voxgig::Plugin qw(make_host make_catalog);

my $catalog = make_catalog([
    { name => 'retry',
      define => sub {
          my ($i) = @_;
          $i->bind('request', sub { my ($nxt, @a) = @_; return $nxt->(@a) });
      } },
]);

my $host = make_host({
    catalog => $catalog,
    points  => { request => { kind => 'chain', base => $transport } },
});

$host->ready('retry$fast');
```

Definitions are plain hashrefs with coderef values, which is what makes a
catalog a data structure a document could produce. Errors are `die`n as
`Voxgig::Plugin::Error` objects carrying the §12 `code` the corpus compares
by; they stringify to the pinned `plugin/<code>: <text> [k=v]` message.

## The trap that shaped this port

**Perl has no JSON types, and the corpus pins them.** `1`, `"1"` and `!!1`
are all equal under `==`, and the first two under `eq` — while
`capability/match` has an entry for each direction saying they are
different. So the port carries `jsontype`, which reads the scalar's own
IOK/NOK/POK flags (the same test `JSON::PP` uses to decide whether to emit
a number) plus `builtin::is_bool` for the boolean, and **every leaf
comparison goes through it**.

It has one limit, and it is perl's rather than the port's: using a numeric
scalar in **string context sets POK permanently**, after which it reads as
a string. Nothing in the library interpolates a corpus value before
comparing it — and the corpus runner's `matches` originally did, in the
`'__EXISTS__' eq $expect` test, which turned every numeric expectation into
a string and failed thirty entries that were in fact correct. The type test
now comes first, and the comment there says why.

## Two more that cost real debugging

**`foreach` ALIASES its list, and aliasing a hash element autovivifies
it.** `for my $src ($basedef->{$nm}, $b, $overdef->{$nm}, $o)` silently
created `$overdef->{$nm}` as undef, and the `default` output then copied
that undef over the base's real value. A list assignment first is the fix;
`config/normkeys#root` is what caught it.

**A hash has no order, and it is randomized per process.** Every walk of
the registry sorts its keys first — not tidiness, the difference between a
deterministic teardown and one that changes between runs. `sort` is stable
here (`use sort 'stable'`, in every file that sorts).

## What the runner does that others do not

`$SIG{__WARN__}` **dies**. Perl's default is to warn about an undefined
value and continue with the empty string, which surfaces as a corpus
disagreement three functions from the mistake — or as no disagreement at
all: a mutation making an ABSENT ordering constraint read as *declared*
passes the whole corpus, and is visible only as one "Use of uninitialized
value" on stderr. With warnings fatal, that mutation fails two entries by
name.

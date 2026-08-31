package Corpus;

# The corpus runner.
#
# Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
# exactly as every other port's runner does. No port needs a Node toolchain
# to run its tests, and this one does not get a private door into the
# source either.
#
# A group name selects the subject. That is the whole dispatch, and it is
# deliberately dumb: a runner that inferred the subject from the entry's
# shape would silently run the wrong function when an entry was mistyped.

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();
use Voxgig::Plugin::Types qw(jsontype ismap islist sortedkeys);
use Voxgig::Plugin::Capability qw(samescalar);
use Voxgig::Plugin qw(codeof);

use Exporter 'import';
our @EXPORT_OK = qw(corpus section label same matches check json MISSING);

our $SPEC = File::Spec->catfile(dirname(__FILE__), '..', '..', 'spec', 'plugin.json');

# A sentinel for "this key was not present". Perl collapses an absent key
# and a JSON null to undef, and `__UNDEF__` and `__NULL__` are different
# assertions.
our $MISSING = bless {}, 'Corpus::Missing';

sub MISSING { return $MISSING }

sub ismissing {
    my ($v) = @_;
    return ref($v) && 'Corpus::Missing' eq ref($v) ? 1 : 0;
}

our $CACHE;

sub corpus {
    return $CACHE if defined $CACHE;
    open my $fh, '<:raw', $SPEC or die "cannot read $SPEC: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    $CACHE = JSON::PP->new->decode($text);
    return $CACHE;
}

sub section {
    my ($name) = @_;
    my $spec = corpus();
    my $sec = ($spec->{primary} // {})->{$name};
    die "no such corpus section: $name" if !defined $sec;

    my %out;
    for my $group (keys %$sec) {
        next if 'DEF' eq $group;
        my $body = $sec->{$group};
        next if !ismap($body) || !islist($body->{set});
        $out{$group} = $body->{set};
    }
    return \%out;
}

# A stable label, so a failure names the entry rather than an index.
sub label {
    my ($group, $i, $entry) = @_;
    return $entry->{id} // "$group#$i";
}

# Deep equality over spec values. Key order never matters; list order
# always does.
#
# EVERY LEAF GOES THROUGH `samescalar`, which reads the scalar's own type
# first. Perl would otherwise report `1`, `"1"` and `!!1` as equal, and the
# corpus pins all three as different.
sub same {
    my ($x, $y) = @_;
    my $tx = jsontype($x);
    my $ty = jsontype($y);

    if ('map' eq $tx || 'map' eq $ty) {
        return 0 if 'map' ne $tx || 'map' ne $ty;
        return 0 if keys(%$x) != keys(%$y);
        for my $k (keys %$x) {
            return 0 if !exists $y->{$k};
            return 0 if !same($x->{$k}, $y->{$k});
        }
        return 1;
    }
    if ('list' eq $tx || 'list' eq $ty) {
        return 0 if 'list' ne $tx || 'list' ne $ty || @$x != @$y;
        for my $i (0 .. $#$x) {
            return 0 if !same($x->[$i], $y->[$i]);
        }
        return 1;
    }
    return samescalar($x, $y) ? 1 : 0;
}

# Partial match: every key the expectation names must agree, and keys it
# does not name are ignored. `__EXISTS__` asserts presence without pinning
# a value; `/re/` matches a string as a regular expression.
sub matches {
    my ($expect, $actual) = @_;

    # THE TYPE TEST COMES FIRST, AND IT HAS TO. `'__EXISTS__' eq $expect`
    # puts $expect in STRING context, which sets the scalar's POK flag
    # permanently - so a numeric expectation compared against the sentinels
    # first would afterwards read as the string "3" and disagree with the
    # number 3 the port produced. The runner that reads a type must not be
    # the thing that changes it.
    my $etype = jsontype($expect);

    if ('str' eq $etype) {
        return (!ismissing($actual) && defined $actual) ? 1 : 0
            if '__EXISTS__' eq $expect;
        return ismissing($actual) ? 1 : 0 if '__UNDEF__' eq $expect;
        return (!ismissing($actual) && !defined $actual) ? 1 : 0
            if '__NULL__' eq $expect;
    }

    $actual = undef if ismissing($actual);

    if ('str' eq $etype && 2 < length $expect
        && '/' eq substr($expect, 0, 1) && '/' eq substr($expect, -1)) {
        return 0 if 'str' ne jsontype($actual);
        my $body = substr($expect, 1, -1);
        return $actual =~ /$body/ ? 1 : 0;
    }

    if ('list' eq $etype) {
        return 0 if !islist($actual) || @$expect != @$actual;
        for my $i (0 .. $#$expect) {
            return 0 if !matches($expect->[$i], $actual->[$i]);
        }
        return 1;
    }

    if ('map' eq $etype) {
        return 0 if !ismap($actual);
        for my $k (keys %$expect) {
            my $got = exists $actual->{$k} ? $actual->{$k} : $MISSING;
            return 0 if !matches($expect->{$k}, $got);
        }
        return 1;
    }

    return samescalar($expect, $actual) ? 1 : 0;
}

# Run one entry against a subject and report the disagreement, if any.
#
# The three combinations the spec format allows are enforced here as well
# as at build time, because a runner that quietly accepted `err` beside
# `out` would let a contradictory entry pass.
sub check {
    my ($entry, $subject) = @_;
    return 'entry has both err and out'
        if exists $entry->{err} && exists $entry->{out};

    my $value;
    my $ok = eval { $value = $subject->($entry); 1 };
    my $raised = $ok ? undef : ($@ // 'died');

    if (exists $entry->{err}) {
        return 'expected a raise, got: ' . json($value) if $ok;

        if (!(jsontype($entry->{err}) eq 'bool' && $entry->{err})) {
            # Errors compare by CODE (section 12). Message wording is a
            # port's own business, and pinning it would make every
            # translation a corpus change.
            my $got = codeof($raised);
            return "expected code $entry->{err}, got $got ($raised)"
                if $got ne $entry->{err};
        }
        if (exists $entry->{match}) {
            my $got = { err => { code => codeof($raised),
                                 message => "$raised",
                                 name => 'PluginError' } };
            return 'error did not match ' . json($entry->{match})
                . ', got ' . json($got)
                if !matches($entry->{match}, $got);
        }
        return undef;
    }

    return 'unexpected raise: ' . codeof($raised) . " $raised" if !$ok;

    if (exists $entry->{out} && !same($entry->{out}, $value)) {
        return 'expected ' . json($entry->{out}) . ', got ' . json($value);
    }

    if (exists $entry->{match}) {
        my $got = { in => $entry->{in}, out => $value };
        return 'did not match ' . json($entry->{match})
            . ', got out=' . json($value)
            if !matches($entry->{match}, $got);
    }

    return 'entry asserts nothing'
        if !exists $entry->{out} && !exists $entry->{match};

    return undef;
}

sub json {
    my ($value) = @_;
    my $out = eval {
        JSON::PP->new->canonical->allow_nonref->allow_blessed->convert_blessed
            ->encode($value);
    };
    return defined $out ? $out : '<unencodable>';
}

1;

#!/usr/bin/env perl

# The whole suite: pure sections by direct call, driver sections by command
# list, and a coverage guard above both.
#
# A plain runner rather than Test::More, for the same reason the port has
# no CPAN dependencies: a conformance suite whose only job is to run one
# corpus and report which entries disagree does not need a framework, and
# TAP would add a layer between a disagreement and the line that names it.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin";

use Corpus;
use Driver;
use Voxgig::Plugin qw(
    parse_ref format_ref check_name check_tag canon_ref
    apply_env parse_range satisfies resolve_capability resolve_graph
    resolve_candidates resolve_from normalize_config resolve_options
);

# A WARNING IS A FAILURE HERE, not a footnote on stderr. Perl's default is
# to warn about an undefined value and carry on with the empty string,
# which surfaces as a corpus disagreement three functions from the mistake
# - or, worse, as no disagreement at all: a mutation making `order_declared`
# treat an ABSENT constraint as declared survives the corpus and is visible
# only as "Use of uninitialized value" from the target match.
$SIG{__WARN__} = sub { die "warning: $_[0]" };

my @FAILURES;
my %RAN = (sections => 0, entries => 0);

sub report {
    my ($name, $group, $i, $entry, $why) = @_;
    push @FAILURES, "$name/" . Corpus::label($group, $i, $entry) . ": $why";
    return;
}

# Dispatch every group, and fail on a group the runner does not know - a
# group silently not run is worse than a failure.
sub run_section {
    my ($name, $subject) = @_;
    my $groups = Corpus::section($name);
    $RAN{sections}++;
    for my $group (sort keys %$groups) {
        my $fn = $subject->{$group};
        if (!defined $fn) {
            push @FAILURES, "$name: corpus group with no subject: $group";
            next;
        }
        my $set = $groups->{$group};
        for my $i (0 .. $#$set) {
            $RAN{entries}++;
            my $why = Corpus::check($set->[$i], $fn);
            report($name, $group, $i, $set->[$i], $why) if defined $why;
        }
    }
    return;
}

# ---- pure sections --------------------------------------------------

my $parse  = sub { parse_ref($_[0]->{in}) };
my $format = sub {
    my $args = $_[0]->{args} // [];
    return format_ref($args->[0], $args->[1]);
};
my $name = sub { check_name($_[0]->{in}) };
my $tag  = sub { check_tag($_[0]->{in}) };

run_section('ref', {
    parse => $parse, parsebad => $parse,
    format => $format, formatbad => $format,
    canon => sub { canon_ref($_[0]->{in}) },
    name => $name, tag => $tag, bound => $name, boundtag => $tag,
});

my $env = sub { apply_env($_[0]->{in}) };
run_section('env', {
    option => $env, value => $env, toggle => $env,
    profile => $env, ambiguous => $env, reserved => $env,
});

my $rng = sub { parse_range($_[0]->{in}) };
run_section('version', {
    range => $rng, rangebad => $rng,
    satisfies => sub { satisfies($_[0]->{in}{version}, $_[0]->{in}{range}) },
});

my $cap = sub { resolve_capability($_[0]->{in}{req}, $_[0]->{in}{candidates}) };
run_section('capability', { match => $cap, nested => $cap, rank => $cap });

my $graph = sub { resolve_graph($_[0]->{in}) };
run_section('graph', { resolve => $graph, blocked => $graph });

run_section('resolve', {
    candidates => sub { resolve_candidates($_[0]->{in}{name}, $_[0]->{in}{sources}) },
    from => sub { resolve_from($_[0]->{in}) },
});

# `config` picks its subject by group PREFIX rather than by name, because
# the two functions split the section cleanly.
my $configgroups = Corpus::section('config');
$RAN{sections}++;
for my $group (sort keys %$configgroups) {
    my $fn;
    if (0 == index($group, 'norm')) {
        $fn = sub { normalize_config($_[0]->{in}) };
    }
    elsif (0 == index($group, 'opt')) {
        $fn = sub { resolve_options($_[0]->{in}) };
    }
    if (!defined $fn) {
        push @FAILURES, "config: corpus group with no subject: $group";
        next;
    }
    my $set = $configgroups->{$group};
    for my $i (0 .. $#$set) {
        $RAN{entries}++;
        my $why = Corpus::check($set->[$i], $fn);
        report('config', $group, $i, $set->[$i], $why) if defined $why;
    }
}

# ---- driver sections ------------------------------------------------

my @DRIVER_SECTIONS = qw(
    lifecycle order point export depend
    declare state resource nest trace apply error
);

for my $section (@DRIVER_SECTIONS) {
    my $groups = Corpus::section($section);
    $RAN{sections}++;
    for my $group (sort keys %$groups) {
        my $set = $groups->{$group};
        for my $i (0 .. $#$set) {
            $RAN{entries}++;
            my $entry = $set->[$i];
            if ('ARRAY' ne (ref($entry->{in}) // '')) {
                report($section, $group, $i, $entry, 'driver entry without a command list in `in`');
                next;
            }
            my $why = Corpus::check($entry, sub { Driver::drive($_[0]->{in}) });
            report($section, $group, $i, $entry, $why) if defined $why;
        }
    }
}

# ---- coverage -------------------------------------------------------
#
# EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails on a
# GROUP with no subject; this closes the level above, because a whole
# SECTION the runner never mentions is a section silently not run.

my @PURE_SECTIONS = qw(ref env version capability graph resolve config);

my $spec = Corpus::corpus();
my $primary = $spec->{primary} // {};

# The corpus metadata block is what turns on strict entry validation in
# every runner, so a corpus that lost it must not silently downgrade this
# port's checking.
push @FAILURES, 'corpus PLUGIN.version must be 1'
    if 1 != (($spec->{PLUGIN} // {})->{version} // 0);

my %run = map { $_ => 1 } (@PURE_SECTIONS, @DRIVER_SECTIONS);
my @missing = sort grep { !$run{$_} } keys %$primary;
push @FAILURES, 'corpus sections no test runs: ' . join(', ', @missing)
    if @missing;
my @extra = sort grep { !exists $primary->{$_} } keys %run;
push @FAILURES, 'tests name sections the corpus does not have: '
    . join(', ', @extra) if @extra;

# A floor, not a fixture: the corpus grows, and a run that suddenly covers
# a fraction of it is the failure worth catching.
push @FAILURES, "only $RAN{entries} corpus entries reachable"
    if $RAN{entries} < 400;

# ---- report ---------------------------------------------------------

if (!@FAILURES) {
    print "perl: $RAN{entries} corpus entries across $RAN{sections} sections, all pass\n";
    exit 0;
}

print STDERR "$_\n" for @FAILURES;
print STDERR "\nperl: " . scalar(@FAILURES) . " failure(s) of $RAN{entries} entries\n";
exit 1;

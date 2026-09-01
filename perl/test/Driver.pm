package Driver;

# The driver (DOCS.md section 4).
#
# Every port implements this same small thing and nothing else is
# port-specific: the probe catalog, the command interpreter, and the
# canonical observable.

use strict;
use warnings;
use Voxgig::Plugin::Types qw(truthy ismap sortedkeys);
use Voxgig::Plugin qw(make_host make_catalog);

use Exporter 'import';
our @EXPORT_OK = qw(drive probes);

# A sentinel for "this command produced nothing", so a command that
# legitimately produces undef - `export` of a missing key - still
# overwrites the previous result.
our $NOTHING = bless {}, 'Driver::Nothing';

sub isnothing {
    my ($v) = @_;
    return ref($v) && 'Driver::Nothing' eq ref($v) ? 1 : 0;
}

# Section 4.3's six probes. Their behaviour is as much the contract as the
# runner is - this is where twenty implementations of `noisy` are made to
# fail at the same callback in the same way.
sub probes {
    my $record = sub {
        my ($name) = @_;
        return {
            name => $name,
            define => sub { my ($i) = @_; $i->state->{count} //= 0; return },
            activate => sub { my ($i) = @_; $i->acquire; return },
        };
    };

    my $probe = {
        name => 'probe',
        define => sub {
            my ($i) = @_;
            $i->state->{count} //= 0;
            my $band = $i->options->{band};
            # One hook binding (`p`) and one chain wrap (`c`) - the
            # workhorse shape DOCS.md section 4.3 specifies.
            $i->bind('p', sub {
                $i->state->{count} = ($i->state->{count} // 0) + 1;
                return;
            }, $band);
            # Wrap AFTER next, so the result spells the nesting left to
            # right: outermost first. Wrapping the ARGUMENT instead would
            # spell it backwards and make every chain expectation read
            # wrong.
            $i->bind('c', sub {
                my ($nxt, $v) = @_;
                return ($i->options->{wrap} // ':') . $nxt->($v);
            }, $band);
            $i->export('client', $i->ref);
            # The instance api itself, so the driver's `stray` command can
            # call `release` from OUTSIDE a lifecycle callback.
            $i->export('inst', $i);
            declareprovides($i);
            return;
        },
        activate => sub {
            my ($i) = @_;
            $i->acquire;
            # Section 6.5: an instance that is itself a host. The outer
            # owns the inner's lifetime - registered in the scope, so it
            # closes on deactivate in the same reverse unwind as every
            # other resource.
            my $nest = $i->options->{nest};
            return if !defined $nest;

            my $inner = $i->nest({ points => withpoints() });
            $inner->catalog->add($_) for @{ probes() };
            $inner->ready($_) for @$nest;
            return;
        },
    };

    my $noisy = {
        name => 'noisy',
        define => sub {
            my ($i) = @_;
            $i->state->{count} //= 0;
            boom($i, 'define');
            return;
        },
        activate => sub {
            my ($i) = @_;
            # Acquire BEFORE the raise, so a failing activate has something
            # to leak if the scope does not unwind - which is the whole
            # point of the entry that asserts open == 0 afterwards.
            $i->acquire;
            reenter($i, 'activate');
            boom($i, 'activate');
            return;
        },
        deactivate => sub { boom($_[0], 'deactivate'); return },
        close      => sub { boom($_[0], 'close'); return },
    };

    my $greedy = {
        name => 'greedy',
        define => sub {
            my ($i) = @_;
            $i->state->{count} = 0;
            # Section 8.1 puts resource capture in `activate`. `early`
            # NAMES the call that reaches for it in `define`, because
            # `acquire` and `release` carry the guard separately.
            my $early = $i->options->{early} // '';
            $i->acquire if 'acquire' eq $early;
            $i->release(sub { return }) if 'release' eq $early;
            return;
        },
        activate => sub {
            my ($i) = @_;
            my $opts = $i->options;
            my $n = $opts->{acquire} // 0;
            my $rel = $opts->{release} // 0;
            my @handles = map { $i->acquire } 1 .. $n;
            # Release some explicitly; the DIFFERENCE is what the instance
            # scope must unwind by itself (section 8.3), and that
            # difference is the whole test.
            my $take = $rel < @handles ? $rel : scalar @handles;
            $handles[$_]->() for 0 .. $take - 1;

            # `bind` is `early`'s counterpart for section 8.1's OTHER half.
            # Binding declaration belongs in `define`; this names the
            # callback that tries it from somewhere else.
            $i->bind('p', sub { return })
                if 'activate' eq ($opts->{bind} // '');

            # `mark` registers N FOREIGN releases - section 8.3's
            # `release`, the half `acquire` cannot exercise - each
            # recording its own index as it runs. THE RECORDED LIST IS THE
            # ONLY THING THAT DISTINGUISHES A REVERSE UNWIND FROM A FORWARD
            # ONE.
            $i->state->{unwound} = [];
            my $markfail = truthy($opts->{markfail});
            for my $k (0 .. ($opts->{mark} // 0) - 1) {
                $i->release(sub {
                    # `markfail` makes the release RAISE - the only way
                    # section 8.3's `plugin_release_failed` and its
                    # `failed` status are reachable.
                    die "release failed at $k\n" if $markfail;
                    push @{ $i->state->{unwound} }, $k;
                    return;
                });
            }
            return;
        },
        # `deactivate` completes the pair: the guard is on the PHASE, not
        # on "not define", and an entry exercising only one leaves the
        # other's mutation alive.
        deactivate => sub {
            my ($i) = @_;
            $i->bind('p', sub { return })
                if 'deactivate' eq ($i->options->{bind} // '');
            return;
        },
    };

    my $dep = {
        name => 'dep',
        define => sub {
            my ($i) = @_;
            $i->state->{count} = 0;
            declareprovides($i);
            my $exports = $i->options->{exports} // {};
            $i->export($_, $exports->{$_}) for sortedkeys($exports);
            return;
        },
        activate => sub { $_[0]->acquire; return },
    };

    my $provider = {
        name => 'provider',
        define => sub {
            my ($i) = @_;
            $i->state->{count} = 0;
            my $opts = $i->options;
            my $point = $opts->{point} // 'v';
            $i->bind($point, sub {
                my $o = $i->options;
                return exists $o->{value} ? $o->{value} : $i->ref;
            }, $opts->{band});
            declareprovides($i);
            return;
        },
        activate => sub { $_[0]->acquire; return },
    };

    return [ $probe, $noisy, $greedy, $dep, $provider,
             $record->('slow'), $record->('other'), $record->('adapter'),
             $record->('late') ];
}

sub declareprovides {
    my ($inst) = @_;
    $inst->provides($_) for @{ $inst->options->{provides} // [] };
    return;
}

sub boom {
    my ($inst, $callback) = @_;
    my $opts = $inst->options;
    return if $callback ne ($opts->{fail} // '');

    # `bare` raises WITHOUT a code - the ordinary library error section
    # 12's `plugin_<phase>_failed` codes exist to wrap.
    die "probe failed at $callback\n" if truthy($opts->{bare});

    die Voxgig::Plugin::Error->new(
        $opts->{code} // "plugin_${callback}_failed",
        "probe failed at $callback");
}

sub reenter {
    my ($inst, $callback) = @_;
    return if $callback ne ($inst->options->{reenter} // '');

    # A transition from inside a lifecycle callback (section 5.2).
    $inst->host->activate($inst->ref);
    return;
}

# The points every driver host declares. DOCS.md section 4.3 defines
# `probe` as binding one hook point (`p`) and wrapping one chain point
# (`c`), so a host without them cannot load the probe at all - they are
# part of the contract's baseline rather than a fixture convenience. `v` is
# the provider point the `provider` probe defaults to.
sub basepoints {
    return {
        p => { kind => 'hook' },
        c => { kind => 'chain', base => sub { return $_[0] } },
        v => { kind => 'provider' },
    };
}

sub withpoints {
    my ($extra) = @_;
    my $out = basepoints();
    # A `host` command REPLACES a base point rather than merging into it,
    # so an entry can redeclare `c` with its own base or `v` as exclusive
    # without inheriting the default's shape.
    $out->{$_} = $extra->{$_} for keys %{ $extra // {} };
    return $out;
}

sub withprobes {
    return make_catalog(probes());
}

# Run a command list and return section 4.5's observable. Stops at the
# first raise; the entry's `err` matches its code.
sub drive {
    my ($cmds) = @_;
    my $host = make_host({ catalog => withprobes(), points => withpoints() });

    # Section 4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES
    # ONE. Storing it and continuing - rather than returning at the first
    # producing command - is what lets an entry emit and then inspect,
    # which most of `point` needs.
    my $last;

    for my $cmd (@$cmds) {
        my ($nexthost, $value);
        my $ok = eval { ($nexthost, $value) = docmd($host, $cmd); 1 };
        if (!$ok) {
            # Section 4.1: `catch` records the raise and lets the run
            # continue, which is the only way to observe a `failed`
            # instance - section 5.2's whole claim is that it stays
            # registered and inspectable.
            die $@ if !(exists $cmd->{catch} && $cmd->{catch});
            next;
        }
        $host = $nexthost;
        $last = $value if !isnothing($value);
    }
    return $host->observable($last);
}

sub docmd {
    my ($host, $cmd) = @_;
    my $ref = $cmd->{ref};
    my $point = $cmd->{point};
    my $spec = { options => $cmd->{options}, order => $cmd->{order},
                 definition => $cmd->{definition}, tag => $cmd->{tag} };
    my $do = $cmd->{do};

    if ('host' eq $do) {
        return (make_host({
            catalog => withprobes(),
            reserved => $cmd->{reserved}, keys => $cmd->{keys},
            defaults => $cmd->{defaults}, profile => $cmd->{profile},
            points => withpoints($cmd->{points}),
            # Section 11.3's strict reading. Absent means `restart`.
            dependency => $cmd->{dependency},
        }), $NOTHING);
    }
    # Section 10.1's static registration: the definition ENTERS THE
    # CATALOG here, and registration is where its option shape is
    # validated (section 9.4) - before any load, so a malformed shape
    # fails at one moment in every host rather than whenever a document
    # happens to exercise the key.
    #
    # The catalog is pre-seeded with the probe set, so re-registering a
    # probe by name is the identity this command has always been; `shape`
    # is what makes it do work. A name the probe set does not hold
    # registers a bare definition - enough to reach the catalog, and
    # never loaded.
    if ('define' eq $do) {
        # Section 4.2's three keys, all of them live. `probe` names the
        # PROBE whose callbacks back the definition and `name` is what the
        # definition is called - two keys that ten entries passed as equal
        # strings, so a driver ignoring `probe` passed them all.
        my $source = exists $cmd->{probe} ? $cmd->{probe} : $cmd->{name};
        my $definition = { name => $cmd->{name} };
        for my $d (@{ probes() }) {
            next unless defined $source && $source eq $d->{name};
            $definition = { %$d, name => $cmd->{name} };
        }
        $definition->{shape} = $cmd->{shape} if exists $cmd->{shape};
        $host->define($definition);
        return ($host, $NOTHING);
    }

    if ('load' eq $do)       { $host->load($ref, $spec) }
    elsif ('ready' eq $do) {
        # declare FIRST, so the ordering block and definition reach the
        # instance - `ready` walks the staircase, it does not carry
        # configuration of its own.
        $host->declare($ref, $spec);
        $host->ready($ref);
    }
    elsif ('activate' eq $do)   { $host->activate($ref) }
    elsif ('deactivate' eq $do) { $host->deactivate($ref) }
    elsif ('unload' eq $do)     { $host->unload($ref) }
    elsif ('apply' eq $do)      { $host->apply($cmd->{doc}, $cmd->{profile}) }
    elsif ('options' eq $do)    { $host->options($ref, $cmd->{patch}) }
    elsif ('close' eq $do)      { $host->close }
    elsif ('list' eq $do)       { return ($host, $host->list) }
    elsif ('emit' eq $do)       { return ($host, $host->emit($point, $cmd->{arg})) }
    elsif ('chain' eq $do)      { return ($host, $host->call($point, $cmd->{arg})) }
    elsif ('provider' eq $do)   { return ($host, $host->provider($point, $cmd->{arg})) }
    elsif ('shadowed' eq $do)   { return ($host, $host->shadowed($point)) }
    elsif ('export' eq $do)     { return ($host, $host->exports($cmd->{key})) }
    elsif ('capability' eq $do) { return ($host, $host->capability($cmd->{name})) }
    elsif ('trace' eq $do)      { return ($host, $host->trace) }
    elsif ('hostdeclare' eq $do) {
        # Section 9.1's host-owned path: the embedding host installing the
        # instance whose name it reserved.
        return ($host, $host->hostdeclare($ref, $spec)->{ref});
    }
    elsif ('declare' eq $do) { return ($host, $host->declare($ref, $spec)->{ref}) }
    elsif ('order' eq $do)   { return ($host, $host->order($point)) }
    elsif ('seq' eq $do) {
        my $entry = $host->instance($ref);
        return ($host, defined $entry ? $entry->{seq} : undef);
    }
    elsif ('pos' eq $do) {
        my $entry = $host->instance($ref);
        return ($host, defined $entry ? $entry->{pos} : undef);
    }
    elsif ('inner' eq $do) {
        my $entry = $host->instance($ref);
        return ($host, (defined $entry && defined $entry->{inner})
            ? $entry->{inner}->list : undef);
    }
    elsif ('call' eq $do) { return docall($host, $cmd, $ref, $point) }
    else { die "unknown driver command: $do\n" }

    return ($host, $NOTHING);
}

sub docall {
    my ($host, $cmd, $ref, $point) = @_;
    my $entry = $host->instance($ref);
    die Voxgig::Plugin::Error->new('plugin_not_loaded', "no such instance: $ref")
        if !defined $entry;
    my $method = $cmd->{method} // '';

    if ('bump' eq $method) {
        $entry->{state}{count} = ($entry->{state}{count} // 0) + 1;
        return ($host, $NOTHING);
    }
    return ($host, $entry->{state}{count} // 0) if 'count' eq $method;
    return ($host, $entry->{state}{unwound} // []) if 'unwound' eq $method;
    # Reached through the instance api, which is where section 6.6 puts it
    # - a plugin asks about itself.
    return ($host, $host->positionof($ref, $point)) if 'position' eq $method;
    if ('stray' eq $method) {
        # A release from OUTSIDE a lifecycle callback. THIS BRANCH USED TO
        # DO NOTHING, and its corpus row stayed green whatever `release`
        # did with its guard.
        $host->exports("$ref/inst")->release(sub { return });
        return ($host, $NOTHING);
    }
    return ($host, $NOTHING);
}

1;

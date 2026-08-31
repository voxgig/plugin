<?php

/**
 * The driver (DOCS.md §4).
 *
 * Every port implements this same small thing and nothing else is
 * port-specific: the probe catalog, the command interpreter, and the
 * canonical observable.
 */

declare(strict_types=1);

namespace Voxgig\Plugin\Test;

use Voxgig\Plugin\Host;
use Voxgig\Plugin\Inst;
use Voxgig\Plugin\PluginError;
use Voxgig\Plugin\Util;

use function Voxgig\Plugin\make_catalog;
use function Voxgig\Plugin\make_host;

require_once __DIR__ . '/../src/plugin.php';

class Driver
{
    /**
     * A sentinel for "this command produced nothing", so a command that
     * legitimately produces null - `export` of a missing key - still
     * overwrites the previous result.
     */
    public static function nothing(): object
    {
        static $nothing = null;
        if (null === $nothing) {
            $nothing = new \stdClass();
        }
        return $nothing;
    }

    /**
     * §4.3's six probes. Their behaviour is as much the contract as the
     * runner is - this is where twenty implementations of `noisy` are made
     * to fail at the same callback in the same way.
     *
     * @return array<int,array<string,mixed>>
     */
    public static function probes(): array
    {
        $record = static function (string $name): array {
            return [
                'name' => $name,
                'define' => static function (Inst $i): void {
                    $i->state['count'] = $i->state['count'] ?? 0;
                },
                'activate' => static function (Inst $i): void {
                    $i->acquire();
                },
            ];
        };

        $probe = [
            'name' => 'probe',
            'define' => static function (Inst $i): void {
                $i->state['count'] = $i->state['count'] ?? 0;
                $band = $i->options()['band'] ?? null;
                // One hook binding (`p`) and one chain wrap (`c`) - the
                // workhorse shape DOCS.md §4.3 specifies.
                $i->bind('p', static function ($arg = null) use ($i): void {
                    $i->state['count'] = ($i->state['count'] ?? 0) + 1;
                }, $band);
                // Wrap AFTER next, so the result spells the nesting left
                // to right: outermost first. Wrapping the ARGUMENT instead
                // would spell it backwards and make every chain
                // expectation read wrong.
                $i->bind('c', static function ($nxt, $v) use ($i) {
                    return ($i->options()['wrap'] ?? ':') . $nxt($v);
                }, $band);
                $i->export('client', $i->ref);
                // The instance api itself, so the driver's `stray` command
                // can call `release` from OUTSIDE a lifecycle callback.
                $i->export('inst', $i);
                self::declareprovides($i);
            },
            'activate' => static function (Inst $i): void {
                $i->acquire();
                // §6.5: an instance that is itself a host. The outer owns
                // the inner's lifetime - registered in the scope, so it
                // closes on deactivate in the same reverse unwind as every
                // other resource.
                $nest = $i->options()['nest'] ?? null;
                if (null === $nest) {
                    return;
                }

                $inner = $i->nest(['points' => self::withpoints()]);
                foreach (self::probes() as $d) {
                    $inner->catalog->add($d);
                }
                foreach ($nest as $r) {
                    $inner->ready($r);
                }
            },
        ];

        $noisy = [
            'name' => 'noisy',
            'define' => static function (Inst $i): void {
                $i->state['count'] = $i->state['count'] ?? 0;
                self::boom($i, 'define');
            },
            'activate' => static function (Inst $i): void {
                // Acquire BEFORE the raise, so a failing activate has
                // something to leak if the scope does not unwind - which
                // is the whole point of the entry that asserts open == 0
                // afterwards.
                $i->acquire();
                self::reenter($i, 'activate');
                self::boom($i, 'activate');
            },
            'deactivate' => static function (Inst $i): void {
                self::boom($i, 'deactivate');
            },
            'close' => static function (Inst $i): void {
                self::boom($i, 'close');
            },
        ];

        $greedy = [
            'name' => 'greedy',
            'define' => static function (Inst $i): void {
                $i->state['count'] = 0;
                // §8.1 puts resource capture in `activate`. `early` NAMES
                // the call that reaches for it in `define`, because
                // `acquire` and `release` carry the guard separately.
                $early = $i->options()['early'] ?? null;
                if ('acquire' === $early) {
                    $i->acquire();
                }
                if ('release' === $early) {
                    $i->release(static function (): void {
                    });
                }
            },
            'activate' => static function (Inst $i): void {
                $opts = $i->options();
                $n = $opts['acquire'] ?? 0;
                $rel = $opts['release'] ?? 0;
                $handles = [];
                for ($k = 0; $k < $n; $k++) {
                    $handles[] = $i->acquire();
                }
                // Release some explicitly; the DIFFERENCE is what the
                // instance scope must unwind by itself (§8.3), and that
                // difference is the whole test.
                $take = min($rel, count($handles));
                for ($k = 0; $k < $take; $k++) {
                    ($handles[$k])();
                }

                // `bind` is `early`'s counterpart for §8.1's OTHER half.
                // Binding declaration belongs in `define`; this names the
                // callback that tries it from somewhere else.
                if ('activate' === ($opts['bind'] ?? null)) {
                    $i->bind('p', static function (...$a): void {
                    });
                }

                // `mark` registers N FOREIGN releases - §8.3's `release`,
                // the half `acquire` cannot exercise - each recording its
                // own index as it runs. THE RECORDED LIST IS THE ONLY
                // THING THAT DISTINGUISHES A REVERSE UNWIND FROM A FORWARD
                // ONE.
                $i->state['unwound'] = [];
                $markfail = Util::truthy($opts['markfail'] ?? null);
                $mark = $opts['mark'] ?? 0;
                for ($k = 0; $k < $mark; $k++) {
                    $i->release(static function () use ($i, $k, $markfail): void {
                        // `markfail` makes the release RAISE - the only
                        // way §8.3's `plugin_release_failed` and its
                        // `failed` status are reachable.
                        if ($markfail) {
                            throw new \RuntimeException('release failed at ' . $k);
                        }
                        $i->state['unwound'][] = $k;
                    });
                }
            },
            // `deactivate` completes the pair: the guard is on the PHASE,
            // not on "not define", and an entry exercising only one leaves
            // the other's mutation alive.
            'deactivate' => static function (Inst $i): void {
                if ('deactivate' === ($i->options()['bind'] ?? null)) {
                    $i->bind('p', static function (...$a): void {
                    });
                }
            },
        ];

        $dep = [
            'name' => 'dep',
            'define' => static function (Inst $i): void {
                $i->state['count'] = 0;
                self::declareprovides($i);
                $exports = $i->options()['exports'] ?? [];
                foreach (Util::sortedkeys($exports) as $k) {
                    $i->export($k, $exports[$k]);
                }
            },
            'activate' => static function (Inst $i): void {
                $i->acquire();
            },
        ];

        $provider = [
            'name' => 'provider',
            'define' => static function (Inst $i): void {
                $i->state['count'] = 0;
                $opts = $i->options();
                $point = $opts['point'] ?? 'v';
                $i->bind($point, static function (...$a) use ($i) {
                    $opts = $i->options();
                    return array_key_exists('value', $opts)
                        ? $opts['value'] : $i->ref;
                }, $opts['band'] ?? null);
                self::declareprovides($i);
            },
            'activate' => static function (Inst $i): void {
                $i->acquire();
            },
        ];

        return [$probe, $noisy, $greedy, $dep, $provider,
                $record('slow'), $record('other'), $record('adapter'),
                $record('late')];
    }

    public static function declareprovides(Inst $inst): void
    {
        foreach ($inst->options()['provides'] ?? [] as $p) {
            $inst->provides($p);
        }
    }

    public static function boom(Inst $inst, string $callback): void
    {
        $opts = $inst->options();
        if ($callback !== ($opts['fail'] ?? null)) {
            return;
        }

        // `bare` raises WITHOUT a code - the ordinary library error §12's
        // `plugin_<phase>_failed` codes exist to wrap.
        if (Util::truthy($opts['bare'] ?? null)) {
            throw new \RuntimeException('probe failed at ' . $callback);
        }

        throw new PluginError(
            $opts['code'] ?? ('plugin_' . $callback . '_failed'),
            'probe failed at ' . $callback
        );
    }

    public static function reenter(Inst $inst, string $callback): void
    {
        if ($callback !== ($inst->options()['reenter'] ?? null)) {
            return;
        }

        // A transition from inside a lifecycle callback (§5.2).
        $inst->host()->activate($inst->ref);
    }

    /**
     * The points every driver host declares. DOCS.md §4.3 defines `probe`
     * as binding one hook point (`p`) and wrapping one chain point (`c`),
     * so a host without them cannot load the probe at all - they are part
     * of the contract's baseline rather than a fixture convenience. `v` is
     * the provider point the `provider` probe defaults to.
     *
     * @return array<string,mixed>
     */
    public static function basepoints(): array
    {
        return [
            'p' => ['kind' => 'hook'],
            'c' => ['kind' => 'chain',
                    'base' => static function (...$a) {
                        return $a[0] ?? null;
                    }],
            'v' => ['kind' => 'provider'],
        ];
    }

    /**
     * @param array<string,mixed>|null $extra
     * @return array<string,mixed>
     */
    public static function withpoints(?array $extra = null): array
    {
        $out = self::basepoints();
        // A `host` command REPLACES a base point rather than merging into
        // it, so an entry can redeclare `c` with its own base or `v` as
        // exclusive without inheriting the default's shape.
        foreach ($extra ?? [] as $k => $v) {
            $out[$k] = $v;
        }
        return $out;
    }

    public static function withprobes()
    {
        return make_catalog(self::probes());
    }

    /**
     * Run a command list and return §4.5's observable. Stops at the first
     * raise; the entry's `err` matches its code.
     *
     * @param array<int,array<string,mixed>> $cmds
     * @return array<string,mixed>
     */
    public static function drive(array $cmds): array
    {
        $host = make_host(['catalog' => self::withprobes(),
                           'points' => self::withpoints()]);

        // §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES
        // ONE. Storing it and continuing - rather than returning at the
        // first producing command - is what lets an entry emit and then
        // inspect, which most of `point` needs.
        $last = null;

        foreach ($cmds as $cmd) {
            try {
                [$host, $value] = self::docmd($host, $cmd);
                if ($value !== self::nothing()) {
                    $last = $value;
                }
            } catch (\Throwable $e) {
                // §4.1: `catch` records the raise and lets the run
                // continue, which is the only way to observe a `failed`
                // instance - §5.2's whole claim is that it stays
                // registered and inspectable.
                if (true !== ($cmd['catch'] ?? null)) {
                    throw $e;
                }
            }
        }
        return $host->observable($last);
    }

    /**
     * @param array<string,mixed> $cmd
     * @return array{0:Host,1:mixed}
     */
    public static function docmd(Host $host, array $cmd): array
    {
        $ref = $cmd['ref'] ?? null;
        $point = $cmd['point'] ?? null;
        $spec = ['options' => $cmd['options'] ?? null,
                 'order' => $cmd['order'] ?? null,
                 'definition' => $cmd['definition'] ?? null,
                 'tag' => $cmd['tag'] ?? null];

        switch ($cmd['do']) {
            case 'host':
                return [make_host(
                    ['catalog' => self::withprobes(),
                     'reserved' => $cmd['reserved'] ?? null,
                     'keys' => $cmd['keys'] ?? null,
                     'defaults' => $cmd['defaults'] ?? null,
                     'profile' => $cmd['profile'] ?? null,
                     'points' => self::withpoints($cmd['points'] ?? null),
                     // §11.3's strict reading. Absent means `restart`.
                     'dependency' => $cmd['dependency'] ?? null]
                ), self::nothing()];

            case 'define':
                // The catalog is pre-seeded with the probe set; `define`
                // names which entry backs this definition.
                return [$host, self::nothing()];

            case 'load':
                $host->load($ref, $spec);
                break;

            case 'ready':
                // declare FIRST, so the ordering block and definition
                // reach the instance - `ready` walks the staircase, it
                // does not carry configuration of its own.
                $host->declare($ref, $spec);
                $host->ready($ref);
                break;

            case 'activate':
                $host->activate($ref);
                break;

            case 'deactivate':
                $host->deactivate($ref);
                break;

            case 'unload':
                $host->unload($ref);
                break;

            case 'apply':
                $host->apply($cmd['doc'] ?? null, $cmd['profile'] ?? null);
                break;

            case 'options':
                $host->options($ref, $cmd['patch'] ?? null);
                break;

            case 'close':
                $host->close();
                break;

            case 'list':
                return [$host, $host->list()];

            case 'emit':
                return [$host, $host->emit($point, $cmd['arg'] ?? null)];

            case 'chain':
                return [$host, $host->call($point, $cmd['arg'] ?? null)];

            case 'provider':
                return [$host, $host->provider($point, $cmd['arg'] ?? null)];

            case 'shadowed':
                return [$host, $host->shadowed($point)];

            case 'export':
                return [$host, $host->exports($cmd['key'] ?? '')];

            case 'capability':
                return [$host, $host->capability($cmd['name'] ?? '')];

            case 'trace':
                return [$host, $host->trace()];

            case 'hostdeclare':
                // §9.1's host-owned path: the embedding host installing
                // the instance whose name it reserved.
                return [$host, $host->hostdeclare($ref, $spec)->ref];

            case 'declare':
                return [$host, $host->declare($ref, $spec)->ref];

            case 'order':
                return [$host, $host->order($point)];

            case 'seq':
                $entry = $host->instance($ref);
                return [$host, null === $entry ? null : $entry->seq];

            case 'pos':
                $entry = $host->instance($ref);
                return [$host, null === $entry ? null : $entry->pos];

            case 'inner':
                $entry = $host->instance($ref);
                return [$host, null === $entry || null === $entry->inner
                    ? null : $entry->inner->list()];

            case 'call':
                return self::docall($host, $cmd, $ref, $point);

            default:
                throw new \RuntimeException('unknown driver command: ' . $cmd['do']);
        }

        return [$host, self::nothing()];
    }

    /**
     * @param array<string,mixed> $cmd
     * @return array{0:Host,1:mixed}
     */
    public static function docall(Host $host, array $cmd, $ref, $point): array
    {
        $entry = $host->instance($ref);
        if (null === $entry) {
            throw new PluginError('plugin_not_loaded', 'no such instance: ' . $ref);
        }
        switch ($cmd['method'] ?? null) {
            case 'bump':
                $entry->state['count'] = ($entry->state['count'] ?? 0) + 1;
                return [$host, self::nothing()];

            case 'count':
                return [$host, $entry->state['count'] ?? 0];

            case 'unwound':
                return [$host, $entry->state['unwound'] ?? []];

            case 'position':
                // Reached through the instance api, which is where §6.6
                // puts it - a plugin asks about itself.
                return [$host, $host->positionof($ref, $point)];

            case 'stray':
                // A release from OUTSIDE a lifecycle callback. THIS BRANCH
                // USED TO DO NOTHING, and its corpus row stayed green
                // whatever `release` did with its guard.
                $inst = $host->exports($ref . '/inst');
                $inst->release(static function (): void {
                });
                return [$host, self::nothing()];

            default:
                return [$host, self::nothing()];
        }
    }
}

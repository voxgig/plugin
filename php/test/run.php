<?php

/**
 * The whole suite: pure sections by direct call, driver sections by
 * command list, and a coverage guard above both.
 *
 * A plain runner rather than PHPUnit, for the same reason the port has no
 * composer manifest: a conformance suite whose only job is to run one
 * corpus and report which entries disagree does not need a framework, and
 * adding one would make `make test` depend on a vendor tree nobody else in
 * this repo has.
 */

declare(strict_types=1);

namespace Voxgig\Plugin\Test;

use function Voxgig\Plugin\apply_env;
use function Voxgig\Plugin\canon_ref;
use function Voxgig\Plugin\check_name;
use function Voxgig\Plugin\check_tag;
use function Voxgig\Plugin\format_ref;
use function Voxgig\Plugin\normalize_config;
use function Voxgig\Plugin\parse_range;
use function Voxgig\Plugin\parse_ref;
use function Voxgig\Plugin\resolve_candidates;
use function Voxgig\Plugin\resolve_capability;
use function Voxgig\Plugin\resolve_from;
use function Voxgig\Plugin\resolve_graph;
use function Voxgig\Plugin\resolve_options;
use function Voxgig\Plugin\satisfies;

require_once __DIR__ . '/../src/plugin.php';
require_once __DIR__ . '/corpus.php';
require_once __DIR__ . '/driver.php';

// A PHP notice is a failure here, not a footnote: reading an absent index
// yields null and the corpus then disagrees three functions away.
set_error_handler(static function (int $no, string $msg, string $file, int $line): bool {
    throw new \ErrorException($msg, 0, $no, $file, $line);
});

$FAILURES = [];
$RAN = ['sections' => 0, 'entries' => 0];

function report(string $name, string $group, int $i, array $entry, string $why): void
{
    global $FAILURES;
    $FAILURES[] = $name . '/' . Corpus::label($group, $i, $entry) . ': ' . $why;
}

/**
 * Dispatch every group, and fail on a group the runner does not know - a
 * group silently not run is worse than a failure.
 *
 * @param array<string,callable> $subject
 */
function run_section(string $name, array $subject): void
{
    global $FAILURES, $RAN;
    $groups = Corpus::section($name);
    $RAN['sections']++;
    $names = array_keys($groups);
    sort($names, SORT_STRING);
    foreach ($names as $group) {
        $fn = $subject[$group] ?? null;
        if (null === $fn) {
            $FAILURES[] = $name . ': corpus group with no subject: ' . $group;
            continue;
        }
        foreach ($groups[$group] as $i => $entry) {
            $RAN['entries']++;
            $why = Corpus::check($entry, $fn);
            if (null !== $why) {
                report($name, $group, $i, $entry, $why);
            }
        }
    }
}

// ---- pure sections --------------------------------------------------

$parse = static function (array $e) {
    return parse_ref($e['in'] ?? null);
};
$format = static function (array $e) {
    $args = $e['args'] ?? [];
    return format_ref($args[0] ?? null, $args[1] ?? null);
};
$name = static function (array $e) {
    return check_name($e['in'] ?? null);
};
$tag = static function (array $e) {
    return check_tag($e['in'] ?? null);
};
run_section('ref', [
    'parse' => $parse,
    'parsebad' => $parse,
    'format' => $format,
    'formatbad' => $format,
    'canon' => static function (array $e) {
        return canon_ref($e['in'] ?? null);
    },
    'name' => $name,
    'tag' => $tag,
    'bound' => $name,
    'boundtag' => $tag,
]);

$env = static function (array $e) {
    return apply_env($e['in'] ?? null);
};
run_section('env', [
    'option' => $env, 'value' => $env, 'toggle' => $env,
    'profile' => $env, 'ambiguous' => $env, 'reserved' => $env,
]);

$rng = static function (array $e) {
    return parse_range($e['in'] ?? null);
};
run_section('version', [
    'range' => $rng, 'rangebad' => $rng,
    'satisfies' => static function (array $e) {
        return satisfies($e['in']['version'] ?? null, $e['in']['range'] ?? null);
    },
]);

$cap = static function (array $e) {
    return resolve_capability($e['in']['req'], $e['in']['candidates']);
};
run_section('capability', ['match' => $cap, 'nested' => $cap, 'rank' => $cap]);

$graph = static function (array $e) {
    return resolve_graph($e['in']);
};
run_section('graph', ['resolve' => $graph, 'blocked' => $graph]);

run_section('resolve', [
    'candidates' => static function (array $e) {
        return resolve_candidates($e['in']['name'], $e['in']['sources'] ?? null);
    },
    'from' => static function (array $e) {
        return resolve_from($e['in']);
    },
]);

// `config` picks its subject by group PREFIX rather than by name, because
// the two functions split the section cleanly.
$configgroups = Corpus::section('config');
$RAN['sections']++;
$confignames = array_keys($configgroups);
sort($confignames, SORT_STRING);
foreach ($confignames as $group) {
    $fn = null;
    if (str_starts_with($group, 'norm')) {
        $fn = static function (array $e) {
            return normalize_config($e['in'] ?? null);
        };
    } elseif (str_starts_with($group, 'opt')) {
        $fn = static function (array $e) {
            return resolve_options($e['in'] ?? []);
        };
    }
    if (null === $fn) {
        $FAILURES[] = 'config: corpus group with no subject: ' . $group;
        continue;
    }
    foreach ($configgroups[$group] as $i => $entry) {
        $RAN['entries']++;
        $why = Corpus::check($entry, $fn);
        if (null !== $why) {
            report('config', $group, $i, $entry, $why);
        }
    }
}

// ---- driver sections ------------------------------------------------

const DRIVER_SECTIONS = [
    'lifecycle', 'order', 'point', 'export', 'depend',
    'declare', 'state', 'resource', 'nest', 'trace', 'apply', 'error',
];

foreach (DRIVER_SECTIONS as $section) {
    $groups = Corpus::section($section);
    $RAN['sections']++;
    $names = array_keys($groups);
    sort($names, SORT_STRING);
    foreach ($names as $group) {
        foreach ($groups[$group] as $i => $entry) {
            $RAN['entries']++;
            if (!is_array($entry['cmd'] ?? null)) {
                report($section, $group, $i, $entry, 'driver entry without cmd');
                continue;
            }
            $why = Corpus::check($entry, static function (array $e) {
                return Driver::drive($e['cmd']);
            });
            if (null !== $why) {
                report($section, $group, $i, $entry, $why);
            }
        }
    }
}

// ---- coverage -------------------------------------------------------
//
// EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails on a
// GROUP with no subject; this closes the level above, because a whole
// SECTION the runner never mentions is a section silently not run.

const PURE_SECTIONS = ['ref', 'env', 'version', 'capability', 'graph',
                       'resolve', 'config'];

$spec = Corpus::corpus();
$primary = $spec['primary'] ?? [];

// The corpus metadata block is what turns on strict entry validation in
// every runner, so a corpus that lost it must not silently downgrade this
// port's checking.
if (1 !== (($spec['PLUGIN'] ?? [])['version'] ?? null)) {
    $FAILURES[] = 'corpus PLUGIN.version must be 1';
}

$run = array_merge(PURE_SECTIONS, DRIVER_SECTIONS);
$missing = [];
foreach (array_keys($primary) as $n) {
    if (!in_array($n, $run, true)) {
        $missing[] = $n;
    }
}
sort($missing, SORT_STRING);
if (!empty($missing)) {
    $FAILURES[] = 'corpus sections no test runs: ' . implode(', ', $missing);
}
$extra = [];
foreach ($run as $n) {
    if (!array_key_exists($n, $primary)) {
        $extra[] = $n;
    }
}
sort($extra, SORT_STRING);
if (!empty($extra)) {
    $FAILURES[] = 'tests name sections the corpus does not have: '
        . implode(', ', $extra);
}

// A floor, not a fixture: the corpus grows, and a run that suddenly covers
// a fraction of it is the failure worth catching.
if ($RAN['entries'] < 400) {
    $FAILURES[] = 'only ' . $RAN['entries'] . ' corpus entries reachable';
}

// ---- report ---------------------------------------------------------

if (empty($FAILURES)) {
    echo 'php: ' . $RAN['entries'] . ' corpus entries across '
        . $RAN['sections'] . " sections, all pass\n";
    exit(0);
}

foreach ($FAILURES as $f) {
    fwrite(STDERR, $f . "\n");
}
fwrite(STDERR, "\nphp: " . count($FAILURES) . ' failure(s) of '
    . $RAN['entries'] . " entries\n");
exit(1);

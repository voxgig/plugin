<?php

/**
 * The corpus runner.
 *
 * Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
 * exactly as every other port's runner does. No port needs a Node
 * toolchain to run its tests, and this one does not get a private door
 * into the source either.
 *
 * A group name selects the subject. That is the whole dispatch, and it is
 * deliberately dumb: a runner that inferred the subject from the entry's
 * shape would silently run the wrong function when an entry was mistyped.
 */

declare(strict_types=1);

namespace Voxgig\Plugin\Test;

use Voxgig\Plugin\PluginError;

use function Voxgig\Plugin\codeof;
use function Voxgig\Plugin\samescalar;

require_once __DIR__ . '/../src/plugin.php';

class Corpus
{
    public const SPEC = __DIR__ . '/../../spec/plugin.json';

    /** @var array<string,mixed>|null */
    private static ?array $cache = null;

    /**
     * A sentinel for "this key was not present". PHP's `??` collapses an
     * absent key and a JSON null, and `__UNDEF__` and `__NULL__` are
     * different assertions.
     */
    public static function missing(): object
    {
        static $missing = null;
        if (null === $missing) {
            $missing = new \stdClass();
        }
        return $missing;
    }

    /** @return array<string,mixed> */
    public static function corpus(): array
    {
        if (null === self::$cache) {
            $text = file_get_contents(self::SPEC);
            if (false === $text) {
                throw new \RuntimeException('cannot read ' . self::SPEC);
            }
            $parsed = json_decode($text, true);
            if (!is_array($parsed)) {
                throw new \RuntimeException('cannot parse ' . self::SPEC);
            }
            self::$cache = $parsed;
        }
        return self::$cache;
    }

    /** @return array<string,array<int,array<string,mixed>>> */
    public static function section(string $name): array
    {
        $spec = self::corpus();
        $sec = ($spec['primary'] ?? [])[$name] ?? null;
        if (null === $sec) {
            throw new \RuntimeException('no such corpus section: ' . $name);
        }

        $out = [];
        foreach ($sec as $group => $body) {
            if ('DEF' === $group) {
                continue;
            }
            if (!is_array($body) || !is_array($body['set'] ?? null)) {
                continue;
            }
            $out[$group] = $body['set'];
        }
        return $out;
    }

    /** A stable label, so a failure names the entry rather than an index. */
    public static function label(string $group, int $i, array $entry): string
    {
        return $entry['id'] ?? ($group . '#' . $i);
    }

    /**
     * Deep equality over spec values. Key order never matters; list order
     * always does - and a PHP list IS a map with keys 0..n-1, so one walk
     * covers both.
     *
     * AN EMPTY MAP AND AN EMPTY LIST ARE THE SAME VALUE HERE, because PHP
     * has one array type and cannot tell them apart (php/AGENTS.md). It is
     * the only corpus distinction this port cannot see, and it can only
     * ever make a passing entry pass for a slightly weaker reason - never
     * make a failing one pass, since every non-empty shape still differs.
     *
     * @param mixed $a
     * @param mixed $b
     */
    public static function same($a, $b): bool
    {
        if (is_array($a) && is_array($b)) {
            if (count($a) !== count($b)) {
                return false;
            }
            foreach ($a as $k => $v) {
                if (!array_key_exists($k, $b) || !self::same($v, $b[$k])) {
                    return false;
                }
            }
            return true;
        }
        if (is_array($a) || is_array($b)) {
            return false;
        }
        // Type-strict on booleans and null, numeric across int and float:
        // `true == 1` is true in PHP and `1 === 1.0` is false, and JSON
        // agrees with neither.
        return samescalar($a, $b);
    }

    /**
     * Partial match: every key the expectation names must agree, and keys
     * it does not name are ignored. `__EXISTS__` asserts presence without
     * pinning a value; `/re/` matches a string as a regular expression.
     *
     * @param mixed $expect
     * @param mixed $actual
     */
    public static function matches($expect, $actual): bool
    {
        $missing = self::missing();

        if ('__EXISTS__' === $expect) {
            return $actual !== $missing && null !== $actual;
        }
        if ('__UNDEF__' === $expect) {
            return $actual === $missing;
        }
        if ('__NULL__' === $expect) {
            return $actual !== $missing && null === $actual;
        }

        if ($actual === $missing) {
            $actual = null;
        }

        if (is_string($expect) && strlen($expect) > 2
            && str_starts_with($expect, '/') && str_ends_with($expect, '/')) {
            if (!is_string($actual)) {
                return false;
            }
            // The body is used verbatim between PCRE delimiters. Every `/`
            // the corpus writes inside one is already escaped (the corpus
            // authors them as javascript regex literals), so re-escaping
            // here would turn an escaped slash into an escaped backslash
            // and end the pattern early.
            $re = '/' . substr($expect, 1, -1) . '/';
            return 1 === preg_match($re, $actual);
        }

        if (is_array($expect)) {
            if (!is_array($actual)) {
                return false;
            }
            if (array_is_list($expect) && [] !== $expect) {
                if (!array_is_list($actual) || count($expect) !== count($actual)) {
                    return false;
                }
                foreach ($expect as $i => $v) {
                    if (!self::matches($v, $actual[$i])) {
                        return false;
                    }
                }
                return true;
            }
            foreach ($expect as $k => $v) {
                $got = array_key_exists($k, $actual) ? $actual[$k] : $missing;
                if (!self::matches($v, $got)) {
                    return false;
                }
            }
            return true;
        }

        return samescalar($expect, $actual);
    }

    /**
     * Run one entry against a subject and report the disagreement, if any.
     *
     * The three combinations the spec format allows are enforced here as
     * well as at build time, because a runner that quietly accepted `err`
     * beside `out` would let a contradictory entry pass.
     *
     * @param array<string,mixed> $entry
     */
    public static function check(array $entry, callable $subject): ?string
    {
        if (array_key_exists('err', $entry) && array_key_exists('out', $entry)) {
            return 'entry has both err and out';
        }

        $value = null;
        $raised = null;
        try {
            $value = $subject($entry);
        } catch (\Throwable $e) {
            $raised = $e;
        }

        if (array_key_exists('err', $entry)) {
            if (null === $raised) {
                return 'expected a raise, got: ' . self::json($value);
            }

            if (true !== $entry['err']) {
                // Errors compare by CODE (§12). Message wording is a
                // port's own business, and pinning it would make every
                // translation a corpus change.
                $got = codeof($raised);
                if ($got !== $entry['err']) {
                    return 'expected code ' . $entry['err'] . ', got ' . $got
                        . ' (' . $raised->getMessage() . ')';
                }
            }
            if (array_key_exists('match', $entry)) {
                $got = ['err' => ['code' => codeof($raised),
                                  'message' => $raised->getMessage(),
                                  'name' => 'PluginError']];
                if (!self::matches($entry['match'], $got)) {
                    return 'error did not match ' . self::json($entry['match'])
                        . ', got ' . self::json($got);
                }
            }
            return null;
        }

        if (null !== $raised) {
            return 'unexpected raise: ' . codeof($raised) . ' '
                . $raised->getMessage();
        }

        if (array_key_exists('out', $entry) && !self::same($entry['out'], $value)) {
            return 'expected ' . self::json($entry['out']) . ', got '
                . self::json($value);
        }

        if (array_key_exists('match', $entry)) {
            $got = ['in' => $entry['in'] ?? null, 'out' => $value];
            if (!self::matches($entry['match'], $got)) {
                return 'did not match ' . self::json($entry['match'])
                    . ', got out=' . self::json($value);
            }
        }

        if (!array_key_exists('out', $entry) && !array_key_exists('match', $entry)) {
            return 'entry asserts nothing';
        }

        return null;
    }

    /** @param mixed $value */
    public static function json($value): string
    {
        $out = json_encode($value, JSON_UNESCAPED_SLASHES | JSON_PARTIAL_OUTPUT_ON_ERROR);
        return false === $out ? '<unencodable>' : $out;
    }
}

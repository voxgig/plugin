//! The corpus runner.
//!
//! Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
//! exactly as every other port's runner does. No port needs a Node
//! toolchain to run its tests, and this one does not get a private door
//! into the source either.

pub mod driver;

use voxgig_plugin::types::{codeof, PluginError};
use voxgig_plugin::value::{self, Value};

pub const SPEC: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../spec/plugin.json");

pub fn corpus() -> Value {
    let text = std::fs::read_to_string(SPEC).expect("cannot read spec/plugin.json");
    value::parse(&text).expect("cannot parse spec/plugin.json")
}

/// The groups of a section, minus `DEF`.
pub fn section(spec: &Value, name: &str) -> Vec<(String, Vec<Value>)> {
    let sec = spec.get("primary").get(name);
    assert!(!sec.is_null(), "no such corpus section: {}", name);
    let mut out = Vec::new();
    for group in sec.keys() {
        if "DEF" == group {
            continue;
        }
        let body = sec.get(&group);
        match body.get("set") {
            Value::List(set) => out.push((group, set)),
            _ => continue,
        }
    }
    out
}

/// A stable label, so a failure names the entry rather than an index.
pub fn label(group: &str, i: usize, entry: &Value) -> String {
    match entry.get("id").as_str() {
        Some(id) => id.to_string(),
        None => format!("{}#{}", group, i),
    }
}

/// A sentinel for "this key was not present". `Value::get` returns `Null`
/// for both an absent key and a JSON null, and `__UNDEF__` and `__NULL__`
/// are different assertions.
pub enum Got {
    Missing,
    Present(Value),
}

/// Deep equality over spec values. Key order never matters; list order
/// always does.
///
/// AGENTS.md section 1: "The plugin library must never be used to implement
/// its own tests." A shared comparison lets a broken implementation and its
/// oracle be wrong together and stay green, so the corpus's equality is
/// written here rather than imported.
pub fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Null, Value::Null) => true,
        (Value::Bool(x), Value::Bool(y)) => x == y,
        (Value::Num(x), Value::Num(y)) => x == y,
        (Value::Str(x), Value::Str(y)) => x == y,
        (Value::List(x), Value::List(y)) => {
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(p, q)| same(p, q))
        }
        (Value::Map(x), Value::Map(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).map(|o| same(v, o)).unwrap_or(false))
        }
        _ => false,
    }
}

/// Partial match: every key the expectation names must agree, and keys it
/// does not name are ignored. `__EXISTS__` asserts presence without
/// pinning a value; `/re/` matches a string as a regular expression.
pub fn matches(expect: &Value, actual: &Got) -> bool {
    if let Some(sentinel) = expect.as_str() {
        match sentinel {
            "__EXISTS__" => {
                return matches!(actual, Got::Present(v) if !v.is_null());
            }
            "__UNDEF__" => return matches!(actual, Got::Missing),
            "__NULL__" => {
                return matches!(actual, Got::Present(v) if v.is_null());
            }
            _ => {}
        }
    }

    let actual = match actual {
        Got::Missing => Value::Null,
        Got::Present(v) => v.clone(),
    };

    if let Some(pattern) = expect.as_str() {
        if 2 < pattern.len() && pattern.starts_with('/') && pattern.ends_with('/') {
            let text = match actual.as_str() {
                Some(t) => t,
                None => return false,
            };
            return regex_lite(&pattern[1..pattern.len() - 1], text);
        }
    }

    if let Value::List(want) = expect {
        let got = match actual.as_list() {
            Some(l) => l.clone(),
            None => return false,
        };
        return want.len() == got.len()
            && want
                .iter()
                .zip(got.iter())
                .all(|(w, g)| matches(w, &Got::Present(g.clone())));
    }

    if let Value::Map(want) = expect {
        if actual.as_map().is_none() {
            return false;
        }
        return want.iter().all(|(k, w)| {
            let got = if actual.has(k) {
                Got::Present(actual.get(k))
            } else {
                Got::Missing
            };
            matches(w, &got)
        });
    }

    same(expect, &actual)
}

/// A LITERAL-WITH-ANCHORS MATCHER, NOT A REGEX ENGINE.
///
/// The standard library has no regex and §16 permits no crate to supply
/// one. Every pattern the corpus writes is a literal, optionally anchored:
/// `/^plugin\/plugin_not_loaded: /`, `/cycle=\[/`, `/retry\$fast/`. So
/// this unescapes and compares - and PANICS on any unescaped
/// metacharacter, because the one thing a hand-rolled matcher must never
/// do is quietly report a mismatch it could not evaluate.
pub fn regex_lite(pattern: &str, text: &str) -> bool {
    let chars: Vec<char> = pattern.chars().collect();
    let mut literal = String::new();
    let mut anchored_start = false;
    let mut anchored_end = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if '\\' == c {
            if i + 1 < chars.len() {
                literal.push(chars[i + 1]);
                i += 2;
                continue;
            }
            panic!("corpus regex ends in a backslash: {}", pattern);
        }
        if '^' == c && 0 == i {
            anchored_start = true;
            i += 1;
            continue;
        }
        if '$' == c && i + 1 == chars.len() {
            anchored_end = true;
            i += 1;
            continue;
        }
        assert!(
            !"*+?()[]{}|.".contains(c),
            "corpus regex needs a real engine, which this port does not have: {}",
            pattern
        );
        literal.push(c);
        i += 1;
    }

    match (anchored_start, anchored_end) {
        (true, true) => text == literal,
        (true, false) => text.starts_with(&literal),
        (false, true) => text.ends_with(&literal),
        (false, false) => text.contains(&literal),
    }
}

/// Run one entry against a subject and report the disagreement, if any.
///
/// The three combinations the spec format allows are enforced here as well
/// as at build time, because a runner that quietly accepted `err` beside
/// `out` would let a contradictory entry pass.
pub fn check<F>(entry: &Value, subject: F) -> Option<String>
where
    F: FnOnce(&Value) -> Result<Value, PluginError>,
{
    if entry.has("err") && entry.has("out") {
        return Some("entry has both err and out".to_string());
    }

    let outcome = subject(entry);

    if entry.has("err") {
        let raised = match outcome {
            Ok(v) => return Some(format!("expected a raise, got: {}", v.json())),
            Err(e) => e,
        };

        let want = entry.get("err");
        if !matches!(want, Value::Bool(true)) {
            // Errors compare by CODE (§12). Message wording is a port's
            // own business, and pinning it would make every translation a
            // corpus change.
            let got = codeof(&raised);
            if Some(got) != want.as_str() {
                return Some(format!(
                    "expected code {}, got {} ({})",
                    want.json(),
                    got,
                    raised.message
                ));
            }
        }
        if entry.has("match") {
            let mut err = Value::map();
            err.set("code", Value::str(&raised.code));
            err.set("message", Value::str(&raised.message));
            err.set("name", Value::str("PluginError"));
            let mut got = Value::map();
            got.set("err", err);
            if !matches(&entry.get("match"), &Got::Present(got.clone())) {
                return Some(format!(
                    "error did not match {}, got {}",
                    entry.get("match").json(),
                    got.json()
                ));
            }
        }
        return None;
    }

    let value = match outcome {
        Ok(v) => v,
        Err(e) => {
            return Some(format!("unexpected raise: {} {}", e.code, e.message));
        }
    };

    if entry.has("out") && !same(&entry.get("out"), &value) {
        return Some(format!(
            "expected {}, got {}",
            entry.get("out").json(),
            value.json()
        ));
    }

    if entry.has("match") {
        let mut got = Value::map();
        got.set("in", entry.get("in"));
        got.set("out", value.clone());
        if !matches(&entry.get("match"), &Got::Present(got)) {
            return Some(format!(
                "did not match {}, got out={}",
                entry.get("match").json(),
                value.json()
            ));
        }
    }

    if !entry.has("out") && !entry.has("match") {
        return Some("entry asserts nothing".to_string());
    }

    None
}

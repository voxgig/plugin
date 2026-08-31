//! The whole suite: pure sections by direct call, driver sections by
//! command list, and a coverage guard above both.
//!
//! One `#[test]`, not one per section, for the same reason the other ports
//! have a plain runner: a conformance suite whose only job is to run one
//! corpus and report which entries disagree does not need a framework
//! around it, and 539 separate test cases would bury the one line that
//! says which entry is wrong.

mod support;

use support::driver::drive;
use support::{check, corpus, label, section};

use voxgig_plugin::config::{normalize_config, resolve_options};
use voxgig_plugin::env::apply_env;
use voxgig_plugin::graph::resolve_graph;
use voxgig_plugin::refs::{canon_ref, check_name, check_tag, format_ref, parse_ref};
use voxgig_plugin::resolve::{resolve_candidates, resolve_from};
use voxgig_plugin::types::PluginError;
use voxgig_plugin::value::Value;
use voxgig_plugin::version::{parse_range, satisfies};
use voxgig_plugin::capability::resolve_capability;

type Subject = fn(&Value) -> Result<Value, PluginError>;

const PURE_SECTIONS: [&str; 7] = [
    "ref", "env", "version", "capability", "graph", "resolve", "config",
];

const DRIVER_SECTIONS: [&str; 12] = [
    "lifecycle", "order", "point", "export", "depend", "declare", "state", "resource", "nest",
    "trace", "apply", "error",
];

struct Run {
    failures: Vec<String>,
    sections: usize,
    entries: usize,
}

impl Run {
    /// Dispatch every group, and fail on a group the runner does not know
    /// - a group silently not run is worse than a failure.
    fn section(&mut self, spec: &Value, name: &str, subjects: &[(&str, Subject)]) {
        self.sections += 1;
        for (group, set) in section(spec, name) {
            let subject = subjects.iter().find(|(g, _)| *g == group).map(|(_, f)| *f);
            let subject = match subject {
                Some(f) => f,
                None => {
                    self.failures
                        .push(format!("{}: corpus group with no subject: {}", name, group));
                    continue;
                }
            };
            for (i, entry) in set.iter().enumerate() {
                self.entries += 1;
                if let Some(why) = check(entry, subject) {
                    self.failures
                        .push(format!("{}/{}: {}", name, label(&group, i, entry), why));
                }
            }
        }
    }
}

// -- the pure subjects ------------------------------------------------

fn s_parse(e: &Value) -> Result<Value, PluginError> {
    parse_ref(&e.get("in"))
}
fn s_format(e: &Value) -> Result<Value, PluginError> {
    let args = e.get("args");
    format_ref(&args.at(0), &args.at(1)).map(|s| Value::Str(s))
}
fn s_canon(e: &Value) -> Result<Value, PluginError> {
    canon_ref(&e.get("in")).map(Value::Str)
}
fn s_name(e: &Value) -> Result<Value, PluginError> {
    Ok(Value::Bool(check_name(&e.get("in"))))
}
fn s_tag(e: &Value) -> Result<Value, PluginError> {
    Ok(Value::Bool(check_tag(&e.get("in"))))
}
fn s_env(e: &Value) -> Result<Value, PluginError> {
    apply_env(&e.get("in"))
}
fn s_range(e: &Value) -> Result<Value, PluginError> {
    parse_range(&e.get("in"))
}
fn s_satisfies(e: &Value) -> Result<Value, PluginError> {
    let input = e.get("in");
    satisfies(&input.get("version"), &input.get("range")).map(Value::Bool)
}
fn s_capability(e: &Value) -> Result<Value, PluginError> {
    let input = e.get("in");
    let cands = input.get("candidates");
    let cands = cands.as_list().cloned().unwrap_or_default();
    Ok(Value::List(resolve_capability(&input.get("req"), &cands)))
}
fn s_graph(e: &Value) -> Result<Value, PluginError> {
    Ok(resolve_graph(&e.get("in")))
}
fn s_candidates(e: &Value) -> Result<Value, PluginError> {
    let input = e.get("in");
    let name = input.get("name");
    Ok(Value::List(
        resolve_candidates(name.as_str().unwrap_or(""), &input.get("sources"))
            .iter()
            .map(|c| Value::str(c))
            .collect(),
    ))
}
fn s_from(e: &Value) -> Result<Value, PluginError> {
    Ok(Value::List(resolve_from(&e.get("in"))))
}
fn s_norm(e: &Value) -> Result<Value, PluginError> {
    normalize_config(&e.get("in"))
}
fn s_opts(e: &Value) -> Result<Value, PluginError> {
    resolve_options(&e.get("in"))
}
fn s_drive(e: &Value) -> Result<Value, PluginError> {
    drive(&e.get("cmd"))
}

#[test]
fn corpus_conformance() {
    let spec = corpus();
    let mut run = Run {
        failures: Vec::new(),
        sections: 0,
        entries: 0,
    };

    run.section(
        &spec,
        "ref",
        &[
            ("parse", s_parse),
            ("parsebad", s_parse),
            ("format", s_format),
            ("formatbad", s_format),
            ("canon", s_canon),
            ("name", s_name),
            ("tag", s_tag),
            ("bound", s_name),
            ("boundtag", s_tag),
        ],
    );

    run.section(
        &spec,
        "env",
        &[
            ("option", s_env),
            ("value", s_env),
            ("toggle", s_env),
            ("profile", s_env),
            ("ambiguous", s_env),
            ("reserved", s_env),
        ],
    );

    run.section(
        &spec,
        "version",
        &[
            ("range", s_range),
            ("rangebad", s_range),
            ("satisfies", s_satisfies),
        ],
    );

    run.section(
        &spec,
        "capability",
        &[
            ("match", s_capability),
            ("nested", s_capability),
            ("rank", s_capability),
        ],
    );

    run.section(&spec, "graph", &[("resolve", s_graph), ("blocked", s_graph)]);

    run.section(
        &spec,
        "resolve",
        &[("candidates", s_candidates), ("from", s_from)],
    );

    // `config` picks its subject by group PREFIX rather than by name,
    // because the two functions split the section cleanly.
    run.sections += 1;
    for (group, set) in section(&spec, "config") {
        let subject: Subject = if group.starts_with("norm") {
            s_norm
        } else if group.starts_with("opt") {
            s_opts
        } else {
            run.failures
                .push(format!("config: corpus group with no subject: {}", group));
            continue;
        };
        for (i, entry) in set.iter().enumerate() {
            run.entries += 1;
            if let Some(why) = check(entry, subject) {
                run.failures
                    .push(format!("config/{}: {}", label(&group, i, entry), why));
            }
        }
    }

    // -- driver sections ----------------------------------------------

    for name in DRIVER_SECTIONS.iter() {
        run.sections += 1;
        for (group, set) in section(&spec, name) {
            for (i, entry) in set.iter().enumerate() {
                run.entries += 1;
                if entry.get("cmd").as_list().is_none() {
                    run.failures.push(format!(
                        "{}/{}: driver entry without cmd",
                        name,
                        label(&group, i, entry)
                    ));
                    continue;
                }
                if let Some(why) = check(entry, s_drive) {
                    run.failures
                        .push(format!("{}/{}: {}", name, label(&group, i, entry), why));
                }
            }
        }
    }

    // -- coverage ------------------------------------------------------
    //
    // EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails
    // on a GROUP with no subject; this closes the level above, because a
    // whole SECTION the runner never mentions is a section silently not
    // run.

    let primary = spec.get("primary");

    // The corpus metadata block is what turns on strict entry validation
    // in every runner, so a corpus that lost it must not silently
    // downgrade this port's checking.
    if spec.get("PLUGIN").get("version").as_num() != Some(1.0) {
        run.failures.push("corpus PLUGIN.version must be 1".to_string());
    }

    let mut ran: Vec<&str> = PURE_SECTIONS.to_vec();
    ran.extend(DRIVER_SECTIONS.iter());
    let missing: Vec<String> = primary
        .keys()
        .into_iter()
        .filter(|n| !ran.contains(&n.as_str()))
        .collect();
    if !missing.is_empty() {
        run.failures
            .push(format!("corpus sections no test runs: {}", missing.join(", ")));
    }
    let extra: Vec<&str> = ran
        .iter()
        .filter(|n| !primary.has(n))
        .cloned()
        .collect();
    if !extra.is_empty() {
        run.failures.push(format!(
            "tests name sections the corpus does not have: {}",
            extra.join(", ")
        ));
    }

    // A floor, not a fixture: the corpus grows, and a run that suddenly
    // covers a fraction of it is the failure worth catching.
    if run.entries < 400 {
        run.failures
            .push(format!("only {} corpus entries reachable", run.entries));
    }

    if run.failures.is_empty() {
        println!(
            "rust: {} corpus entries across {} sections, all pass",
            run.entries, run.sections
        );
        return;
    }

    panic!(
        "\n{}\n\nrust: {} failure(s) of {} entries",
        run.failures.join("\n"),
        run.failures.len(),
        run.entries
    );
}

//! The driver (DOCS.md §4).
//!
//! Every port implements this same small thing and nothing else is
//! port-specific: the probe catalog, the command interpreter, and the
//! canonical observable.
//!
//! ONE RUST-ONLY NOTE. Every probe closure captures the `Inst` it was
//! handed, and the `Inst` holds the entry the closure is stored in: an
//! `Rc` cycle that is never collected. It is deliberate and it is bounded
//! - a driver process runs 539 entries and exits - and the alternative
//! (`Weak` everywhere) would put lifetime plumbing into the one file whose
//! job is to read like the other ports.

use std::rc::Rc;

use voxgig_plugin::catalog::{make_catalog, Definition};
use voxgig_plugin::host::{make_host, Host, Inst};
use voxgig_plugin::point::{BindFn, NextFn};
use voxgig_plugin::types::{fail, PluginError};
use voxgig_plugin::value::Value;

/// A value rendered as text: a string is itself, anything else is its
/// JSON. The chain probe concatenates whatever it is handed, and the
/// corpus writes strings.
pub fn text(value: &Value) -> String {
    match value.as_str() {
        Some(s) => s.to_string(),
        None => value.json(),
    }
}

fn num(value: &Value) -> f64 {
    value.as_num().unwrap_or(0.0)
}

/// §4.3's six probes. Their behaviour is as much the contract as the
/// runner is - this is where twenty implementations of `noisy` are made to
/// fail at the same callback in the same way.
pub fn probes() -> Vec<Definition> {
    let mut out = Vec::new();

    // -- probe: the workhorse ------------------------------------------
    let mut probe = Definition::named("probe");
    probe.define = Some(Rc::new(|i: &Inst| {
        if i.state_get("count").is_null() {
            i.state_set("count", Value::Num(0.0));
        }
        let band = i.options().get("band");

        // One hook binding (`p`) and one chain wrap (`c`) - the workhorse
        // shape DOCS.md §4.3 specifies.
        let hook = i.clone();
        let hookfn: BindFn = Rc::new(move |_next, _args| {
            let n = num(&hook.state_get("count"));
            hook.state_set("count", Value::Num(n + 1.0));
            Ok(Value::Null)
        });
        i.bind("p", hookfn, &band)?;

        // Wrap AFTER next, so the result spells the nesting left to right:
        // outermost first. Wrapping the ARGUMENT instead would spell it
        // backwards and make every chain expectation read wrong.
        let chain = i.clone();
        let chainfn: BindFn = Rc::new(move |next, args| {
            let wrap = chain.options().get("wrap");
            let wrap = wrap.as_str().unwrap_or(":").to_string();
            let inner = match next {
                Some(n) => n(args)?,
                None => Value::Null,
            };
            Ok(Value::Str(format!("{}{}", wrap, text(&inner))))
        });
        i.bind("c", chainfn, &band)?;

        i.export("client", Value::str(&i.eref));
        // The instance api itself, so the driver's `stray` command can
        // call `release` from OUTSIDE a lifecycle callback.
        i.export("inst", Value::Opaque(Rc::new(i.clone())));
        declareprovides(i);
        Ok(())
    }));
    probe.activate = Some(Rc::new(|i: &Inst| {
        i.acquire()?;
        // §6.5: an instance that is itself a host. The outer owns the
        // inner's lifetime - registered in the scope, so it closes on
        // deactivate in the same reverse unwind as every other resource.
        let nest = i.options().get("nest");
        if nest.is_null() {
            return Ok(());
        }
        let mut opts = Value::map();
        opts.set("points", withpoints(&Value::Null));
        let inner = i.nest(&opts)?;
        for d in probes() {
            inner.define(d)?;
        }
        for r in nest.as_list().cloned().unwrap_or_default().iter() {
            inner.ready(r)?;
        }
        Ok(())
    }));
    out.push(probe);

    // -- noisy: fails on demand ----------------------------------------
    let mut noisy = Definition::named("noisy");
    noisy.define = Some(Rc::new(|i: &Inst| {
        if i.state_get("count").is_null() {
            i.state_set("count", Value::Num(0.0));
        }
        boom(i, "define")
    }));
    noisy.activate = Some(Rc::new(|i: &Inst| {
        // Acquire BEFORE the raise, so a failing activate has something to
        // leak if the scope does not unwind - which is the whole point of
        // the entry that asserts open == 0 afterwards.
        i.acquire()?;
        reenter(i, "activate")?;
        boom(i, "activate")
    }));
    noisy.deactivate = Some(Rc::new(|i: &Inst| boom(i, "deactivate")));
    noisy.close = Some(Rc::new(|i: &Inst| boom(i, "close")));
    out.push(noisy);

    // -- greedy: acquires and releases ---------------------------------
    let mut greedy = Definition::named("greedy");
    greedy.define = Some(Rc::new(|i: &Inst| {
        i.state_set("count", Value::Num(0.0));
        // §8.1 puts resource capture in `activate`. `early` NAMES the call
        // that reaches for it in `define`, because `acquire` and `release`
        // carry the guard separately.
        let early = i.options().get("early");
        match early.as_str() {
            Some("acquire") => {
                i.acquire()?;
            }
            Some("release") => {
                i.release(Rc::new(|| Ok(())))?;
            }
            _ => {}
        }
        Ok(())
    }));
    greedy.activate = Some(Rc::new(|i: &Inst| {
        let opts = i.options();
        let n = num(&opts.get("acquire")) as usize;
        let rel = num(&opts.get("release")) as usize;
        let mut handles = Vec::new();
        for _ in 0..n {
            handles.push(i.acquire()?);
        }
        // Release some explicitly; the DIFFERENCE is what the instance
        // scope must unwind by itself (§8.3), and that difference is the
        // whole test.
        for h in handles.iter().take(rel.min(handles.len())) {
            h()?;
        }

        // `bind` is `early`'s counterpart for §8.1's OTHER half. Binding
        // declaration belongs in `define`; this names the callback that
        // tries it from somewhere else.
        if Some("activate") == opts.get("bind").as_str() {
            i.bind("p", Rc::new(|_n, _a| Ok(Value::Null)), &Value::Null)?;
        }

        // `mark` registers N FOREIGN releases - §8.3's `release`, the half
        // `acquire` cannot exercise - each recording its own index as it
        // runs. THE RECORDED LIST IS THE ONLY THING THAT DISTINGUISHES A
        // REVERSE UNWIND FROM A FORWARD ONE.
        i.state_set("unwound", Value::List(Vec::new()));
        let markfail = opts.get("markfail").truthy();
        for k in 0..(num(&opts.get("mark")) as usize) {
            let owner = i.clone();
            i.release(Rc::new(move || {
                // `markfail` makes the release RAISE - the only way §8.3's
                // `plugin_release_failed` and its `failed` status are
                // reachable.
                if markfail {
                    return Err(PluginError::bare(&format!("release failed at {}", k)));
                }
                let mut list = owner
                    .state_get("unwound")
                    .as_list()
                    .cloned()
                    .unwrap_or_default();
                list.push(Value::Num(k as f64));
                owner.state_set("unwound", Value::List(list));
                Ok(())
            }))?;
        }
        Ok(())
    }));
    // `deactivate` completes the pair: the guard is on the PHASE, not on
    // "not define", and an entry exercising only one leaves the other's
    // mutation alive.
    greedy.deactivate = Some(Rc::new(|i: &Inst| {
        if Some("deactivate") == i.options().get("bind").as_str() {
            i.bind("p", Rc::new(|_n, _a| Ok(Value::Null)), &Value::Null)?;
        }
        Ok(())
    }));
    out.push(greedy);

    // -- dep: declares requirements ------------------------------------
    let mut dep = Definition::named("dep");
    dep.define = Some(Rc::new(|i: &Inst| {
        i.state_set("count", Value::Num(0.0));
        declareprovides(i);
        let exports = i.options().get("exports");
        for k in exports.keys() {
            i.export(&k, exports.get(&k));
        }
        Ok(())
    }));
    dep.activate = Some(Rc::new(|i: &Inst| {
        i.acquire()?;
        Ok(())
    }));
    out.push(dep);

    // -- provider: binds a provider point ------------------------------
    let mut provider = Definition::named("provider");
    provider.define = Some(Rc::new(|i: &Inst| {
        i.state_set("count", Value::Num(0.0));
        let opts = i.options();
        let point = opts.get("point");
        let point = point.as_str().unwrap_or("v").to_string();
        let owner = i.clone();
        let fnv: BindFn = Rc::new(move |_next, _args| {
            let opts = owner.options();
            Ok(if opts.has("value") {
                opts.get("value")
            } else {
                Value::str(&owner.eref)
            })
        });
        i.bind(&point, fnv, &opts.get("band"))?;
        declareprovides(i);
        Ok(())
    }));
    provider.activate = Some(Rc::new(|i: &Inst| {
        i.acquire()?;
        Ok(())
    }));
    out.push(provider);

    // -- the recorders: `slow` and the three ordering extras ------------
    for name in ["slow", "other", "adapter", "late"] {
        let mut d = Definition::named(name);
        d.define = Some(Rc::new(|i: &Inst| {
            if i.state_get("count").is_null() {
                i.state_set("count", Value::Num(0.0));
            }
            Ok(())
        }));
        d.activate = Some(Rc::new(|i: &Inst| {
            i.acquire()?;
            Ok(())
        }));
        out.push(d);
    }

    out
}

fn declareprovides(inst: &Inst) {
    for p in inst
        .options()
        .get("provides")
        .as_list()
        .cloned()
        .unwrap_or_default()
    {
        inst.provides(p);
    }
}

fn boom(inst: &Inst, callback: &str) -> Result<(), PluginError> {
    let opts = inst.options();
    if opts.get("fail").as_str() != Some(callback) {
        return Ok(());
    }

    // `bare` raises WITHOUT a code - the ordinary library error §12's
    // `plugin_<phase>_failed` codes exist to wrap.
    if opts.get("bare").truthy() {
        return Err(PluginError::bare(&format!(
            "probe failed at {}",
            callback
        )));
    }

    let code = opts.get("code");
    let code = code
        .as_str()
        .map(|c| c.to_string())
        .unwrap_or_else(|| format!("plugin_{}_failed", callback));
    fail(
        &code,
        &format!("probe failed at {}", callback),
        Value::Null,
    )
}

fn reenter(inst: &Inst, callback: &str) -> Result<(), PluginError> {
    if inst.options().get("reenter").as_str() != Some(callback) {
        return Ok(());
    }
    // A transition from inside a lifecycle callback (§5.2).
    inst.host.activate(&Value::str(&inst.eref))?;
    Ok(())
}

/// The points every driver host declares. DOCS.md §4.3 defines `probe` as
/// binding one hook point (`p`) and wrapping one chain point (`c`), so a
/// host without them cannot load the probe at all - they are part of the
/// contract's baseline rather than a fixture convenience. `v` is the
/// provider point the `provider` probe defaults to.
pub fn withpoints(extra: &Value) -> Value {
    let mut out = Value::map();

    let mut p = Value::map();
    p.set("kind", Value::str("hook"));
    out.set("p", p);

    let mut c = Value::map();
    c.set("kind", Value::str("chain"));
    let base: NextFn = Rc::new(|a: &[Value]| Ok(a.first().cloned().unwrap_or(Value::Null)));
    c.set("base", Value::Opaque(Rc::new(base)));
    out.set("c", c);

    let mut v = Value::map();
    v.set("kind", Value::str("provider"));
    out.set("v", v);

    // A `host` command REPLACES a base point rather than merging into it,
    // so an entry can redeclare `c` with its own base or `v` as exclusive
    // without inheriting the default's shape.
    for k in extra.keys() {
        out.set(&k, extra.get(&k));
    }
    out
}

fn newhost(cmd: &Value) -> Result<Host, PluginError> {
    let mut opts = Value::map();
    opts.set("reserved", cmd.get("reserved"));
    opts.set("keys", cmd.get("keys"));
    opts.set("defaults", cmd.get("defaults"));
    opts.set("profile", cmd.get("profile"));
    opts.set("points", withpoints(&cmd.get("points")));
    // §11.3's strict reading. Absent means `restart`.
    opts.set("dependency", cmd.get("dependency"));
    let host = make_host(&opts);
    for d in probes() {
        host.define(d)?;
    }
    let _ = make_catalog(Vec::new());
    Ok(host)
}

/// Run a command list and return §4.5's observable. Stops at the first
/// raise; the entry's `err` matches its code.
pub fn drive(cmds: &Value) -> Result<Value, PluginError> {
    let mut host = newhost(&Value::map())?;

    // §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
    // Storing it and continuing - rather than returning at the first
    // producing command - is what lets an entry emit and then inspect,
    // which most of `point` needs.
    let mut last = Value::Null;

    for cmd in cmds.as_list().cloned().unwrap_or_default().iter() {
        match docmd(&host, cmd) {
            Ok((next, value)) => {
                host = next;
                if let Some(v) = value {
                    last = v;
                }
            }
            Err(e) => {
                // §4.1: `catch` records the raise and lets the run
                // continue, which is the only way to observe a `failed`
                // instance - §5.2's whole claim is that it stays
                // registered and inspectable.
                if !matches!(cmd.get("catch"), Value::Bool(true)) {
                    return Err(e);
                }
            }
        }
    }
    Ok(host.observable(last))
}

type Step = Result<(Host, Option<Value>), PluginError>;

fn docmd(host: &Host, cmd: &Value) -> Step {
    let eref = cmd.get("ref");
    let point = cmd.get("point");
    let point = point.as_str();
    let mut spec = Value::map();
    spec.set("options", cmd.get("options"));
    spec.set("order", cmd.get("order"));
    spec.set("definition", cmd.get("definition"));
    spec.set("tag", cmd.get("tag"));

    let verb = cmd.get("do");
    let verb = verb.as_str().unwrap_or("");
    let none = |h: &Host| -> Step { Ok((h.clone(), None)) };

    match verb {
        "host" => Ok((newhost(cmd)?, None)),
        // The catalog is pre-seeded with the probe set; `define` names
        // which entry backs this definition.
        "define" => none(host),
        "load" => {
            host.load(&eref, &spec)?;
            none(host)
        }
        "ready" => {
            // declare FIRST, so the ordering block and definition reach
            // the instance - `ready` walks the staircase, it does not
            // carry configuration of its own.
            host.declare(&eref, &spec)?;
            host.ready(&eref)?;
            none(host)
        }
        "activate" => {
            host.activate(&eref)?;
            none(host)
        }
        "deactivate" => {
            host.deactivate(&eref)?;
            none(host)
        }
        "unload" => {
            host.unload(&eref)?;
            none(host)
        }
        "apply" => {
            host.apply(&cmd.get("doc"), &cmd.get("profile"))?;
            none(host)
        }
        "options" => {
            host.options(&eref, &cmd.get("patch"))?;
            none(host)
        }
        "close" => {
            host.close()?;
            none(host)
        }
        "list" => Ok((host.clone(), Some(host.list()))),
        "emit" => Ok((
            host.clone(),
            Some(host.emit(point.unwrap_or(""), &cmd.get("arg"))?),
        )),
        "chain" => Ok((
            host.clone(),
            Some(host.call(point.unwrap_or(""), &[cmd.get("arg")])?),
        )),
        "provider" => Ok((
            host.clone(),
            Some(host.provider(point.unwrap_or(""), &[cmd.get("arg")])?),
        )),
        "shadowed" => Ok((
            host.clone(),
            Some(Value::List(
                host.shadowed(point.unwrap_or(""))?
                    .iter()
                    .map(|r| Value::str(r))
                    .collect(),
            )),
        )),
        "export" => {
            let key = cmd.get("key");
            Ok((
                host.clone(),
                Some(host.exports(key.as_str().unwrap_or(""))?),
            ))
        }
        "capability" => {
            let name = cmd.get("name");
            Ok((
                host.clone(),
                Some(Value::List(
                    host.capability(name.as_str().unwrap_or(""))
                        .iter()
                        .map(|r| Value::str(r))
                        .collect(),
                )),
            ))
        }
        "trace" => Ok((host.clone(), Some(host.trace()))),
        // §9.1's host-owned path: the embedding host installing the
        // instance whose name it reserved.
        "hostdeclare" => {
            let entry = host.hostdeclare(&eref, &spec)?;
            let r = entry.borrow().eref.clone();
            Ok((host.clone(), Some(Value::str(&r))))
        }
        "declare" => {
            let entry = host.declare(&eref, &spec)?;
            let r = entry.borrow().eref.clone();
            Ok((host.clone(), Some(Value::str(&r))))
        }
        "order" => Ok((
            host.clone(),
            Some(Value::List(
                host.order(point)?.iter().map(|r| Value::str(r)).collect(),
            )),
        )),
        "seq" => {
            let entry = host.instance(&eref)?;
            Ok((
                host.clone(),
                Some(match entry {
                    Some(e) => Value::Num(e.borrow().seq),
                    None => Value::Null,
                }),
            ))
        }
        "pos" => {
            let entry = host.instance(&eref)?;
            Ok((
                host.clone(),
                Some(match entry {
                    Some(e) => Value::Num(e.borrow().pos),
                    None => Value::Null,
                }),
            ))
        }
        "inner" => {
            let entry = host.instance(&eref)?;
            let inner = entry.and_then(|e| e.borrow().inner.clone());
            Ok((
                host.clone(),
                Some(match inner {
                    Some(h) => h.list(),
                    None => Value::Null,
                }),
            ))
        }
        "call" => docall(host, cmd, &eref, point),
        other => Err(PluginError::bare(&format!(
            "unknown driver command: {}",
            other
        ))),
    }
}

fn docall(host: &Host, cmd: &Value, eref: &Value, point: Option<&str>) -> Step {
    let name = eref.as_str().unwrap_or("");
    let entry = match host.instance(eref)? {
        Some(e) => e,
        None => {
            return fail(
                "plugin_not_loaded",
                &format!("no such instance: {}", name),
                Value::Null,
            )
        }
    };
    let method = cmd.get("method");
    match method.as_str().unwrap_or("") {
        "bump" => {
            let n = num(&entry.borrow().state.get("count"));
            entry.borrow_mut().state.set("count", Value::Num(n + 1.0));
            Ok((host.clone(), None))
        }
        "count" => {
            let v = entry.borrow().state.get("count");
            Ok((
                host.clone(),
                Some(if v.is_null() { Value::Num(0.0) } else { v }),
            ))
        }
        "unwound" => {
            let v = entry.borrow().state.get("unwound");
            Ok((
                host.clone(),
                Some(if v.is_null() {
                    Value::List(Vec::new())
                } else {
                    v
                }),
            ))
        }
        // Reached through the instance api, which is where §6.6 puts it -
        // a plugin asks about itself.
        "position" => Ok((host.clone(), Some(host.positionof(name, point)?))),
        "stray" => {
            // A release from OUTSIDE a lifecycle callback. THIS BRANCH
            // USED TO DO NOTHING, and its corpus row stayed green whatever
            // `release` did with its guard.
            let exported = host.exports(&format!("{}/inst", name))?;
            match exported {
                Value::Opaque(o) => match o.downcast_ref::<Inst>() {
                    Some(inst) => {
                        inst.release(Rc::new(|| Ok(())))?;
                        Ok((host.clone(), None))
                    }
                    None => Err(PluginError::bare("exported `inst` is not an instance api")),
                },
                _ => Err(PluginError::bare("no exported `inst` to release through")),
            }
        }
        _ => Ok((host.clone(), None)),
    }
}

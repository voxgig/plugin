using System;
using System.Collections.Generic;
using Voxgig.Plugin;

namespace Voxgig.Plugin.Test
{
    /// <summary>
    /// The driver (DOCS.md §4).
    ///
    /// <para>Every port implements this same small thing and nothing else
    /// is port-specific: the probe catalog, the command interpreter, and
    /// the canonical observable.</para>
    /// </summary>
    public static class Driver
    {
        /// <summary>
        /// A sentinel for "this command produced nothing", so a command
        /// that legitimately produces null - <c>export</c> of a missing
        /// key - still overwrites the previous result.
        /// </summary>
        public static readonly object NOTHING = new object();

        /// A value rendered as text: a string is itself, anything else is JSON.
        private static string Text(object value)
        {
            return Types.Str(value) ?? Json.Write(value);
        }

        private static double Num(object value)
        {
            return Types.Num(value) ?? 0;
        }

        /// <summary>
        /// §4.3's six probes. Their behaviour is as much the contract as
        /// the runner is - this is where twenty implementations of
        /// <c>noisy</c> are made to fail at the same callback in the same
        /// way.
        /// </summary>
        public static List<Definition> Probes()
        {
            var out_ = new List<Definition>();

            var probe = new Definition("probe");
            probe.Define = i =>
            {
                if (!i.State().ContainsKey("count"))
                {
                    i.State()["count"] = 0.0;
                }
                var band = Types.Get(i.Options(), "band");
                // One hook binding (`p`) and one chain wrap (`c`) - the
                // workhorse shape DOCS.md §4.3 specifies.
                i.Bind("p", (next, args) =>
                {
                    i.State()["count"] = Num(Types.Get(i.State(), "count")) + 1;
                    return null;
                }, band);
                // Wrap AFTER next, so the result spells the nesting left
                // to right: outermost first. Wrapping the ARGUMENT instead
                // would spell it backwards and make every chain
                // expectation read wrong.
                i.Bind("c", (next, args) =>
                {
                    var wrap = Types.Str(Types.Get(i.Options(), "wrap")) ?? ":";
                    var inner = null == next ? null : next(args);
                    return wrap + Text(inner);
                }, band);
                i.Export("client", i.Ref);
                // The instance api itself, so the driver's `stray` command
                // can call `release` from OUTSIDE a lifecycle callback.
                i.Export("inst", i);
                DeclareProvides(i);
            };
            probe.Activate = i =>
            {
                i.Acquire();
                // §6.5: an instance that is itself a host. The outer owns
                // the inner's lifetime - registered in the scope, so it
                // closes on deactivate in the same reverse unwind as every
                // other resource.
                var nest = Types.Get(i.Options(), "nest");
                if (null == nest)
                {
                    return;
                }
                var opts = Types.NewMap();
                opts["points"] = WithPoints(null);
                var inner = i.Nest(opts);
                foreach (var d in Probes())
                {
                    inner.Define(d);
                }
                foreach (var r in Types.List(nest))
                {
                    inner.Ready(r);
                }
            };
            out_.Add(probe);

            var noisy = new Definition("noisy");
            noisy.Define = i =>
            {
                if (!i.State().ContainsKey("count"))
                {
                    i.State()["count"] = 0.0;
                }
                Boom(i, "define");
            };
            noisy.Activate = i =>
            {
                // Acquire BEFORE the raise, so a failing activate has
                // something to leak if the scope does not unwind - which
                // is the whole point of the entry that asserts open == 0
                // afterwards.
                i.Acquire();
                Reenter(i, "activate");
                Boom(i, "activate");
            };
            noisy.Deactivate = i => Boom(i, "deactivate");
            noisy.Close = i => Boom(i, "close");
            out_.Add(noisy);

            var greedy = new Definition("greedy");
            greedy.Define = i =>
            {
                i.State()["count"] = 0.0;
                // §8.1 puts resource capture in `activate`. `early` NAMES
                // the call that reaches for it in `define`, because
                // `acquire` and `release` carry the guard separately.
                var early = Types.Get(i.Options(), "early");
                if ("acquire".Equals(early))
                {
                    i.Acquire();
                }
                if ("release".Equals(early))
                {
                    i.Release(() => { });
                }
            };
            greedy.Activate = i =>
            {
                var opts = i.Options();
                var n = (int)Num(Types.Get(opts, "acquire"));
                var rel = (int)Num(Types.Get(opts, "release"));
                var handles = new List<Entry.ScopeFn>();
                for (var k = 0; k < n; k++)
                {
                    handles.Add(i.Acquire());
                }
                // Release some explicitly; the DIFFERENCE is what the
                // instance scope must unwind by itself (§8.3), and that
                // difference is the whole test.
                for (var k = 0; k < Math.Min(rel, handles.Count); k++)
                {
                    handles[k]();
                }

                // `bind` is `early`'s counterpart for §8.1's OTHER half.
                // Binding declaration belongs in `define`; this names the
                // callback that tries it from somewhere else.
                if ("activate".Equals(Types.Get(opts, "bind")))
                {
                    i.Bind("p", (next, args) => null, null);
                }

                // `mark` registers N FOREIGN releases - §8.3's `release`,
                // the half `acquire` cannot exercise - each recording its
                // own index as it runs. THE RECORDED LIST IS THE ONLY
                // THING THAT DISTINGUISHES A REVERSE UNWIND FROM A FORWARD
                // ONE.
                i.State()["unwound"] = new List<object>();
                var markfail = Types.Truthy(Types.Get(opts, "markfail"));
                var mark = (int)Num(Types.Get(opts, "mark"));
                for (var k = 0; k < mark; k++)
                {
                    var index = k;
                    i.Release(() =>
                    {
                        // `markfail` makes the release RAISE - the only
                        // way §8.3's `plugin_release_failed` and its
                        // `failed` status are reachable.
                        if (markfail)
                        {
                            throw new InvalidOperationException("release failed at " + index);
                        }
                        Types.List(i.State()["unwound"]).Add((double)index);
                    });
                }
            };
            // `deactivate` completes the pair: the guard is on the PHASE,
            // not on "not define", and an entry exercising only one leaves
            // the other's mutation alive.
            greedy.Deactivate = i =>
            {
                if ("deactivate".Equals(Types.Get(i.Options(), "bind")))
                {
                    i.Bind("p", (next, args) => null, null);
                }
            };
            out_.Add(greedy);

            var dep = new Definition("dep");
            dep.Define = i =>
            {
                i.State()["count"] = 0.0;
                DeclareProvides(i);
                var exports = Types.Get(i.Options(), "exports");
                foreach (var k in Types.Keys(exports))
                {
                    i.Export(k, Types.Get(exports, k));
                }
            };
            dep.Activate = i => i.Acquire();
            out_.Add(dep);

            var provider = new Definition("provider");
            provider.Define = i =>
            {
                i.State()["count"] = 0.0;
                var opts = i.Options();
                var point = Types.Str(Types.Get(opts, "point")) ?? "v";
                i.Bind(point, (next, args) =>
                    Types.Has(i.Options(), "value")
                        ? Types.Get(i.Options(), "value")
                        : i.Ref,
                    Types.Get(opts, "band"));
                DeclareProvides(i);
            };
            provider.Activate = i => i.Acquire();
            out_.Add(provider);

            foreach (var name in new[] { "slow", "other", "adapter", "late" })
            {
                var d = new Definition(name);
                d.Define = i =>
                {
                    if (!i.State().ContainsKey("count"))
                    {
                        i.State()["count"] = 0.0;
                    }
                };
                d.Activate = i => i.Acquire();
                out_.Add(d);
            }

            return out_;
        }

        private static void DeclareProvides(Inst inst)
        {
            var provides = Types.List(Types.Get(inst.Options(), "provides"));
            if (null == provides)
            {
                return;
            }
            foreach (var p in provides)
            {
                inst.Provides(p);
            }
        }

        private static void Boom(Inst inst, string callback)
        {
            var opts = inst.Options();
            if (!callback.Equals(Types.Get(opts, "fail")))
            {
                return;
            }
            // `bare` raises WITHOUT a code - the ordinary library error
            // §12's `plugin_<phase>_failed` codes exist to wrap.
            if (Types.Truthy(Types.Get(opts, "bare")))
            {
                throw new InvalidOperationException("probe failed at " + callback);
            }
            var code = Types.Str(Types.Get(opts, "code"))
                       ?? ("plugin_" + callback + "_failed");
            throw new PluginException(code, "probe failed at " + callback, null);
        }

        private static void Reenter(Inst inst, string callback)
        {
            if (!callback.Equals(Types.Get(inst.Options(), "reenter")))
            {
                return;
            }
            // A transition from inside a lifecycle callback (§5.2).
            inst.HostRef.Activate(inst.Ref);
        }

        /// <summary>
        /// The points every driver host declares. DOCS.md §4.3 defines
        /// <c>probe</c> as binding one hook point (<c>p</c>) and wrapping
        /// one chain point (<c>c</c>), so a host without them cannot load
        /// the probe at all - they are part of the contract's baseline
        /// rather than a fixture convenience. <c>v</c> is the provider
        /// point the <c>provider</c> probe defaults to.
        /// </summary>
        public static object WithPoints(object extra)
        {
            var out_ = Types.NewMap();

            var p = Types.NewMap();
            p["kind"] = "hook";
            out_["p"] = p;

            var c = Types.NewMap();
            c["kind"] = "chain";
            c["base"] = (Point.NextFn)(args => 0 < args.Length ? args[0] : null);
            out_["c"] = c;

            var v = Types.NewMap();
            v["kind"] = "provider";
            out_["v"] = v;

            // A `host` command REPLACES a base point rather than merging
            // into it, so an entry can redeclare `c` with its own base or
            // `v` as exclusive without inheriting the default's shape.
            foreach (var k in Types.Keys(extra))
            {
                out_[k] = Types.Get(extra, k);
            }
            return out_;
        }

        private static Host NewHost(object cmd)
        {
            var opts = Types.NewMap();
            opts["reserved"] = Types.Get(cmd, "reserved");
            opts["keys"] = Types.Get(cmd, "keys");
            opts["defaults"] = Types.Get(cmd, "defaults");
            opts["profile"] = Types.Get(cmd, "profile");
            opts["points"] = WithPoints(Types.Get(cmd, "points"));
            // §11.3's strict reading. Absent means `restart`.
            opts["dependency"] = Types.Get(cmd, "dependency");
            var host = new Host(opts);
            host.CatalogRef(Catalog.MakeCatalog(Probes()));
            return host;
        }

        private sealed class Step
        {
            public readonly Host HostRef;
            public readonly object Value;

            public Step(Host host, object value)
            {
                HostRef = host;
                Value = value;
            }
        }

        /// <summary>
        /// Run a command list and return §4.5's observable. Stops at the
        /// first raise; the entry's <c>err</c> matches its code.
        /// </summary>
        public static object Drive(object cmds)
        {
            var host = NewHost(Types.NewMap());

            // §4.5: `result` is the value of THE LAST COMMAND THAT
            // PRODUCES ONE. Storing it and continuing - rather than
            // returning at the first producing command - is what lets an
            // entry emit and then inspect, which most of `point` needs.
            object last = null;

            foreach (var cmd in Types.List(cmds))
            {
                try
                {
                    var step = DoCmd(host, cmd);
                    host = step.HostRef;
                    if (NOTHING != step.Value)
                    {
                        last = step.Value;
                    }
                }
                catch (Exception)
                {
                    // §4.1: `catch` records the raise and lets the run
                    // continue, which is the only way to observe a
                    // `failed` instance - §5.2's whole claim is that it
                    // stays registered and inspectable.
                    if (!true.Equals(Types.Get(cmd, "catch")))
                    {
                        throw;
                    }
                }
            }
            return host.Observable(last);
        }

        private static Step DoCmd(Host host, object cmd)
        {
            var eref = Types.Get(cmd, "ref");
            var point = Types.Str(Types.Get(cmd, "point"));
            var spec = Types.NewMap();
            spec["options"] = Types.Get(cmd, "options");
            spec["order"] = Types.Get(cmd, "order");
            spec["definition"] = Types.Get(cmd, "definition");
            spec["tag"] = Types.Get(cmd, "tag");

            switch (Types.Str(Types.Get(cmd, "do")) ?? "")
            {
                case "host":
                    return new Step(NewHost(cmd), NOTHING);
                // The catalog is pre-seeded with the probe set; `define`
                // names which entry backs this definition.
                case "define":
                    return new Step(host, NOTHING);
                case "load":
                    host.Load(eref, spec);
                    return new Step(host, NOTHING);
                case "ready":
                    // declare FIRST, so the ordering block and definition
                    // reach the instance - `ready` walks the staircase, it
                    // does not carry configuration of its own.
                    host.Declare(eref, spec);
                    host.Ready(eref);
                    return new Step(host, NOTHING);
                case "activate":
                    host.Activate(eref);
                    return new Step(host, NOTHING);
                case "deactivate":
                    host.Deactivate(eref);
                    return new Step(host, NOTHING);
                case "unload":
                    host.Unload(eref);
                    return new Step(host, NOTHING);
                case "apply":
                    host.Apply(Types.Get(cmd, "doc"), Types.Get(cmd, "profile"));
                    return new Step(host, NOTHING);
                case "options":
                    host.Options(eref, Types.Get(cmd, "patch"));
                    return new Step(host, NOTHING);
                case "close":
                    host.Close();
                    return new Step(host, NOTHING);
                case "list":
                    return new Step(host, host.List());
                case "emit":
                    return new Step(host, host.Emit(point, Types.Get(cmd, "arg")));
                case "chain":
                    return new Step(host, host.Call(point, new[] { Types.Get(cmd, "arg") }));
                case "provider":
                    return new Step(host, host.Provider(point, new[] { Types.Get(cmd, "arg") }));
                case "shadowed":
                    return new Step(host, Types.Strings(host.Shadowed(point)));
                case "export":
                    return new Step(host, host.Exports(Types.Str(Types.Get(cmd, "key"))));
                case "capability":
                    return new Step(host,
                        Types.Strings(host.CapabilityOf(Types.Str(Types.Get(cmd, "name")))));
                case "trace":
                    return new Step(host, host.Trace());
                case "hostdeclare":
                    // §9.1's host-owned path: the embedding host
                    // installing the instance whose name it reserved.
                    return new Step(host, host.HostDeclare(eref, spec).Ref);
                case "declare":
                    return new Step(host, host.Declare(eref, spec).Ref);
                case "order":
                    return new Step(host, Types.Strings(host.Order(point)));
                case "seq":
                    {
                        var entry = host.Instance(eref);
                        return new Step(host, null == entry ? null : (object)entry.Seq);
                    }
                case "pos":
                    {
                        var entry = host.Instance(eref);
                        return new Step(host, null == entry ? null : (object)entry.Pos);
                    }
                case "inner":
                    {
                        var entry = host.Instance(eref);
                        return new Step(host,
                            null == entry || null == entry.Inner ? null : entry.Inner.List());
                    }
                case "call":
                    return DoCall(host, cmd, eref, point);
                default:
                    throw new InvalidOperationException(
                        "unknown driver command: " + Types.Get(cmd, "do"));
            }
        }

        private static Step DoCall(Host host, object cmd, object eref, string point)
        {
            var entry = host.Instance(eref);
            if (null == entry)
            {
                throw new PluginException("plugin_not_loaded", "no such instance: " + eref, null);
            }
            switch (Types.Str(Types.Get(cmd, "method")) ?? "")
            {
                case "bump":
                    entry.State["count"] = Num(Types.Get(entry.State, "count")) + 1;
                    return new Step(host, NOTHING);
                case "count":
                    return new Step(host,
                        entry.State.ContainsKey("count") ? entry.State["count"] : 0.0);
                case "unwound":
                    return new Step(host,
                        entry.State.ContainsKey("unwound")
                            ? entry.State["unwound"]
                            : new List<object>());
                // Reached through the instance api, which is where §6.6
                // puts it - a plugin asks about itself.
                case "position":
                    return new Step(host, host.PositionOf(Types.Str(eref), point));
                case "stray":
                    {
                        // A release from OUTSIDE a lifecycle callback.
                        // THIS BRANCH USED TO DO NOTHING, and its corpus
                        // row stayed green whatever `release` did with its
                        // guard.
                        var exported = host.Exports(Types.Str(eref) + "/inst");
                        ((Inst)exported).Release(() => { });
                        return new Step(host, NOTHING);
                    }
                default:
                    return new Step(host, NOTHING);
            }
        }
    }
}

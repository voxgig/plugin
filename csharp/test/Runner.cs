using System;
using System.Collections.Generic;
using Voxgig.Plugin;

namespace Voxgig.Plugin.Test
{
    /// <summary>
    /// The whole suite: pure sections by direct call, driver sections by
    /// command list, and a coverage guard above both.
    ///
    /// <para>A plain <c>Main</c> rather than xunit, for the same reason
    /// the port has no PackageReference: a conformance suite whose only
    /// job is to run one corpus and report which entries disagree does not
    /// need a framework, and adding one would make <c>make test</c> depend
    /// on a package restore nobody else in this repo has.</para>
    /// </summary>
    public static class Runner
    {
        private static readonly List<string> FAILURES = new List<string>();
        private static int sections;
        private static int entries;

        private static readonly string[] PURE_SECTIONS =
        {
            "ref", "env", "version", "capability", "graph", "resolve", "config",
        };

        private static readonly string[] DRIVER_SECTIONS =
        {
            "lifecycle", "order", "point", "export", "depend", "declare", "state",
            "resource", "nest", "trace", "apply", "error",
        };

        private static void Report(string name, string group, int i, object entry, string why)
        {
            FAILURES.Add(name + "/" + Corpus.Label(group, i, entry) + ": " + why);
        }

        /// <summary>
        /// Dispatch every group, and fail on a group the runner does not
        /// know - a group silently not run is worse than a failure.
        /// </summary>
        private static void Section(
            string name, Dictionary<string, Func<object, object>> subjects)
        {
            sections++;
            foreach (var g in Corpus.Section(name))
            {
                if (!subjects.TryGetValue(g.Key, out var subject))
                {
                    FAILURES.Add(name + ": corpus group with no subject: " + g.Key);
                    continue;
                }
                for (var i = 0; i < g.Value.Count; i++)
                {
                    entries++;
                    var why = Corpus.Check(g.Value[i], subject);
                    if (null != why)
                    {
                        Report(name, g.Key, i, g.Value[i], why);
                    }
                }
            }
        }

        private static Dictionary<string, Func<object, object>> Subjects(params object[] pairs)
        {
            var out_ = new Dictionary<string, Func<object, object>>(StringComparer.Ordinal);
            for (var i = 0; i + 1 < pairs.Length; i += 2)
            {
                out_[(string)pairs[i]] = (Func<object, object>)pairs[i + 1];
            }
            return out_;
        }

        public static int Main(string[] args)
        {
            Func<object, object> parse = e => Refs.ParseRef(Types.Get(e, "in"));
            Func<object, object> format = e =>
            {
                var list = Types.Get(e, "args");
                return Refs.FormatRef(Types.At(list, 0), Types.At(list, 1));
            };
            Func<object, object> name = e => Refs.CheckName(Types.Get(e, "in"));
            Func<object, object> tag = e => Refs.CheckTag(Types.Get(e, "in"));

            Section("ref", Subjects(
                "parse", parse,
                "parsebad", parse,
                "format", format,
                "formatbad", format,
                "canon", (Func<object, object>)(e => Refs.CanonRef(Types.Get(e, "in"))),
                "name", name,
                "tag", tag,
                "bound", name,
                "boundtag", tag));

            Func<object, object> env = e => Env.ApplyEnv(Types.Get(e, "in"));
            Section("env", Subjects(
                "option", env, "value", env, "toggle", env,
                "profile", env, "ambiguous", env, "reserved", env));

            Func<object, object> range = e => Version.ParseRange(Types.Get(e, "in"));
            Section("version", Subjects(
                "range", range,
                "rangebad", range,
                "satisfies", (Func<object, object>)(e => Version.Satisfies(
                    Types.Get(Types.Get(e, "in"), "version"),
                    Types.Get(Types.Get(e, "in"), "range")))));

            Func<object, object> cap = e => Capability.ResolveCapability(
                Types.Get(Types.Get(e, "in"), "req"),
                Types.List(Types.Get(Types.Get(e, "in"), "candidates")));
            Section("capability", Subjects("match", cap, "nested", cap, "rank", cap));

            Func<object, object> graph = e => Graph.ResolveGraph(Types.Get(e, "in"));
            Section("graph", Subjects("resolve", graph, "blocked", graph));

            Section("resolve", Subjects(
                "candidates", (Func<object, object>)(e => Resolve.ResolveCandidates(
                    Types.Str(Types.Get(Types.Get(e, "in"), "name")),
                    Types.Get(Types.Get(e, "in"), "sources"))),
                "from", (Func<object, object>)(e => Resolve.ResolveFrom(Types.Get(e, "in")))));

            // `config` picks its subject by group PREFIX rather than by
            // name, because the two functions split the section cleanly.
            sections++;
            foreach (var g in Corpus.Section("config"))
            {
                Func<object, object> subject = null;
                if (g.Key.StartsWith("norm", StringComparison.Ordinal))
                {
                    subject = e => Config.NormalizeConfig(Types.Get(e, "in"));
                }
                else if (g.Key.StartsWith("opt", StringComparison.Ordinal))
                {
                    subject = e => Config.ResolveOptions(Types.Get(e, "in"));
                }
                if (null == subject)
                {
                    FAILURES.Add("config: corpus group with no subject: " + g.Key);
                    continue;
                }
                for (var i = 0; i < g.Value.Count; i++)
                {
                    entries++;
                    var why = Corpus.Check(g.Value[i], subject);
                    if (null != why)
                    {
                        Report("config", g.Key, i, g.Value[i], why);
                    }
                }
            }

            // ---- driver sections -------------------------------------

            Func<object, object> drive = e => Driver.Drive(Types.Get(e, "in"));
            foreach (var section in DRIVER_SECTIONS)
            {
                sections++;
                foreach (var g in Corpus.Section(section))
                {
                    for (var i = 0; i < g.Value.Count; i++)
                    {
                        entries++;
                        if (null == Types.List(Types.Get(g.Value[i], "in")))
                        {
                            Report(section, g.Key, i, g.Value[i], "driver entry without a command list in `in`");
                            continue;
                        }
                        var why = Corpus.Check(g.Value[i], drive);
                        if (null != why)
                        {
                            Report(section, g.Key, i, g.Value[i], why);
                        }
                    }
                }
            }

            // ---- coverage ---------------------------------------------
            //
            // EVERY CORPUS SECTION IS RUN. The per-section dispatch already
            // fails on a GROUP with no subject; this closes the level
            // above, because a whole SECTION the runner never mentions is a
            // section silently not run.

            var spec = Corpus.Get();
            var primary = Types.Get(spec, "primary");

            // The corpus metadata block is what turns on strict entry
            // validation in every runner, so a corpus that lost it must not
            // silently downgrade this port's checking.
            if (1.0 != (Types.Num(Types.Get(Types.Get(spec, "PLUGIN"), "version")) ?? 0))
            {
                FAILURES.Add("corpus PLUGIN.version must be 1");
            }

            var ran = new List<string>(PURE_SECTIONS);
            ran.AddRange(DRIVER_SECTIONS);
            var missing = new List<string>();
            foreach (var n in Types.Keys(primary))
            {
                if (!ran.Contains(n))
                {
                    missing.Add(n);
                }
            }
            if (0 != missing.Count)
            {
                FAILURES.Add("corpus sections no test runs: " + string.Join(", ", missing));
            }
            var extra = new List<string>();
            foreach (var n in ran)
            {
                if (!Types.Has(primary, n))
                {
                    extra.Add(n);
                }
            }
            if (0 != extra.Count)
            {
                FAILURES.Add("tests name sections the corpus does not have: "
                             + string.Join(", ", extra));
            }

            // A floor, not a fixture: the corpus grows, and a run that
            // suddenly covers a fraction of it is the failure worth
            // catching.
            if (entries < 400)
            {
                FAILURES.Add("only " + entries + " corpus entries reachable");
            }

            // ---- report ------------------------------------------------

            if (0 == FAILURES.Count)
            {
                Console.WriteLine("csharp: " + entries + " corpus entries across "
                                  + sections + " sections, all pass");
                return 0;
            }

            foreach (var f in FAILURES)
            {
                Console.Error.WriteLine(f);
            }
            Console.Error.WriteLine("\ncsharp: " + FAILURES.Count + " failure(s) of "
                                    + entries + " entries");
            return 1;
        }
    }
}

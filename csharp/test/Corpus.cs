using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using Voxgig.Plugin;

namespace Voxgig.Plugin.Test
{
    /// <summary>
    /// The corpus runner.
    ///
    /// <para>Reads spec/plugin.json - the COMMITTED artifact, not the
    /// aontu source - exactly as every other port's runner does. No port
    /// needs a Node toolchain to run its tests, and this one does not get
    /// a private door into the source either.</para>
    /// </summary>
    public static class Corpus
    {
        /// <summary>
        /// A sentinel for "this key was not present". A map returns null
        /// for both an absent key and a JSON null, and <c>__UNDEF__</c>
        /// and <c>__NULL__</c> are different assertions.
        /// </summary>
        public static readonly object MISSING = new object();

        private static object cache;

        /// <summary>
        /// Walk UP for `spec/plugin.json` rather than assuming a working
        /// directory: `dotnet run` and a built binary disagree about what
        /// the current directory is, and a suite that only runs one of
        /// those ways is a suite nobody runs the other way.
        /// </summary>
        private static string FindSpec()
        {
            var starts = new List<string>
            {
                Directory.GetCurrentDirectory(),
                AppContext.BaseDirectory,
            };
            foreach (var start in starts)
            {
                var dir = new DirectoryInfo(start);
                while (null != dir)
                {
                    var candidate = Path.Combine(dir.FullName, "spec", "plugin.json");
                    if (File.Exists(candidate))
                    {
                        return candidate;
                    }
                    dir = dir.Parent;
                }
            }
            throw new FileNotFoundException("cannot find spec/plugin.json");
        }

        public static object Get()
        {
            if (null == cache)
            {
                cache = Json.Parse(File.ReadAllText(FindSpec()));
            }
            return cache;
        }

        /// The groups of a section, minus <c>DEF</c>, in name order.
        public static List<KeyValuePair<string, List<object>>> Section(string name)
        {
            var sec = Types.Get(Types.Get(Get(), "primary"), name);
            if (null == sec)
            {
                throw new ArgumentException("no such corpus section: " + name);
            }
            var out_ = new List<KeyValuePair<string, List<object>>>();
            foreach (var group in Types.Keys(sec))
            {
                if ("DEF" == group)
                {
                    continue;
                }
                var set = Types.List(Types.Get(Types.Get(sec, group), "set"));
                if (null == set)
                {
                    continue;
                }
                out_.Add(new KeyValuePair<string, List<object>>(group, set));
            }
            return out_;
        }

        /// A stable label, so a failure names the entry rather than an index.
        public static string Label(string group, int i, object entry)
        {
            return Types.Str(Types.Get(entry, "id")) ?? (group + "#" + i);
        }

        /// <summary>
        /// Partial match: every key the expectation names must agree, and
        /// keys it does not name are ignored. <c>__EXISTS__</c> asserts
        /// presence without pinning a value; <c>/re/</c> matches a string
        /// as a regular expression.
        /// </summary>
        public static bool Matches(object expect, object actual)
        {
            if ("__EXISTS__".Equals(expect))
            {
                return MISSING != actual && null != actual;
            }
            if ("__UNDEF__".Equals(expect))
            {
                return MISSING == actual;
            }
            if ("__NULL__".Equals(expect))
            {
                return MISSING != actual && null == actual;
            }

            var got = MISSING == actual ? null : actual;

            var pattern = expect as string;
            if (null != pattern && 2 < pattern.Length
                && pattern.StartsWith("/", StringComparison.Ordinal)
                && pattern.EndsWith("/", StringComparison.Ordinal))
            {
                var text = got as string;
                if (null == text)
                {
                    return false;
                }
                // `IsMatch`, not an anchored match: the corpus writes
                // javascript regex literals, and `/cycle=\[/` is a
                // SUBSTRING test there.
                return Regex.IsMatch(text, pattern.Substring(1, pattern.Length - 2));
            }

            var wl = expect as IList<object>;
            if (null != wl)
            {
                var gl = got as IList<object>;
                if (null == gl || wl.Count != gl.Count)
                {
                    return false;
                }
                for (var i = 0; i < wl.Count; i++)
                {
                    if (!Matches(wl[i], gl[i]))
                    {
                        return false;
                    }
                }
                return true;
            }

            var wm = expect as IDictionary<string, object>;
            if (null != wm)
            {
                var gm = got as IDictionary<string, object>;
                if (null == gm)
                {
                    return false;
                }
                foreach (var pair in wm)
                {
                    var sub = gm.TryGetValue(pair.Key, out var v) ? v : MISSING;
                    if (!Matches(pair.Value, sub))
                    {
                        return false;
                    }
                }
                return true;
            }

            return Same(expect, got);
        }

        /// <summary>
        /// Deep equality over spec values. Key order never matters; list order
        /// always does.
        /// </summary>
        /// <remarks>
        /// AGENTS.md section 1: "The plugin library must never be used to implement
        /// its own tests." A shared comparison lets a broken implementation and its
        /// oracle be wrong together and stay green, so the corpus's equality is
        /// written here rather than imported.
        /// </remarks>
        public static bool Same(object expect, object got)
        {
            if (expect is IDictionary<string, object> || got is IDictionary<string, object>)
            {
                if (!(expect is IDictionary<string, object> a)
                    || !(got is IDictionary<string, object> b)
                    || a.Count != b.Count)
                {
                    return false;
                }
                foreach (var pair in a)
                {
                    if (!b.TryGetValue(pair.Key, out var other) || !Same(pair.Value, other))
                    {
                        return false;
                    }
                }
                return true;
            }
            if (expect is IList<object> || got is IList<object>)
            {
                if (!(expect is IList<object> la) || !(got is IList<object> lb)
                    || la.Count != lb.Count)
                {
                    return false;
                }
                for (var i = 0; i < la.Count; i++)
                {
                    if (!Same(la[i], lb[i]))
                    {
                        return false;
                    }
                }
                return true;
            }
            return null == expect ? null == got : expect.Equals(got);
        }

        /// <summary>
        /// Run one entry against a subject and report the disagreement, if
        /// any. The three combinations the spec format allows are enforced
        /// here as well as at build time, because a runner that quietly
        /// accepted <c>err</c> beside <c>out</c> would let a contradictory
        /// entry pass.
        /// </summary>
        public static string Check(object entry, Func<object, object> subject)
        {
            if (Types.Has(entry, "err") && Types.Has(entry, "out"))
            {
                return "entry has both err and out";
            }

            object value = null;
            Exception raised = null;
            try
            {
                value = subject(entry);
            }
            catch (Exception e)
            {
                raised = e;
            }

            if (Types.Has(entry, "err"))
            {
                if (null == raised)
                {
                    return "expected a raise, got: " + Json.Write(value);
                }
                var want = Types.Get(entry, "err");
                if (!true.Equals(want))
                {
                    // Errors compare by CODE (§12). Message wording is a
                    // port's own business, and pinning it would make every
                    // translation a corpus change.
                    var got = Types.CodeOf(raised);
                    if (!got.Equals(want))
                    {
                        return "expected code " + Json.Write(want) + ", got " + got
                               + " (" + raised.Message + ")";
                    }
                }
                if (Types.Has(entry, "match"))
                {
                    var err = Types.NewMap();
                    err["code"] = Types.CodeOf(raised);
                    err["message"] = raised.Message;
                    err["name"] = "PluginError";
                    var got = Types.NewMap();
                    got["err"] = err;
                    if (!Matches(Types.Get(entry, "match"), got))
                    {
                        return "error did not match " + Json.Write(Types.Get(entry, "match"))
                               + ", got " + Json.Write(got);
                    }
                }
                return null;
            }

            if (null != raised)
            {
                return "unexpected raise: " + Types.CodeOf(raised) + " " + raised.Message;
            }

            if (Types.Has(entry, "out") && !Same(Types.Get(entry, "out"), value))
            {
                return "expected " + Json.Write(Types.Get(entry, "out"))
                       + ", got " + Json.Write(value);
            }

            if (Types.Has(entry, "match"))
            {
                var got = Types.NewMap();
                got["in"] = Types.Get(entry, "in");
                got["out"] = value;
                if (!Matches(Types.Get(entry, "match"), got))
                {
                    return "did not match " + Json.Write(Types.Get(entry, "match"))
                           + ", got out=" + Json.Write(value);
                }
            }

            if (!Types.Has(entry, "out") && !Types.Has(entry, "match"))
            {
                return "entry asserts nothing";
            }

            return null;
        }
    }
}

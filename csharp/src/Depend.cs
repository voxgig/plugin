using System;
using System.Collections.Generic;

namespace Voxgig.Plugin
{
    /// <summary>
    /// Dependency cardinality, policy, and the restart graph (§11.3).
    ///
    /// <para>TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE
    /// REQUIREMENT, because only it knows what it can cope with. A
    /// mandatory-static requirement gates activation and restarts on loss;
    /// a mandatory-dynamic one gates but survives a swap; an
    /// optional-static one never gates but restarts on a change; an
    /// optional-dynamic one is a notification and nothing else.</para>
    ///
    /// <para><c>dynamic</c> means the plugin has said, IN WRITING, that it
    /// can survive its provider being swapped underneath it. It is not the
    /// default because most plugins cannot, and the cost of wrongly
    /// assuming they can is a live instance holding a dead
    /// reference.</para>
    /// </summary>
    public static class Depend
    {
        /// A node of the requirement graph, as plain data for the detector.
        public sealed class Node
        {
            public readonly string Ref;
            public readonly List<string> Provides;
            public readonly List<object> Requires;

            public Node(string eref, List<string> provides, List<object> requires)
            {
                Ref = eref;
                Provides = provides;
                Requires = requires;
            }
        }

        /// A bare string is shorthand for <c>{name}</c>.
        public static SortedDictionary<string, object> NormRequire(object raw)
        {
            var out_ = Types.NewMap();
            if (raw is string)
            {
                out_["name"] = raw;
                return out_;
            }
            var map = Types.Map(raw);
            if (null != map)
            {
                foreach (var pair in map)
                {
                    out_[pair.Key] = pair.Value;
                }
            }
            return out_;
        }

        /// <summary>
        /// The requirements a definition declared, normalized.
        ///
        /// <para>BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT
        /// ONE WINS. <c>optional</c> unions rather than overriding - both
        /// spellings are statements that this requirement need not gate
        /// activation, and there is no reading under which one of them
        /// means "actually, mandatory".</para>
        /// </summary>
        public static List<object> Requirements(object options)
        {
            var raw = Types.List(Types.Get(options, "requires")) ?? new List<object>();
            var marked = Types.List(Types.Get(options, "optional"));
            var fallback = Types.Get(options, "policy");

            var out_ = new List<object>();
            foreach (var item in raw)
            {
                var req = NormRequire(item);
                var ismarked = false;
                if (null != marked)
                {
                    foreach (var m in marked)
                    {
                        if (Types.Same(m, Types.Get(req, "name")))
                        {
                            ismarked = true;
                            break;
                        }
                    }
                }
                if (Types.Truthy(Types.Get(req, "optional")) || ismarked)
                {
                    req["optional"] = true;
                }
                if (null == Types.Get(req, "policy") && null != fallback)
                {
                    req["policy"] = fallback;
                }
                out_.Add(req);
            }
            return out_;
        }

        /// <summary>
        /// Does losing this requirement's SELECTED provider restart the
        /// consumer? The mandatory ones under <c>static</c>, and the
        /// <c>static</c> optional ones. <c>dynamic</c> never restarts.
        /// </summary>
        public static bool RestartsOnLoss(object req)
        {
            var policy = Types.Str(Types.Get(req, "policy")) ?? "static";
            return "dynamic" != policy;
        }

        /// <summary>
        /// Does an unmet requirement keep the consumer out of
        /// <c>live</c>? Cardinality alone decides this, NOT policy:
        /// <c>dynamic</c> is a statement about surviving a SWAP, not about
        /// starting without the thing at all.
        /// </summary>
        public static bool GatesActivation(object req)
        {
            return !true.Equals(Types.Get(req, "optional"));
        }

        /// <summary>
        /// Edges that can cause a restart, which is exactly the set a
        /// cycle must be detected over (§11.3). ONLY <c>dynamic</c>
        /// OPTIONAL EDGES ARE EXCLUDED - an earlier draft excluded EVERY
        /// optional edge and thereby admitted the non-terminating case it
        /// was trying to permit.
        /// </summary>
        public static bool RestartCausing(object req)
        {
            return GatesActivation(req) || RestartsOnLoss(req);
        }

        /// <summary>
        /// A cycle through restart-causing requirements is
        /// <c>plugin_dependency_cycle</c>, detected AT LOAD - before
        /// anything runs, because the failure it describes is a
        /// non-terminating reconcile and the only safe time to report that
        /// is before it starts.
        /// </summary>
        public static List<string> DependencyCycle(List<Node> nodes)
        {
            var provider = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);
            foreach (var n in nodes)
            {
                var caps = new List<string>(n.Provides) { n.Ref };
                foreach (var cap in caps)
                {
                    if (!provider.TryGetValue(cap, out var list))
                    {
                        list = new List<string>();
                        provider[cap] = list;
                    }
                    list.Add(n.Ref);
                }
            }

            var edges = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);
            foreach (var n in nodes)
            {
                var out_ = new List<string>();
                foreach (var req in n.Requires)
                {
                    if (!RestartCausing(req))
                    {
                        continue;
                    }
                    if (!provider.TryGetValue(Types.Str(Types.Get(req, "name")) ?? "", out var list))
                    {
                        continue;
                    }
                    foreach (var p in list)
                    {
                        if (p != n.Ref && !out_.Contains(p))
                        {
                            out_.Add(p);
                        }
                    }
                }
                Types.SortStrings(out_);
                edges[n.Ref] = out_;
            }

            // Iterative DFS with an explicit stack: twenty ports, and
            // several of them have no recursion budget worth relying on.
            const int white = 0;
            const int grey = 1;
            const int black = 2;
            var colour = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var n in nodes)
            {
                colour[n.Ref] = white;
            }

            foreach (var start in new List<string>(edges.Keys))
            {
                if (white != colour[start])
                {
                    continue;
                }

                var path = new List<string> { start };
                var stack = new List<int[]>();
                var names = new List<string> { start };
                stack.Add(new[] { 0 });
                colour[start] = grey;

                while (0 < stack.Count)
                {
                    var node = names[names.Count - 1];
                    var index = stack[stack.Count - 1][0];
                    var outs = edges[node];
                    if (outs.Count <= index)
                    {
                        colour[node] = black;
                        stack.RemoveAt(stack.Count - 1);
                        names.RemoveAt(names.Count - 1);
                        path.RemoveAt(path.Count - 1);
                        continue;
                    }
                    var next = outs[index];
                    stack[stack.Count - 1][0] = index + 1;
                    if (grey == colour[next])
                    {
                        // Report the cycle itself, not the walk that found
                        // it.
                        var cycle = path.GetRange(path.IndexOf(next),
                                                  path.Count - path.IndexOf(next));
                        cycle.Add(next);
                        return cycle;
                    }
                    if (black == colour[next])
                    {
                        continue;
                    }
                    colour[next] = grey;
                    path.Add(next);
                    names.Add(next);
                    stack.Add(new[] { 0 });
                }
            }
            return null;
        }

        /// Raise on a cycle, naming it. Separate from the detector so the
        /// detector stays pure and corpus-testable.
        public static void CheckCycle(List<Node> nodes)
        {
            var cycle = DependencyCycle(nodes);
            if (null == cycle)
            {
                return;
            }
            Types.Fail("plugin_dependency_cycle",
                       "requirements cycle: " + string.Join(" -> ", cycle),
                       Types.Details("cycle", Types.Strings(cycle)));
        }
    }
}

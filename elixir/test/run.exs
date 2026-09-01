# The whole suite: pure sections by direct call, driver sections by
# command list, and a coverage guard above both.
#
# A plain runner rather than ExUnit, for the same reason the port has no
# hex dependencies: a conformance suite whose only job is to run one
# corpus and report which entries disagree does not need a framework, and
# adding one would make `make test` depend on a mix project nobody else in
# this repo has.

Code.require_file("corpus.exs", __DIR__)
Code.require_file("driver.exs", __DIR__)

defmodule Run do
  alias Voxgig.Plugin
  alias Voxgig.Plugin.Capability
  alias Voxgig.Plugin.Graph
  alias Voxgig.Plugin.Resolve
  alias Voxgig.Plugin.Types
  alias Voxgig.Plugin.Version

  @pure ~w(ref env version capability graph resolve config)
  @driver ~w(lifecycle order point export depend
             declare state resource nest trace apply error)

  def main do
    spec = Corpus.corpus()

    {failures, entries} =
      Enum.reduce(sections(), {[], 0}, fn {name, subjects}, {failures, entries} ->
        run_section(spec, name, subjects, failures, entries)
      end)

    failures = failures ++ coverage(spec, entries)
    report(failures, entries, length(sections()))
  end

  # Dispatch every group, and fail on a group the runner does not know - a
  # group silently not run is worse than a failure.
  defp run_section(spec, name, subjects, failures, entries) do
    groups = Corpus.section(spec, name)

    Enum.reduce(Enum.sort(Map.keys(groups)), {failures, entries}, fn group, {fs, n} ->
      case subject(subjects, group) do
        nil ->
          {fs ++ ["#{name}: corpus group with no subject: #{group}"], n}

        fun ->
          groups[group]
          |> Enum.with_index()
          |> Enum.reduce({fs, n}, fn {entry, i}, {fs, n} ->
            case Corpus.check(entry, fun) do
              nil -> {fs, n + 1}
              why -> {fs ++ ["#{name}/#{Corpus.label(group, i, entry)}: #{why}"], n + 1}
            end
          end)
      end
    end)
  end

  # A subject map is keyed by group name, except `config`, which picks by
  # group PREFIX because its two functions split the section cleanly.
  defp subject(subjects, group) when is_map(subjects), do: Map.get(subjects, group)
  defp subject(subjects, group) when is_function(subjects, 1), do: subjects.(group)

  defp sections do
    ref = &Types.get(&1, "in")
    args = fn e, i -> Enum.at(Types.get(e, "args") || [], i) end
    env = fn e -> Plugin.apply_env(Types.get(e, "in")) end
    rng = fn e -> Version.parse_range(Types.get(e, "in")) end
    cap = fn e -> Capability.resolve_capability(Types.get(e, "in")["req"],
                                                Types.get(e, "in")["candidates"]) end
    graph = fn e -> Graph.resolve_graph(Types.get(e, "in")) end
    drive = fn e -> Driver.drive(Types.get(e, "cmd")) end

    [
      {"ref",
       %{"parse" => &Plugin.parse_ref(ref.(&1)),
         "parsebad" => &Plugin.parse_ref(ref.(&1)),
         "format" => &Plugin.format_ref(args.(&1, 0), args.(&1, 1)),
         "formatbad" => &Plugin.format_ref(args.(&1, 0), args.(&1, 1)),
         "canon" => &Voxgig.Plugin.Ref.canon_ref(ref.(&1)),
         "name" => &Plugin.check_name(ref.(&1)),
         "tag" => &Plugin.check_tag(ref.(&1)),
         "bound" => &Plugin.check_name(ref.(&1)),
         "boundtag" => &Plugin.check_tag(ref.(&1))}},
      {"env",
       %{"option" => env, "value" => env, "toggle" => env,
         "profile" => env, "ambiguous" => env, "reserved" => env}},
      {"version",
       %{"range" => rng, "rangebad" => rng,
         "satisfies" => &Version.satisfies(Types.get(&1, "in")["version"],
                                           Types.get(&1, "in")["range"])}},
      {"capability", %{"match" => cap, "nested" => cap, "rank" => cap}},
      {"graph", %{"resolve" => graph, "blocked" => graph}},
      {"resolve",
       %{"candidates" => &Resolve.resolve_candidates(Types.get(&1, "in")["name"],
                                                     Types.get(&1, "in")["sources"]),
         "from" => &Resolve.resolve_from(ref.(&1))}},
      {"config",
       fn group ->
         cond do
           String.starts_with?(group, "norm") -> &Plugin.normalize_config(Types.get(&1, "in"))
           String.starts_with?(group, "opt") -> &Plugin.resolve_options(Types.get(&1, "in"))
           true -> nil
         end
       end}
    ] ++ Enum.map(@driver, fn name -> {name, fn _group -> drive end} end)
  end

  # EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails on
  # a GROUP with no subject; this closes the level above, because a whole
  # SECTION the runner never mentions is a section silently not run.
  defp coverage(spec, entries) do
    primary = Types.get(spec, "primary") || %{}
    run = @pure ++ @driver
    missing = primary |> Map.keys() |> Enum.reject(&(&1 in run)) |> Enum.sort()
    extra = run |> Enum.reject(&Map.has_key?(primary, &1)) |> Enum.sort()

    []
    # The corpus metadata block is what turns on strict entry validation in
    # every runner, so a corpus that lost it must not silently downgrade
    # this port's checking.
    |> add(1 != Types.get(Types.get(spec, "PLUGIN") || %{}, "version"),
           "corpus PLUGIN.version must be 1")
    |> add([] != missing, "corpus sections no test runs: #{Enum.join(missing, ", ")}")
    |> add([] != extra, "tests name sections the corpus does not have: #{Enum.join(extra, ", ")}")
    # A floor, not a fixture: the corpus grows, and a run that suddenly
    # covers a fraction of it is the failure worth catching.
    |> add(entries < 400, "only #{entries} corpus entries reachable")
  end

  defp add(list, true, message), do: list ++ [message]
  defp add(list, false, _message), do: list

  defp report([], entries, sections) do
    IO.puts("elixir: #{entries} corpus entries across #{sections} sections, all pass")
    System.halt(0)
  end

  defp report(failures, entries, _sections) do
    Enum.each(failures, &IO.puts(:stderr, &1))
    IO.puts(:stderr, "\nelixir: #{length(failures)} failure(s) of #{entries} entries")
    System.halt(1)
  end
end

Run.main()

# The driver (DOCS.md section 4).
#
# Every port implements this same small thing and nothing else is
# port-specific: the probe catalog, the command interpreter, and the
# canonical observable.

defmodule Driver do
  alias Voxgig.Plugin
  alias Voxgig.Plugin.Host
  alias Voxgig.Plugin.Inst
  alias Voxgig.Plugin.Types

  # A sentinel for "this command produced nothing", so a command that
  # legitimately produces nil - `export` of a missing key - still
  # overwrites the previous result.
  @nothing :__driver_nothing__

  # EVERY BINDING IS ARITY TWO, `(next, arg)`, hook and chain alike.
  # Elixir has no optional arguments on anonymous functions and no
  # variadic call, so a port that gave hooks arity one would need `Point`
  # to know which kind it is holding - and the point's kind is the HOST's
  # property, not the binding's. `next` is nil for a hook.

  defp count(i), do: Types.get(Inst.state(i), "count") || 0

  defp bump(i, by), do: Inst.state_put(i, "count", count(i) + by)

  defp opt(i, key), do: Types.get(Inst.options(i), key)

  # Section 4.3's six probes. Their behaviour is as much the contract as
  # the runner is - this is where twenty implementations of `noisy` are
  # made to fail at the same callback in the same way.
  def probes do
    [probe(), noisy(), greedy(), dep(), provider(),
     record("slow"), record("other"), record("adapter"), record("late")]
  end

  defp record(name) do
    %{"name" => name,
      "define" => fn i -> bump(i, 0) end,
      "activate" => fn i -> Inst.acquire(i) end}
  end

  defp probe do
    %{"name" => "probe",
      "define" => fn i ->
        bump(i, 0)
        band = opt(i, "band")

        # One hook binding (`p`) and one chain wrap (`c`) - the workhorse
        # shape DOCS.md section 4.3 specifies. `p` RETURNS NOTHING, as the
        # canonical's arrow-with-a-block does: in `bail` mode a return is
        # an answer, and a counter that answered with its own count would
        # make every hook that keeps one un-bailable.
        Inst.bind(i, "p", fn _next, _arg ->
          bump(i, 1)
          nil
        end, band)

        # Wrap AFTER next, so the result spells the nesting left to right:
        # outermost first. Wrapping the ARGUMENT instead would spell it
        # backwards and make every chain expectation read wrong.
        Inst.bind(i, "c", fn next, v -> "#{opt(i, "wrap") || ":"}#{next.(v)}" end, band)
        Inst.export(i, "client", Inst.ref(i))
        # The instance api itself, so the driver's `stray` command can call
        # `release` from OUTSIDE a lifecycle callback.
        Inst.export(i, "inst", i)
        declareprovides(i)
      end,
      "activate" => fn i ->
        Inst.acquire(i)

        # Section 6.5: an instance that is itself a host. The outer owns
        # the inner's lifetime - registered in the scope, so it closes on
        # deactivate in the same reverse unwind as every other resource.
        nest = opt(i, "nest")

        if not is_nil(nest) do
          inner = Inst.nest(i, %{"points" => withpoints()})
          Enum.each(probes(), &Host.catalog_add(inner, &1))
          Enum.each(nest, &Host.ready(inner, &1))
        end
      end}
  end

  defp noisy do
    %{"name" => "noisy",
      "define" => fn i ->
        bump(i, 0)
        boom(i, "define")
      end,
      "activate" => fn i ->
        # Acquire BEFORE the raise, so a failing activate has something to
        # leak if the scope does not unwind - which is the whole point of
        # the entry that asserts open == 0 afterwards.
        Inst.acquire(i)
        reenter(i, "activate")
        boom(i, "activate")
      end,
      "deactivate" => fn i -> boom(i, "deactivate") end,
      "close" => fn i -> boom(i, "close") end}
  end

  defp greedy do
    %{"name" => "greedy",
      "define" => fn i ->
        Inst.state_put(i, "count", 0)
        # Section 8.1 puts resource capture in `activate`. `early` NAMES
        # the call that reaches for it in `define`, because `acquire` and
        # `release` carry the guard separately.
        if "acquire" == opt(i, "early"), do: Inst.acquire(i)
        if "release" == opt(i, "early"), do: Inst.release(i, fn -> nil end)
      end,
      "activate" => fn i ->
        handles = Enum.map(1..(opt(i, "acquire") || 0)//1, fn _ -> Inst.acquire(i) end)
        # Release some explicitly; the DIFFERENCE is what the instance
        # scope must unwind by itself (section 8.3), and that difference is
        # the whole test.
        handles |> Enum.take(opt(i, "release") || 0) |> Enum.each(& &1.())

        # `bind` is `early`'s counterpart for section 8.1's OTHER half.
        # Binding declaration belongs in `define`; this names the callback
        # that tries it from somewhere else.
        if "activate" == opt(i, "bind"), do: Inst.bind(i, "p", fn _next, _arg -> nil end)

        # `mark` registers N FOREIGN releases - section 8.3's `release`,
        # the half `acquire` cannot exercise - each recording its own index
        # as it runs. THE RECORDED LIST IS THE ONLY THING THAT
        # DISTINGUISHES A REVERSE UNWIND FROM A FORWARD ONE.
        Inst.state_put(i, "unwound", [])

        Enum.each(0..((opt(i, "mark") || 0) - 1)//1, fn k ->
          Inst.release(i, fn ->
            # `markfail` makes the release RAISE - the only way section
            # 8.3's `plugin_release_failed` and its `failed` status are
            # reachable.
            if Types.truthy(opt(i, "markfail")) do
              raise ArgumentError, "release failed at #{k}"
            end

            Inst.state_update(i, "unwound", [], &(&1 ++ [k]))
          end)
        end)
      end,
      # `deactivate` completes the pair: the guard is on the PHASE, not on
      # "not define", and an entry exercising only one leaves the other's
      # mutation alive.
      "deactivate" => fn i ->
        if "deactivate" == opt(i, "bind"), do: Inst.bind(i, "p", fn _next, _arg -> nil end)
      end}
  end

  defp dep do
    %{"name" => "dep",
      "define" => fn i ->
        Inst.state_put(i, "count", 0)
        declareprovides(i)
        exports = opt(i, "exports") || %{}
        Enum.each(Types.keys(exports), &Inst.export(i, &1, Types.get(exports, &1)))
      end,
      "activate" => fn i -> Inst.acquire(i) end}
  end

  defp provider do
    %{"name" => "provider",
      "define" => fn i ->
        Inst.state_put(i, "count", 0)

        Inst.bind(i, opt(i, "point") || "v", fn _next, _arg ->
          if Types.has(Inst.options(i), "value"), do: opt(i, "value"), else: Inst.ref(i)
        end, opt(i, "band"))

        declareprovides(i)
      end,
      "activate" => fn i -> Inst.acquire(i) end}
  end

  defp declareprovides(i) do
    Enum.each(opt(i, "provides") || [], &Inst.provides(i, &1))
  end

  defp boom(i, callback) do
    if callback == opt(i, "fail") do
      # `bare` raises WITHOUT a code - the ordinary library error section
      # 12's `plugin_<phase>_failed` codes exist to wrap.
      if Types.truthy(opt(i, "bare")) do
        raise ArgumentError, "probe failed at #{callback}"
      end

      Types.fail(opt(i, "code") || "plugin_#{callback}_failed",
                 "probe failed at #{callback}")
    end
  end

  defp reenter(i, callback) do
    # A transition from inside a lifecycle callback (section 5.2).
    if callback == opt(i, "reenter"), do: Host.activate(Inst.host(i), Inst.ref(i))
  end

  # The points every driver host declares. DOCS.md section 4.3 defines
  # `probe` as binding one hook point (`p`) and wrapping one chain point
  # (`c`), so a host without them cannot load the probe at all - they are
  # part of the contract's baseline rather than a fixture convenience. `v`
  # is the provider point the `provider` probe defaults to.
  def basepoints do
    %{"p" => %{"kind" => "hook"},
      "c" => %{"kind" => "chain", "base" => fn value -> value end},
      "v" => %{"kind" => "provider"}}
  end

  # A `host` command REPLACES a base point rather than merging into it, so
  # an entry can redeclare `c` with its own base or `v` as exclusive
  # without inheriting the default's shape.
  def withpoints(extra \\ nil), do: Map.merge(basepoints(), extra || %{})

  def withprobes, do: Plugin.make_catalog(probes())

  @doc """
  Run a command list and return section 4.5's observable. Stops at the
  first raise; the entry's `err` matches its code.
  """
  def drive(cmds) do
    host = Plugin.make_host(%{"catalog" => withprobes(), "points" => withpoints()})

    # Section 4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES
    # ONE. Storing it and continuing - rather than returning at the first
    # producing command - is what lets an entry emit and then inspect,
    # which most of `point` needs.
    {host, last} =
      Enum.reduce(cmds, {host, nil}, fn cmd, {host, last} ->
        try do
          {next, value} = docmd(host, cmd)
          {next, if(@nothing == value, do: last, else: value)}
        rescue
          e ->
            # Section 4.1: `catch` records the raise and lets the run
            # continue, which is the only way to observe a `failed`
            # instance - section 5.2's whole claim is that it stays
            # registered and inspectable.
            if true == Types.get(cmd, "catch"),
              do: {host, last},
              else: reraise(e, __STACKTRACE__)
        end
      end)

    Host.observable(host, last)
  end

  def docmd(host, cmd) do
    ref = Types.get(cmd, "ref")
    point = Types.get(cmd, "point")

    spec = %{"options" => Types.get(cmd, "options"), "order" => Types.get(cmd, "order"),
             "definition" => Types.get(cmd, "definition"), "tag" => Types.get(cmd, "tag")}

    case Types.get(cmd, "do") do
      "host" ->
        {Plugin.make_host(%{
           "catalog" => withprobes(),
           "reserved" => Types.get(cmd, "reserved"),
           "keys" => Types.get(cmd, "keys"),
           "defaults" => Types.get(cmd, "defaults"),
           "profile" => Types.get(cmd, "profile"),
           "points" => withpoints(Types.get(cmd, "points")),
           # Section 11.3's strict reading. Absent means `restart`.
           "dependency" => Types.get(cmd, "dependency")
         }), @nothing}

      # The catalog is pre-seeded with the probe set; `define` names which
      # entry backs this definition.
      "define" -> {host, @nothing}
      "load" -> nothing(host, fn -> Host.load(host, ref, spec) end)
      "ready" ->
        # declare FIRST, so the ordering block and definition reach the
        # instance - `ready` walks the staircase, it does not carry
        # configuration of its own.
        Host.declare(host, ref, spec)
        nothing(host, fn -> Host.ready(host, ref) end)

      "activate" -> nothing(host, fn -> Host.activate(host, ref) end)
      "deactivate" -> nothing(host, fn -> Host.deactivate(host, ref) end)
      "unload" -> nothing(host, fn -> Host.unload(host, ref) end)
      "apply" -> nothing(host, fn -> Host.apply(host, Types.get(cmd, "doc"), Types.get(cmd, "profile")) end)
      "options" -> nothing(host, fn -> Host.options(host, ref, Types.get(cmd, "patch")) end)
      "close" -> nothing(host, fn -> Host.close(host) end)
      "list" -> {host, Host.list(host)}
      "emit" -> {host, Host.emit(host, point, Types.get(cmd, "arg"))}
      "chain" -> {host, Host.call(host, point, Types.get(cmd, "arg"))}
      "provider" -> {host, Host.provider(host, point, Types.get(cmd, "arg"))}
      "shadowed" -> {host, Host.shadowed(host, point)}
      "export" -> {host, Host.exports(host, Types.get(cmd, "key"))}
      "capability" -> {host, Host.capability(host, Types.get(cmd, "name"))}
      "trace" -> {host, Host.trace(host)}
      # Section 9.1's host-owned path: the embedding host installing the
      # instance whose name it reserved.
      "hostdeclare" -> {host, Host.hostdeclare(host, ref, spec)["ref"]}
      "declare" -> {host, Host.declare(host, ref, spec)["ref"]}
      "order" -> {host, Host.order(host, point)}
      "seq" -> {host, entryfield(host, ref, "seq")}
      "pos" -> {host, entryfield(host, ref, "pos")}
      "inner" ->
        inner = entryfield(host, ref, "inner")
        {host, if(inner, do: Host.list(inner), else: nil)}

      "call" -> docall(host, cmd, ref, point)
      other -> raise ArgumentError, "unknown driver command: #{other}"
    end
  end

  defp nothing(host, fun) do
    fun.()
    {host, @nothing}
  end

  defp entryfield(host, ref, key) do
    entry = Host.instance(host, ref)
    if entry, do: entry[key], else: nil
  end

  defp docall(host, cmd, ref, point) do
    entry = Host.instance(host, ref)

    if is_nil(entry) do
      Types.fail("plugin_not_loaded", "no such instance: #{ref}")
    end

    case Types.get(cmd, "method") do
      "bump" ->
        Host.entry_update(host, entry["ref"], fn e ->
          Map.put(e, "state", Map.put(e["state"], "count", (e["state"]["count"] || 0) + 1))
        end)

        {host, @nothing}

      "count" -> {host, Types.get(entry["state"], "count") || 0}
      "unwound" -> {host, Types.get(entry["state"], "unwound") || []}
      # Reached through the instance api, which is where section 6.6 puts
      # it - a plugin asks about itself.
      "position" -> {host, Host.positionof(host, ref, point)}
      "stray" ->
        # A release from OUTSIDE a lifecycle callback. THIS BRANCH USED TO
        # DO NOTHING, and its corpus row stayed green whatever `release`
        # did with its guard.
        Inst.release(Host.exports(host, "#{ref}/inst"), fn -> nil end)
        {host, @nothing}

      _ -> {host, @nothing}
    end
  end
end

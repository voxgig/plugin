# The corpus runner.
#
# Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
# exactly as every other port's runner does. No port needs a Node
# toolchain to run its tests, and this one does not get a private door
# into the source either.
#
# A group name selects the subject. That is the whole dispatch, and it is
# deliberately dumb: a runner that inferred the subject from the entry's
# shape would silently run the wrong function when an entry was mistyped.

defmodule Corpus do
  alias Voxgig.Plugin.Json
  alias Voxgig.Plugin.Types

  @spec_path Path.join([__DIR__, "..", "..", "spec", "plugin.json"])

  # A sentinel for "this key was not present". `Map.get` returns nil for
  # both an absent key and a JSON null, and `__UNDEF__` and `__NULL__` are
  # different assertions.
  @missing :__corpus_missing__

  def corpus, do: @spec_path |> File.read!() |> Json.parse()

  def section(spec, name) do
    sec = Types.get(Types.get(spec, "primary") || %{}, name)
    if is_nil(sec), do: raise(ArgumentError, "no such corpus section: #{name}")

    sec
    |> Enum.filter(fn {group, body} ->
      "DEF" != group and is_map(body) and is_list(Types.get(body, "set"))
    end)
    |> Map.new(fn {group, body} -> {group, Types.get(body, "set")} end)
  end

  # A stable label, so a failure names the entry rather than an index.
  def label(group, i, entry), do: Types.get(entry, "id") || "#{group}##{i}"

  @doc """
  Deep equality over spec values. Key order never matters; list order
  always does.

  Elixir's `true == 1` is already false - atoms and numbers never compare
  equal - so the bool guard the other dynamic ports need is not required
  here. `1 == 1.0` IS true, as it is in ruby and javascript, and no corpus
  entry turns on the difference.
  """
  def same(a, b) when is_map(a) and is_map(b) do
    map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and same(v, Map.get(b, k)) end)
  end

  def same(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and a |> Enum.zip(b) |> Enum.all?(fn {x, y} -> same(x, y) end)
  end

  def same(a, b) when is_list(a) or is_list(b) or is_map(a) or is_map(b), do: false

  def same(a, b), do: a == b

  @doc """
  Partial match: every key the expectation names must agree, and keys it
  does not name are ignored. `__EXISTS__` asserts presence without pinning
  a value; `/re/` matches a string as a regular expression.
  """
  def matches("__EXISTS__", actual), do: @missing != actual and not is_nil(actual)
  def matches("__UNDEF__", actual), do: @missing == actual
  def matches("__NULL__", actual), do: @missing != actual and is_nil(actual)

  def matches(expect, @missing), do: matches(expect, nil)

  def matches(expect, actual) when is_binary(expect) do
    if 2 < byte_size(expect) and String.starts_with?(expect, "/") and
         String.ends_with?(expect, "/") do
      is_binary(actual) and
        Regex.match?(Regex.compile!(binary_part(expect, 1, byte_size(expect) - 2)), actual)
    else
      expect == actual
    end
  end

  def matches(expect, actual) when is_list(expect) do
    is_list(actual) and length(expect) == length(actual) and
      expect |> Enum.zip(actual) |> Enum.all?(fn {e, a} -> matches(e, a) end)
  end

  def matches(expect, actual) when is_map(expect) do
    is_map(actual) and
      Enum.all?(expect, fn {k, v} ->
        matches(v, if(Map.has_key?(actual, k), do: Map.get(actual, k), else: @missing))
      end)
  end

  def matches(expect, actual), do: expect == actual

  @doc """
  Run one entry against a subject and report the disagreement, if any.

  The three combinations the spec format allows are enforced here as well
  as at build time, because a runner that quietly accepted `err` beside
  `out` would let a contradictory entry pass.
  """
  def check(entry, subject) do
    if Types.has(entry, "err") and Types.has(entry, "out") do
      "entry has both err and out"
    else
      verdict(entry, outcome(entry, subject))
    end
  end

  defp outcome(entry, subject) do
    {:ok, subject.(entry)}
  rescue
    e -> {:raised, e}
  end

  defp verdict(entry, {:ok, value}) do
    cond do
      Types.has(entry, "err") ->
        "expected a raise, got: #{Types.encode(value)}"

      Types.has(entry, "out") and not same(Types.get(entry, "out"), value) ->
        "expected #{Types.encode(Types.get(entry, "out"))}, got #{Types.encode(value)}"

      Types.has(entry, "match") and
          not matches(Types.get(entry, "match"), %{"in" => Types.get(entry, "in"), "out" => value}) ->
        "did not match #{Types.encode(Types.get(entry, "match"))}, got out=#{Types.encode(value)}"

      not Types.has(entry, "out") and not Types.has(entry, "match") ->
        "entry asserts nothing"

      true ->
        nil
    end
  end

  defp verdict(entry, {:raised, e}) do
    if Types.has(entry, "err"), do: errverdict(entry, e), else:
      "unexpected raise: #{Types.codeof(e)} #{Types.message(e)}"
  end

  defp errverdict(entry, e) do
    want = Types.get(entry, "err")
    # Errors compare by CODE (section 12). Message wording is a port's own
    # business, and pinning it would make every translation a corpus
    # change.
    got = Types.codeof(e)

    cond do
      true != want and got != want ->
        "expected code #{want}, got #{got} (#{Types.message(e)})"

      Types.has(entry, "match") and
          not matches(Types.get(entry, "match"),
                      %{"err" => %{"code" => got, "message" => Types.message(e),
                                   "name" => "PluginError"}}) ->
        "error did not match #{Types.encode(Types.get(entry, "match"))}, got code=#{got}"

      true ->
        nil
    end
  end
end

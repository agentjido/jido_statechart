defmodule Mix.Tasks.Statechart.W3c do
  use Mix.Task

  alias Jido.Statechart.Conformance
  alias Jido.Statechart.SCXML

  @shortdoc "Runs W3C SCXML fixtures and local statechart cases in live Agents"
  @requirements ["app.start"]
  @manifest_results ~w(PASS ADJUSTED XFAIL DEFERRED FAIL)

  @impl Mix.Task
  def run(["--example", path]) do
    {cases, _bindings} = Code.eval_file(path)

    Enum.each(cases, fn %{name: name} = test_case ->
      report(name, Conformance.run(test_case))
    end)
  end

  def run(["--manifest", path]) do
    directory = Path.dirname(path)

    counts =
      path
      |> manifest_entries()
      |> Enum.frequencies_by(fn {entry, deferral} ->
        {status, detail} = manifest_result(directory, entry, deferral)
        message = if detail, do: " (#{detail})", else: ""
        Mix.shell().info("#{status} #{entry}#{message}")
        status
      end)

    total = counts |> Map.values() |> Enum.sum()
    summary = Enum.map_join(@manifest_results, "  ", &"#{&1} #{Map.get(counts, &1, 0)}")
    Mix.shell().info("TOTAL #{total}  #{summary}")

    if Map.get(counts, "FAIL", 0) > 0, do: Mix.raise("W3C manifest has unexpected results")
  end

  def run([path]), do: report(path, Conformance.w3c(path))

  def run(_args),
    do:
      Mix.raise(
        "Usage: mix statechart.w3c FIXTURE_PATH | --manifest PATH.xml | --example PATH.exs"
      )

  @doc false
  def manifest_entries(path) do
    case path |> File.read!() |> SCXML.read!() do
      {{nil, "assertions"}, _, assertions} ->
        entries =
          for {{nil, "assert"}, attributes, tests} <- assertions,
              {{nil, "test"}, _, files} <- tests,
              {{nil, "start"}, start, _} <- files do
            {{nil, "specnum"}, section} = List.keyfind!(attributes, {nil, "specnum"}, 0)
            {{nil, "uri"}, entry} = List.keyfind!(start, {nil, "uri"}, 0)
            {entry, deferral_reason(section)}
          end

        if entries == [], do: Mix.raise("W3C manifest has no start entries: #{path}")
        entries

      _ ->
        Mix.raise("Expected a W3C assertions manifest: #{path}")
    end
  rescue
    error in [File.Error, ArgumentError, KeyError, SCXML.Unsupported] ->
      Mix.raise("Cannot read W3C manifest #{path} (#{Exception.message(error)})")
  end

  defp deferral_reason("5.8"), do: "requires scripting"
  defp deferral_reason("B.2"), do: "requires ECMAScript"
  defp deferral_reason(_section), do: nil

  defp manifest_result(_directory, _entry, reason) when is_binary(reason),
    do: {"DEFERRED", reason}

  defp manifest_result(directory, entry, nil) do
    case {entry, Conformance.w3c(Path.join(directory, entry))} do
      {"198/test198.txml", :ok} ->
        {"ADJUSTED", ~s(origintype URI comparison mapped to "scxml")}

      {"352/test352.txml", {:fail, :fixture_reached_fail}} ->
        {"XFAIL", ~s(fixture expects the origintype URI, SCXML requires "scxml")}

      {"352/test352.txml", result} ->
        {"FAIL", "expected fixture to reach fail, got #{inspect(result)}"}

      {_entry, :ok} ->
        {"PASS", nil}

      {_entry, result} ->
        {"FAIL", inspect(result)}
    end
  end

  defp report(name, :ok), do: Mix.shell().info("PASS #{name}")
  defp report(name, {:skip, reason}), do: Mix.raise("SKIP #{name} (#{reason})")
  defp report(name, {:fail, reason}), do: Mix.raise("FAIL #{name} (#{inspect(reason)})")
  defp report(name, {:error, reason}), do: Mix.raise("ERROR #{name} (#{inspect(reason)})")
end

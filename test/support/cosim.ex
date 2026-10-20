defmodule ExAudio.Cosim do
  @moduledoc false
  # Co-simulation of a kernel specification (ExAudio.Q.spec/5): the generated RTL under
  # Verilator against the Nx reference, bit for bit, with and without backpressure.
  import ExUnit.Assertions

  alias ExAudio.Q
  alias ExHdl.Sim.Verilator

  # {valid_pct, ready_pct, seed}
  @traffic [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}]

  def build(spec, name, opts \\ []) do
    {:ok, design} = Q.to_sv(spec, [name: name] ++ opts)
    {:ok, sim} = Verilator.build_stream(design)
    sim
  end

  def leaf_ints(container),
    do: [container] |> Nx.Defn.Composite.flatten_list() |> Enum.map(&Nx.to_flat_list/1)

  @doc "Reference outputs: one flat integer list per output leaf."
  def reference(spec, samples, opts \\ []),
    do: spec |> Q.run(samples, opts) |> elem(0) |> leaf_ints()

  defp params(spec) do
    case spec[:params] do
      nil ->
        []

      params ->
        [params]
        |> Nx.Defn.Composite.flatten_list()
        |> Enum.map(fn t -> if Nx.rank(t) == 0, do: Nx.to_number(t), else: Nx.to_flat_list(t) end)
    end
  end

  @doc "Runs `samples` through the RTL under each traffic pattern and compares with `expected`."
  def check(sim, spec, samples, expected, opts \\ []) do
    inputs = if is_list(samples), do: [samples], else: [samples]
    total = Keyword.fetch!(opts, :total)

    assert expected |> hd() |> Enum.uniq() |> length() > 3,
           "the stimulus must produce varied output"

    for {vp, rp, seed} = traffic <- @traffic do
      assert {:ok, res} =
               Verilator.run_stream(sim, inputs, params(spec),
                 valid_pct: vp,
                 ready_pct: rp,
                 seed: seed
               )

      assert res.outputs == expected,
             "traffic #{inspect(traffic)}: first mismatch at sample #{first_mismatch(res.outputs, expected)}"

      # no backpressure: one sample per ii cycles, pipeline fill and the harness drain
      if traffic == {100, 100, 1},
        do:
          assert(res.cycles <= total * sim.design.ii + sim.design.latency + drain(sim.design) + 2)
    end

    :ok
  end

  @doc """
  `channels: n` kernels: samples are dealt round robin to n channels; each channel
  must match the reference run on its own subsequence. Samples are a list of ints.
  """
  def check_channels(sim, spec, samples, n) do
    total = length(samples)

    per_channel =
      for c <- 0..(n - 1) do
        sub = samples |> Enum.drop(c) |> Enum.take_every(n)
        reference(spec, sub)
      end

    expected =
      for leaf <- 0..(length(hd(per_channel)) - 1) do
        for i <- 0..(total - 1) do
          per_channel |> Enum.at(rem(i, n)) |> Enum.at(leaf) |> Enum.at(div(i, n))
        end
      end

    check(sim, spec, samples, expected, total: total)
    {:ok, res} = Verilator.run_stream(sim, [samples], params(spec), seed: 1)
    assert res.cycles <= total + sim.design.latency + 64 + 2
  end

  defp first_mismatch(got, expected) do
    got
    |> Enum.zip(expected)
    |> Enum.map(fn {g, e} ->
      Enum.zip(g, e) |> Enum.find_index(fn {a, b} -> a != b end) || min(length(g), length(e))
    end)
    |> Enum.min()
  end

  # idle cycles the stream harness runs after the last sample (ExHdl.Sim.Verilator)
  defp drain(d), do: 64 + if(max(d.ii, d.latency) >= 64, do: max(d.ii, d.latency), else: 0)
end

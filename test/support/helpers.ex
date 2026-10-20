defmodule ExAudio.TestHelpers do
  @moduledoc false
  import ExUnit.Assertions
  import StreamData

  alias NxFixed.IntSet

  @fs 48_000

  def fs, do: @fs

  @doc "Every next-state value is proven to stay within the declared range of its state tensor."
  def assert_state_closed(spec, extra \\ []) do
    {:ok, scan} = ExAudio.Q.analyze(spec, extra)
    graph = scan.graph
    {_, next_ids} = graph.outputs
    layout = Enum.find(scan.args, &(&1.role == :state))
    ranges = spec[:param_ranges]

    nexts = flat(next_ids)
    assert length(nexts) == length(layout.leaves)

    for {id, leaf} <- Enum.zip(nexts, layout.leaves) do
      declared = ranges[leaf.index]
      proven = graph.nodes[id].range

      if declared do
        assert IntSet.subtype?(proven, IntSet.range(declared.first, declared.last)),
               "state leaf #{leaf.index}: next value #{inspect(IntSet.bounds(proven))} leaves #{inspect(declared)}"
      end
    end

    scan
  end

  defp flat(x) when is_tuple(x), do: x |> Tuple.to_list() |> Enum.flat_map(&flat/1)
  defp flat(x) when is_list(x), do: Enum.flat_map(x, &flat/1)
  defp flat(x), do: [x]

  @doc "Sum of a sine and uniform noise as 24-bit integers."
  def signal(n, freq, amp, noise, seed) do
    :rand.seed(:exsss, {seed, 7, 13})

    for i <- 0..(n - 1)//1 do
      v = amp * :math.sin(2 * :math.pi() * freq * i / @fs) + noise * (:rand.uniform() * 2 - 1)
      v |> round() |> max(-8_388_608) |> min(8_388_607)
    end
  end

  def log_uniform(lo, hi) do
    map(float(min: :math.log10(lo), max: :math.log10(hi)), &:math.pow(10, &1))
  end

  def db(x), do: 20 * :math.log10(max(abs(x), 1.0e-12))
end

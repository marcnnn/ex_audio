defmodule ExAudio.MixerStripTest do
  @moduledoc """
  The channel strip bank (`ExAudio.Mixer.Strip`) in Verilator against the
  Nx reference of every channel: its own coefficients (4 biquads, gate,
  compressor) written through the 32-bit window, a bank swap in the middle
  of the stream, random gaps in the input, a sideband per sample.
  """
  use ExUnit.Case, async: true

  import ExAudio.MixerBench

  alias ExAudio.Mixer.{Config, Strip}
  alias ExHdl.RTL.Cosim

  @moduletag :verilator
  @moduletag timeout: 1_800_000

  defp write(c, w, v),
    do: %{
      coeff_en: 1,
      coeff_we: 1,
      coeff_be: 15,
      coeff_addr: c * 64 + w,
      coeff_wdata: v
    }

  @idle %{coeff_en: 0, coeff_we: 0}

  defp bank_writes(bank, channels),
    do: for(c <- channels, {v, w} <- Enum.with_index(strip_words(c, bank)), do: write(c, w, v))

  # Runs `frames` frames of `n` channels, flipping to bank :b at frame `flip`.
  defp run(opts, frames, flip, gap_pct) do
    cfg = Config.new(opts)
    n = cfg.channels
    mod = Strip.build(cfg, "t")
    {:ok, sim} = Cosim.build(mod)
    late = for c <- 0..(n - 1), rem(c, 16) == 3, do: c
    early = Enum.to_list(0..(n - 1)) -- late

    xs = for c <- 0..(n - 1), into: %{}, do: {c, signal(frames, c)}
    users = for f <- 0..(frames - 1), c <- 0..(n - 1), do: rem(f * 7 + c * 3, 2)
    list = for f <- 0..(frames - 1), c <- 0..(n - 1), do: Enum.at(xs[c], f)

    stream =
      list
      |> Enum.zip(users)
      |> Enum.with_index()
      |> Enum.map(fn {{x, u}, i} -> {x, rem(i, n), u} end)
      |> beats(7, gap_pct)

    # swap requested with the beat that is 500 samples into frame flip - 1
    k = (flip - 1) * n + div(n, 2)

    cycle_of_beat =
      stream
      |> Enum.with_index()
      |> Enum.filter(fn {m, _} -> m.s_axis_tvalid == 1 end)
      |> Enum.map(&elem(&1, 1))
      |> List.to_tuple()

    swap_cycle = elem(cycle_of_beat, k)
    late_writes = bank_writes(:b, late)
    assert length(late_writes) < swap_cycle

    stream =
      stream
      |> Enum.with_index()
      |> Enum.map(fn {m, i} ->
        m = Map.merge(m, Enum.at(late_writes, i) || @idle)
        if i == swap_cycle, do: Map.put(m, :swap, 1), else: Map.put(m, :swap, 0)
      end)

    stimulus =
      reset() ++
        [%{m_axis_tready: 1, swap: 0} | List.duplicate(@idle, 10)] ++
        bank_writes(:a, 0..(n - 1)) ++
        [@idle, %{swap: 1}, %{swap: 0}] ++
        List.duplicate(@idle, 100) ++
        bank_writes(:b, early) ++
        [@idle] ++ stream ++ [Map.put(@idle, :s_axis_tvalid, 0)] ++ List.duplicate(@idle, 400)

    {:ok, outs} = Cosim.run(sim, stimulus)
    held = Cosim.full_inputs(mod, stimulus)

    # every beat the stimulus offers is taken (outputs are sampled before the edge)
    for {i, o} <- Enum.zip(held, outs), i.s_axis_tvalid == 1 do
      assert o.s_axis_tready == 1
    end

    got = for o <- outs, o.m_axis_tvalid == 1, do: o

    refs =
      strip_references(0..(n - 1), fn c ->
        x = xs[c]
        [{:a, Enum.take(x, flip)}, {:b, Enum.drop(x, flip)}]
      end)

    expected =
      for f <- 0..(frames - 1), c <- 0..(n - 1) do
        {seg, i} = if f < flip, do: {0, f}, else: {1, f - flip}
        {c, refs[c] |> Enum.at(seg) |> Enum.at(i)}
      end

    assert length(got) == length(expected)

    got_pairs = for o <- got, do: {o.m_axis_tid, signed24(o.m_axis_tdata)}

    mismatches =
      got_pairs
      |> Enum.zip(expected)
      |> Enum.with_index()
      |> Enum.reject(fn {{g, e}, _} -> g == e end)

    assert mismatches == [],
           "#{length(mismatches)} of #{length(got)} samples differ, first: #{inspect(Enum.take(mismatches, 3))}"

    assert Enum.map(got, & &1.m_axis_tuser) == users
    assert Enum.uniq(for {_, y} <- got_pairs, do: y) |> length() > div(length(got), 2)
    # the swap was visible on the pending flag
    assert Enum.any?(outs, &(&1.pending == 1))
    assert List.last(outs).pending == 0
    {cfg, got_pairs, expected}
  end

  test "24 channels: coefficients per channel, bank swap, gaps" do
    {_cfg, got, expected} = run([channels: 24, state_mem: :block], 12, 7, 15)
    assert got == expected
  end

  @tag :slow
  test "1024 channels at one sample per cycle, state in UltraRAM, distinct strips per channel" do
    {cfg, got, expected} = run([], 12, 7, 10)
    assert cfg.channels == 1024
    assert got == expected
  end
end

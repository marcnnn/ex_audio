defmodule ExAudio.StripTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExAudio.TestHelpers

  alias ExAudio.{Biquad, Dynamics, Filter, Q, Strip}

  @full 8_388_608

  defp bands do
    [
      Filter.design(:highpass, 80, fs()),
      Filter.design(:lowshelf, 200, fs(), gain_db: 4),
      Filter.design(:peaking, 1000, fs(), q: 2, gain_db: 6),
      Filter.design(:highshelf, 6000, fs(), gain_db: -5)
    ]
    |> Enum.map(&Biquad.quantize/1)
  end

  defp run(spec, xs), do: spec |> Q.run(xs) |> elem(0) |> Nx.to_flat_list()

  test "the cascade is exactly the biquads one after the other" do
    xs = signal(500, 700.0, 3.0e6, 5.0e5, 4)
    sequential = Enum.reduce(bands(), xs, fn c, acc -> acc |> Biquad.run(c) |> elem(0) end)
    assert run(Strip.spec(bands()), xs) == sequential
  end

  test "the full strip is the cascade, gate and compressor one after the other" do
    opts = [
      gate: [open_db: -45, hold_ms: 2, release_ms: 5, detector_release_ms: 5],
      compressor: [threshold_db: -18, ratio: 3, attack_ms: 1, release_ms: 20]
    ]

    xs = signal(1500, 300.0, 2.0e6, 1.0e5, 6) ++ signal(1500, 300.0, 3.0e3, 0.0, 7)
    eq = Enum.reduce(bands(), xs, fn c, acc -> acc |> Biquad.run(c) |> elem(0) end)
    gated = run(Dynamics.spec(:gate, opts[:gate]), eq)
    expected = run(Dynamics.spec(:compressor, opts[:compressor]), gated)
    assert run(Strip.spec(bands(), [dynamics: true] ++ opts), xs) == expected
  end

  test "steady-state gain of the cascade is the sum of the sections' gains" do
    # whole cycles in the 1000 sample analysis window: f = k * 48 Hz
    for f <- [96.0, 960.0, 4800.0] do
      xs = signal(6000, f, 1.0e6, 0.0, 1)
      ys = run(Strip.spec(bands()), xs) |> Enum.take(-1000)
      w = 2 * :math.pi() * f / fs()

      re =
        ys |> Enum.with_index() |> Enum.map(fn {y, n} -> y * :math.cos(w * n) end) |> Enum.sum()

      im =
        ys |> Enum.with_index() |> Enum.map(fn {y, n} -> y * :math.sin(w * n) end) |> Enum.sum()

      amplitude = 2 / 1000 * :math.sqrt(re * re + im * im)

      expected =
        bands()
        |> Enum.map(&(&1 |> Biquad.dequantize() |> Filter.magnitude_db(f, fs())))
        |> Enum.sum()

      assert_in_delta db(amplitude / 1.0e6), expected, 0.01
    end
  end

  test "baked parameters give the same samples as parameter ports" do
    xs = signal(300, 900.0, 2.0e6, 1.0e5, 2)
    opts = [dynamics: true, compressor: [threshold_db: -15]]

    assert run(Strip.spec(bands(), opts), xs) ==
             run(Strip.spec(bands(), [baked: true] ++ opts), xs)
  end

  test "saturation inside the cascade clips, it does not wrap" do
    loud = Biquad.quantize(Filter.design(:peaking, 1000, fs(), q: 1.0, gain_db: 24))
    xs = for i <- 0..999, do: round((@full - 1) * :math.sin(i * 0.131))
    ys = run(Strip.spec([loud, loud]), xs)
    assert Enum.all?(ys, &(&1 in -@full..(@full - 1)))
    assert Enum.count(ys, &(&1 in [-@full, @full - 1])) > 50
  end

  describe "hardware analysis" do
    test "eq and full strip: state closed, sections have separate loops" do
      eq = assert_state_closed(Strip.spec(bands()), ii: :auto)
      one = assert_state_closed(Biquad.spec(), ii: :auto)
      # each section's state is its own recurrence, so the cascade loops no longer than one
      assert eq.loop_latency == one.loop_latency

      full = assert_state_closed(Strip.spec(bands(), dynamics: true), ii: :auto)
      assert full.loop_latency >= eq.loop_latency
    end
  end
end

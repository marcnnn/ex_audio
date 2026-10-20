defmodule ExAudio.CosimFiltersTest do
  @moduledoc """
  Biquad and channel strip: the generated RTL (Verilator) against the Nx
  reference, bit for bit, including saturation, with and without backpressure.
  """
  use ExUnit.Case, async: true

  import ExAudio.TestHelpers, only: [signal: 5, fs: 0]

  alias ExAudio.{Biquad, Cosim, Filter, Strip}

  @moduletag :verilator
  @moduletag timeout: 900_000

  # sine and noise, a full scale square burst (saturation), silence, a decaying tail
  defp stimulus(n) do
    loud = for i <- 0..299, do: if(rem(div(i, 20), 2) == 0, do: 8_388_607, else: -8_388_608)

    signal(n - 450, 440.0, 3.0e6, 1.0e6, 3) ++ loud ++ List.duplicate(0, 150)
  end

  defp quantised(kind, f0, opts),
    do: kind |> Filter.design(f0, fs(), opts) |> Biquad.quantize()

  test "biquad with coefficient ports: peaking boost, 24 dB so that it saturates" do
    spec = Biquad.spec(quantised(:peaking, 1000, q: 1.0, gain_db: 24))
    sim = Cosim.build(spec, "ea_biquad", ii: :auto)
    xs = stimulus(900)
    Cosim.check(sim, spec, xs, Cosim.reference(spec, xs), total: length(xs))
  end

  test "biquad: the loop of a low-frequency high-pass, coefficients changed between streams" do
    for {name, coef} <- [
          {"hp", quantised(:highpass, 20, q: 2.0)},
          {"ls", quantised(:lowshelf, 300, gain_db: -9)}
        ] do
      spec = Biquad.spec(coef)
      sim = Cosim.build(spec, "ea_biquad_#{name}", ii: :auto)
      xs = stimulus(500)
      Cosim.check(sim, spec, xs, Cosim.reference(spec, xs), total: length(xs))
    end
  end

  test "biquad with channels: n interleaves n filters at one sample per cycle" do
    spec = Biquad.spec(quantised(:lowpass, 2000, q: 3.0))
    {:ok, %{loop_latency: l}} = ExAudio.Q.analyze(spec, ii: :auto)
    assert l > 1

    for n <- [l, l + 3] do
      sim = Cosim.build(spec, "ea_biquad_ch#{n}", channels: n)
      Cosim.check_channels(sim, spec, stimulus(10 * n * 12), n)
    end
  end

  test "two-band strip with constant coefficients (no parameter ports)" do
    coefs = [quantised(:highpass, 80, []), quantised(:peaking, 1000, q: 2.0, gain_db: 12)]
    spec = Strip.spec(coefs, baked: true)
    sim = Cosim.build(spec, "ea_strip_eq2", ii: :auto)
    assert sim.design.params == []
    xs = stimulus(500)
    Cosim.check(sim, spec, xs, Cosim.reference(spec, xs), total: length(xs))
  end

  test "strip with gate and compressor, parameters baked" do
    coefs = [quantised(:lowshelf, 200, gain_db: 6)]

    opts = [
      dynamics: true,
      baked: true,
      gate: [open_db: -50, hold_ms: 1, release_ms: 2, detector_release_ms: 2],
      compressor: [threshold_db: -20, ratio: 4, knee_db: 6, attack_ms: 0.5, release_ms: 5]
    ]

    spec = Strip.spec(coefs, opts)
    sim = Cosim.build(spec, "ea_strip_full", ii: :auto)
    xs = stimulus(400) ++ signal(400, 300.0, 2000.0, 0.0, 1)
    Cosim.check(sim, spec, xs, Cosim.reference(spec, xs), total: length(xs))
  end
end

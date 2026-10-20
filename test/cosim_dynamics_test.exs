defmodule ExAudio.CosimDynamicsTest do
  @moduledoc """
  Gate, compressor, envelope, meters and the mixer row: the generated RTL
  (Verilator) against the Nx reference, bit for bit.
  """
  use ExUnit.Case, async: true

  import ExAudio.TestHelpers, only: [signal: 5]

  alias ExAudio.{Cosim, Dynamics, Matrix, Meter}

  @moduletag :verilator
  @moduletag timeout: 900_000

  # loud, quiet, silent and full scale sections
  defp stimulus do
    signal(500, 700.0, 4.0e6, 0.0, 1) ++
      signal(500, 700.0, 4.0e3, 1.0e3, 2) ++
      List.duplicate(0, 200) ++
      signal(300, 90.0, 8_388_607.0, 0.0, 3) ++ signal(300, 300.0, 40.0, 10.0, 4)
  end

  defp check(spec, name, opts \\ []) do
    sim = Cosim.build(spec, name, [ii: :auto] ++ opts)
    xs = stimulus()
    Cosim.check(sim, spec, xs, Cosim.reference(spec, xs), total: length(xs))
    sim
  end

  test "envelope follower" do
    check(Dynamics.spec(:envelope, attack_ms: 0.5, release_ms: 5), "ea_envelope")
  end

  test "gate" do
    spec = Dynamics.spec(:gate, open_db: -55, hold_ms: 2, release_ms: 3, detector_release_ms: 3)
    check(spec, "ea_gate")
  end

  test "compressor with soft knee and makeup (log2 and exp2 tables in block RAM)" do
    spec =
      Dynamics.spec(:compressor,
        threshold_db: -24,
        ratio: 5,
        knee_db: 8,
        makeup_db: 4,
        attack_ms: 0.3,
        release_ms: 8
      )

    sim = check(spec, "ea_compressor")
    assert sim.design.source =~ "initial begin" or sim.design.source =~ "function automatic"
  end

  test "limiter" do
    check(
      Dynamics.spec(:compressor, threshold_db: -6, ratio: :inf, attack_ms: 0, release_ms: 20),
      "ea_limiter"
    )
  end

  test "compressor with channels: n" do
    spec = Dynamics.spec(:compressor, threshold_db: -20, ratio: 3, attack_ms: 0.3, release_ms: 5)
    {:ok, %{loop_latency: l}} = ExAudio.Q.analyze(spec, ii: :auto)
    sim = Cosim.build(spec, "ea_compressor_ch", channels: l)
    Cosim.check_channels(sim, spec, Enum.take(stimulus(), l * 100), l)
  end

  test "peak hold meter with clip flag" do
    check(Meter.spec(:peak, hold_ms: 3, decay_ms: 4, clip_margin: 4), "ea_peak")
  end

  test "rms meter" do
    check(Meter.spec(:rms, tau_ms: 2), "ea_rms")
  end

  test "mixer row: 8 sources, saturation counted" do
    :rand.seed(:exsss, {5, 6, 7})

    gains = [
      Matrix.gain(1.0),
      Matrix.gain(-0.5),
      Matrix.gain(3.9),
      0,
      Matrix.gain(0.25),
      Matrix.gain(-3.9),
      1,
      Matrix.gain(2.0)
    ]

    spec = Matrix.spec(gains)
    sim = Cosim.build(spec, "ea_matrix_row", ii: 1)

    rows =
      for i <- 1..300 do
        for _ <- 1..8,
            do:
              if(rem(i, 7) == 0,
                do: 8_000_000 - :rand.uniform(100),
                else: :rand.uniform(2_000_000) - 1_000_000
              )
      end

    x = Nx.tensor(rows, type: :s32)
    Cosim.check(sim, spec, x, Cosim.reference(spec, x), total: length(rows))
  end

  describe "mixer row as a stream: one multiplier, one output every k beats" do
    setup do
      :rand.seed(:exsss, {8, 9, 10})
      slots = 6
      gains = [1.0, -0.5, 3.9, 0.25, -3.9, 2.0]

      m =
        gains
        |> Enum.with_index()
        |> Enum.reduce(Matrix.new(n_in: 8, n_out: 2, slots: slots), fn {g, i}, m ->
          m |> Matrix.connect(0, i, g) |> Matrix.connect(1, 7 - i, -g)
        end)

      frames =
        for i <- 1..60 do
          for _ <- 1..8,
              do:
                if(rem(i, 7) == 0,
                  do: 8_000_000 - :rand.uniform(100),
                  else: :rand.uniform(2_000_000) - 1_000_000
                )
        end

      %{m: m, frames: frames}
    end

    test "ii: :auto", %{m: m, frames: frames} do
      spec = Matrix.mac_spec(m.slots)
      {:ok, design} = ExAudio.Q.to_sv(spec, name: "ea_mac", ii: :auto)
      {:ok, sim} = ExHdl.Sim.Verilator.build_stream(design)
      {xs, gs} = Matrix.mac_stream(m, 0, frames)
      {ys, clips} = Matrix.run_mac(m, 0, frames)
      assert Enum.any?(clips, &(&1 == 1))

      for {vp, rp, seed} <- [{100, 100, 1}, {70, 50, 2}, {30, 95, 3}, {95, 20, 4}] do
        assert {:ok, res} =
                 ExHdl.Sim.Verilator.run_stream(sim, [xs, gs], [],
                   valid_pct: vp,
                   ready_pct: rp,
                   seed: seed
                 )

        assert res.outputs == [ys, clips]
      end
    end

    test "channels: 2 serves two outputs with one multiplier", %{m: m, frames: frames} do
      spec = Matrix.mac_spec(m.slots)
      {:ok, design} = ExAudio.Q.to_sv(spec, name: "ea_mac_ch2", channels: 2)
      {:ok, sim} = ExHdl.Sim.Verilator.build_stream(design)
      {xs0, gs0} = Matrix.mac_stream(m, 0, frames)
      {xs1, gs1} = Matrix.mac_stream(m, 1, frames)
      interleave = fn a, b -> Enum.zip_with(a, b, &[&1, &2]) |> List.flatten() end
      {y0, c0} = Matrix.run_mac(m, 0, frames)
      {y1, c1} = Matrix.run_mac(m, 1, frames)

      for {vp, rp, seed} <- [{100, 100, 1}, {70, 50, 2}, {95, 20, 4}] do
        assert {:ok, res} =
                 ExHdl.Sim.Verilator.run_stream(
                   sim,
                   [interleave.(xs0, xs1), interleave.(gs0, gs1)],
                   [],
                   valid_pct: vp,
                   ready_pct: rp,
                   seed: seed
                 )

        assert res.outputs == [interleave.(y0, y1), interleave.(c0, c1)]
      end
    end
  end
end

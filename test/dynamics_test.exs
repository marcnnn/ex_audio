defmodule ExAudio.DynamicsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  import ExAudio.TestHelpers

  alias ExAudio.{Dynamics, Q}

  doctest ExAudio.Dynamics

  @full 8_388_608
  @fs 48_000

  defp amp(db), do: min(round(@full * :math.pow(10, db / 20)), @full - 1)
  defp run(spec, xs), do: spec |> Q.run(xs) |> elem(0) |> Nx.to_flat_list()

  describe "envelope time constants" do
    property "attack and release follow the exponential after one time constant" do
      check all tau <- log_uniform(0.2, 100),
                level <- float(min: -40.0, max: -3.0),
                max_runs: 20 do
        a = amp(level)
        n = round(tau * @fs / 1000)
        decay = :math.exp(-n / (tau * @fs / 1000))
        spec = Dynamics.spec(:envelope, attack_ms: tau, release_ms: tau)

        # the step input is a constant: the envelope is that of its absolute value
        {up, state} = Q.run(spec, List.duplicate(a, n))
        env = up |> Nx.to_flat_list() |> List.last()
        assert_in_delta env, a * (1 - decay), a * 0.002 + 1

        {down, _} =
          Q.run(spec, List.duplicate(0, n),
            state: Dynamics.init_envelope() |> then(fn _ -> state end)
          )

        # release from the exact state reached above: scale to the full level first
        env2 = down |> Nx.to_flat_list() |> List.last()
        assert_in_delta env2, a * (1 - decay) * decay, a * 0.002 + 1
      end
    end

    test "attack and release differ; the envelope reaches the target exactly" do
      spec = Dynamics.spec(:envelope, attack_ms: 1, release_ms: 20)
      {up, state} = Q.run(spec, List.duplicate(1_000_000, 2000))
      assert up |> Nx.to_flat_list() |> List.last() == 1_000_000
      {down, _} = Q.run(spec, List.duplicate(0, 960), state: state)
      env = down |> Nx.to_flat_list() |> Enum.at(959)
      assert_in_delta env, 1_000_000 * :math.exp(-1), 1_000_000 * 0.003

      # long release never stalls: a 1 LSB signal, 100 ms tau, a tenth of a second later it is zero
      slow = Dynamics.spec(:envelope, attack_ms: 1, release_ms: 100)
      {_, state} = Q.run(slow, List.duplicate(1, 100))
      {env, _} = Q.run(slow, List.duplicate(0, 6000), state: state)
      assert env |> Nx.to_flat_list() |> List.last() == 0
    end

    test "coefficient/3 is 1 - exp(-1/(fs tau))" do
      assert_in_delta Dynamics.coefficient(5.0, @fs) / (1 <<< 28),
                      1 - :math.exp(-1 / (0.005 * @fs)),
                      1.0e-8

      assert Dynamics.coefficient(0, @fs) == (1 <<< 28) - 1
    end
  end

  describe "compressor static curve" do
    # steady DC at `level` dB, long enough for the envelope to settle
    defp steady(level, opts) do
      opts = Keyword.merge([attack_ms: 0.2, release_ms: 10], opts)
      y = run(Dynamics.spec(:compressor, opts), List.duplicate(amp(level), 600)) |> List.last()
      db(y / @full) - db(amp(level) / @full) + level
    end

    property "output level follows threshold, ratio, knee and makeup within 0.02 dB" do
      check all threshold <- float(min: -40.0, max: -6.0),
                ratio <- one_of([float(min: 1.5, max: 20.0), constant(:inf)]),
                knee <- one_of([constant(0.0), float(min: 0.5, max: 12.0)]),
                makeup <- float(min: 0.0, max: 12.0),
                level <- float(min: -60.0, max: -0.5),
                opts = [threshold_db: threshold, ratio: ratio, knee_db: knee, makeup_db: makeup],
                expected = Dynamics.compressor_curve(level, opts),
                # above full scale the output saturates
                expected < -0.3,
                max_runs: 40 do
        assert_in_delta steady(level, opts), expected, 0.02
      end
    end

    test "1:1 below the threshold, ratio above, limiter flat" do
      assert_in_delta steady(-50.0, threshold_db: -20, ratio: 4), -50, 0.01
      assert_in_delta steady(-8.0, threshold_db: -20, ratio: 4), -20 + 12 / 4, 0.01
      assert_in_delta steady(-1.0, threshold_db: -12, ratio: :inf), -12, 0.01
    end

    test "the curve is continuous through the knee and has the knee's slope bounds" do
      opts = [threshold_db: -20, ratio: 4, knee_db: 10]
      pts = for l <- -30..-10, do: Dynamics.compressor_curve(l * 1.0, opts)

      assert Enum.all?(Enum.chunk_every(pts, 2, 1, :discard), fn [a, b] ->
               b - a >= 0.25 - 1.0e-9 and b - a <= 1.0 + 1.0e-9
             end)

      assert_in_delta Dynamics.compressor_curve(-25.0, opts), -25.0, 1.0e-9
      assert_in_delta Dynamics.compressor_curve(-15.0, opts), -20 + 5 / 4, 1.0e-9
    end
  end

  describe "compressor dynamics" do
    test "a limiter never exceeds its threshold, from the first sample on" do
      spec =
        Dynamics.spec(:compressor, threshold_db: -6, ratio: :inf, attack_ms: 0, release_ms: 50)

      xs = signal(4000, 997.0, @full - 1, 0.0, 1)
      ys = run(spec, xs)
      limit = @full * :math.pow(10, -6 / 20)
      assert ys |> Enum.map(&abs/1) |> Enum.max() <= limit * 1.001
      assert ys |> Enum.map(&abs/1) |> Enum.max() >= limit * 0.99
    end

    test "gain reduction follows the attack time constant" do
      # constant 0 dBFS into a limiter at -20 dB: gain = threshold / envelope
      spec =
        Dynamics.spec(:compressor, threshold_db: -20, ratio: :inf, attack_ms: 10, release_ms: 100)

      ys = run(spec, List.duplicate(@full - 1, 2400))
      n = round(0.010 * @fs)
      env = 1 - :math.exp(-1)
      assert_in_delta Enum.at(ys, n - 1) / (@full - 1), 0.1 / env, 0.002
    end

    property "tracks the float reference within 0.02 dB on signals" do
      check all threshold <- float(min: -30.0, max: -6.0),
                ratio <- float(min: 2.0, max: 12.0),
                knee <- float(min: 0.0, max: 8.0),
                attack <- float(min: 0.1, max: 10.0),
                release <- float(min: 5.0, max: 100.0),
                freq <- log_uniform(50, 5000),
                amplitude <- float(min: 1.0e5, max: 8.0e6),
                max_runs: 15 do
        opts = [
          threshold_db: threshold,
          ratio: ratio,
          knee_db: knee,
          attack_ms: attack,
          release_ms: release,
          makeup_db: 3.0
        ]

        xs = signal(1500, freq, amplitude, 0.0, round(freq))
        ys = run(Dynamics.spec(:compressor, opts), xs)
        ref = Dynamics.compressor_float(Enum.map(xs, &(&1 / @full)), opts)
        ref = Enum.map(ref, &(&1 |> max(-1.0) |> min(1.0 - 1 / @full)))

        for {y, r} <- Enum.zip(ys, ref) do
          assert abs(y / @full - r) <= abs(r) * 0.0025 + 2 / @full
        end
      end
    end
  end

  describe "gate" do
    defp burst_then_silence(loud, quiet, n_loud, n_quiet) do
      signal(n_loud, 500.0, loud, 0.0, 1) ++ signal(n_quiet, 500.0, quiet, 0.0, 2)
    end

    test "attenuates a quiet signal to the range, passes a loud one" do
      opts = [
        open_db: -40,
        close_db: -43,
        range_db: -30,
        hold_ms: 5,
        release_ms: 5,
        attack_ms: 1,
        detector_release_ms: 5
      ]

      spec = Dynamics.spec(:gate, opts)
      xs = burst_then_silence(amp(-20), amp(-60), 2400, 4000)
      ys = run(spec, xs)

      loud = Enum.slice(ys, 1500..2399)

      assert loud == Enum.slice(xs, 1500..2399) or
               Enum.zip(loud, Enum.slice(xs, 1500..2399))
               |> Enum.all?(fn {y, x} -> abs(y - x) <= 1 end)

      quiet_in = Enum.slice(xs, 6000..6399) |> Enum.map(&abs/1) |> Enum.max()
      quiet_out = Enum.slice(ys, 6000..6399) |> Enum.map(&abs/1) |> Enum.max()
      assert_in_delta quiet_out / quiet_in, :math.pow(10, -30 / 20), 0.003
    end

    test "hold keeps the gate open for hold_ms after the signal drops" do
      # the first sample at which the gain has fallen below 1/2 comes later with a longer hold
      closing = fn hold ->
        spec =
          Dynamics.spec(:gate,
            open_db: -40,
            hold_ms: hold,
            detector_release_ms: 1,
            release_ms: 1,
            range_db: -60
          )

        # constant levels: DC keeps the arithmetic simple (gain = y / x)
        xs = List.duplicate(amp(-20), 1000) ++ List.duplicate(amp(-70), 6000)
        ys = run(spec, xs)
        Enum.find_index(Enum.drop(ys, 1000), &(&1 < amp(-70) / 2))
      end

      short = closing.(0.0)
      long = closing.(20.0)
      assert_in_delta long - short, 20 * @fs / 1000, 2
    end

    test "hysteresis: a level between the thresholds keeps the state" do
      opts = [
        open_db: -30,
        close_db: -40,
        range_db: -40,
        detector_release_ms: 1,
        hold_ms: 0,
        release_ms: 1,
        attack_ms: 1
      ]

      spec = Dynamics.spec(:gate, opts)
      mid = amp(-35)
      # coming from below, -35 dB does not open the gate; coming from above it stays open
      ys_low = run(spec, List.duplicate(amp(-60), 4000) ++ List.duplicate(mid, 3000))
      ys_high = run(spec, List.duplicate(amp(-20), 2000) ++ List.duplicate(mid, 3000))
      assert_in_delta List.last(ys_low) / mid, 0.01, 0.0005
      assert_in_delta List.last(ys_high) / mid, 1.0, 0.0001
    end

    property "tracks the float reference on signals" do
      check all open <- float(min: -55.0, max: -30.0),
                hold <- float(min: 0.0, max: 20.0),
                range <- float(min: -60.0, max: -10.0),
                max_runs: 10 do
        opts = [
          open_db: open,
          hold_ms: hold,
          range_db: range,
          detector_release_ms: 5,
          release_ms: 5,
          attack_ms: 1
        ]

        xs = burst_then_silence(amp(-25), amp(-65), 1500, 3000)
        ys = run(Dynamics.spec(:gate, opts), xs)
        ref = Dynamics.gate_float(Enum.map(xs, &(&1 / @full)), opts)

        for {y, r} <- Enum.zip(ys, ref),
            do: assert(abs(y / @full - r) <= 0.003 * abs(r) + 3 / @full + 2.0e-4 * abs(r))
      end
    end
  end

  describe "hardware analysis" do
    for kind <- [:envelope, :gate, :compressor] do
      test "#{kind}: ranges proven, state closed, loop latency known" do
        scan = assert_state_closed(Dynamics.spec(unquote(kind)), ii: :auto)
        assert scan.loop_latency >= 1
      end
    end

    test "log2 and exp2 tables" do
      assert Enum.max(for(v <- 1..70_000//7, do: abs(log2_q16(v) / 65536 - :math.log2(v)))) <
               0.0012

      for d <- [0, 1, 65_535, 65_536, 1_000_000, 24 * 65_536] do
        got = exp2_q24(d) / (1 <<< 24)

        assert_in_delta got,
                        :math.pow(2, -d / 65536),
                        0.0007 * :math.pow(2, -div(d, 65536)) + 2.0e-7
      end
    end
  end

  defp log2_q16(v) do
    {y, _} =
      NxFixed.run_scan_stacked(
        fn x, s -> {Q.log2_q16(x, bits: 36), s} end,
        Nx.tensor([v], type: :s64),
        Nx.tensor(0, type: :s32)
      )

    y |> Nx.to_flat_list() |> hd()
  end

  defp exp2_q24(d) do
    {y, _} =
      NxFixed.run_scan_stacked(
        fn x, s -> {Q.exp2_neg_q24(x), s} end,
        Nx.tensor([d], type: :s64),
        Nx.tensor(0, type: :s32),
        [],
        param_ranges: %{0 => 0..(24 * 65_536)}
      )

    y |> Nx.to_flat_list() |> hd()
  end
end

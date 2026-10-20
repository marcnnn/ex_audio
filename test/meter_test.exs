defmodule ExAudio.MeterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExAudio.TestHelpers

  alias ExAudio.{Meter, Q}

  doctest ExAudio.Meter

  @full 8_388_608

  defp run(spec, xs) do
    {out, _} = Q.run(spec, xs)
    out
  end

  describe "peak" do
    test "follows the maximum, holds it, then decays with the decay constant" do
      spec = Meter.spec(:peak, hold_ms: 10, decay_ms: 5)
      hold = 480
      xs = [0, 1000, -5000, 200] ++ List.duplicate(0, 4000)
      {peak, _} = Q.run(spec, xs)
      peak = peak |> elem(0) |> Nx.to_flat_list()
      # the reading lags the input by one sample (it is the state)
      assert Enum.slice(peak, 0..3) == [0, 0, 1000, 5000]
      assert Enum.all?(Enum.slice(peak, 4..(hold + 2)), &(&1 == 5000))
      tau = round(0.005 * 48_000)
      assert_in_delta Enum.at(peak, hold + 3 + tau), 5000 * :math.exp(-1), 15
      assert List.last(peak) == 0
    end

    property "rises at once, then holds for hold_n samples, then only falls" do
      check all freq <- log_uniform(30, 4000), amp <- float(min: 1.0e3, max: 8.0e6), max_runs: 15 do
        xs = signal(900, freq, amp, amp / 4, round(freq))
        spec = Meter.spec(:peak, hold_ms: 5, decay_ms: 50)
        {{peak, _}, _} = Q.run(spec, xs)
        peak = peak |> Nx.to_flat_list() |> Kernel.++([nil])
        hold = 240

        # p[i + 1] is the reading after sample i
        rises =
          for {x, i} <- Enum.with_index(xs), i > 0, abs(x) >= Enum.at(peak, i), do: {i, abs(x)}

        for {i, a} <- rises, do: assert(Enum.at(peak, i + 1) == a or Enum.at(peak, i + 1) == nil)

        for {i, a} <- rises,
            i + hold < 899,
            not Enum.any?(rises, fn {j, _} -> j > i and j <= i + hold end) do
          assert Enum.slice(peak, (i + 1)..(i + hold)) |> Enum.all?(&(&1 == a))
        end

        falls = for {x, i} <- Enum.with_index(xs), i > 0, abs(x) < Enum.at(peak, i), do: i
        for i <- falls, i < 899, do: assert(Enum.at(peak, i + 1) <= Enum.at(peak, i))
      end
    end

    test "clip flag marks samples at full scale" do
      spec = Meter.spec(:peak, clip_margin: 8)
      xs = [0, 8_388_607, -8_388_608, 8_388_598, 8_388_599, 1_000_000]
      {{_, clip}, _} = Q.run(spec, xs)
      assert Nx.to_flat_list(clip) == [0, 1, 1, 0, 1, 0]
    end
  end

  describe "rms" do
    defp level_db(spec, xs),
      do: spec |> run(xs) |> Nx.to_flat_list() |> List.last() |> Q.log2_to_db()

    test "full scale constant reads 0 dB, a full scale sine -3.01 dB" do
      spec = Meter.spec(:rms, tau_ms: 20)
      assert_in_delta level_db(spec, List.duplicate(@full - 1, 6000)), 0.0, 0.02
      sine = signal(12_000, 1000.0, @full - 1, 0.0, 1)
      assert_in_delta level_db(spec, sine), -3.01, 0.05
    end

    property "reads the level of a sine within 0.1 dB from -80 dBFS to 0 dBFS" do
      check all level <- float(min: -80.0, max: -1.0),
                freq <- log_uniform(100, 5000),
                max_runs: 15 do
        a = @full * :math.pow(10, level / 20)
        xs = signal(9600, freq, a, 0.0, round(freq))
        assert_in_delta level_db(Meter.spec(:rms, tau_ms: 30), xs), level - 3.01, 0.1
      end
    end

    test "time constant: a step reaches 1 - 1/e of the final mean square after tau" do
      tau = 50
      n = round(tau * 48 / 1)
      spec = Meter.spec(:rms, tau_ms: tau)
      final = 4_000_000
      # mean square in units of full scale squared
      out = run(spec, List.duplicate(final, n)) |> Nx.to_flat_list() |> List.last()
      ms = :math.pow(2, 2 * (out / 65_536)) * @full * @full
      assert_in_delta ms / (final * final), 1 - :math.exp(-1), 0.01
    end
  end

  describe "hardware analysis" do
    for kind <- [:peak, :rms] do
      test "#{kind}: ranges proven, state closed" do
        assert_state_closed(Meter.spec(unquote(kind)), ii: :auto)
      end
    end
  end
end

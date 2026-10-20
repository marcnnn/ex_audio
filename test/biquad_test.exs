defmodule ExAudio.BiquadTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  import ExAudio.TestHelpers

  alias ExAudio.{Biquad, Filter, Q}

  doctest ExAudio.Biquad

  @kinds ~w(lowpass highpass bandpass notch allpass peaking lowshelf highshelf)a
  @full 8_388_607

  # random but valid design: {kind, f0, q, gain}, numerator within Q5.27
  defp design_gen(f_lo \\ 20) do
    gen all kind <- member_of(@kinds),
            f0 <- log_uniform(f_lo, 20_000),
            q <- float(min: 0.3, max: 10.0),
            g <- float(min: -18.0, max: 18.0),
            {b0, b1, b2, _, _} = coef = Filter.design(kind, f0, fs(), q: q, gain_db: g),
            Enum.all?([b0, b1, b2], &(abs(&1) < 15)) do
      {kind, f0, q, g, coef}
    end
  end

  describe "coefficient quantisation" do
    property "rounds to half an LSB of the Q5.27 / Q2.30 grid" do
      check all {_, _, _, _, coef} <- design_gen() do
        {b0, b1, b2, a1, a2} = coef
        {d0, d1, d2, e1, e2} = coef |> Biquad.quantize() |> Biquad.dequantize()

        for {x, y} <- [{b0, d0}, {b1, d1}, {b2, d2}],
            do: assert(abs(x - y) <= 2.0 ** -28 + 1.0e-15)

        for {x, y} <- [{a1, e1}, {a2, e2}], do: assert(abs(x - y) <= 2.0 ** -31 + 1.0e-15)
      end
    end

    # level error in dB where the response is above -30 dB
    defp response_error(coef) do
      quantised = coef |> Biquad.quantize() |> Biquad.dequantize()

      10
      |> Filter.log_space(22_000, 150)
      |> Enum.filter(&(Filter.magnitude_db(coef, &1, fs()) > -30))
      |> Enum.map(
        &abs(Filter.magnitude_db(quantised, &1, fs()) - Filter.magnitude_db(coef, &1, fs()))
      )
      |> Enum.max(fn -> 0.0 end)
    end

    property "magnitude response error is below 0.02 dB from 100 Hz up" do
      check all {_, _, _, _, coef} <- design_gen(100) do
        assert response_error(coef) < 0.02
      end
    end

    property "and below 0.1 dB from 20 Hz up (not for notches)" do
      check all {kind, _, _, _, coef} <- design_gen(20), kind != :notch do
        assert response_error(coef) < 0.1
      end
    end

    test "refuses unstable filters and numerators beyond Q5.27" do
      assert_raise ArgumentError, ~r/unstable/, fn ->
        Biquad.quantize({1.0, 0.0, 0.0, -2.1, 1.0})
      end

      assert_raise ArgumentError, ~r/outside/, fn ->
        Biquad.quantize({16.5, 0.0, 0.0, 0.0, 0.0})
      end

      # a gain of +24 dB still fits
      coef = Filter.design(:lowshelf, 5_000, fs(), gain_db: 24, q: 0.3)
      assert Biquad.quantize(coef)
    end

    test "a pole on the unit circle is clamped inside it" do
      {_, _, _, a1, a2} = Biquad.quantize({1.0, 0.0, 0.0, -2.0 + 1.0e-9, 1.0 - 0.9e-9})
      assert a2 == (1 <<< 30) - 1 and abs(a1) < 2 <<< 30
    end
  end

  describe "kernel against the float direct form I" do
    property "within the proven error bound (no saturation)" do
      check all {_, f0, _, _, coef} <- design_gen(),
                freq <- log_uniform(20, 20_000),
                amp <- float(min: 1.0e5, max: 3.0e6),
                noise <- float(min: 0.0, max: 2.0e6),
                max_runs: 40 do
        cq = Biquad.quantize(coef)
        xs = signal(400, freq, amp, noise, round(f0))
        ref = Filter.process(Biquad.dequantize(cq), xs)

        if Enum.all?(ref, &(abs(&1) < @full - 4)) do
          {ys, _} = Biquad.run(xs, cq)
          err = ys |> Enum.zip(ref) |> Enum.map(fn {y, r} -> abs(y - r) end) |> Enum.max()

          assert err <= Biquad.error_bound(cq),
                 "error #{err} LSB, bound #{Biquad.error_bound(cq)}"
        end
      end
    end

    test "20 Hz high-pass, Q 8: the worst case stays within its bound and the typical error is far below it" do
      cq = :highpass |> Filter.design(20, fs(), q: 8.0) |> Biquad.quantize()
      xs = signal(3000, 33.0, 1.0e6, 1.0e6, 5)
      ref = Filter.process(Biquad.dequantize(cq), xs)
      {ys, _} = Biquad.run(xs, cq)
      err = ys |> Enum.zip(ref) |> Enum.map(fn {y, r} -> abs(y - r) end) |> Enum.max()
      assert err < 2.0
      assert Biquad.error_bound(cq) > err
    end

    test "unity coefficients pass the signal, and the kernel is bit-exact on an impulse" do
      xs = signal(50, 440, 1.0e6, 1.0e5, 1)
      assert {^xs, _} = Biquad.run(xs, Biquad.identity())

      cq = :lowpass |> Filter.design(1000, fs()) |> Biquad.quantize()
      {ys, _} = Biquad.run([1 <<< 22 | List.duplicate(0, 63)], cq)
      assert hd(ys) == round(elem(Biquad.dequantize(cq), 0) * (1 <<< 22))
    end
  end

  describe "saturation" do
    test "a +24 dB boost on full scale clips at the 24-bit limits, it does not wrap" do
      cq = :peaking |> Filter.design(1000, fs(), q: 1.0, gain_db: 24) |> Biquad.quantize()
      xs = for i <- 0..999, do: if(rem(div(i, 24), 2) == 0, do: @full, else: -@full - 1)
      {ys, _} = Biquad.run(xs, cq)
      assert Enum.all?(ys, &(&1 in -8_388_608..8_388_607))
      assert Enum.max(ys) == @full and Enum.min(ys) == -8_388_608
      assert Enum.count(ys, &(&1 in [@full, -8_388_608])) > 100

      # against the float filter with the same saturation: the sign of every
      # clipped sample is right and the unclipped ones agree
      ref = Filter.process(Biquad.dequantize(cq), xs, saturate: {-8_388_608.0, @full + 0.0})
      err = ys |> Enum.zip(ref) |> Enum.map(fn {y, r} -> abs(y - r) end) |> Enum.max()
      assert err < 4
    end

    test "after clipping the filter recovers: no latch-up" do
      cq = :lowpass |> Filter.design(2000, fs(), q: 2.0) |> Biquad.quantize()
      loud = List.duplicate(@full, 4000)
      quiet = signal(2000, 300.0, 1.0e5, 0.0, 3)
      {ys, _} = Biquad.run(loud ++ quiet, cq)
      ref = Filter.process(Biquad.dequantize(cq), quiet)
      tail = Enum.take(ys, -1000) |> Enum.zip(Enum.take(ref, -1000))
      assert Enum.all?(tail, fn {y, r} -> abs(y - r) < 2 end)
    end
  end

  describe "stability: zero input" do
    # After an excitation the output must die out. The rounding residual is
    # fed back, so there is no dead band: the bound for the tail is 1 LSB
    # (the tests observe 0).
    property "no limit cycle beyond 1 LSB" do
      check all kind <- member_of(~w(lowpass highpass peaking bandpass)a),
                f0 <- log_uniform(300, 16_000),
                q <- float(min: 0.5, max: 3.0),
                seed <- integer(1..1000),
                max_runs: 12 do
        cq = kind |> Filter.design(f0, fs(), q: q, gain_db: 12) |> Biquad.quantize()
        burst = signal(100, 1000.0, 2.0e6, 2.0e6, seed)
        {_, state} = Biquad.run(burst, cq)
        {ys, _} = Biquad.run(List.duplicate(0, 8_000), cq, state)
        assert ys |> Enum.take(-1000) |> Enum.map(&abs/1) |> Enum.max() <= 1
      end
    end
  end

  test "a 20 Hz high-pass dies out to exactly zero (without error feedback it sticks at 280 LSB)" do
    cq = :highpass |> Filter.design(20, fs(), q: 2.0) |> Biquad.quantize()
    {_, state} = Biquad.run(signal(200, 1000.0, 3.0e6, 3.0e6, 9), cq)
    {ys, _} = Biquad.run(List.duplicate(0, 60_000), cq, state)
    assert ys |> Enum.take(-5000) |> Enum.all?(&(&1 == 0))
  end

  describe "hardware analysis" do
    test "proves all state ranges and a loop latency" do
      scan = assert_state_closed(Biquad.spec(), ii: :auto)
      assert scan.ii == scan.loop_latency
    end

    test "rejects wider coefficient ranges: the accumulator proof depends on them" do
      spec = Biquad.spec()
      a2 = spec[:param_ranges] |> Map.keys() |> Enum.max()
      wide = Map.put(spec[:param_ranges], a2, -(1 <<< 31)..((1 <<< 31) - 1))

      assert {:error, %NxFixed.RangeError{}} =
               Q.analyze(Keyword.put(spec, :param_ranges, wide), ii: :auto)
    end
  end
end

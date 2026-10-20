defmodule ExAudio.FilterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExAudio.TestHelpers, only: [fs: 0, log_uniform: 2]

  alias ExAudio.Filter

  doctest ExAudio.Filter

  @kinds ~w(lowpass highpass bandpass bandpass_skirt notch allpass peaking lowshelf highshelf)a

  # The analog prototypes of the cookbook; the digital filters are their
  # bilinear transforms with the frequency warped so that w0 maps to s = j.
  defp analog(kind, s, q, a) do
    import Complex
    one = Complex.new(1.0)
    s2 = multiply(s, s)
    sq = multiply(s, 1 / q)
    sa = multiply(s, :math.sqrt(a) / q)
    den = fn p -> add(add(s2, multiply(s, p)), one) end

    case kind do
      :lowpass ->
        divide(one, den.(1 / q))

      :highpass ->
        divide(s2, den.(1 / q))

      :bandpass ->
        divide(sq, den.(1 / q))

      :bandpass_skirt ->
        divide(s, den.(1 / q))

      :notch ->
        divide(add(s2, one), den.(1 / q))

      :allpass ->
        divide(add(subtract(s2, sq), one), den.(1 / q))

      :peaking ->
        divide(den.(a / q), den.(1 / (a * q)))

      :lowshelf ->
        divide(
          multiply(add(add(s2, sa), Complex.new(a)), a),
          add(add(multiply(s2, a), sa), one)
        )

      :highshelf ->
        divide(
          multiply(add(add(multiply(s2, a), sa), one), a),
          add(add(s2, sa), Complex.new(a))
        )
    end
  end

  property "the digital response is the cookbook's analog prototype at warped frequency" do
    check all kind <- member_of(@kinds),
              f0 <- log_uniform(30, 18_000),
              q <- float(min: 0.2, max: 12.0),
              gain_db <- float(min: -20.0, max: 20.0),
              f <- log_uniform(10, 23_000) do
      coef = Filter.design(kind, f0, fs(), q: q, gain_db: gain_db)
      a = :math.pow(10, gain_db / 40)
      omega = :math.tan(:math.pi() * f / fs()) / :math.tan(:math.pi() * f0 / fs())
      expected = analog(kind, Complex.new(0.0, omega), q, a)
      {re, im} = Filter.response(coef, f, fs())
      assert_in_delta re, Complex.real(expected), 1.0e-6 * max(1, Complex.abs(expected))
      assert_in_delta im, Complex.imag(expected), 1.0e-6 * max(1, Complex.abs(expected))
    end
  end

  property "gains at DC, f0 and Nyquist follow the cookbook" do
    check all f0 <- log_uniform(100, 12_000),
              q <- float(min: 0.3, max: 8.0),
              g <- float(min: -18.0, max: 18.0) do
      mag = fn kind, f, opts ->
        Filter.magnitude_db(Filter.design(kind, f0, fs(), [q: q] ++ opts), f, fs())
      end

      nyq = fs() / 2 - 0.01
      db_q = 20 * :math.log10(q)

      assert_in_delta mag.(:lowpass, 0.01, []), 0.0, 1.0e-3
      assert_in_delta mag.(:lowpass, f0, []), db_q, 1.0e-6
      assert mag.(:lowpass, nyq, []) < -60
      assert_in_delta mag.(:highpass, nyq, []), 0.0, 1.0e-3
      assert_in_delta mag.(:highpass, f0, []), db_q, 1.0e-6
      assert mag.(:highpass, 0.01, []) < -60
      assert_in_delta mag.(:bandpass, f0, []), 0.0, 1.0e-6
      assert_in_delta mag.(:bandpass_skirt, f0, []), db_q, 1.0e-6
      assert mag.(:notch, f0, []) < -120
      assert_in_delta mag.(:notch, 0.01, []), 0.0, 1.0e-3
      assert_in_delta mag.(:peaking, f0, gain_db: g), g, 1.0e-6
      assert_in_delta mag.(:lowshelf, 0.01, gain_db: g), g, 1.0e-3
      assert_in_delta mag.(:lowshelf, f0, gain_db: g), g / 2, 1.0e-6
      assert_in_delta mag.(:lowshelf, nyq, gain_db: g), 0.0, 1.0e-3
      assert_in_delta mag.(:highshelf, 0.01, gain_db: g), 0.0, 1.0e-3
      assert_in_delta mag.(:highshelf, f0, gain_db: g), g / 2, 1.0e-6
      assert_in_delta mag.(:highshelf, nyq, gain_db: g), g, 1.0e-3
    end
  end

  property "all pass: unit magnitude, phase -pi at f0" do
    check all f0 <- log_uniform(100, 12_000),
              q <- float(min: 0.3, max: 8.0),
              f <- log_uniform(20, 23_000) do
      coef = Filter.design(:allpass, f0, fs(), q: q)
      assert_in_delta Filter.magnitude_db(coef, f, fs()), 0.0, 1.0e-9
      assert_in_delta abs(Filter.phase(coef, f0, fs())), :math.pi(), 1.0e-6
    end
  end

  property "response/3 is the DTFT of the impulse response of process/2" do
    check all kind <- member_of(@kinds),
              f0 <- log_uniform(300, 10_000),
              q <- float(min: 0.5, max: 4.0),
              g <- float(min: -12.0, max: 12.0),
              f <- log_uniform(50, 20_000),
              max_runs: 30 do
      coef = Filter.design(kind, f0, fs(), q: q, gain_db: g)
      h = Filter.process(coef, [1.0 | List.duplicate(0.0, 4_000)])
      w = 2 * :math.pi() * f / fs()

      {re, im} =
        h
        |> Enum.with_index()
        |> Enum.reduce({0.0, 0.0}, fn {v, n}, {re, im} ->
          {re + v * :math.cos(w * n), im - v * :math.sin(w * n)}
        end)

      {er, ei} = Filter.response(coef, f, fs())
      assert_in_delta re, er, 1.0e-6
      assert_in_delta im, ei, 1.0e-6
    end
  end

  test "shelf slope S = 1 is Q = 1/sqrt(2)" do
    {b0, b1, b2, a1, a2} = Filter.design(:lowshelf, 500, fs(), gain_db: 9, slope: 1.0)
    q = 1 / :math.sqrt(2)
    {c0, c1, c2, d1, d2} = Filter.design(:lowshelf, 500, fs(), gain_db: 9, q: q)
    assert {b0, b1, b2, a1, a2} == {c0, c1, c2, d1, d2}
  end

  test "stable?/1 and design errors" do
    for kind <- @kinds, f0 <- [20, 1000, 20_000] do
      assert Filter.stable?(Filter.design(kind, f0, fs(), q: 5, gain_db: 6))
    end

    refute Filter.stable?({1.0, 0.0, 0.0, -2.1, 1.0})
    assert_raise ArgumentError, fn -> Filter.design(:lowpass, 24_000, fs()) end
  end
end

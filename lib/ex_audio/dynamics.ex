defmodule ExAudio.Dynamics do
  @moduledoc """
  Envelope follower, noise gate and compressor/limiter kernels, with their
  parameter design (dB and ms to fixed point) and float references.

  ## Envelope

  A peak follower on `|x|` with separate attack and release coefficients,
  `env += k * (|x| - env)`, `k = 1 - exp(-1/(fs * tau))` in Q28. The
  envelope carries 12 more fractional bits than a sample (35 bits) and the
  step is rounded away from the current value (`ExAudio.Q.approach/5`),
  so release times of seconds do not stall in a dead band and the
  envelope reaches the input exactly. The step never overshoots, so the
  envelope stays between its old value and `|x|` (at most `2^23 - 1`,
  `-2^23` counts as `2^23 - 1`), below `2^35`; the update is written as a
  35-bit unsigned wrap (`ExAudio.Q.wrap_unsigned/2`), which proves the
  state's range without a clamp in the feedback loop. The gate's gain
  (`0..2^24`) is kept in 25 bits the same way.

  ## Gate

  `gate/3`: state `{env, open, hold, gain}`. The gate opens when the
  envelope exceeds `open_db` and closes below `close_db` (hysteresis),
  stays open for `hold_ms` more (at most 65535 samples, 1365 ms at 48 kHz),
  and its gain moves towards 1 (opening,
  `attack_ms`) or towards `range_db` (closing, `release_ms`). The output uses
  the gain of the state, one sample behind the decision.

  ## Compressor and limiter

  `compressor/3`: feed-forward, level detection on the envelope, gain
  computer in the log2 domain (`ExAudio.Q.log2_q16/2`, 1024-entry table,
  at most 0.004 dB error), gain `2^-d` from a table, `d` from the threshold,
  ratio and quadratic soft knee:

      over = level - threshold
      d    = (1 - 1/ratio) * (xc^2 / (2 knee) + max(over - knee/2, 0))
      xc   = clamp(over + knee/2, 0, knee)

  A limiter is `ratio: :inf` with a near-instant attack. The knee's
  reciprocal is a parameter, so the kernel needs no divider.
  The level path is feed-forward: the only feedback loop is the envelope.

  Time constants, levels and ratios are designed with `gate_params/1` and
  `compressor_params/1`; options for both the integer parameters and the
  float references (`gate_float/2`, `compressor_float/2`) are the same.

      iex> ExAudio.Dynamics.compressor_curve(-10.0, threshold_db: -20, ratio: 4, knee_db: 0)
      -17.5
  """
  import Nx.Defn
  import Bitwise
  import NxFixed.Primitives, only: [shift_round: 2]

  alias ExAudio.Q

  @env_shift 12
  @env_bits 35
  @env_range 0..((1 <<< @env_bits) - 1)
  @sample_max (1 <<< 23) - 1
  @k_bits 28
  @k_max (1 <<< @k_bits) - 1
  @unity 1 <<< 24
  @gain_bits 25
  @hold_max (1 <<< 16) - 1

  # -- design ----------------------------------------------------------------------

  @doc """
  Smoothing coefficient for time constant `tau_ms`: `1 - exp(-1/(fs*tau))`
  as an integer in Q`bits` (default 28), at least 1.
  """
  def coefficient(tau_ms, fs, bits \\ @k_bits) do
    k = if tau_ms <= 0, do: 1.0, else: 1 - :math.exp(-1000 / (fs * tau_ms))
    k |> Kernel.*(1 <<< bits) |> round() |> max(1) |> min((1 <<< bits) - 1)
  end

  @doc "Float coefficient `1 - exp(-1/(fs*tau))`."
  def coefficient_float(tau_ms, fs),
    do: if(tau_ms <= 0, do: 1.0, else: 1 - :math.exp(-1000 / (fs * tau_ms)))

  @doc """
  Gate parameters `{open_th, close_th, hold, floor, env_att, env_rel, g_att, g_rel}`.

  Options (defaults): `:fs` (48000), `:open_db` (-50), `:close_db`
  (`open_db - 3`), `:hold_ms` (50), `:range_db` (-80, gain when closed),
  `:detector_attack_ms` (0.1), `:detector_release_ms` (20), `:attack_ms`
  (2), `:release_ms` (50).
  """
  def gate_params(opts \\ []) do
    o = gate_opts(opts)
    fs = o[:fs]
    hold = round(o[:hold_ms] * fs / 1000)

    unless hold <= @hold_max,
      do:
        raise(
          ArgumentError,
          "hold_ms: #{o[:hold_ms]} is #{hold} samples, at most #{@hold_max}"
        )

    {amplitude(o[:open_db]), amplitude(o[:close_db]), hold, round(db_gain(o[:range_db]) * @unity),
     coefficient(o[:detector_attack_ms], fs), coefficient(o[:detector_release_ms], fs),
     coefficient(o[:attack_ms], fs), coefficient(o[:release_ms], fs)}
  end

  defp gate_opts(opts) do
    base = [
      fs: 48_000,
      open_db: -50.0,
      hold_ms: 50.0,
      range_db: -80.0,
      detector_attack_ms: 0.1,
      detector_release_ms: 20.0,
      attack_ms: 2.0,
      release_ms: 50.0
    ]

    o = Keyword.merge(base, opts)
    Keyword.put_new(o, :close_db, o[:open_db] - 3)
  end

  @doc """
  Compressor parameters `{threshold, slope, knee, knee_r, makeup, env_att, env_rel}`.

  Options (defaults): `:fs` (48000), `:threshold_db` (-20), `:ratio` (4,
  or `:inf`), `:knee_db` (0, up to 24), `:makeup_db` (0, up to 24),
  `:attack_ms` (5), `:release_ms` (100). Knees below 0.2 dB are hard.
  """
  def compressor_params(opts \\ []) do
    o = compressor_opts(opts)
    fs = o[:fs]
    knee = Q.db_to_log2(o[:knee_db])
    knee = if knee < 2048, do: 0, else: min(knee, 1 <<< 18)

    {max(Q.db_to_log2(o[:threshold_db]), -(35 <<< 16)), round(slope(o[:ratio]) * 65536), knee,
     if(knee == 0, do: 0, else: round((1 <<< 31) / knee)),
     min(round(db_gain(o[:makeup_db]) * 4096), 65536), coefficient(o[:attack_ms], fs),
     coefficient(o[:release_ms], fs)}
  end

  defp compressor_opts(opts) do
    Keyword.merge(
      [
        fs: 48_000,
        threshold_db: -20.0,
        ratio: 4.0,
        knee_db: 0.0,
        makeup_db: 0.0,
        attack_ms: 5.0,
        release_ms: 100.0
      ],
      opts
    )
  end

  defp slope(:inf), do: 1.0
  defp slope(ratio), do: 1 - 1 / ratio
  defp amplitude(db), do: db |> db_gain() |> Kernel.*(1 <<< 23) |> round() |> min(@sample_max)
  defp db_gain(db), do: :math.pow(10, db / 20)

  @doc """
  Static curve of the compressor in dB: output level for a steady input
  level, both re full scale (makeup included). Options as `compressor_params/1`.
  """
  def compressor_curve(level_db, opts \\ []) do
    o = compressor_opts(opts)
    {t, w, s} = {o[:threshold_db], o[:knee_db], slope(o[:ratio])}
    over = level_db - t

    gr =
      cond do
        over <= -w / 2 -> 0.0
        over < w / 2 -> s * :math.pow(over + w / 2, 2) / (2 * w)
        true -> s * over
      end

    level_db - gr + o[:makeup_db]
  end

  # -- kernels ---------------------------------------------------------------------

  @doc "Declared tensor ranges of `envelope/3`, as `ExAudio.Biquad.ranges/0`."
  def envelope_ranges,
    do: %{sample: [Q.sample_range()], state: [@env_range], params: [0..@k_max, 0..@k_max]}

  @doc "Initial state of `envelope/3`."
  def init_envelope, do: Nx.tensor(0, type: :s64)

  @doc """
  `envelope(x, env, {k_att, k_rel})`: the follower alone. Returns
  `{env >> 12, next_env}`, the envelope as a 24-bit amplitude.
  """
  defn envelope(x, env, params) do
    {k_att, k_rel} = params
    env2 = follow(x, env, k_att, k_rel)
    {Nx.as_type(Nx.right_shift(env2, @env_shift), :s32), env2}
  end

  defnp follow(x, env, k_att, k_rel) do
    level = x |> Q.wide() |> Q.absolute() |> Nx.min(@sample_max) |> Nx.left_shift(@env_shift)
    env |> Q.approach(level, k_att, k_rel, @k_bits) |> Q.wrap_unsigned(@env_bits)
  end

  @doc "Declared tensor ranges of `gate/3`."
  def gate_ranges do
    k = 0..@k_max
    th = 0..@sample_max
    hold = 0..@hold_max
    gain = 0..((1 <<< @gain_bits) - 1)

    %{
      sample: [Q.sample_range()],
      state: [@env_range, 0..1, hold, gain],
      params: [th, th, hold, 0..@unity, k, k, k, k]
    }
  end

  @doc "Initial gate state `{env, open, hold, gain}` (transparent, closing)."
  def init_gate, do: {init_envelope(), Q.sample(0), Q.sample(0), Q.sample(@unity)}

  @doc """
  Noise gate `gate(x, {env, open, hold, gain}, {open_th, close_th, hold_n,
  floor, env_att, env_rel, g_att, g_rel})`, see the moduledoc.
  """
  defn gate(x, state, params) do
    {env, open, hold, gain} = state
    {open_th, close_th, hold_n, floor, k_att, k_rel, g_att, g_rel} = params

    env2 = follow(x, env, k_att, k_rel)
    above = env2 >= Nx.left_shift(Q.wide(open_th), @env_shift)
    below = env2 < Nx.left_shift(Q.wide(close_th), @env_shift)
    open2 = Nx.select(above, 1, Nx.select(below, 0, open)) |> Nx.as_type(:s32)
    hold2 = Nx.select(open2 != 0, hold_n, Nx.max(hold - 1, 0)) |> Nx.as_type(:s32)
    target = Nx.select(open2 != 0 or hold > 0, @unity, Q.wide(floor))

    gain2 =
      gain |> Q.wide() |> Q.approach(target, g_att, g_rel, @k_bits) |> Q.wrap_unsigned(@gain_bits)

    y = (Q.wide(x) * Q.wide(gain)) |> shift_round(24) |> Q.sat24()
    {y, {env2, open2, hold2, Nx.as_type(gain2, :s32)}}
  end

  @doc "Declared tensor ranges of `compressor/3`."
  def compressor_ranges do
    k = 0..@k_max

    %{
      sample: [Q.sample_range()],
      state: [@env_range],
      params: [-(35 <<< 16)..0, 0..65536, 0..(1 <<< 18), 0..(1 <<< 20), 0..65536, k, k]
    }
  end

  @doc "Initial compressor state (the envelope)."
  def init_compressor, do: init_envelope()

  @doc """
  Compressor / limiter `compressor(x, env, {threshold, slope, knee, knee_r,
  makeup, env_att, env_rel})`, see the moduledoc. Returns `{y, next_env}`.
  """
  defn compressor(x, env, params) do
    {threshold, slope, knee, knee_r, makeup, k_att, k_rel} = params

    env2 = follow(x, env, k_att, k_rel)
    level = Q.log2_q16(env2, bits: 36) - 35 * 65536
    over = level - threshold
    half = Nx.right_shift(knee, 1)
    xc = Nx.min(Nx.max(over + half, 0), knee) |> Q.wide()
    knee_gr = Nx.right_shift(xc * xc * Q.wide(knee_r), 32)
    beyond = Nx.max(over - half, 0) |> Q.wide()
    d = Nx.right_shift((knee_gr + beyond) * Q.wide(slope), 16) |> Nx.min(24 * 65536)
    gain = Nx.right_shift(Q.wide(Q.exp2_neg_q24(d)) * Q.wide(makeup), 12)
    y = (Q.wide(x) * gain) |> shift_round(24) |> Q.sat24()
    {y, env2}
  end

  # -- float references ------------------------------------------------------------------

  @doc """
  Float reference of `gate/3` for samples in `[-1, 1)`, same options as
  `gate_params/1`, exact exponentials and no rounding. Returns the output list.
  """
  def gate_float(xs, opts \\ []) do
    o = gate_opts(opts)
    fs = o[:fs]
    ka = coefficient_float(o[:detector_attack_ms], fs)
    kr = coefficient_float(o[:detector_release_ms], fs)
    ga = coefficient_float(o[:attack_ms], fs)
    gr = coefficient_float(o[:release_ms], fs)
    {open_th, close_th} = {db_gain(o[:open_db]), db_gain(o[:close_db])}
    hold_n = round(o[:hold_ms] * fs / 1000)
    floor = db_gain(o[:range_db])

    {ys, _} =
      Enum.map_reduce(xs, {0.0, 0, 0, 1.0}, fn x, {env, open, hold, gain} ->
        env2 = smooth(env, abs(x), ka, kr)

        open2 =
          cond do
            env2 >= open_th -> 1
            env2 < close_th -> 0
            true -> open
          end

        hold2 = if open2 == 1, do: hold_n, else: max(hold - 1, 0)
        target = if open2 == 1 or hold > 0, do: 1.0, else: floor
        {x * gain, {env2, open2, hold2, smooth(gain, target, ga, gr)}}
      end)

    ys
  end

  @doc "Float reference of `compressor/3`, see `gate_float/2`."
  def compressor_float(xs, opts \\ []) do
    o = compressor_opts(opts)
    fs = o[:fs]
    ka = coefficient_float(o[:attack_ms], fs)
    kr = coefficient_float(o[:release_ms], fs)

    {ys, _} =
      Enum.map_reduce(xs, 0.0, fn x, env ->
        env2 = smooth(env, abs(x), ka, kr)
        level = 20 * :math.log10(max(env2, 1.0e-12))
        gr = level - compressor_curve(level, Keyword.put(opts, :makeup_db, 0.0))
        {x * db_gain(o[:makeup_db] - gr), env2}
      end)

    ys
  end

  defp smooth(cur, target, k_up, k_down),
    do: cur + (target - cur) * if(target > cur, do: k_up, else: k_down)

  @doc """
  The kernel specification for `ExHdl.DSP.analyze_scan/3` (see `ExAudio.Biquad.spec/1`)
  of `:envelope`, `:gate` or `:compressor`, with the parameters of `opts`
  (`gate_params/1`, `compressor_params/1`; for the envelope `:attack_ms`,
  `:release_ms`, `:fs`).
  """
  def spec(kind, opts \\ [])

  def spec(:envelope, opts) do
    fs = Keyword.get(opts, :fs, 48_000)
    k = {coefficient(opts[:attack_ms] || 1.0, fs), coefficient(opts[:release_ms] || 50.0, fs)}
    Q.spec(&envelope/3, init_envelope(), k, envelope_ranges(), ["k"])
  end

  def spec(:gate, opts),
    do: Q.spec(&gate/3, init_gate(), gate_params(opts), gate_ranges(), ["gate"])

  def spec(:compressor, opts),
    do:
      Q.spec(&compressor/3, init_compressor(), compressor_params(opts), compressor_ranges(), [
        "comp"
      ])
end

defmodule ExAudio.Biquad do
  @moduledoc """
  Fixed-point biquad: coefficient quantisation and the stream kernel.

  ## Why direct form I

  `y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]`

    * All state is signal history: `x` is a 24-bit sample and `y` is the
      output saturated to the range of a sample plus 8 guard bits. Their
      ranges are proven by one saturation, so the width check passes with
      no extra headroom. Direct form II transposed keeps partial sums,
      which for a resonant low-frequency section exceed full scale even
      when the output does not; it needs wide state or a nonlinear clamp.
    * The recursive part sees the guard bits, so rounding enters the
      feedback at `2^-8` LSB, and the rounding residual is fed back into the
      next sum (first-order error feedback). That puts a zero at DC into the
      noise transfer function. Without it a low-frequency section has a dead
      band of `2^-9 / (1 + a1 + a2)` extension units, about `2^-9 / w0^2` LSB
      (`w0 = 2 pi f0 / fs`): a stuck DC offset of 280 LSB for a 20 Hz high-pass.
      With it the zero-input response decays to zero (tested).
      The signal sees one more rounding, at the output (`error_bound/1`).
    * Switching coefficients while running is safe because the history
      is real signal values, which DF2T's internal states are not.
    * Cost: five state words (24+24+32+32+19 bit) instead of two, and five
      multipliers either way.

  ## Formats

    * `b0, b1, b2`: Q5.27 in `s32`, range `[-16, 16)`. A boost of +24 dB
      in a peaking or shelving band reaches `b < 16`; `quantize/1` refuses
      more.
    * `a1, a2`: Q2.30 in `s32`. `a1` is in `(-2, 2)` and `a2` in `(-1, 1)`
      for every stable filter; the kernel declares `a2` as `|a2| < 2^30`
      (this keeps the 64-bit accumulator proof).
    * Coefficient resolution is `2^-30` for the poles. At 48 kHz a 20 Hz
      high-pass has `1 - r` of about `1.3e-3`, three orders of magnitude
      above that. Measured against the unquantised design (levels above
      -30 dB): below 0.02 dB for `f0 >= 100` Hz (typically 0.003), below 0.1 dB for `f0 >= 20`
      Hz and Q up to 10; the exception is a narrow notch below 100 Hz, whose
      width and centre move with the zeros' resolution of `2^-28`.
    * Accumulator: `b*x` at 50 fractional bits, `a*y` at 61 (shifted down
      by 11), both in `s64`. The sum is rounded to 31 fractional bits
      (Q1.31 history), saturated, and the output is that rounded to 23
      bits and saturated to 24.

  The kernel is `step/3`; arguments `x`, `{x1, x2, y1, y2, res}`,
  `{b0, b1, b2, a1, a2}`, all `s32` tensors.

      iex> coef = ExAudio.Biquad.quantize(ExAudio.Filter.design(:lowpass, 1000, 48_000))
      iex> {ys, _} = ExAudio.Biquad.run([8_000_000, 0, 0, 0], coef)
      iex> Enum.map(ys, &(&1 > 0))
      [true, true, true, true]
  """
  import Nx.Defn
  import Bitwise
  import NxFixed.Primitives, only: [shift_round: 2, saturate: 2]

  alias ExAudio.Q

  @b_frac 27
  @a_frac 30
  @guard 8
  # the residual of rounding the sum to 31 fractional bits has 50 - 31 = 19 bits
  @res_shift 19
  @res_bits 18
  @res_half 1 <<< 18
  @res_mask (1 <<< 19) - 1

  @doc "Fractional bits of `b0..b2`."
  def b_frac, do: @b_frac
  @doc "Fractional bits of `a1, a2`."
  def a_frac, do: @a_frac

  @doc """
  Quantises `{b0, b1, b2, a1, a2}` to integers `{b0, b1, b2, a1, a2}`
  (round to nearest). Raises `ArgumentError` for an unstable filter or a
  numerator outside `[-16, 16)`.
  """
  @spec quantize(ExAudio.Filter.coef()) :: {integer(), integer(), integer(), integer(), integer()}
  def quantize({b0, b1, b2, a1, a2} = coef) do
    unless ExAudio.Filter.stable?(coef),
      do: raise(ArgumentError, "unstable filter #{inspect(coef)}")

    for b <- [b0, b1, b2],
        b >= 16 or b < -16,
        do: raise(ArgumentError, "numerator coefficient #{b} is outside [-16, 16)")

    # |a2| < 1 and |a1| < 2, clamped for filters within 2^-30 of the unit circle
    a2q = a2 |> scale(@a_frac) |> clamp(-((1 <<< 30) - 1), (1 <<< 30) - 1)
    a1q = a1 |> scale(@a_frac) |> clamp(-((1 <<< 31) - 1), (1 <<< 31) - 1)
    {scale(b0, @b_frac), scale(b1, @b_frac), scale(b2, @b_frac), a1q, a2q}
  end

  @doc "The float coefficients a quantised tuple stands for."
  def dequantize({b0, b1, b2, a1, a2}),
    do:
      {b0 / (1 <<< @b_frac), b1 / (1 <<< @b_frac), b2 / (1 <<< @b_frac), a1 / (1 <<< @a_frac),
       a2 / (1 <<< @a_frac)}

  @doc "Unity gain: `y = x`."
  def identity, do: {1 <<< @b_frac, 0, 0, 0, 0}

  defp scale(v, frac), do: round(v * (1 <<< frac))
  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  @doc "Coefficient tuple as `s32` tensors, the kernel's parameter."
  def coef_tensors(coef), do: coef |> Tuple.to_list() |> Enum.map(&Q.sample/1) |> List.to_tuple()

  @doc "Zero state `{x1, x2, y1, y2, res}`."
  def init_state, do: Q.tensors({0, 0, 0, 0, 0})

  @doc """
  Declared ranges of the kernel's tensors for `param_ranges:`:
  `%{sample: _, state: _, params: _}`, flat lists in argument order.
  """
  def ranges do
    s = Q.sample_range()
    y = -(1 <<< 31)..((1 <<< 31) - 1)
    a2 = -(1 <<< 30)..((1 <<< 30) - 1)
    full = y
    res = -(1 <<< @res_bits)..((1 <<< @res_bits) - 1)
    %{sample: [s], state: [s, s, y, y, res], params: [full, full, full, full, a2]}
  end

  @doc """
  The biquad stream kernel: `step(x, {x1, x2, y1, y2, res}, {b0, b1, b2, a1, a2})`
  returns `{y, next_state}`.
  """
  defn step(x, state, coef) do
    {x1, x2, y1, y2, res} = state
    {b0, b1, b2, a1, a2} = coef

    feedforward = Q.wide(b0) * Q.wide(x) + Q.wide(b1) * Q.wide(x1) + Q.wide(b2) * Q.wide(x2)
    feedback = Q.wide(a1) * Q.wide(y1) + Q.wide(a2) * Q.wide(y2)
    # b*x has 27 + 23 = 50 fractional bits, a*y has 30 + 31 = 61
    acc =
      feedforward - Nx.right_shift(feedback, @a_frac + 23 + @guard - (@b_frac + 23)) + Q.wide(res)

    y_ext = acc |> shift_round(@res_shift) |> saturate(:s32)
    # what rounding dropped, in [-2^18, 2^18): added to the next sum
    half = Nx.tensor(@res_half, type: :s64)
    res2 = acc |> Nx.add(half) |> Nx.bitwise_and(@res_mask) |> Nx.subtract(half)
    y = y_ext |> Q.wide() |> shift_round(@guard) |> Q.sat24()
    {y, {x, x1, y_ext, y1, Nx.as_type(res2, :s32)}}
  end

  @doc """
  Kernel specification for `ExHdl.DSP.analyze_scan/3` and `scan_to_sv/3`:
  `[fun:, args:, state: 1, param_ranges:, init:, param_names:]`. `init` is
  an initial state container, `coefs` the coefficient tuple (integers).
  """
  def spec(coefs \\ identity()),
    do: Q.spec(&step/3, init_state(), coefs, ranges(), ["coef"])

  @doc """
  Runs `samples` (24-bit integers) through the kernel (the Nx reference,
  width-checked once). Returns `{outputs, final_state}`; `state` as
  `init_state/0`.
  """
  def run(samples, coef, state \\ init_state()) do
    {out, state} = Q.run(spec(coef), samples, state: state)
    {Nx.to_flat_list(out), state}
  end

  @doc """
  Worst-case deviation (in output LSB) of the kernel from a double
  precision direct form I with the same (dequantised) coefficients, for
  inputs that never saturate: half an LSB for the output rounding, plus
  the guard-bit rounding of the recursion. The recursion's error is the
  rounding residual (at most `2^-9` LSB) filtered by `(1 - z^-1) / A(z)`; the
  bound sums the absolute impulse response of that filter.
  """
  @spec error_bound({integer(), integer(), integer(), integer(), integer()}) :: float()
  def error_bound({_, _, _, a1, a2}) do
    {a1, a2} = {a1 / (1 <<< @a_frac), a2 / (1 <<< @a_frac)}

    l1 =
      Stream.iterate({1.0, 0.0}, fn {h1, h2} -> {-a1 * h1 - a2 * h2, h1} end)
      |> Stream.map(&elem(&1, 0))
      |> Stream.chunk_every(2, 1, :discard)
      |> Stream.map(fn [h, next] -> abs(next - h) end)
      |> Enum.reduce_while({1.0, 0}, fn g, {acc, quiet} ->
        quiet = if g < 1.0e-9, do: quiet + 1, else: 0
        if quiet > 8, do: {:halt, {acc, quiet}}, else: {:cont, {acc + g, quiet}}
      end)
      |> elem(0)

    0.5 + l1 / (2 <<< @guard)
  end
end

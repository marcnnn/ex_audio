defmodule ExAudio.Filter do
  @moduledoc """
  Biquad designs from the Audio EQ Cookbook (Robert Bristow-Johnson), in
  floats, plus frequency response evaluation.

  A design is a tuple `{b0, b1, b2, a1, a2}` normalised by `a0`, for
  `y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]`.
  `ExAudio.Biquad` quantises it for the fixed-point kernel.

  Types: `:lowpass`, `:highpass`, `:bandpass` (0 dB peak), `:bandpass_skirt`
  (peak gain Q), `:notch`, `:allpass`, `:peaking`, `:lowshelf`,
  `:highshelf`. Options: `:q` (default `1/sqrt(2)`), `:gain_db` (peaking and
  shelves), `:slope` (shelves, instead of `:q`, as in the cookbook).

      iex> {b0, b1, b2, a1, a2} = ExAudio.Filter.design(:lowpass, 1000, 48_000, q: 0.7071)
      iex> Float.round((b0 + b1 + b2) / (1 + a1 + a2), 9)
      1.0
      iex> ExAudio.Filter.magnitude_db(ExAudio.Filter.design(:peaking, 1000, 48_000, q: 2, gain_db: 6), 1000, 48_000) |> Float.round(6)
      6.0
  """

  @type coef :: {float(), float(), float(), float(), float()}
  @type kind ::
          :lowpass
          | :highpass
          | :bandpass
          | :bandpass_skirt
          | :notch
          | :allpass
          | :peaking
          | :lowshelf
          | :highshelf

  @doc "Designs a biquad for centre or corner frequency `f0` (Hz) at sample rate `fs`."
  @spec design(kind(), number(), number(), keyword()) :: coef()
  def design(kind, f0, fs, opts \\ []) do
    unless f0 > 0 and f0 < fs / 2,
      do: raise(ArgumentError, "f0 must be in (0, fs/2), got #{f0} at fs = #{fs}")

    w0 = 2 * :math.pi() * f0 / fs
    cos = :math.cos(w0)
    sin = :math.sin(w0)
    db = Keyword.get(opts, :gain_db, 0.0)
    a = :math.pow(10, db / 40)
    q = quality(kind, opts, a)
    alpha = sin / (2 * q)

    {b0, b1, b2, a0, a1, a2} = raw(kind, cos, sin, alpha, a, q)
    {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0}
  end

  defp quality(kind, opts, a) when kind in [:lowshelf, :highshelf] do
    case Keyword.fetch(opts, :slope) do
      {:ok, s} -> 1 / :math.sqrt((a + 1 / a) * (1 / s - 1) + 2)
      :error -> Keyword.get(opts, :q, :math.sqrt(0.5))
    end
  end

  defp quality(_kind, opts, _a), do: Keyword.get(opts, :q, :math.sqrt(0.5))

  defp raw(:lowpass, cos, _sin, alpha, _a, _q),
    do: {(1 - cos) / 2, 1 - cos, (1 - cos) / 2, 1 + alpha, -2 * cos, 1 - alpha}

  defp raw(:highpass, cos, _sin, alpha, _a, _q),
    do: {(1 + cos) / 2, -(1 + cos), (1 + cos) / 2, 1 + alpha, -2 * cos, 1 - alpha}

  defp raw(:bandpass, cos, _sin, alpha, _a, _q),
    do: {alpha, 0.0, -alpha, 1 + alpha, -2 * cos, 1 - alpha}

  defp raw(:bandpass_skirt, cos, sin, alpha, _a, _q),
    do: {sin / 2, 0.0, -sin / 2, 1 + alpha, -2 * cos, 1 - alpha}

  defp raw(:notch, cos, _sin, alpha, _a, _q),
    do: {1.0, -2 * cos, 1.0, 1 + alpha, -2 * cos, 1 - alpha}

  defp raw(:allpass, cos, _sin, alpha, _a, _q),
    do: {1 - alpha, -2 * cos, 1 + alpha, 1 + alpha, -2 * cos, 1 - alpha}

  defp raw(:peaking, cos, _sin, alpha, a, _q),
    do: {1 + alpha * a, -2 * cos, 1 - alpha * a, 1 + alpha / a, -2 * cos, 1 - alpha / a}

  defp raw(:lowshelf, cos, _sin, alpha, a, _q) do
    s = 2 * :math.sqrt(a) * alpha

    {a * (a + 1 - (a - 1) * cos + s), 2 * a * (a - 1 - (a + 1) * cos),
     a * (a + 1 - (a - 1) * cos - s), a + 1 + (a - 1) * cos + s, -2 * (a - 1 + (a + 1) * cos),
     a + 1 + (a - 1) * cos - s}
  end

  defp raw(:highshelf, cos, _sin, alpha, a, _q) do
    s = 2 * :math.sqrt(a) * alpha

    {a * (a + 1 + (a - 1) * cos + s), -2 * a * (a - 1 + (a + 1) * cos),
     a * (a + 1 + (a - 1) * cos - s), a + 1 - (a - 1) * cos + s, 2 * (a - 1 - (a + 1) * cos),
     a + 1 - (a - 1) * cos - s}
  end

  @doc "Complex frequency response `{re, im}` at `f` Hz."
  @spec response(coef(), number(), number()) :: {float(), float()}
  def response({b0, b1, b2, a1, a2}, f, fs) do
    w = 2 * :math.pi() * f / fs
    {c1, s1, c2, s2} = {:math.cos(w), :math.sin(w), :math.cos(2 * w), :math.sin(2 * w)}
    {nr, ni} = {b0 + b1 * c1 + b2 * c2, -(b1 * s1 + b2 * s2)}
    {dr, di} = {1 + a1 * c1 + a2 * c2, -(a1 * s1 + a2 * s2)}
    d = dr * dr + di * di
    {(nr * dr + ni * di) / d, (ni * dr - nr * di) / d}
  end

  @doc "Magnitude in dB."
  @spec magnitude_db(coef(), number(), number()) :: float()
  def magnitude_db(coef, f, fs) do
    {re, im} = response(coef, f, fs)
    10 * :math.log10(max(re * re + im * im, 1.0e-300))
  end

  @doc "Phase in radians, in `(-pi, pi]`."
  @spec phase(coef(), number(), number()) :: float()
  def phase(coef, f, fs) do
    {re, im} = response(coef, f, fs)
    :math.atan2(im, re)
  end

  @doc "`{freq, magnitude_db, phase}` for each frequency."
  def sweep(coef, freqs, fs),
    do: for(f <- freqs, do: {f, magnitude_db(coef, f, fs), phase(coef, f, fs)})

  @doc "`n` frequencies spaced logarithmically from `lo` to `hi` Hz."
  def log_space(lo, hi, n),
    do: for(i <- 0..(n - 1), do: lo * :math.pow(hi / lo, i / (n - 1)))

  @doc "True if both poles are inside the unit circle."
  @spec stable?(coef()) :: boolean()
  def stable?({_b0, _b1, _b2, a1, a2}), do: abs(a2) < 1 and abs(a1) < 1 + a2

  @doc """
  Filters `xs` (floats) in direct form I with double precision: the float
  reference for the fixed-point kernel. With `saturate: {lo, hi}` the output
  (which is also the feedback) is clamped, like the kernel's.
  """
  @spec process(coef(), [number()], keyword()) :: [float()]
  def process({b0, b1, b2, a1, a2}, xs, opts \\ []) do
    {lo, hi} = Keyword.get(opts, :saturate, {-1.0e300, 1.0e300})

    {ys, _} =
      Enum.map_reduce(xs, {0.0, 0.0, 0.0, 0.0}, fn x, {x1, x2, y1, y2} ->
        y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) |> max(lo) |> min(hi)
        {y, {x, x1, y, y1}}
      end)

    ys
  end
end

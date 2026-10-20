defmodule ExAudio.Q do
  @moduledoc """
  Number formats and building blocks shared by the kernels.

  Audio samples are 24-bit signed integers, Q1.23 (full scale is
  `2^23`), carried in `s32` tensors. Nx has no `s24`, so every kernel is
  analysed with `param_ranges` that narrow the sample, state and parameter
  tensors to what they really hold (`ranges/1`); the width check then
  proves every intermediate value, and the generated hardware uses
  exactly those widths. A value outside its declared range is a contract
  violation of the caller, not detected at run time.

  ## Log and exp

  Levels are `log2` values in Q16 (`log2_q16/2`, 6.02 dB per unit):
  the leading one is found by comparing with the constants `2^k` and
  summing, the mantissa is normalised with a variable shift and the
  fractional part comes from a table. `exp2_neg_q24/2` is the inverse for
  gains `2^-d`.
  """
  import Nx.Defn
  import Bitwise

  @sample_max (1 <<< 23) - 1
  @sample_min -(1 <<< 23)

  @doc "Range of a 24-bit sample."
  def sample_range, do: @sample_min..@sample_max

  @doc "A 24-bit sample as a `s32` scalar tensor."
  def sample(v), do: Nx.tensor(v, type: :s32)

  @doc "A list of samples (or gains) as an `s32` vector."
  def sample_tensor(list), do: Nx.tensor(list, type: :s32)

  @doc "Float in `[-1, 1)` to a 24-bit sample (rounded, saturated)."
  def from_float(v),
    do: v |> Kernel.*(1 <<< 23) |> round() |> max(@sample_min) |> min(@sample_max)

  @doc "24-bit sample to float."
  def to_float(v), do: v / (1 <<< 23)

  @doc "Saturates to 24 bits, result `s32`."
  deftransform(sat24(x), do: x |> Nx.clip(@sample_min, @sample_max) |> Nx.as_type(:s32))

  @doc """
  `|x|` as `max(max(x, 0 - x), 0)` (the outer `max` lets the range analysis see that the result is not negative). The generated SystemVerilog of `Nx.abs/1` contains
  `-25'(n)`, which Yosys 0.69 reads as a cast to a negative size (see NEEDS.md).
  """
  deftransform absolute(x), do: Nx.max(Nx.max(x, Nx.subtract(0, x)), 0)

  @doc "`s64` view of a tensor (products of 32-bit values need it)."
  deftransform(wide(x), do: Nx.as_type(x, :s64))

  @doc """
  One step of a first-order smoother towards `target`, with separate
  coefficients for rising (`k_att`) and falling (`k_rel`) targets, in Q`kbits`.

  The move is `diff * k` rounded away from `cur`, so it is at least one unit
  and never overshoots: the value reaches the target exactly instead of
  stalling in a dead band, whatever the time constant.
  """
  deftransform approach(cur, target, k_att, k_rel, kbits) do
    diff = Nx.subtract(target, cur)
    up = Nx.greater(diff, 0)
    k = Nx.select(up, wide(k_att), wide(k_rel))
    bias = Nx.select(up, Nx.tensor((1 <<< kbits) - 1, type: :s64), Nx.tensor(0, type: :s64))
    Nx.add(cur, Nx.right_shift(Nx.add(Nx.multiply(diff, k), bias), kbits))
  end

  @doc "Clamps `x` to `lo..hi` (Elixir integers), keeps the type."
  deftransform clamp(x, lo, hi) do
    type = Nx.type(x)
    Nx.clip(x, Nx.tensor(lo, type: type), Nx.tensor(hi, type: type))
  end

  @doc """
  `log2(v)` in Q16 for `1 <= v < 2^bits` (smaller values count as 1).
  Option `:lut_bits` (default 10) is the table's address width; the table
  holds the value at the middle of each cell, so the error is at most
  `2^-(lut_bits + 1) / ln 2` log2 units.
  """
  deftransform log2_q16(v, opts \\ []) do
    bits = Keyword.fetch!(opts, :bits)
    lut_bits = Keyword.get(opts, :lut_bits, 10)
    n = 1 <<< lut_bits
    v = Nx.max(wide(v), 1)
    ks = for k <- 1..(bits - 1), do: 1 <<< k
    thresholds = Nx.tensor(ks, type: :s64, backend: Nx.BinaryBackend)
    m = v |> Nx.greater_equal(thresholds) |> Nx.as_type(:s32) |> Nx.sum()
    # the bits below the leading one: shift down for large v, up for small v
    down = Nx.right_shift(v, Nx.max(Nx.subtract(m, lut_bits), 0))
    up = Nx.left_shift(Nx.min(v, n - 1), Nx.max(Nx.subtract(lut_bits, m), 0))
    idx = Nx.select(Nx.greater_equal(m, lut_bits), down, up) |> Nx.bitwise_and(n - 1)
    table = Nx.tensor(log2_table(n), type: :s32, backend: Nx.BinaryBackend)
    Nx.add(Nx.left_shift(m, 16), Nx.take(table, idx))
  end

  @doc false
  def log2_table(n),
    do: for(j <- 0..(n - 1), do: round(:math.log2(1 + (j + 0.5) / n) * 65536))

  @doc """
  `2^-d` in Q24 for `d` in Q16, `0 <= d <= 24 * 2^16` (the caller clamps).
  Option `:lut_bits` as for `log2_q16/2`.
  """
  deftransform exp2_neg_q24(d, opts \\ []) do
    lut_bits = Keyword.get(opts, :lut_bits, 10)
    n = 1 <<< lut_bits
    table = Nx.tensor(exp2_table(n), type: :s32, backend: Nx.BinaryBackend)
    int = Nx.right_shift(d, 16)
    idx = d |> Nx.bitwise_and(0xFFFF) |> Nx.right_shift(16 - lut_bits)
    Nx.right_shift(Nx.take(table, idx), int)
  end

  @doc false
  def exp2_table(n),
    do: for(j <- 0..(n - 1), do: round(:math.pow(2, -(j + 0.5) / n) * (1 <<< 24)))

  @doc """
  Per-leaf range map for `param_ranges:` from the lists of ranges of the
  kernel's arguments, e.g. `ranges([sample_ranges, state_ranges, param_ranges])`
  where each element is a flat list with one `lo..hi` (or `nil`) per tensor
  leaf, in argument order.
  """
  def ranges(per_argument) do
    per_argument
    |> List.flatten()
    |> Enum.with_index()
    |> Enum.reject(fn {r, _} -> is_nil(r) end)
    |> Map.new(fn {r, i} -> {i, r} end)
  end

  @doc "Argument templates (shapes and types) for `ExHdl.DSP.analyze_scan/3`."
  def templates(container),
    do: Nx.Defn.Composite.traverse(container, &Nx.to_template(Nx.tensor(&1)))

  @doc """
  Float level `dB` (re full scale) to Q16 log2 units (rounded).

      iex> ExAudio.Q.db_to_log2(-6.0206)
      -65536
  """
  def db_to_log2(db), do: round(db / (20 * :math.log10(2)) * 65536)

  @doc "Q16 log2 units to dB."
  def log2_to_db(l), do: l / 65536 * 20 * :math.log10(2)

  @doc "Integers in (nested tuples of) parameters as `s32` scalar tensors."
  def tensors(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&tensors/1) |> List.to_tuple()

  def tensors(v) when is_integer(v), do: sample(v)
  def tensors(%Nx.Tensor{} = t), do: t

  @doc """
  Builds a kernel specification: `fun` is `step(x, state, params)`, `init` the
  initial state, `params` the parameters (integers, `tensors/1` converts them;
  `nil` for kernels without), `ranges` a map with `:sample`, `:state` and
  `:params` lists of per-leaf ranges and `names` the parameter port names.
  `extra` may hold `:sample` (an example when the sample is not a scalar),
  `:kernel_opts` (the trailing keyword argument of the kernel) and options for
  `ExHdl.DSP.scan_to_sv/3` such as `:lanes`.
  Returns `[fun:, args:, state: 1, param_ranges:, init:, param_names:, params:, ...]`.
  """
  def spec(fun, init, params, ranges, names, extra \\ []) do
    {sample, extra} = Keyword.pop(extra, :sample)
    {kernel_opts, extra} = Keyword.pop(extra, :kernel_opts)
    params = params && tensors(params)
    arguments = [sample || sample(0), init] ++ if(params, do: [params], else: [])

    [
      fun: fun,
      args: Enum.map(arguments, &templates/1) ++ if(kernel_opts, do: [kernel_opts], else: []),
      state: 1,
      param_ranges: ranges([ranges.sample, ranges.state, ranges.params]),
      init: init,
      param_names: names,
      params: params,
      kernel_opts: kernel_opts
    ] ++ extra
  end

  @doc """
  Analyses kernel `spec` (`ExAudio.Biquad.spec/1` and friends) with
  `ExHdl.DSP.analyze_scan/3`; `extra` are further options (`:ii`, `:channels`, ...).
  """
  def analyze(spec, extra \\ []),
    do: ExHdl.DSP.analyze_scan(spec[:fun], spec[:args], scan_opts(spec, extra))

  @doc "Generates SystemVerilog for `spec` with `ExHdl.DSP.scan_to_sv/3`."
  def to_sv(spec, extra \\ []),
    do: ExHdl.DSP.scan_to_sv(spec[:fun], spec[:args], scan_opts(spec, extra))

  defp scan_opts(spec, extra),
    do: Keyword.drop(spec, [:fun, :args, :params, :kernel_opts]) ++ extra

  @doc """
  The Nx reference: runs `samples` (a list of integers, or a container of
  stacked tensors) through the kernel of `spec` with the parameters
  `spec[:params]`; `opts` may hold `:state` (default `spec[:init]`) and
  `:params`. Returns `{outputs, final_state}`; outputs are tensors with the
  sample index first.
  """
  def run(spec, samples, opts \\ []) do
    samples = if is_list(samples), do: Nx.tensor(samples, type: :s32), else: samples
    state = Keyword.get(opts, :state, spec[:init])
    params = Keyword.get(opts, :params, spec[:params])

    NxFixed.run_scan_stacked(
      spec[:fun],
      samples,
      state,
      if(params, do: [params], else: []),
      param_ranges: spec[:param_ranges],
      kernel_opts: spec[:kernel_opts]
    )
  end
end

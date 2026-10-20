defmodule ExAudio.Matrix do
  @moduledoc """
  Sparse crosspoint matrix mixer: every output sums up to `slots` sources,
  each with its own gain.

  Gains are signed integers in Q3.15 (`[-4, 4)`, `gain/1`; negative gains
  invert), so a 24-bit sample times a gain is a 25 x 18 bit product, one
  DSP48E1. The sum of up to 64 products needs 48 bits; it is rounded to
  24 bits (half up) and saturated, and the saturation is counted.

  The BEAM side is the `%ExAudio.Matrix{}` table (`connect/4`,
  `disconnect/3`, `row/2`) and `mix/2`, exact integer arithmetic.
  The part that is a stream kernel today is one output row: `step/3`
  takes the `k` source samples of an output (gathered by the caller,
  `row/2` gives the indices and gains) and the gains and produces the
  output sample; its state counts saturated outputs. `mac/3` is the same
  row as a stream: one `{source sample, gain}` pair per beat into one
  multiplier and an accumulator, one output (and clip flag) every `slots`
  beats (variable-rate output, `lanes: 1`). `mix/2`, `step/3` and `mac/3` agree
  bit for bit.

      iex> m = ExAudio.Matrix.new(n_in: 4, n_out: 2, slots: 2)
      iex> m = m |> ExAudio.Matrix.connect(0, 1, 0.5) |> ExAudio.Matrix.connect(0, 3, -1.0)
      iex> ExAudio.Matrix.mix(m, [0, 1000, 0, 400])
      [100, 0]
  """
  import Nx.Defn
  import Bitwise
  import NxFixed.Primitives, only: [shift_round: 2]

  alias ExAudio.Q

  @frac 15
  @gain_max (1 <<< 17) - 1
  @gain_min -(1 <<< 17)
  @clip_max 65_535

  defstruct [:n_in, :n_out, :slots, rows: %{}]

  @type t :: %__MODULE__{}

  @doc "Empty matrix. Options: `:n_in`, `:n_out`, `:slots` (default 64)."
  def new(opts),
    do: %__MODULE__{
      n_in: Keyword.fetch!(opts, :n_in),
      n_out: Keyword.fetch!(opts, :n_out),
      slots: Keyword.get(opts, :slots, 64)
    }

  @doc "Linear gain to Q3.15 (rounded, saturated)."
  def gain(linear),
    do: linear |> Kernel.*(1 <<< @frac) |> round() |> max(@gain_min) |> min(@gain_max)

  @doc "dB to linear gain."
  def db(db), do: :math.pow(10, db / 20)

  @doc """
  Connects source `src` to output `out` with linear gain `linear` (replacing an
  existing crosspoint; a gain that quantises to zero disconnects). Raises when
  the output already has `slots` other sources.
  """
  @spec connect(t(), non_neg_integer(), non_neg_integer(), number()) :: t()
  def connect(%__MODULE__{} = m, out, src, linear) do
    unless out in 0..(m.n_out - 1) and src in 0..(m.n_in - 1),
      do: raise(ArgumentError, "crosspoint #{src} -> #{out} outside the matrix")

    row = Map.get(m.rows, out, %{})
    g = gain(linear)

    cond do
      g == 0 ->
        disconnect(m, out, src)

      not Map.has_key?(row, src) and map_size(row) >= m.slots ->
        raise ArgumentError, "output #{out} already has #{m.slots} sources"

      true ->
        %{m | rows: Map.put(m.rows, out, Map.put(row, src, g))}
    end
  end

  @doc "Removes a crosspoint."
  def disconnect(%__MODULE__{} = m, out, src) do
    row = m.rows |> Map.get(out, %{}) |> Map.delete(src)
    %{m | rows: if(row == %{}, do: Map.delete(m.rows, out), else: Map.put(m.rows, out, row))}
  end

  @doc """
  `{sources, gains}` of an output, each a list of `slots` entries sorted by
  source and padded with `0` (source 0, gain 0): what the kernel takes.
  """
  def row(%__MODULE__{} = m, out) do
    entries = m.rows |> Map.get(out, %{}) |> Enum.sort()
    pad = List.duplicate({0, 0}, m.slots - length(entries))
    entries |> Kernel.++(pad) |> Enum.unzip()
  end

  @doc """
  Mixes one frame (a list of `n_in` 24-bit integers) into `n_out` outputs.
  """
  @spec mix(t(), [integer()]) :: [integer()]
  def mix(m, frame), do: m |> mix_clip(frame) |> elem(0)

  @doc "Like `mix/2`, also returns for each output whether it saturated."
  def mix_clip(%__MODULE__{} = m, frame) do
    samples = List.to_tuple(frame)

    results =
      for out <- 0..(m.n_out - 1) do
        acc =
          m.rows
          |> Map.get(out, %{})
          |> Enum.reduce(0, fn {src, g}, acc -> acc + g * elem(samples, src) end)

        round_saturate(acc)
      end

    {Enum.map(results, &elem(&1, 0)), Enum.map(results, &elem(&1, 1))}
  end

  defp round_saturate(acc) do
    y = (acc + (1 <<< (@frac - 1))) >>> @frac
    lo = -(1 <<< 23)
    hi = (1 <<< 23) - 1
    {y |> max(lo) |> min(hi), y < lo or y > hi}
  end

  @doc "Float reference of `mix/2`: the same quantised gains, no rounding or saturation."
  def mix_float(%__MODULE__{} = m, frame) do
    for out <- 0..(m.n_out - 1) do
      m.rows
      |> Map.get(out, %{})
      |> Enum.reduce(0.0, fn {src, g}, acc -> acc + g / (1 <<< @frac) * Enum.at(frame, src) end)
    end
  end

  # -- kernel -----------------------------------------------------------------------------

  @doc "Declared tensor ranges of `step/3` for `slots` sources."
  def ranges do
    %{sample: [Q.sample_range()], state: [0..@clip_max], params: [@gain_min..@gain_max]}
  end

  @doc """
  One output row: `step(x, clips, gains)` with `x` the `k` source samples
  (`s32[k]`), `gains` Q3.15 gains (`s32[k]`) and `clips` the saturation
  count (stops at 65535). Returns `{y, next_clips}`.
  """
  defn step(x, clips, gains) do
    acc = Nx.dot(Q.wide(x), Q.wide(gains))
    y = shift_round(acc, @frac)
    over = Nx.logical_or(y > 8_388_607, y < -8_388_608)
    clips2 = Nx.select(over, Nx.min(clips + 1, @clip_max), clips)
    {Q.sat24(y), Nx.as_type(clips2, :s32)}
  end

  @doc """
  Kernel specification (see `ExAudio.Biquad.spec/1`) for rows of `k` sources
  with the gains `gains` (a list of `k` Q3.15 integers).
  """
  def spec(gains) do
    k = length(gains)
    r = ranges()
    sample = Nx.broadcast(Q.sample(0), {k})

    Q.spec(&step/3, Q.sample(0), Nx.tensor(gains, type: :s32), r, ["gains"], sample: sample)
  end

  # -- streaming multiply-accumulate -------------------------------------------------------

  @product_max 1 <<< 40

  @doc "Declared tensor ranges of `mac/3` for rows of `slots` sources."
  def mac_ranges(slots) do
    bound = slots * @product_max

    %{
      sample: [Q.sample_range(), @gain_min..@gain_max],
      state: [-bound..bound, 0..(slots - 1)],
      params: []
    }
  end

  @doc "Initial state of `mac/3`: `{acc, position}`."
  def init_mac, do: {Nx.tensor(0, type: :s64), Q.sample(0)}

  @doc """
  `mac({x, gain}, {acc, position}, slots: k)`: adds `x * gain` to the
  accumulator; at the `k`-th pair the sum is rounded to 24 bits, saturated,
  and emitted as `{{[y], [clip]}, 1}` (one lane, count 1), otherwise the
  count is 0. Pad a row with `{0, 0}` pairs to `k`.
  """
  defn mac(sample, state, opts \\ []) do
    opts = keyword!(opts, [:slots])
    {x, gain} = sample
    {acc, position} = state
    bound = opts[:slots] * @product_max

    acc2 = Q.clamp(acc + Q.wide(x) * Q.wide(gain), -bound, bound)
    last = position == opts[:slots] - 1
    y = shift_round(acc2, @frac)
    clip = Nx.logical_or(y > 8_388_607, y < -8_388_608)
    acc3 = Nx.select(last, Nx.tensor(0, type: :s64), acc2)
    position2 = Nx.select(last, 0, Nx.min(position + 1, opts[:slots] - 1)) |> Nx.as_type(:s32)

    {{{Nx.reshape(Q.sat24(y), {1}), Nx.reshape(Nx.as_type(clip, :s32), {1})},
      Nx.as_type(last, :s32)}, {acc3, position2}}
  end

  @doc """
  Kernel specification (see `ExAudio.Biquad.spec/1`) of `mac/3` for rows
  of `slots` sources. The pairs are the sample; there are no parameter ports.
  """
  def mac_spec(slots) do
    sample = {Q.sample(0), Q.sample(0)}

    Q.spec(&mac/3, init_mac(), nil, mac_ranges(slots), [],
      sample: sample,
      kernel_opts: [slots: slots],
      lanes: 1
    )
  end

  @doc """
  The input stream of output `out` for `frames` (lists of `n_in` samples):
  `{samples, gains}`, the `slots` pairs of each frame in row order.
  """
  def mac_stream(%__MODULE__{} = m, out, frames) do
    {srcs, gains} = row(m, out)

    {Enum.flat_map(frames, fn f -> Enum.map(srcs, &Enum.at(f, &1)) end),
     Enum.flat_map(frames, fn _ -> gains end)}
  end

  @doc """
  Runs `frames` of output `out` through `mac/3` (the Nx reference). Returns
  `{ys, clips}`, one entry per frame.
  """
  def run_mac(%__MODULE__{} = m, out, frames) do
    {xs, gs} = mac_stream(m, out, frames)
    {{{y, clip}, count}, _} = Q.run(mac_spec(m.slots), {Q.sample_tensor(xs), Q.sample_tensor(gs)})
    counts = Nx.to_flat_list(count)

    keep = fn t ->
      t
      |> Nx.to_flat_list()
      |> Enum.zip(counts)
      |> Enum.filter(&(elem(&1, 1) == 1))
      |> Enum.map(&elem(&1, 0))
    end

    {keep.(y), keep.(clip)}
  end
end

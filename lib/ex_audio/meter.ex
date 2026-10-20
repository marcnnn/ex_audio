defmodule ExAudio.Meter do
  @moduledoc """
  Level meters as stream kernels.

  ## Peak with hold

  `peak/3`: state `{peak, hold}`, parameters `{hold_n, decay, clip_level}`.
  The peak follows `|x|` upwards at once, stays for `hold_n` samples,
  then decays by the factor `1 - decay` per sample (Q28, see
  `ExAudio.Dynamics.coefficient/3`; never stalls, see `ExAudio.Q.approach/5`).
  Outputs `{peak, clip}`: the held peak as a 24-bit amplitude and 1 if
  `|x| >= clip_level` for this sample (use `2^23 - 1` or a few LSB less).
  Read the latest output at the display rate; the kernel itself runs at the
  sample rate.

  ## RMS

  `rms/3`: state `ms` (mean square, exponentially weighted), parameter `k`
  (Q23). The squares are kept in units of `2^-40` full scale squared (the
  input square is rounded down by 6 bits so the `diff * k` product fits
  64 bits, which puts the floor at -120 dBFS). The output is the level in
  Q16 log2 units relative to full scale (`ExAudio.Q.log2_to_db/1`: 6.02 dB
  per unit); the square root is the halving of the logarithm. A full scale
  sine reads -3.01 dB, a full scale constant 0 dB.

      iex> spec = ExAudio.Meter.spec(:rms, tau_ms: 1)
      iex> {l, _} = ExAudio.Q.run(spec, List.duplicate(4_194_304, 2000))
      iex> l |> Nx.to_flat_list() |> List.last() |> ExAudio.Q.log2_to_db() |> Float.round(1)
      -6.0
  """
  import Nx.Defn
  import Bitwise
  import NxFixed.Primitives, only: [shift_round: 2]

  alias ExAudio.{Dynamics, Q}

  @env_shift 12
  @env_max 1 <<< 35
  @k_bits 28
  @ms_shift 6
  @ms_max 1 <<< 40
  @ms_k_bits 23

  @doc "Declared tensor ranges of `peak/3`."
  def peak_ranges do
    hold = 0..((1 <<< 24) - 1)

    %{
      sample: [Q.sample_range()],
      state: [0..@env_max, hold],
      params: [hold, 0..((1 <<< @k_bits) - 1), 0..(1 <<< 23)]
    }
  end

  @doc "Initial state of `peak/3`."
  def init_peak, do: {Nx.tensor(0, type: :s64), Q.sample(0)}

  @doc "Peak hold meter `peak(x, {peak, hold}, {hold_n, decay, clip_level})`, see the moduledoc."
  defn peak(x, state, params) do
    {peak, hold} = state
    {hold_n, decay, clip_level} = params

    a = Nx.left_shift(Q.absolute(Q.wide(x)), @env_shift)
    rising = a >= peak
    held = hold > 0

    decayed =
      peak |> Q.approach(Nx.tensor(0, type: :s64), decay, decay, @k_bits) |> Q.clamp(0, @env_max)

    peak2 = Nx.select(rising, a, Nx.select(held, peak, decayed))
    hold2 = Nx.select(rising, hold_n, Nx.max(hold - 1, 0)) |> Nx.as_type(:s32)
    out = Nx.right_shift(peak, @env_shift) |> Nx.as_type(:s32)
    clip = Nx.as_type(Q.absolute(Q.wide(x)) >= Q.wide(clip_level), :s32)
    {{out, clip}, {peak2, hold2}}
  end

  @doc "Declared tensor ranges of `rms/3`."
  def rms_ranges,
    do: %{sample: [Q.sample_range()], state: [0..@ms_max], params: [0..((1 <<< @ms_k_bits) - 1)]}

  @doc "Initial state of `rms/3`."
  def init_rms, do: Nx.tensor(0, type: :s64)

  @doc "RMS meter `rms(x, ms, k)`; returns `{level, next_ms}`."
  defn rms(x, ms, k) do
    sq = (Q.wide(x) * Q.wide(x)) |> shift_round(@ms_shift) |> Q.clamp(0, @ms_max)
    ms2 = ms |> Q.approach(sq, k, k, @ms_k_bits) |> Q.clamp(0, @ms_max)
    level = Nx.right_shift(Q.log2_q16(ms2, bits: 41) - 40 * 65536, 1)
    {level, ms2}
  end

  @doc """
  Kernel specification (see `ExAudio.Biquad.spec/1`) of `:peak` or `:rms`.
  Options: `:fs` (48000); peak: `:hold_ms` (500), `:decay_ms` (time constant
  of the decay, 300), `:clip_margin` (LSB below full scale, 0); rms: `:tau_ms` (300).
  """
  def spec(kind, opts \\ [])

  def spec(:peak, opts) do
    fs = Keyword.get(opts, :fs, 48_000)
    hold = round(Keyword.get(opts, :hold_ms, 500) * fs / 1000)
    decay = Dynamics.coefficient(Keyword.get(opts, :decay_ms, 300), fs)
    clip = (1 <<< 23) - 1 - Keyword.get(opts, :clip_margin, 0)
    Q.spec(&peak/3, init_peak(), {hold, decay, clip}, peak_ranges(), ["meter"])
  end

  def spec(:rms, opts) do
    fs = Keyword.get(opts, :fs, 48_000)
    k = Dynamics.coefficient(Keyword.get(opts, :tau_ms, 300), fs, @ms_k_bits)
    Q.spec(&rms/3, init_rms(), k, rms_ranges(), ["k"])
  end
end

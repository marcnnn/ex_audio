defmodule ExAudio.Mixer.Host do
  @moduledoc """
  Host side of the mixer: musical units (Hz, dB, ms, linear gains) to
  register and window writes, and the decoding of what the mixer reports.

  Every function that changes the mixer returns a list of `{byte_offset, value}`
  AXI4-Lite writes (32-bit values); issue them in order. The offsets and
  field encodings come from the register map (`ExAudio.Mixer.Layout`,
  `ExHdl.Regs.encode/3` and `window_offset/3`), so they follow the map when
  it changes.

      host = ExAudio.Mixer.Host.new()

      strip = [
        eq: [{:highpass, 80}, {:peaking, 1000, q: 2.0, gain_db: 4}, {:highshelf, 8000, gain_db: -3}],
        gate: [open_db: -55, hold_ms: 80],
        compressor: [threshold_db: -18, ratio: 3, knee_db: 6, attack_ms: 5, release_ms: 120]
      ]

      writes = ExAudio.Mixer.Host.strip_writes(host, :in, 17, strip)
      writes ++ ExAudio.Mixer.Host.swap(host, :inputs)

  ## Strips

  A strip description is a keyword list: `eq:` up to four bands
  `{kind, hz}` or `{kind, hz, opts}` (`ExAudio.Filter.design/4`; a missing
  band is a pass-through), `gate:` options of `ExAudio.Dynamics.gate_params/1`
  or `:off`, `compressor:` options of `ExAudio.Dynamics.compressor_params/1`
  or `:off`. A bypassed gate is exact; a bypassed compressor has the table
  gain of zero reduction, within 0.001 dB of unity (see
  `ExAudio.Dynamics`). Coefficients of a bank are written while the other
  bank is in use: `strip_writes/4` for the channels, then `swap/2`, and
  wait until `status.in_pending` / `out_pending` read 0 before writing the
  old bank again.

  ## Crosspoints

  The matrix is an `ExAudio.Matrix` (`connect/4` with
  `ExAudio.Matrix.db/1` for gains in dB). `matrix_writes/2` loads all of it,
  `matrix_diff/3` only the outputs whose row changed. The mixer computes
  with the table while it is written: a change shows up in the frame in
  which its write lands, and a row that is rewritten may be mixed with
  some old and some new entries for one frame.
  """
  import Bitwise

  alias ExAudio.{Biquad, Dynamics, Filter, Q, Strip}
  alias ExAudio.Matrix, as: M
  alias ExAudio.Mixer.{Config, Layout, Matrix}
  alias ExHdl.Regs

  defstruct [:cfg, :map]

  @type t :: %__MODULE__{}
  @type write :: {non_neg_integer(), non_neg_integer()}

  @doc "Host helpers for a `ExAudio.Mixer.Config` (default: the 1024 channel mixer)."
  def new(%Config{} = cfg \\ Config.new()), do: %__MODULE__{cfg: cfg, map: Layout.map(cfg)}

  # -- control ------------------------------------------------------------------------------

  @doc "Writes `ctrl`: take samples (`true`) or not."
  def enable(%__MODULE__{map: map}, on \\ true),
    do: [{Regs.offset(map, :ctrl), Regs.encode(map, :ctrl, enable: if(on, do: 1, else: 0))}]

  @doc "Bank swap at the next frame start: `:inputs`, `:outputs` or `:both`."
  def swap(%__MODULE__{map: map}, which) when which in [:inputs, :outputs, :both] do
    word =
      Regs.encode(map, :swap,
        inputs: if(which in [:inputs, :both], do: 1, else: 0),
        outputs: if(which in [:outputs, :both], do: 1, else: 0)
      )

    [{Regs.offset(map, :swap), word}]
  end

  @doc "Clears the sticky status bits named in `flags` (`:overrun_compute`, `:overrun_output`, `:sync_error`)."
  def clear_status(%__MODULE__{map: map}, flags) do
    fields = for f <- flags, into: [], do: {f, 1}
    [{Regs.offset(map, :status), Regs.encode(map, :status, fields)}]
  end

  @doc "Status register fields (`ExHdl.Regs.decode/3` of the word read at `status`)."
  def decode_status(%__MODULE__{map: map}, word), do: Regs.decode(map, :status, word)

  @doc "Byte offset of a register (`:status`, `:frames`, `:clips`, ...)."
  def offset(%__MODULE__{map: map}, reg), do: Regs.offset(map, reg)

  # -- strips -------------------------------------------------------------------------------

  @doc """
  The 35 parameter words of a strip description (see the moduledoc), as
  unsigned 32-bit values in the order the window takes them.
  """
  def strip_words(%__MODULE__{cfg: cfg}, strip) do
    bands = Keyword.get(strip, :eq, [])
    n = Strip.sections()

    if length(bands) > n,
      do: raise(ArgumentError, "a strip has #{n} equaliser bands, got #{length(bands)}")

    coefs =
      for i <- 0..(n - 1) do
        case Enum.at(bands, i) do
          nil -> Biquad.identity()
          {kind, hz} -> kind |> Filter.design(hz, cfg.fs) |> Biquad.quantize()
          {kind, hz, opts} -> kind |> Filter.design(hz, cfg.fs, opts) |> Biquad.quantize()
        end
      end

    gate =
      case Keyword.get(strip, :gate, :off) do
        :off -> [range_db: 0.0]
        opts -> opts
      end

    compressor =
      case Keyword.get(strip, :compressor, :off) do
        :off -> [threshold_db: 0.0, ratio: 1.0, makeup_db: 0.003]
        opts -> opts
      end

    coefs
    |> Strip.channel_words(
      gate: Keyword.put_new(gate, :fs, cfg.fs),
      compressor: Keyword.put_new(compressor, :fs, cfg.fs)
    )
    |> Enum.map(&(&1 &&& 0xFFFF_FFFF))
  end

  @doc """
  Window writes that load `strip` into channel `channel` of the `:in` or
  `:out` strips. The last word commits the channel.
  """
  def strip_writes(%__MODULE__{map: map} = h, side, channel, strip) when side in [:in, :out] do
    window = if side == :in, do: :coeff_in, else: :coeff_out
    base = channel * Config.coeff_stride()

    for {word, i} <- Enum.with_index(strip_words(h, strip)),
        do: {Regs.window_offset(map, window, base + i), word}
  end

  # -- crosspoints --------------------------------------------------------------------------

  @doc "Window writes for every crosspoint entry of `matrix` (all slots of all outputs)."
  def matrix_writes(%__MODULE__{cfg: cfg, map: map}, %M{} = matrix),
    do:
      for(
        {addr, word} <- Matrix.table_writes(cfg, matrix),
        do: {Regs.window_offset(map, :xp, addr), word}
      )

  @doc "Window writes for the outputs whose row differs between `old` and `new`."
  def matrix_diff(%__MODULE__{cfg: cfg, map: map}, %M{} = old, %M{} = new) do
    for out <- 0..(cfg.channels - 1), M.row(old, out) != M.row(new, out) do
      {srcs, gains} = M.row(new, out)

      for {{src, gain}, slot} <- Enum.with_index(Enum.zip(srcs, gains)) do
        {Regs.window_offset(map, :xp, Config.xp_word(cfg, out, slot)),
         Matrix.entry(cfg, src, gain)}
      end
    end
    |> List.flatten()
  end

  # -- meters -------------------------------------------------------------------------------

  @doc """
  Writes the meter parameters (`ExAudio.Meter`) and applies them: peak
  `hold_ms` (500), `decay_ms` (300, the time constant of the fall), the
  RMS window `tau_ms` (300) and `clip_margin` (0 LSB below full scale).
  """
  def meter_writes(%__MODULE__{cfg: cfg, map: map}, opts \\ []) do
    fs = cfg.fs
    hold = round(Keyword.get(opts, :hold_ms, 500) * fs / 1000)
    decay = Dynamics.coefficient(Keyword.get(opts, :decay_ms, 300), fs)
    k = Dynamics.coefficient(Keyword.get(opts, :tau_ms, 300), fs, 23)
    clip = Bitwise.bsl(1, 23) - 1 - Keyword.get(opts, :clip_margin, 0)

    for {reg, v} <- [meter_hold: hold, meter_decay: decay, meter_clip: clip, meter_k: k] do
      {Regs.offset(map, reg), Regs.encode(map, reg, value: v)}
    end ++ [{Regs.offset(map, :meter_load), Regs.encode(map, :meter_load, load: 1)}]
  end

  @doc "Byte offsets `{peak, rms}` of a channel's meter words; `side` is `:in` or `:out`."
  def meter_offsets(%__MODULE__{map: map}, side, channel) when side in [:in, :out] do
    window = if side == :in, do: :meters_in, else: :meters_out

    {Regs.window_offset(map, window, 2 * channel),
     Regs.window_offset(map, window, 2 * channel + 1)}
  end

  @doc """
  Reads of the meter words of channels `channels`: the list of byte offsets,
  in the order peak, RMS for each channel.
  """
  def meter_reads(%__MODULE__{} = h, side, channels) do
    Enum.flat_map(channels, fn c ->
      {p, r} = meter_offsets(h, side, c)
      [p, r]
    end)
  end

  @doc "Peak word to `%{db:, linear:, clip:}`; `db` is `-infinity` for 0."
  def decode_peak(word) do
    peak = word &&& 0xFFFFFF
    db = if peak == 0, do: :neg_infinity, else: 20 * :math.log10(peak / (1 <<< 23))
    %{db: db, linear: peak / (1 <<< 23), clip: (word >>> 24 &&& 1) == 1}
  end

  @doc "RMS word (signed Q16 log2 level, 32 bit) to dB re full scale."
  def decode_rms(word) do
    signed = if word >= 0x8000_0000, do: word - 0x1_0000_0000, else: word
    Q.log2_to_db(signed)
  end
end

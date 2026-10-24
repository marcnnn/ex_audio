defmodule ExAudio.Mixer.Config do
  @moduledoc """
  Sizes of the mixer and everything derived from them.

  Defaults are the 1024 channel mixer at 48 kHz on a 250 MHz clock:

      iex> cfg = ExAudio.Mixer.Config.new()
      iex> {cfg.frame_cycles, cfg.lanes, cfg.per_lane, cfg.cycles}
      {5208, 13, 79, 5063}

  `lanes` is `ceil(channels * slots / frame_cycles)` (13 MACs for 65536
  products in 5208 cycles), raised if the pipeline latency of a lane
  would not fit the frame. Every lane computes `per_lane` consecutive
  outputs one after the other (`slots` cycles each); the last lane may
  have fewer. `cycles` is the whole compute time of a frame, which must
  be at most `frame_cycles`.

  Options: `:channels` (1024, at most 2^16), `:slots` (a power of two, 64),
  `:fs` (48000), `:clock_mhz` (250), `:frame_cycles` (`clock / fs`),
  `:lanes`, `:state_mem` (strips, see below), `:meter_mem` (`:block`),
  `:xp_style` (crosspoint RAMs, `:block`), `:family`
  (`:ultrascale_plus`).

  The strip state is about 1200 bits per channel, so its memory is as
  wide as 17 UltraRAMs (72 bits each) but only `channels` deep. A URAM is
  4096 deep and a RAMB18 512, so up to 512 channels the state goes to block
  RAM (34 RAMB18 per strip bank instead of 17 URAM), above that to URAM:

      iex> {ExAudio.Mixer.Config.new(channels: 256).state_mem, ExAudio.Mixer.Config.new().state_mem}
      {:block, :ultra}
  """
  import Bitwise

  # cycles from the last issue of a lane to its last result in the output RAM
  @pipe 7

  defstruct [
    :channels,
    :slots,
    :fs,
    :clock_mhz,
    :frame_cycles,
    :lanes,
    :per_lane,
    :cycles,
    :family,
    :state_mem,
    :meter_mem,
    :xp_style,
    :cw,
    :sb,
    :ob,
    :lb,
    :gain_bits
  ]

  @type t :: %__MODULE__{}

  @doc "See the moduledoc."
  def new(opts \\ []) do
    channels = Keyword.get(opts, :channels, 1024)
    slots = Keyword.get(opts, :slots, 64)
    fs = Keyword.get(opts, :fs, 48_000)
    mhz = Keyword.get(opts, :clock_mhz, 250)
    frame = Keyword.get(opts, :frame_cycles, div(mhz * 1_000_000, fs))

    unless slots >= 2 and (slots &&& slots - 1) == 0,
      do: raise(ArgumentError, "slots must be a power of two, got #{slots}")

    unless channels in 2..65_536, do: raise(ArgumentError, "channels must be in 2..65536")

    lanes = Keyword.get_lazy(opts, :lanes, fn -> div(channels * slots + frame - 1, frame) end)
    {lanes, per_lane} = fit(channels, slots, frame, lanes, Keyword.has_key?(opts, :lanes))

    %__MODULE__{
      channels: channels,
      slots: slots,
      fs: fs,
      clock_mhz: mhz,
      frame_cycles: frame,
      lanes: lanes,
      per_lane: per_lane,
      cycles: per_lane * slots + @pipe,
      family: Keyword.get(opts, :family, :ultrascale_plus),
      state_mem: Keyword.get(opts, :state_mem, if(channels > 512, do: :ultra, else: :block)),
      meter_mem: Keyword.get(opts, :meter_mem, :block),
      xp_style: Keyword.get(opts, :xp_style, :block),
      cw: clog2(channels),
      sb: clog2(slots),
      ob: clog2(per_lane),
      lb: clog2(lanes),
      gain_bits: 18
    }
  end

  # the fewest lanes (at least `lanes`) whose compute time fits the frame, or the given count
  defp fit(channels, slots, frame, lanes, fixed?) do
    fits? = fn l -> div(channels + l - 1, l) * slots + @pipe <= frame end

    lanes =
      cond do
        fixed? -> lanes
        l = Enum.find(lanes..channels, fits?) -> l
        true -> raise ArgumentError, "#{channels} x #{slots} products do not fit #{frame} cycles"
      end

    per = div(channels + lanes - 1, lanes)
    {div(channels + per - 1, per), per}
  end

  @doc "Pipeline latency of a lane in cycles (last issue to last result written)."
  def pipe_latency, do: @pipe

  @doc "Number of outputs computed by `lane`."
  def lane_outputs(%__MODULE__{} = c, lane), do: min(c.per_lane, c.channels - lane * c.per_lane)

  @doc "Lane and local index of output channel `out`."
  def lane_of(%__MODULE__{} = c, out), do: {div(out, c.per_lane), rem(out, c.per_lane)}

  @doc "Word address in the crosspoint window of slot `slot` of output `out`."
  def xp_word(%__MODULE__{} = c, out, slot) do
    {lane, local} = lane_of(c, out)
    lane <<< (c.ob + c.sb) ||| local <<< c.sb ||| slot
  end

  @doc "Words per channel in a coefficient window (a power of two, 64)."
  def coeff_stride, do: 64

  @doc "Bits of a crosspoint entry: source channel, then the gain."
  def xp_bits(%__MODULE__{} = c), do: c.cw + c.gain_bits

  @doc "Smallest `n` with `2^n >= v`."
  def clog2(v) when v <= 1, do: 0
  def clog2(v), do: length(Integer.digits(v - 1, 2))
end

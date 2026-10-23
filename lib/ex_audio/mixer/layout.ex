defmodule ExAudio.Mixer.Layout do
  @moduledoc """
  The register map of the mixer for a `ExAudio.Mixer.Config`: the
  declarations behind `ExAudio.Mixer.Regs` (the default 1024 channel map,
  `defregs`) and `map/1` for other sizes (`ExHdl.Regs.build/3` at run time).

  Registers (byte offsets from 0):

  | Register | Fields |
  |---|---|
  | `id` | `version` (const) |
  | `config` | `channels`, `slots`, `lanes` (const, from the build) |
  | `ctrl` | `enable`: the mixer takes samples (reset 0: set it once `status.busy` is 0 and the coefficients are loaded) |
  | `swap` | write `inputs` / `outputs` = 1: swap the coefficient banks of the input / output strips at the next frame start |
  | `status` | `busy` (state RAMs clearing after reset), `in_pending`, `out_pending` (bank swap not yet complete; the old bank may be rewritten when 0), `compute_busy`, `overrun_compute`, `overrun_output`, `sync_error` (write 1 to clear) |
  | `frames` | frames completed since reset (wraps at 2^32) |
  | `clips` | output samples that saturated since reset (wraps at 2^32) |
  | `meter_hold`, `meter_decay`, `meter_clip`, `meter_k` | meter parameters (`ExAudio.Mixer.Meters`), reset to 500 ms, 300 ms, full scale, 300 ms |
  | `meter_load` | write 1: the meter parameters apply (they also load once after reset) |

  Windows, from the highest alignment down (offsets from `window_offsets/1`):

  | Window | Access | Word address |
  |---|---|---|
  | `xp` | write | crosspoint entry, `ExAudio.Mixer.Config.xp_word/3` |
  | `coeff_in`, `coeff_out` | write | `channel * 64 + word` of the strip parameters (`ExAudio.Mixer.Strip`) |
  | `meters_in`, `meters_out` | read | `channel * 2 + which`, 0 peak, 1 RMS (`ExAudio.Mixer.Meters`) |
  """
  use ExHdl.Regs

  alias ExAudio.Dynamics
  alias ExAudio.Mixer.Config

  @version 0x0100

  @doc "Version constant of the `id` register."
  def version, do: @version

  @doc "Byte size of every window for `cfg`."
  def window_sizes(%Config{} = cfg) do
    [
      xp: 4 * Bitwise.bsl(1, cfg.lb + cfg.ob + cfg.sb),
      coeff_in: 4 * Bitwise.bsl(1, cfg.cw + 6),
      coeff_out: 4 * Bitwise.bsl(1, cfg.cw + 6),
      meters_in: 4 * 2 * Bitwise.bsl(1, cfg.cw),
      meters_out: 4 * 2 * Bitwise.bsl(1, cfg.cw)
    ]
  end

  @doc "Byte offset of every window: largest first, each aligned to its size, after the registers."
  def window_offsets(%Config{} = cfg) do
    {offsets, _} =
      cfg
      |> window_sizes()
      |> Enum.sort_by(fn {_, size} -> -size end)
      |> Enum.map_reduce(0x1000, fn {name, size}, cursor ->
        off = div(cursor + size - 1, size) * size
        {{name, off}, off + size}
      end)

    offsets
  end

  @doc "The register map for `cfg` (name `ea_mixer_regs_<channels>`)."
  def map(%Config{} = cfg),
    do: ExHdl.Regs.build("ea_mixer_regs_#{cfg.channels}", [], fn -> declare(cfg) end)

  @doc false
  def declare(%Config{} = cfg) do
    sizes = window_sizes(cfg)
    offsets = window_offsets(cfg)
    hold = round(500 * cfg.fs / 1000)
    decay = Dynamics.coefficient(300, cfg.fs)
    rms_k = Dynamics.coefficient(300, cfg.fs, 23)

    register :id, doc: "Identification" do
      field(:version, 0..15, :ro, const: @version)
    end

    register :config, doc: "Build configuration" do
      field(:channels, 0..15, :ro, const: Bitwise.band(cfg.channels, 0xFFFF))
      field(:slots, 16..23, :ro, const: min(cfg.slots, 255))
      field(:lanes, 24..31, :ro, const: min(cfg.lanes, 255))
    end

    register :ctrl, strobe: :write, doc: "Control" do
      field(:enable, 0, :rw, doc: "Take samples from s_axis")
    end

    register :swap, strobe: :write, doc: "Coefficient bank swap at the next frame start" do
      field(:inputs, 0, :wo)
      field(:outputs, 1, :wo)
    end

    register :status, doc: "Status" do
      field(:busy, 0, :ro, doc: "State RAMs are being cleared")
      field(:in_pending, 1, :ro)
      field(:out_pending, 2, :ro)
      field(:compute_busy, 3, :ro)
      field(:overrun_compute, 4, :w1c, doc: "A frame ended while the lanes were busy")
      field(:overrun_output, 5, :w1c, doc: "Results ready while the last frame was streaming")
      field(:sync_error, 6, :w1c, doc: "Frame start flag and channel 0 disagree")
    end

    register :frames, doc: "Frames completed" do
      field(:count, 0..31, :ro)
    end

    register :clips, doc: "Saturated output samples" do
      field(:count, 0..31, :ro)
    end

    register :meter_hold, doc: "Peak hold in samples" do
      field(:value, 0..23, :rw, reset: hold)
    end

    register :meter_decay, doc: "Peak decay coefficient, Q28" do
      field(:value, 0..27, :rw, reset: decay)
    end

    register :meter_clip, doc: "Clip level" do
      field(:value, 0..23, :rw, reset: Bitwise.bsl(1, 23) - 1)
    end

    register :meter_k, doc: "RMS coefficient, Q23" do
      field(:value, 0..22, :rw, reset: rms_k)
    end

    register :meter_load, strobe: :write, doc: "Apply the meter parameters" do
      field(:load, 0, :wo)
    end

    for {name, access, doc} <- [
          {:xp, :wo, "Crosspoint table"},
          {:coeff_in, :wo, "Input strip parameters"},
          {:coeff_out, :wo, "Output strip parameters"},
          {:meters_in, :ro, "Input meters"},
          {:meters_out, :ro, "Output meters"}
        ] do
      window(name, offset: offsets[name], size: sizes[name], latency: 1, access: access, doc: doc)
    end
  end
end

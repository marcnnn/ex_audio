defmodule ExAudio.Mixer.Meters do
  @moduledoc """
  Peak and RMS meters for every channel of a TDM stream, written to RAMs
  the host reads through a window.

  The two kernels are `ExAudio.Meter.peak/3` (peak with hold) and
  `ExAudio.Meter.rms/3`, each with the state of all channels in RAM
  (`channels: n`, channel from `tid`). The stream is a sink: a sample is
  taken by both kernels in the same cycle (`tready` is the AND of theirs,
  so the meters never see a sample twice).

  | Port | Meaning |
  |---|---|
  | `s_axis` | the stream to measure: 24-bit samples, `tid` the channel (a frame ends at the last channel) |
  | `hold`, `decay`, `clip`, `k` | peak hold (samples, 24 bit), decay coefficient (Q28), clip level (24 bit), RMS coefficient (Q23); see `ExAudio.Meter` |
  | `load` | pulse: the four parameter values apply once the samples before it have passed |
  | `win` | `ExHdl.RTL.Interface.mem_port/1` slave (read only), word address `{channel, which}`, `which` 0 the peak word, 1 the RMS word; data one cycle after `en` |
  | `busy` | the state RAMs are being cleared after reset |

  Peak word: bits 0 to 23 the held peak amplitude (`2^23` is full scale,
  `ExAudio.Q.to_float/1`), bit 24 the clip flag of the last sample. RMS
  word: signed level in Q16 log2 units relative to full scale
  (`ExAudio.Q.log2_to_db/1`, a full scale sine reads -3.01 dB). The RAM
  holds the value of the channel's most recent sample; a read returns
  one complete word, the peak and RMS words of a channel need not be of
  the same frame.
  """
  use ExHdl.RTL

  alias ExAudio.Mixer.Config
  alias ExAudio.Meter
  alias ExHdl.RTL.Wrap

  @doc "The kernel design for `:peak` or `:rms`."
  def design(%Config{} = cfg, kind, name) do
    spec = Meter.spec(kind)

    {:ok, d} =
      ExHdl.DSP.scan_to_sv(
        spec[:fun],
        spec[:args],
        Keyword.drop(spec, [:fun, :args, :params, :kernel_opts]) ++
          [
            name: "ea_meter_#{name}_#{kind}_#{cfg.channels}",
            channels: cfg.channels,
            state_mem: cfg.meter_mem,
            tid: true,
            family: cfg.family,
            clock_mhz: cfg.clock_mhz
          ]
      )

    d
  end

  @doc "The RTL module, see the moduledoc."
  def build(%Config{} = cfg, name) do
    cw = cfg.cw
    peak_d = design(cfg, :peak, name)
    rms_d = design(cfg, :rms, name)
    axis = Interface.axi_stream(data: 24, keep: false, last: false, id: cw, user: 0)

    module "ea_meters_#{name}_#{cfg.channels}" do
      s = slave(:s_axis, axis)
      hold = input(:hold, 24)
      decay = input(:decay, 28)
      clip = input(:clip, 24)
      k = input(:k, 23)
      load = input(:load, 1)
      win = slave(:win, Interface.mem_port(addr: cw + 1, data: 32, be: true))
      busy = output(:busy, 1)

      pk =
        instance(:peak, Wrap.scan(peak_d),
          connect: [
            p_meter_0: zext(hold, 32),
            p_meter_1: zext(decay, 32),
            p_meter_2: zext(clip, 32),
            p_load: load
          ]
        )

      rm = instance(:rms, Wrap.scan(rms_d), connect: [p_k: zext(k, 32), p_load: load])

      sample = as_unsigned(sext(as_signed(s.tdata), 32))

      for u <- [pk, rm] do
        u.s_axis.tdata <~ sample
        u.s_axis.tid <~ s.tid
        u.m_axis.tready <~ 1
      end

      s.tready <~ (pk.s_axis.tready and rm.s_axis.tready)
      pk.s_axis.tvalid <~ (s.tvalid and rm.s_axis.tready)
      rm.s_axis.tvalid <~ (s.tvalid and pk.s_axis.tready)
      busy <~ (pk.busy or rm.busy)

      peak_ram = memory(:peak_ram, width: 25, depth: cfg.channels, style: cfg.meter_mem)
      rms_ram = memory(:rms_ram, width: 32, depth: cfg.channels, style: cfg.meter_mem)

      write_port(peak_ram,
        addr: pk.m_axis.tid,
        data: cat([pk.m_axis.tdata[32], pk.m_axis.tdata[0..23]]),
        en: pk.m_axis.tvalid
      )

      write_port(rms_ram, addr: rm.m_axis.tid, data: rm.m_axis.tdata, en: rm.m_axis.tvalid)

      which = reg(:which, 1)
      row = win.addr[1..cw]
      peak_rd = read_port(peak_ram, addr: row, en: win.en)
      rms_rd = read_port(rms_ram, addr: row, en: win.en)

      sync do
        if win.en, do: which <~ win.addr[0]
      end

      win.rdata <~ mux(which, rms_rd, zext(peak_rd, 32))
    end
  end
end

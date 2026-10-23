defmodule ExAudio.Mixer do
  @moduledoc """
  The mixer top level: TDM stream in, input strips, crosspoint matrix,
  output strips, TDM stream out, meters on both sides and the AXI4-Lite
  register map. One clock (`clk`, `rst_n`).

  ```
  s_axis -> in strip -+-> frame RAM -> lanes (MAC) -> sequencer -> out strip -+-> m_axis
                      +-> in meters                                          +-> out meters
  ```

  ## Ports of `build/1` (`ea_mixer_<channels>`)

  | Port | Meaning |
  |---|---|
  | `s_axis` | AXI4-Stream in: 24-bit sample, `tid` the channel, `tuser` bit 0 frame start (channel 0). Every frame carries all channels in increasing order, at most one frame per `frame_cycles`; `tvalid` may have gaps |
  | `m_axis` | AXI4-Stream out: 24-bit sample, `tid`, `tuser` bit 0 frame start, bit 1 the sample saturated in the matrix |
  | `s_axil` | AXI4-Lite slave, 21-bit byte addresses: the map of `ExAudio.Mixer.Layout` |

  `s_axis` is accepted only when `ctrl.enable` is set. A frame is complete
  when channel `channels - 1` has left the input strip; then the matrix
  computes it (`ExAudio.Mixer.Matrix`) and streams it to the output strip
  about one frame later (`latency/1`). Control flow, timing and
  limits are in the moduledocs of the parts:

    * `ExAudio.Mixer.Strip`: coefficient windows and bank swap
    * `ExAudio.Mixer.Matrix`: lanes, cycle budget, overruns
    * `ExAudio.Mixer.Meters`: meter words
    * `ExAudio.Mixer.Host`: musical units to register writes

  The bus side shares the clock with the data path; a real design puts a
  clock crossing in front of `s_axil`.
  """
  use ExHdl.RTL

  alias ExAudio.Mixer.{Config, Layout, Matrix, Meters, Strip}

  @doc """
  The RTL modules for `mix ex_hdl.gen.sv ExAudio.Mixer --synth --family xcup`: the
  input and output strip banks, the matrix, the meters and the top.
  """
  def ex_hdl_rtl(%Config{} = cfg \\ Config.new()) do
    [
      Strip.build(cfg, "in", user: 1),
      Strip.build(cfg, "out", user: 2),
      Matrix.build(cfg),
      Meters.build(cfg, "in"),
      build(cfg)
    ]
  end

  @doc """
  Cycles from the cycle in which the first sample of a frame is accepted on
  `s_axis` to the cycle in which the first sample of that frame is valid on
  `m_axis`, when nothing stalls and the frames are back to back: the rest
  of the input frame (`channels - 1`), the input strip pipeline (`d`, the
  latency of the generated kernel), the matrix (`Matrix.first_beat/1` after
  the last sample was written) and the output strip (`d` again).
  """
  def latency(%Config{} = cfg, strip_latency \\ nil) do
    d = strip_latency || Strip.design(cfg, "lat").latency
    cfg.channels - 1 + d + Matrix.first_beat(cfg) + d
  end

  @doc "The RTL module, see the moduledoc. Takes a `ExAudio.Mixer.Config`."
  def build(%Config{} = cfg \\ Config.new()) do
    map = Layout.map(cfg)
    cw = cfg.cw
    last = cfg.channels - 1
    s_axis = Interface.axi_stream(data: 24, keep: false, last: false, id: cw, user: 1)
    m_axis = Matrix.axis(cfg)

    module "ea_mixer_#{cfg.channels}" do
      s = slave(:s_axis, s_axis)
      m = master(:m_axis, m_axis)
      axil = slave(:s_axil, Interface.axi_lite(addr: map.addr_width, data: 32))

      regs = instance(:regs, ExHdl.Regs.RTL.build(map))
      connect(axil, regs.s_axil)
      in_strip = instance(:in_strip, Strip.build(cfg, "in", user: 1))
      out_strip = instance(:out_strip, Strip.build(cfg, "out", user: 2))
      mat = instance(:matrix, Matrix.build(cfg))
      in_m = instance(:in_meters, Meters.build(cfg, "in"))
      out_m = instance(:out_meters, Meters.build(cfg, "out"))

      connect(regs.coeff_in, in_strip.coeff)
      connect(regs.coeff_out, out_strip.coeff)
      connect(regs.xp, mat.xp)
      connect(regs.meters_in, in_m.win)
      connect(regs.meters_out, out_m.win)

      enable = regs.ctrl_enable

      # -- input: s_axis -> in strip
      i = in_strip.s_axis
      i.tdata <~ s.tdata
      i.tid <~ s.tid
      i.tuser <~ s.tuser
      i.tvalid <~ (s.tvalid and enable)
      s.tready <~ (i.tready and enable)
      in_strip.swap <~ (regs.swap_wr and regs.swap_inputs)

      # -- in strip -> frame RAM and input meters
      ia = in_strip.m_axis
      im = in_m.s_axis
      im.tdata <~ ia.tdata
      im.tid <~ ia.tid
      im.tvalid <~ ia.tvalid
      ia.tready <~ im.tready
      write = wire(:write, ia.tvalid and im.tready)
      mat.fr_we <~ write
      mat.fr_addr <~ ia.tid
      mat.fr_data <~ ia.tdata
      done = wire(:done, write and ia.tid == last)
      mat.frame_done <~ done

      # -- matrix -> out strip -> m_axis and output meters
      connect(mat.m_axis, out_strip.s_axis)
      out_strip.swap <~ (regs.swap_wr and regs.swap_outputs)
      oa = out_strip.m_axis
      om = out_m.s_axis
      oa.tready <~ (m.tready and om.tready)
      m.tvalid <~ (oa.tvalid and om.tready)
      m.tdata <~ oa.tdata
      m.tid <~ oa.tid
      m.tuser <~ oa.tuser
      om.tvalid <~ (oa.tvalid and m.tready)
      om.tdata <~ oa.tdata
      om.tid <~ oa.tid

      # -- meter parameters: loaded after reset and on a write to meter_load
      booted = reg(:booted, 1)
      load = wire(:load, (regs.meter_load_wr and regs.meter_load_load) or not booted)

      sync do
        booted <~ 1
      end

      for mt <- [in_m, out_m] do
        mt.hold <~ regs.meter_hold_value
        mt.decay <~ regs.meter_decay_value
        mt.clip <~ regs.meter_clip_value
        mt.k <~ regs.meter_k_value
        mt.load <~ load
      end

      # -- status
      frames = reg(:frames_r, 32)
      clips = reg(:clips_r, 32)

      sync do
        if done, do: frames <~ add_wrap(frames, 1)
        if mat.clip, do: clips <~ add_wrap(clips, 1)
      end

      regs.frames_count <~ frames
      regs.clips_count <~ clips
      regs.status_busy <~ (in_strip.busy or out_strip.busy or in_m.busy or out_m.busy)
      regs.status_in_pending <~ in_strip.pending
      regs.status_out_pending <~ out_strip.pending
      regs.status_compute_busy <~ mat.busy
      regs.status_overrun_compute_set <~ mat.overrun_compute
      regs.status_overrun_output_set <~ mat.overrun_output
      regs.status_sync_error_set <~ (write and bxor(ia.tuser[0], ia.tid == 0))
    end
  end
end

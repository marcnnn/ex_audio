defmodule ExAudio.Mixer.Strip do
  @moduledoc """
  One bank of channel strips as RTL: `ExAudio.Strip.cascade_spec/1` (four
  biquads, gate, compressor) as a stream kernel for `channels` interleaved
  channels with the state in RAM and the parameters of every channel in a
  two-bank RAM, and the 32-bit window the host writes them through.

  Ports of `build/3` (module `ea_strip_<name>_<channels>_u<user>`):

  | Port | Meaning |
  |---|---|
  | `s_axis`, `m_axis` | AXI4-Stream: 24-bit sample, `tid` the channel, `tuser` a sideband (`user` bits) that travels with the sample. A frame starts where the channel does not increase. With `cfg.state_fold` k > 1 `s_axis` takes one sample every k cycles |
  | `coeff` | `ExHdl.RTL.Interface.mem_port/1` slave (write only), word address `{channel, word}` with `word` in 6 bits |
  | `swap` | pulse: the banks swap at the next frame start |
  | `pending` | high until the swap is done and no sample of the old bank is left |
  | `busy` | high while the state RAM is cleared after reset |

  A channel's parameters are `words/1` (35) 32-bit words (`ExAudio.Strip.channel_words/2`).
  The window collects words 0 to `words - 2` in staging registers and the
  write of the last word commits the whole set to the RAM bank that is
  not in use. Write a channel's words in any order, the last one last;
  the byte strobes are ignored. The window address is `channel * 64 + word`.
  The RAM write port runs on the same clock as the stream (the bus side
  needs a clock crossing in a real design, `pc_clock: :separate` of the
  kernel is not used here).
  """
  use ExHdl.RTL

  alias ExAudio.Mixer.Config
  alias ExHdl.RTL.Wrap

  @doc """
  The generated stream kernel (`ExHdl.Backends.SystemVerilog.Scan.Design`).
  `opts`: `:user` (sideband bits, 1), `:sections` and `:dynamics` of
  `ExAudio.Strip.cascade_spec/1`, `:channels` (default `cfg.channels`),
  `:state_mem`, `:state_fold` and `:state_row_bits` (defaults from `cfg`).
  """
  def design(%Config{} = cfg, name, opts \\ []) do
    spec = ExAudio.Strip.cascade_spec(Keyword.take(opts, [:sections, :dynamics]))
    channels = Keyword.get(opts, :channels, cfg.channels)

    {:ok, d} =
      ExHdl.DSP.scan_to_sv(
        spec[:fun],
        spec[:args],
        Keyword.drop(spec, [:fun, :args]) ++
          [
            name: "ea_strip_#{name}_#{channels}_core",
            channels: channels,
            state_mem: Keyword.get(opts, :state_mem, cfg.state_mem),
            state_fold: Keyword.get(opts, :state_fold, cfg.state_fold),
            state_row_bits: Keyword.get(opts, :state_row_bits, cfg.state_row_bits),
            channel_params: :all,
            tid: true,
            tuser: Keyword.get(opts, :user, 1),
            family: cfg.family,
            clock_mhz: cfg.clock_mhz
          ]
      )

    d
  end

  @doc "Number of 32-bit parameter words of a channel for `opts` (`:sections`, `:dynamics`)."
  def words(opts \\ []) do
    sections = Keyword.get(opts, :sections, 4)
    sections * 5 + if(Keyword.get(opts, :dynamics, true), do: 15, else: 0)
  end

  @doc "The RTL module, see the moduledoc. Options as for `design/3`."
  def build(%Config{} = cfg, name, opts \\ []) do
    d = design(cfg, name, opts)
    user = Keyword.get(opts, :user, 1)
    cw = max(1, Config.clog2(d.channels))
    n = length(d.channel_params)
    unless n <= 64, do: raise(ArgumentError, "a channel has #{n} parameter words, at most 64")
    axis = Interface.axi_stream(data: 24, keep: false, last: false, id: cw, user: user)

    module "ea_strip_#{name}_#{d.channels}_u#{user}" do
      s = slave(:s_axis, axis)
      m = master(:m_axis, axis)
      w = slave(:coeff, Interface.mem_port(addr: cw + 6, data: 32, be: true))
      swap = input(:swap, 1)
      pending = output(:pending, 1)
      busy = output(:busy, 1)

      staged = for i <- 0..(n - 2), do: reg(:"stage_#{i}", 32, reset: nil)
      last = reg(:stage_last, 32, reset: nil)
      commit = reg(:commit, 1)
      ch = reg(:commit_ch, cw, reset: nil)
      wr = wire(:wr, w.en and w.we)
      word = wire(:word, w.addr[0..5])
      last_write = wire(:last_write, wr and word == n - 1)

      sync do
        commit <~ last_write

        if wr do
          for {r, i} <- Enum.with_index(staged), do: if(word == i, do: r <~ w.wdata)
        end

        if last_write do
          last <~ w.wdata
          ch <~ w.addr[6..(cw + 5)]
        end
      end

      w.rdata <~ 0

      k =
        instance(:core, Wrap.scan(d),
          connect: [
            pc_addr: ch,
            pc_data: cat([last | Enum.reverse(staged)]),
            pc_we: commit,
            pc_swap: swap
          ]
        )

      k.s_axis.tdata <~ as_unsigned(sext(as_signed(s.tdata), 32))
      k.s_axis.tid <~ s.tid
      k.s_axis.tuser <~ s.tuser
      k.s_axis.tvalid <~ s.tvalid
      s.tready <~ k.s_axis.tready

      m.tdata <~ k.m_axis.tdata[0..23]
      m.tid <~ k.m_axis.tid
      m.tuser <~ k.m_axis.tuser
      m.tvalid <~ k.m_axis.tvalid
      k.m_axis.tready <~ m.tready

      pending <~ k.pc_pending
      busy <~ k.busy
    end
  end
end

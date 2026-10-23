defmodule ExAudio.Mixer.Matrix do
  @moduledoc """
  The crosspoint matrix as RTL: a frame RAM written by the input strips,
  `lanes` multiply-accumulate pipelines that each compute `per_lane`
  outputs of `slots` products, and a sequencer that streams the 1024
  results of a frame in channel order. The reference is `ExAudio.Matrix`
  (`mix_clip/2`): every output is `sat24((sum(gain * x[src]) + 2^14) >> 15)`.

  ## Ports of `build/2` (`ea_matrix_<channels>x<slots>_l<lanes>`)

  | Port | Meaning |
  |---|---|
  | `fr_we`, `fr_addr`, `fr_data` | write one sample of the frame being collected (`fr_addr` the channel, `fr_data` 24 bits) |
  | `frame_done` | pulse (with or after the last write of a frame): the collected frame is complete, the next one goes to the other bank, the lanes start on it (when they are busy, the frame is dropped and its bank is reused) |
  | `xp` | `ExHdl.RTL.Interface.mem_port/1` slave (write only): crosspoint window, word address `{lane, local output, slot}` (`ExAudio.Mixer.Config.xp_word/3`), entry `src | gain << cw` with `gain` an 18-bit two's complement Q3.15 gain |
  | `m_axis` | the frame, channels 0 to `channels - 1` in order, `tuser` bit 0 frame start, bit 1 the output saturated; `tready` honoured |
  | `busy` | the lanes are computing |
  | `overrun_compute` | pulse: `frame_done` came while the lanes were busy (that frame is not mixed) |
  | `overrun_output` | pulse: results came while the previous frame was still streaming out (dropped, the output RAM bank is reused) |
  | `clip` | pulse for every saturated output as it leaves |

  ## Timing

  All times in cycles from the `frame_done` cycle `g` (the first cycle in
  which it is high), with no backpressure:

  * lane pipeline: issue (crosspoint RAM address) `g + 1 ...
    g + per_lane * slots`; crosspoint RAM, frame RAM, input registers,
    product register, accumulator and result register are 6 stages, the
    result is in the output RAM after 7 (`ExAudio.Mixer.Config.pipe_latency/0`);
  * `busy` falls at `g + cycles` with `cycles = per_lane * slots + 7`, and
    the next `frame_done` is accepted from then on: `cycles` is the
    compute budget per frame (`<= frame_cycles`, checked by `Config.new/1`);
  * the first `m_axis` beat is valid at `g + cycles + 2`, then one per cycle
    (`first_beat/1`, `last_beat/1`).

  The frame RAM and the output RAM are double buffered: samples of frame
  `t + 1` are written while frame `t` is computed, and frame `t` streams
  out while frame `t + 1` is computed.

  ## Lanes

  Lane `l` computes outputs `l * per_lane ...` one after the other, so
  each lane needs one frame RAM read port (every lane has its own copy
  of the frame RAM, written in parallel) and one crosspoint RAM of
  `per_lane * slots` entries. The multiply is 24 x 18 bit with the
  accumulator in 48 bits (a DSP48E2: input registers, product register,
  P register; the rounding constant `2^14` enters as the first term of the
  sum); 64 products of at most `2^40` cannot overflow 48 bits.
  """
  use ExHdl.RTL

  import Bitwise, only: [<<<: 2]

  alias ExAudio.Mixer.Config

  @doc "Cycle of the first output beat after the cycle of `frame_done` (no backpressure)."
  def first_beat(%Config{} = cfg), do: cfg.cycles + 2

  @doc "Cycle of the last output beat after the cycle of `frame_done`."
  def last_beat(%Config{} = cfg), do: first_beat(cfg) + cfg.channels - 1

  @doc "The AXI4-Stream interface of the output: 24-bit sample, channel, `{clip, start}`."
  def axis(%Config{} = cfg),
    do: Interface.axi_stream(data: 24, keep: false, last: false, id: cfg.cw, user: 2)

  @doc """
  The crosspoint RAM word of a connection: source channel in the low
  `cw` bits, the Q3.15 gain (`ExAudio.Matrix.gain/1`) as 18-bit two's
  complement above.
  """
  def entry(%Config{} = cfg, src, gain) when is_integer(src) and is_integer(gain),
    do: Bitwise.bor(src, Bitwise.bsl(Bitwise.band(gain, 0x3FFFF), cfg.cw))

  @doc "Source and gain of a crosspoint word (the inverse of `entry/3`)."
  def decode_entry(%Config{} = cfg, word) do
    gain = Bitwise.band(Bitwise.bsr(word, cfg.cw), 0x3FFFF)

    {Bitwise.band(word, Bitwise.bsl(1, cfg.cw) - 1),
     if(gain >= 0x20000, do: gain - 0x40000, else: gain)}
  end

  @doc """
  Window writes `{word_address, word}` that load `matrix` (an
  `ExAudio.Matrix` with `slots == cfg.slots`): every slot of every
  output, unused slots as source 0 with gain 0.
  """
  def table_writes(%Config{} = cfg, %ExAudio.Matrix{} = matrix) do
    for out <- 0..(cfg.channels - 1),
        {{src, gain}, slot} <-
          matrix
          |> ExAudio.Matrix.row(out)
          |> then(fn {a, b} -> Enum.zip(a, b) end)
          |> Enum.with_index() do
      {Config.xp_word(cfg, out, slot), entry(cfg, src, gain)}
    end
  end

  @doc "The RTL module, see the moduledoc."
  def build(%Config{} = cfg) do
    %{channels: n, slots: s, lanes: lanes, per_lane: per, cw: cw, sb: sb, ob: ob, lb: lb} = cfg
    xw = Config.xp_bits(cfg)
    la = ob + sb
    last_cnt = per * s - 1
    rnd = 1 <<< 14
    axis = axis(cfg)
    n_last = Config.lane_outputs(cfg, lanes - 1)

    module "ea_matrix_#{n}x#{s}_l#{lanes}" do
      fr_we = input(:fr_we, 1)
      fr_addr = input(:fr_addr, cw)
      fr_data = input(:fr_data, 24)
      frame_done = input(:frame_done, 1)
      xp = slave(:xp, Interface.mem_port(addr: lb + la, data: 32, be: true))
      m = master(:m_axis, axis)
      busy_o = output(:busy, 1)
      overrun_c = output(:overrun_compute, 1, reset: 0)
      overrun_o = output(:overrun_output, 1, reset: 0)
      clip_o = output(:clip, 1)

      # -- frame control ------------------------------------------------------------------
      run = reg(:run, 1)
      cnt = reg(:cnt, la)
      busy = reg(:busy_r, 1)
      wbank = reg(:wbank, 1)
      rbank = reg(:rbank, 1)
      cbank = reg(:cbank, 1)
      go = wire(:go, frame_done and not busy)
      slot = wire(:slot, cnt[0..(sb - 1)])
      loc = wire(:loc, cnt[sb..(la - 1)])

      # control flags per stage: first term of an output, last term, local output
      first = for k <- 1..4, do: reg(:"first#{k}", 1)
      lastv = for k <- 1..5, do: reg(:"lastv#{k}", 1)
      locs = for k <- 1..6, do: reg(:"loc#{k}", ob)
      we6 = reg(:we6, 1)
      fin = wire(:fin, we6 and locs |> Enum.at(5) == per - 1)

      sync do
        overrun_c <~ (frame_done and busy)

        if go do
          wbank <~ ~~~wbank
          rbank <~ wbank
          run <~ 1
          cnt <~ 0
          busy <~ 1
        end

        if run do
          if cnt == last_cnt, do: run <~ 0, else: cnt <~ add_wrap(cnt, 1)
        end

        if fin, do: busy <~ 0

        hd(first) <~ (run and slot == 0)
        hd(lastv) <~ (run and slot == s - 1)
        hd(locs) <~ loc

        for {a, b} <- Enum.zip(tl(first), first), do: a <~ b
        for {a, b} <- Enum.zip(tl(lastv), lastv), do: a <~ b
        for {a, b} <- Enum.zip(tl(locs), locs), do: a <~ b
        we6 <~ Enum.at(lastv, 4)
      end

      busy_o <~ busy

      # -- lanes ----------------------------------------------------------------------------
      xp_wr = wire(:xp_wr, xp.en and xp.we)
      xp_local = wire(:xp_local, xp.addr[0..(la - 1)])
      xp.rdata <~ 0

      lane_out =
        for l <- 0..(lanes - 1) do
          nl = Config.lane_outputs(cfg, l)
          depth = nl * s
          p = "l#{l}_"
          lane_hit = if lb == 0, do: xp_wr, else: xp_wr and xp.addr[la..(la + lb - 1)] == l

          aw = Config.clog2(depth)
          fit = fn a -> if aw < la, do: trunc(a, aw), else: a end
          xp_mem = memory(:"#{p}xp", width: xw, depth: depth, style: cfg.xp_style)

          write_port(xp_mem,
            addr: fit.(xp_local),
            data: xp.wdata[0..(xw - 1)],
            en: lane_hit and xp_local < depth
          )

          xrd = read_port(xp_mem, addr: fit.(cnt), en: 1)

          fr_mem = memory(:"#{p}fr", width: 24, depth: 1 <<< (cw + 1), style: :block)
          write_port(fr_mem, addr: cat([wbank, fr_addr]), data: fr_data, en: fr_we)
          frd = read_port(fr_mem, addr: cat([rbank, xrd[0..(cw - 1)]]), en: 1)

          g2 = reg(:"#{p}g2", s(18), reset: nil)
          a_r = reg(:"#{p}a", s(24), reset: nil)
          b_r = reg(:"#{p}b", s(18), reset: nil)
          m_r = reg(:"#{p}m", s(42), reset: nil)
          acc = reg(:"#{p}acc", s(48), reset: nil)
          res = reg(:"#{p}res", 25, reset: nil)
          y = wire(:"#{p}y", as_signed(acc[15..47]))
          over = wire(:"#{p}over", y > 8_388_607)
          under = wire(:"#{p}under", y < -8_388_608)

          sat =
            wire(
              :"#{p}sat",
              mux(over, 8_388_607, mux(under, -8_388_608, y[0..23] |> as_signed()))
            )

          out_mem = memory(:"#{p}out", width: 25, depth: 1 <<< (ob + 1), style: :distributed)

          write_port(out_mem,
            addr: cat([cbank, Enum.at(locs, 5)]),
            data: res,
            en: we6 and Enum.at(locs, 5) < nl
          )

          sync do
            g2 <~ as_signed(xrd[cw..(xw - 1)])
            a_r <~ as_signed(frd)
            b_r <~ g2
            m_r <~ (a_r * b_r)
            acc <~ add_wrap(mux(Enum.at(first, 3), const(rnd, s(48)), acc), m_r)
            res <~ cat([over or under, as_unsigned(sat)[0..23]])
          end

          {out_mem, nl}
        end

      # -- output sequencer -------------------------------------------------------------
      sq_run = reg(:sq_run, 1)
      sq_bank = reg(:sq_bank, 1)
      sq_lane = reg(:sq_lane, max(lb, 1))
      sq_j = reg(:sq_j, ob)
      sq_o = reg(:sq_o, cw)
      p_v = reg(:p_v, 1)
      p_lane = reg(:p_lane, max(lb, 1))
      p_o = reg(:p_o, cw)
      p_start = reg(:p_start, 1)
      ov = reg(:ov, 1)
      od = reg(:od, 24)
      od_tid = reg(:od_tid, cw)
      od_user = reg(:od_user, 2)

      consume = wire(:consume, ov and m.tready)
      move = wire(:move, p_v and (not ov or m.tready))
      adv = wire(:adv, sq_run and (not p_v or move))

      j_last =
        if n_last == per,
          do: per - 1,
          else: mux(sq_lane == lanes - 1, const(n_last - 1, ob), const(per - 1, ob))

      rd =
        for {{mem, _nl}, l} <- Enum.with_index(lane_out) do
          read_port(mem, addr: cat([sq_bank, sq_j]), en: adv, name: :"l#{l}_rd")
        end

      word = wire(:word, mux(p_lane, rd))

      sync do
        if fin do
          if sq_run do
            overrun_o <~ 1
          else
            cbank <~ ~~~cbank
            sq_run <~ 1
            sq_bank <~ cbank
            sq_lane <~ 0
            sq_j <~ 0
            sq_o <~ 0
          end
        end

        if not fin, do: overrun_o <~ 0

        if adv do
          if sq_j == j_last do
            sq_j <~ 0
            if sq_lane == lanes - 1, do: sq_run <~ 0, else: sq_lane <~ add_wrap(sq_lane, 1)
          else
            sq_j <~ add_wrap(sq_j, 1)
          end

          sq_o <~ add_wrap(sq_o, 1)
          p_v <~ 1
          p_lane <~ sq_lane
          p_o <~ sq_o
          p_start <~ (sq_o == 0)
        else
          if move, do: p_v <~ 0
        end

        if move do
          ov <~ 1
          od <~ word[0..23]
          od_tid <~ p_o
          od_user <~ cat([word[24], p_start])
        else
          if consume, do: ov <~ 0
        end
      end

      m.tvalid <~ ov
      m.tdata <~ od
      m.tid <~ od_tid
      m.tuser <~ od_user
      clip_o <~ (consume and od_user[1])
    end
  end
end

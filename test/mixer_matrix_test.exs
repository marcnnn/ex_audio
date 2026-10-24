defmodule ExAudio.MixerMatrixTest do
  @moduledoc """
  The matrix RTL (`ExAudio.Mixer.Matrix`) cycle by cycle against a model
  built on `ExAudio.Matrix.mix_clip/2`: the model sees only the ports (frame
  writes, crosspoint window writes, `frame_done`, `m_axis_tready`), keeps
  the crosspoint table and the two frame banks, mixes with the Elixir
  reference when a frame completes and offers the results on the cycles the
  timing in the moduledoc says. BEAM simulator and Verilator.
  """
  use ExUnit.Case, async: true

  import Bitwise
  import ExAudio.MixerBench, only: [s24: 1, signed24: 1]

  alias ExAudio.MixerBench

  alias ExAudio.Matrix, as: M
  alias ExAudio.Mixer.{Config, Matrix}
  alias ExHdl.RTL.Cosim

  # -- test data -----------------------------------------------------------------------------

  # -- stimulus ------------------------------------------------------------------------------

  @idle %{fr_we: 0, frame_done: 0, xp_en: 0, xp_we: 0}

  defp xp_cycle({addr, word}),
    do: %{xp_en: 1, xp_we: 1, xp_be: 15, xp_addr: addr, xp_wdata: word}

  defp frame_cycles(frame),
    do: for({x, c} <- Enum.with_index(frame), do: %{fr_we: 1, fr_addr: c, fr_data: s24(x)})

  # Frames start `spacing` cycles apart; the samples of a frame are written
  # right after the previous frame_done (concurrently with its computation);
  # frame_done comes with the last write or one cycle later, and every
  # frame's `done_at` cycle is exact.
  def stimulus(cfg, matrix, frames, spacing, tready \\ 100) do
    writes = cfg |> Matrix.table_writes(matrix) |> Enum.map(&xp_cycle/1)
    load = [%{rst_n: 0}, %{rst_n: 0}, %{rst_n: 1, m_axis_tready: 1}] ++ writes ++ [@idle]
    start = length(load)

    n = length(hd(frames))

    # frame_done of frame i at i * spacing + n: with the last write (even i) or one cycle after it
    frame_events =
      for {frame, i} <- Enum.with_index(frames) do
        done = i * spacing + n
        {frame_cycles(frame), done - (n - 1) - rem(i, 2), done}
      end

    total = elem(List.last(frame_events), 2) + Matrix.last_beat(cfg) + 40
    cycles = for _ <- 1..total, do: @idle

    body =
      Enum.reduce(frame_events, cycles, fn {beats, from, done}, acc ->
        acc |> put_cycles(from, beats) |> List.update_at(done, &Map.put(&1, :frame_done, 1))
      end)

    :rand.seed(:exsss, {5, 5, 1})

    body =
      body
      |> Enum.with_index()
      |> Enum.map(fn {m, i} ->
        ready =
          if is_function(tready),
            do: tready.(i),
            else: if(:rand.uniform(100) <= tready, do: 1, else: 0)

        Map.put(m, :m_axis_tready, ready)
      end)

    dones = Enum.map(frame_events, fn {_, _, d} -> start + d end)
    {load ++ body, dones}
  end

  defp put_cycles(list, base, extra) do
    {head, tail} = Enum.split(list, base)
    {mid, rest} = Enum.split(tail, length(extra))
    head ++ Enum.zip_with(mid, extra, &Map.merge/2) ++ rest
  end

  # -- the model -------------------------------------------------------------------------------

  def model(cfg) do
    init = %{
      cyc: 0,
      table: %{},
      banks: %{0 => %{}, 1 => %{}},
      wbank: 0,
      busy_until: -1,
      queue: [],
      ready_at: 0,
      overrun: 0,
      overrun_o: 0,
      ovo_next: 0,
      fins: []
    }

    {init, fn st, ins -> step(cfg, st, ins) end}
  end

  defp step(_cfg, st, %{rst_n: 0}), do: {%{st | cyc: st.cyc + 1}, %{m_axis_tvalid: nil}}

  defp step(cfg, st, ins) do
    cyc = st.cyc
    st = finish(st, cyc)

    st =
      if ins.fr_we == 1,
        do: put_in(st.banks[st.wbank][ins.fr_addr], signed24(ins.fr_data)),
        else: st

    st =
      if ins.xp_en == 1 and ins.xp_we == 1,
        do: %{
          st
          | table:
              Map.put(st.table, ins.xp_addr, ins.xp_wdata &&& (1 <<< Config.xp_bits(cfg)) - 1)
        },
        else: st

    # outputs of this cycle (registered state before the edge)
    {out, queue, ready_at} =
      case st.queue do
        [{k, y, clip, avail} | rest] when cyc >= st.ready_at and cyc >= avail ->
          out = %{
            m_axis_tvalid: 1,
            m_axis_tdata: s24(y),
            m_axis_tid: k,
            m_axis_tuser: clip <<< 1 ||| if(k == 0, do: 1, else: 0),
            clip: clip * ins.m_axis_tready
          }

          if ins.m_axis_tready == 1,
            do: {out, rest, cyc + 1},
            else: {out, st.queue, st.ready_at}

        q ->
          {%{m_axis_tvalid: 0, clip: 0}, q, st.ready_at}
      end

    busy = if cyc > st.busy_until - cfg.cycles and cyc < st.busy_until, do: 1, else: 0

    out =
      Map.merge(out, %{
        overrun_compute: st.overrun,
        overrun_output: st.overrun_o,
        busy: busy
      })

    st = %{
      st
      | queue: queue,
        ready_at: ready_at,
        overrun: 0,
        overrun_o: st.ovo_next,
        ovo_next: 0
    }

    st =
      if ins.frame_done == 1 do
        if cyc < st.busy_until do
          %{st | overrun: 1}
        else
          frame = for c <- 0..(cfg.channels - 1), do: Map.get(st.banks[st.wbank], c, 0)
          {ys, clips} = M.mix_clip(matrix_of(cfg, st.table), frame)

          first = cyc + Matrix.first_beat(cfg)

          beats =
            Enum.zip([0..(cfg.channels - 1), ys, clips])
            |> Enum.map(fn {k, y, c} ->
              {k, y, if(c, do: 1, else: 0), if(k == 0, do: first, else: 0)}
            end)

          # the first beat is valid `first_beat` cycles after this one
          %{
            st
            | fins: st.fins ++ [{cyc + cfg.cycles - 1, beats}],
              busy_until: cyc + cfg.cycles,
              wbank: 1 - st.wbank,
              banks: Map.put(st.banks, st.wbank, %{})
          }
        end
      else
        st
      end

    {%{st | cyc: cyc + 1}, out}
  end

  # the results of a frame reach the output RAM `cycles - 1` cycles after frame_done; the
  # sequencer takes them unless it is still streaming the previous frame
  defp finish(st, cyc) do
    {now, later} = Enum.split_with(st.fins, fn {fin, _} -> fin == cyc end)
    st = %{st | fins: later}

    Enum.reduce(now, st, fn {_, beats}, st ->
      if length(st.queue) > 2,
        do: %{st | ovo_next: 1},
        else: %{st | queue: st.queue ++ beats}
    end)
  end

  # the ExAudio.Matrix the crosspoint words stand for
  defp matrix_of(cfg, table) do
    Enum.reduce(table, M.new(n_in: cfg.channels, n_out: cfg.channels, slots: cfg.slots), fn {addr,
                                                                                             word},
                                                                                            m ->
      {src, gain} = Matrix.decode_entry(cfg, word)
      out = out_of(cfg, addr)

      if gain == 0 or out >= cfg.channels do
        m
      else
        row = Map.get(m.rows, out, %{})
        %{m | rows: Map.put(m.rows, out, Map.update(row, src, gain, &(&1 + gain)))}
      end
    end)
  end

  defp out_of(cfg, addr) do
    lane = addr >>> (cfg.ob + cfg.sb)
    local = addr >>> cfg.sb &&& (1 <<< cfg.ob) - 1
    lane * cfg.per_lane + local
  end

  # -- tests -----------------------------------------------------------------------------------

  defp small, do: Config.new(channels: 32, slots: 8, frame_cycles: 100)

  test "the small mixer: 3 lanes, 11 outputs each, frames back to back, BEAM simulator" do
    cfg = small()
    assert {cfg.lanes, cfg.per_lane, cfg.cycles} == {3, 11, 95}
    mod = Matrix.build(cfg)
    matrix = MixerBench.random_matrix(cfg, 1)
    frames = for i <- 1..4, do: MixerBench.random_frame(cfg, i)
    {stim, dones} = stimulus(cfg, matrix, frames, cfg.cycles)
    assert length(dones) == 4
    assert :ok = Cosim.check_model(mod, stim, model(cfg))
    # the mix saturates somewhere and some outputs are empty
    {_, clips} = M.mix_clip(matrix, hd(frames))
    assert Enum.any?(clips) and not Enum.all?(clips)
  end

  @tag :verilator
  @tag timeout: 600_000
  test "small mixer in Verilator and the BEAM simulator, output backpressure, 4 frames" do
    cfg = small()
    mod = Matrix.build(cfg)
    matrix = MixerBench.random_matrix(cfg, 2)
    frames = for i <- 1..4, do: MixerBench.random_frame(cfg, 10 + i)

    for pct <- [100, 60, 25] do
      # the sequencer must have drained a frame before the next one arrives
      spacing = cfg.cycles + div(cfg.channels * 400, pct) + 20
      {stim, _} = stimulus(cfg, matrix, frames, spacing, pct)
      Cosim.assert_model(mod, stim, model(cfg), backend: :both)
    end
  end

  test "a frame_done while the lanes are busy is flagged and that frame is not mixed" do
    cfg = small()
    mod = Matrix.build(cfg)
    matrix = MixerBench.random_matrix(cfg, 3)
    frames = for i <- 1..4, do: MixerBench.random_frame(cfg, 20 + i)
    # frame 1 completes 50 cycles after frame 0: the lanes need 95
    {stim, _} = stimulus(cfg, matrix, frames, 50)
    Cosim.assert_model(mod, stim, model(cfg), backend: :beam)
    {:ok, c} = Cosim.build(mod)
    {:ok, outs} = Cosim.run(c, stim)
    assert Enum.count(outs, &(&1.overrun_compute == 1)) >= 1
    # fewer frames came out than went in
    assert Enum.count(outs, &(&1.m_axis_tvalid == 1 and &1.m_axis_tid == 0)) < 4
  end

  @tag :verilator
  @tag timeout: 600_000
  test "results that arrive while the previous frame is still streaming out are dropped and flagged" do
    cfg = small()
    mod = Matrix.build(cfg)
    matrix = MixerBench.random_matrix(cfg, 6)
    frames = for i <- 1..3, do: MixerBench.random_frame(cfg, 50 + i)
    spacing = cfg.cycles + 10
    # the output is blocked until after the second frame's results are ready
    blocked = fn i -> if i < 32 + spacing + cfg.cycles + 20, do: 0, else: 1 end
    {stim, _} = stimulus(cfg, matrix, frames, spacing, blocked)
    Cosim.assert_model(mod, stim, model(cfg), backend: :both)
    {:ok, c} = Cosim.build(mod)
    {:ok, outs} = Cosim.run(c, stim)
    assert Enum.count(outs, &(&1.overrun_output == 1)) >= 1
  end

  @tag :verilator
  @tag timeout: 600_000
  test "one lane (no lane select) and a power-of-two split" do
    for opts <- [
          [channels: 8, slots: 4, frame_cycles: 1000],
          [channels: 16, slots: 4, frame_cycles: 20]
        ] do
      cfg = Config.new(opts)
      mod = Matrix.build(cfg)
      matrix = MixerBench.random_matrix(cfg, 4)
      frames = for i <- 1..3, do: MixerBench.random_frame(cfg, 30 + i)
      {stim, _} = stimulus(cfg, matrix, frames, cfg.cycles + 3, 80)
      Cosim.assert_model(mod, stim, model(cfg), backend: :both)
    end
  end

  @tag :verilator
  @tag :slow
  @tag timeout: 900_000
  test "1024 channels, 64 slots, 13 lanes: three frames at the frame budget, BEAM and Verilator" do
    cfg = Config.new()
    assert {cfg.lanes, cfg.per_lane, cfg.cycles} == {13, 79, 5063}
    assert cfg.cycles <= cfg.frame_cycles
    mod = Matrix.build(cfg)
    matrix = MixerBench.random_matrix(cfg, 5)
    frames = for i <- 1..3, do: MixerBench.random_frame(cfg, 40 + i)
    {stim, _} = stimulus(cfg, matrix, frames, cfg.frame_cycles, 100)
    Cosim.assert_model(mod, stim, model(cfg), backend: :both)
  end
end

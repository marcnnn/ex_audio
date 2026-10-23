defmodule ExAudio.MixerHostTest do
  @moduledoc """
  The host helpers (`ExAudio.Mixer.Host`) against the register slave of the
  map in the BEAM simulator: every write lands in the field or window word
  it should, strips and crosspoints encode what the kernels expect.
  """
  use ExUnit.Case, async: true

  import Bitwise

  doctest ExAudio.Mixer.Config

  alias ExAudio.{Biquad, Filter, Q, Strip}
  alias ExAudio.Matrix, as: M
  alias ExAudio.Mixer.{Config, Host, Layout, Matrix}
  alias ExAudio.MixerBench
  alias ExAudio.MixerBench.Axi
  alias ExHdl.RTL.Sim

  defp cfg, do: Config.new(channels: 32, slots: 8, frame_cycles: 100)

  # runs AXI writes and reads on the register slave alone; returns the outputs per cycle
  defp run(cfg, writes, reads \\ [], inputs \\ %{}) do
    mod = ExHdl.Regs.RTL.build(Layout.map(cfg))
    reset = [%{rst_n: 0}, %{rst_n: 0}, Map.merge(%{rst_n: 1}, Map.merge(Axi.idle(), inputs))]
    stim = reset ++ Axi.writes(writes) ++ Axi.reads(reads) ++ List.duplicate(%{}, 8)
    {_sim, outs} = mod |> Sim.new() |> Sim.run(stim)
    {mod, stim, outs}
  end

  defp window_writes(outs, win) do
    for o <- outs,
        o[:"#{win}_en"] == 1 and o[:"#{win}_we"] == 1,
        do: {o[:"#{win}_addr"], o[:"#{win}_wdata"]}
  end

  test "Config derives the lanes from the frame budget and rejects what cannot fit" do
    c = Config.new()
    assert {c.lanes, c.per_lane, c.cycles, c.frame_cycles} == {13, 79, 5063, 5208}
    assert Config.lane_outputs(c, 12) == 76
    assert Config.lane_of(c, 1023) == {12, 75}
    # lanes grow until the pipeline fits
    assert {6, 3, 19} ==
             Config.new(channels: 16, slots: 4, frame_cycles: 20)
             |> then(&{&1.lanes, &1.per_lane, &1.cycles})

    assert_raise ArgumentError, ~r/do not fit/, fn ->
      Config.new(channels: 16, slots: 4, frame_cycles: 10)
    end

    assert_raise ArgumentError, ~r/power of two/, fn -> Config.new(slots: 48) end
    # a fixed lane count is kept
    assert Config.new(lanes: 16).lanes == 16
  end

  test "window offsets are aligned, disjoint and inside the address space" do
    cfg = Config.new()
    sizes = Layout.window_sizes(cfg)
    offs = Layout.window_offsets(cfg)

    for {w, off} <- offs do
      assert rem(off, sizes[w]) == 0
      assert off >= 0x1000
    end

    assert 4 * 2 ** (cfg.lb + cfg.ob + cfg.sb) == sizes[:xp]
    assert Layout.map(cfg).addr_width == 21
    # the defregs map of ExAudio.Mixer.Regs is the 1024 channel map
    assert Layout.map(cfg).windows == ExAudio.Mixer.Regs.regmap().windows
    assert Layout.map(cfg).registers == ExAudio.Mixer.Regs.regmap().registers
  end

  test "ctrl, swap, meter parameters and status flags through the bus" do
    h = Host.new(cfg())

    writes =
      Host.enable(h) ++
        Host.swap(h, :outputs) ++
        Host.meter_writes(h, hold_ms: 2, decay_ms: 5, tau_ms: 3, clip_margin: 100)

    {_mod, _stim, outs} = run(cfg(), writes)
    last = List.last(outs)
    assert last.ctrl_enable == 1
    assert last.meter_hold_value == 96
    assert last.meter_decay_value == ExAudio.Dynamics.coefficient(5, 48_000)
    assert last.meter_k_value == ExAudio.Dynamics.coefficient(3, 48_000, 23)
    assert last.meter_clip_value == (1 <<< 23) - 1 - 100
    # strobes are pulses: swap of the outputs only, once; meter_load once
    swaps = Enum.filter(outs, &(&1.swap_wr == 1))
    assert length(swaps) == 1 and hd(swaps).swap_outputs == 1 and hd(swaps).swap_inputs == 0
    assert Enum.count(outs, &(&1.meter_load_wr == 1)) == 1

    # status: hardware events set the sticky bits, a write of 1 clears them
    {_, _, outs} =
      run(cfg(), Host.clear_status(h, [:overrun_compute]), [Host.offset(h, :status)], %{
        status_overrun_compute_set: 1,
        status_busy: 1
      })

    [word] = Axi.read_data(outs)
    assert %{overrun_compute: 1, busy: 1, sync_error: 0} = Host.decode_status(h, word)
  end

  test "strip words land in the coefficient window at channel * 64 + word" do
    h = Host.new(cfg())

    strip = [
      eq: [{:highpass, 80}, {:peaking, 1000, q: 2.0, gain_db: 4}],
      gate: [open_db: -55],
      compressor: [threshold_db: -18, ratio: 3, knee_db: 6]
    ]

    words = Host.strip_words(h, strip)
    assert length(words) == 35
    assert Enum.all?(words, &(&1 in 0..0xFFFF_FFFF))
    writes = Host.strip_writes(h, :in, 17, strip) ++ Host.strip_writes(h, :out, 3, strip)
    {_, _, outs} = run(cfg(), writes)

    assert window_writes(outs, :coeff_in) ==
             for({w, i} <- Enum.with_index(words), do: {17 * 64 + i, w})

    assert window_writes(outs, :coeff_out) ==
             for({w, i} <- Enum.with_index(words), do: {3 * 64 + i, w})

    # bands 3 and 4 are pass-through
    unity = Biquad.identity() |> Tuple.to_list() |> Enum.map(&(&1 &&& 0xFFFF_FFFF))
    assert Enum.slice(words, 10, 5) == unity and Enum.slice(words, 15, 5) == unity

    quantised =
      {:peaking, 1000, q: 2.0, gain_db: 4}
      |> then(fn {k, f, o} -> Filter.design(k, f, 48_000, o) end)
      |> Biquad.quantize()

    assert Enum.slice(words, 5, 5) ==
             quantised |> Tuple.to_list() |> Enum.map(&(&1 &&& 0xFFFF_FFFF))
  end

  test "an empty strip is transparent: exact gate bypass, compressor within 0.002 dB" do
    h = Host.new(cfg())
    words = Host.strip_words(h, [])
    params = MixerBench.params_from_words(words)
    spec = Strip.spec(List.duplicate(Biquad.identity(), 4), dynamics: true)

    xs =
      MixerBench.signal(2000, 3) ++
        List.duplicate(8_388_607, 20) ++ List.duplicate(-8_388_608, 20)

    {y, _} = Q.run(spec, xs, params: params)

    for {a, b} <- Enum.zip(xs, Nx.to_flat_list(y)), abs(a) > 1000 do
      assert abs(20 * :math.log10(abs(b) / abs(a))) < 0.002
    end
  end

  test "crosspoint writes: every slot of every output, and only the changed rows in a diff" do
    h = Host.new(cfg())
    c = cfg()
    m0 = M.new(n_in: 32, n_out: 32, slots: 8)
    m1 = m0 |> M.connect(5, 9, 0.5) |> M.connect(5, 2, -1.0) |> M.connect(30, 31, M.db(-6))
    all = Host.matrix_writes(h, m1)
    assert length(all) == 32 * 8

    diff = Host.matrix_diff(h, m0, m1)
    assert length(diff) == 2 * 8
    # rows go in source order: output 5 has sources 2 (gain -1.0) then 9
    {off, word} = Enum.at(diff, 0)
    assert off == ExHdl.Regs.window_offset(Layout.map(c), :xp, Config.xp_word(c, 5, 0))
    assert Matrix.decode_entry(c, word) == {2, M.gain(-1.0)}
    assert Matrix.decode_entry(c, elem(Enum.at(diff, 1), 1)) == {9, M.gain(0.5)}

    {_, _, outs} = run(c, diff)
    writes = window_writes(outs, :xp)
    assert length(writes) == 16
    assert {Config.xp_word(c, 30, 0), Matrix.entry(c, 31, M.gain(M.db(-6)))} in writes
  end

  test "meter words decode to dB" do
    assert %{db: db, clip: false} = Host.decode_peak(1 <<< 22)
    assert_in_delta db, -6.0206, 1.0e-3
    assert %{clip: true, linear: 1.0} = Host.decode_peak(1 <<< 24 ||| 1 <<< 23)
    assert Host.decode_peak(0).db == :neg_infinity
    # a full scale sine reads -3.01 dB, Q16 log2 units
    assert_in_delta Host.decode_rms(Q.db_to_log2(-3.01) &&& 0xFFFF_FFFF), -3.01, 1.0e-3
  end
end

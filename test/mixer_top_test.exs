defmodule ExAudio.MixerTopTest do
  @moduledoc """
  The whole mixer (`ExAudio.Mixer`) in Verilator, driven only through its
  ports: the register writes of `ExAudio.Mixer.Host` (strips of both banks,
  crosspoints, meter parameters, enable, bank swaps) and TDM frames. The
  expected stream is composed from the references: Nx strip kernels per
  channel (with the bank swap), `ExAudio.Matrix.mix_clip/2`, Nx strip
  kernels again; the meter words read back through the windows against
  `ExAudio.Meter` run over the same samples; status registers.
  """
  use ExUnit.Case, async: true

  import Bitwise
  import ExAudio.MixerBench

  alias ExAudio.Matrix, as: M
  alias ExAudio.{Meter, Q}
  alias ExAudio.Mixer
  alias ExAudio.Mixer.{Config, Host}
  alias ExAudio.MixerBench.Axi
  alias ExHdl.RTL.Cosim

  @moduletag :verilator
  @moduletag timeout: 1_800_000

  @meter_opts [hold_ms: 2, decay_ms: 5, tau_ms: 3, clip_margin: 100]

  # strip description of channel c in bank :a / :b (musical units)
  defp strip(c, bank) do
    k = if bank == :a, do: 0, else: 1

    [
      eq: [
        {:highpass, 30 + 3 * c + 40 * k, q: 0.8},
        {:peaking, 300 + rem(31 * c, 9000) + 500 * k,
         q: 0.5 + 0.4 * rem(c, 7), gain_db: 8 - 2 * rem(c, 7)},
        {:highshelf, 3000 + rem(50 * c, 9000), gain_db: -4 + 3 * k}
      ],
      gate: [open_db: -70 + rem(c, 13), hold_ms: 1 + rem(c, 3), release_ms: 4],
      compressor: [
        threshold_db: -30 + rem(c, 11) - 6 * k,
        ratio: 2 + rem(c, 5),
        knee_db: rem(c, 3) * 4,
        attack_ms: 0.5,
        release_ms: 10
      ]
    ]
  end

  # the strip kernel run with the parameter words the host writes
  defp strip_run(h, strip_opts, samples, state) do
    params = h |> Host.strip_words(strip_opts) |> params_from_words()
    spec = ExAudio.Strip.spec(List.duplicate(ExAudio.Biquad.identity(), 4), dynamics: true)
    {y, st} = Q.run(spec, samples, [params: params] ++ if(state, do: [state: state], else: []))
    {Nx.to_flat_list(y), st}
  end

  # outputs of channel c's strip over `samples`, flipping from bank :a to :b at index `flip`
  defp strip_channel(h, c, samples, flip, b_of) do
    {a, b} = Enum.split(samples, flip)
    {ya, st} = strip_run(h, strip(c, :a), a, nil)
    {yb, _} = if b == [], do: {[], st}, else: strip_run(h, strip(b_of.(c), :b), b, st)
    ya ++ yb
  end

  defp meter_expect(side_samples) do
    {pk, _} = Q.run(Meter.spec(:peak, @meter_opts), side_samples)
    {rms, _} = Q.run(Meter.spec(:rms, @meter_opts), side_samples)
    {out, clip} = pk
    word = fn o, c -> (o &&& 0xFFFFFF) ||| c <<< 24 end

    {word.(List.last(Nx.to_flat_list(out)), List.last(Nx.to_flat_list(clip))),
     List.last(Nx.to_flat_list(rms)) &&& 0xFFFF_FFFF}
  end

  # Runs the scenario; returns the pieces the assertions need.
  defp scenario(cfg_opts, opts) do
    cfg = Config.new(cfg_opts)
    n = cfg.channels
    frames = Keyword.fetch!(opts, :frames)
    flip_in = Keyword.get(opts, :flip_in, frames)
    flip_out = Keyword.get(opts, :flip_out, frames)
    spacing = Keyword.get(opts, :spacing, cfg.frame_cycles)
    k = cfg.state_fold
    swap? = flip_in < frames or flip_out < frames
    h = Host.new(cfg)
    mod = Mixer.build(cfg)
    {:ok, sim} = Cosim.build(mod)

    b_of = fn c -> if rem(c, 4) == 1 or swap?, do: c + 1, else: c end
    channels = 0..(n - 1)

    matrix = random_matrix(cfg, 7)
    xs = for c <- channels, into: %{}, do: {c, signal(frames, c)}

    # -- expected data
    in_y = for c <- channels, into: %{}, do: {c, strip_channel(h, c, xs[c], flip_in, b_of)}

    {mixed, clips} =
      Enum.reduce(0..(frames - 1), {[], []}, fn f, {ys, cs} ->
        {y, clip} = M.mix_clip(matrix, for(c <- channels, do: Enum.at(in_y[c], f)))
        {ys ++ [y], cs ++ [clip]}
      end)

    out_y =
      for c <- channels, into: %{} do
        {c, strip_channel(h, c, for(y <- mixed, do: Enum.at(y, c)), flip_out, b_of)}
      end

    # -- stimulus: configuration over the bus
    bank_b = if swap?, do: for(c <- channels, side <- [:in, :out], do: {side, c}), else: []

    config_writes =
      Host.meter_writes(h, @meter_opts) ++
        Enum.flat_map(channels, fn c ->
          Host.strip_writes(h, :in, c, strip(c, :a)) ++
            Host.strip_writes(h, :out, c, strip(c, :a))
        end) ++
        Host.matrix_writes(h, matrix) ++
        Host.swap(h, :both)

    b_writes =
      Enum.flat_map(bank_b, fn {side, c} -> Host.strip_writes(h, side, c, strip(b_of.(c), :b)) end)

    junk =
      for c <- channels do
        %{s_axis_tvalid: 1, s_axis_tdata: s24(123_456 * (c + 1)), s_axis_tid: c, s_axis_tuser: 0}
      end

    pre =
      reset() ++
        [%{m_axis_tready: 1, s_axis_tvalid: 0} | Axi.writes(config_writes)] ++
        List.duplicate(%{}, 60) ++
        Axi.writes(b_writes) ++
        junk ++
        [%{s_axis_tvalid: 0}] ++
        Axi.writes(Host.enable(h)) ++ List.duplicate(%{}, 20)

    # -- stimulus: frames, swaps at the gaps, final reads
    stream =
      Enum.flat_map(0..(frames - 1), fn f ->
        # one beat every state_fold cycles, as fast as the input strip takes them
        beats =
          for c <- channels do
            [
              %{
                s_axis_tvalid: 1,
                s_axis_tdata: s24(Enum.at(xs[c], f)),
                s_axis_tid: c,
                s_axis_tuser:
                  if(c == 0 and not (f == frames - 1 and opts[:bad_start] == true),
                    do: 1,
                    else: 0
                  )
              }
              | List.duplicate(%{s_axis_tvalid: 0}, k - 1)
            ]
          end

        List.flatten(beats) ++ List.duplicate(%{s_axis_tvalid: 0}, spacing - n * k)
      end)

    latency = Mixer.latency(cfg, Mixer.Strip.design(cfg, "t").latency)
    gap = div(spacing - n * k, 2)

    swaps_in =
      if flip_in < frames, do: [{flip_in * spacing - gap, Host.swap(h, :inputs)}], else: []

    swaps_out =
      if flip_out < frames,
        do: [{flip_out * spacing + latency - gap, Host.swap(h, :outputs)}],
        else: []

    bus =
      Enum.reduce(swaps_in ++ swaps_out, [], fn {at, writes}, acc ->
        acc ++ List.duplicate(%{}, max(at - length(acc), 0)) ++ Axi.writes(writes)
      end)

    reads =
      [
        Host.offset(h, :id),
        Host.offset(h, :config),
        Host.offset(h, :status),
        Host.offset(h, :frames),
        Host.offset(h, :clips)
      ] ++
        Host.meter_reads(h, :in, channels) ++ Host.meter_reads(h, :out, channels)

    tail = List.duplicate(%{s_axis_tvalid: 0}, latency + spacing + 300)
    main = Axi.merge([stream ++ tail, bus]) ++ Axi.reads(reads) ++ List.duplicate(%{}, 10)

    stimulus = pre ++ main
    {:ok, outs} = Cosim.run(sim, stimulus)
    held = Cosim.full_inputs(mod, stimulus)

    %{
      cfg: cfg,
      h: h,
      outs: outs,
      held: held,
      pre: length(pre),
      n_writes:
        length(config_writes) + length(b_writes) + 1 +
          length(List.flatten([swaps_in, swaps_out |> Enum.map(&elem(&1, 1))])),
      xs: xs,
      in_y: in_y,
      out_y: out_y,
      clips: clips,
      reads: reads,
      frames: frames,
      latency: latency
    }
  end

  defp assert_scenario(s, opts) do
    %{cfg: cfg, outs: outs, held: held} = s
    n = cfg.channels
    channels = 0..(n - 1)

    # the junk frame (enable low) is refused: tready low for every valid beat before enable
    {before, _after} = Enum.split(Enum.zip(held, outs), s.pre)
    junk = Enum.filter(before, fn {i, _} -> i.s_axis_tvalid == 1 end)
    assert length(junk) == n
    assert Enum.all?(junk, fn {_, o} -> o.s_axis_tready == 0 end)

    # every later beat is taken
    main = Enum.drop(Enum.zip(held, outs), s.pre)
    assert Enum.all?(main, fn {i, o} -> i.s_axis_tvalid == 0 or o.s_axis_tready == 1 end)

    # all bus writes completed
    assert Axi.write_handshakes(outs, held) == s.n_writes

    # output stream
    beats = for o <- outs, o.m_axis_tvalid == 1, do: o
    assert length(beats) == s.frames * n

    expected =
      for f <- 0..(s.frames - 1), c <- channels do
        {c, Enum.at(s.out_y[c], f)}
      end

    got = for o <- beats, do: {o.m_axis_tid, signed24(o.m_axis_tdata)}

    bad =
      got |> Enum.zip(expected) |> Enum.with_index() |> Enum.reject(fn {{a, b}, _} -> a == b end)

    assert bad == [],
           "#{length(bad)} of #{length(got)} samples differ, first #{inspect(Enum.take(bad, 3))}"

    assert length(Enum.uniq(for {_, y} <- got, do: y)) > div(length(got), 2)

    # frame start flags, and the clip flag of the matrix
    starts = for o <- beats, do: o.m_axis_tuser &&& 1
    assert starts == List.flatten(for _ <- 1..s.frames, do: [1 | List.duplicate(0, n - 1)])

    clip_flags = for o <- beats, do: o.m_axis_tuser >>> 1
    assert clip_flags == for(f <- s.clips, c <- f, do: if(c, do: 1, else: 0))

    # latency of the first output beat after the first accepted input beat
    first_in =
      Enum.find_index(Enum.zip(held, outs), fn {i, o} ->
        i.s_axis_tvalid == 1 and o.s_axis_tready == 1
      end)

    first_out = Enum.find_index(outs, &(&1.m_axis_tvalid == 1))
    assert first_out - first_in == s.latency

    # reads: id, config, status, frames, clips, then the meters
    words = Axi.read_data(outs)
    assert length(words) == length(s.reads)
    [id, config, status, frames, clips | meters] = words
    assert id == Mixer.Layout.version()
    expected_config = bor(bor(bsl(cfg.lanes, 24), bsl(cfg.slots, 16)), band(n, 0xFFFF))
    assert config == expected_config
    st = Host.decode_status(s.h, status)

    assert %{
             busy: 0,
             in_pending: 0,
             out_pending: 0,
             compute_busy: 0,
             overrun_compute: 0,
             overrun_output: 0
           } = st

    assert st.sync_error == if(opts[:bad_start], do: 1, else: 0)
    assert frames == s.frames
    assert clips == Enum.count(List.flatten(s.clips), & &1)

    {in_m, out_m} = Enum.split(meters, 2 * n)

    for {side, words, ys} <- [{:in, in_m, s.in_y}, {:out, out_m, s.out_y}], c <- channels do
      [peak, rms] = Enum.slice(words, 2 * c, 2)
      {ep, er} = meter_expect(ys[c])
      assert {side, c, peak} == {side, c, ep}
      assert {side, c, rms} == {side, c, er}
    end

    # the meters saw both peaks and levels
    assert Enum.any?(in_m, &(&1 != 0))
  end

  test "24 channels: strips, matrix, meters and registers through the ports, bank swap on both strips" do
    s =
      scenario([channels: 24, slots: 8, frame_cycles: 400, state_mem: :block],
        frames: 9,
        flip_in: 4,
        flip_out: 6,
        spacing: 400,
        bad_start: true
      )

    assert_scenario(s, bad_start: true)
  end

  test "24 channels with the strip state folded over 4 rows: one input and output sample every 4 cycles" do
    s =
      scenario([channels: 24, slots: 8, frame_cycles: 400, state_mem: :ultra, state_fold: 4],
        frames: 6,
        flip_in: 3,
        flip_out: 4,
        spacing: 400
      )

    assert s.cfg.state_fold == 4
    assert_scenario(s, [])
  end

  @tag :slow
  @tag timeout: 3_600_000
  test "1024 channels, 13 lanes at the 48 kHz frame: three frames, meters, status" do
    s = scenario([], frames: 3, spacing: 5208)
    assert s.cfg.lanes == 13
    assert_scenario(s, [])
  end
end

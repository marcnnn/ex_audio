defmodule ExAudio.MixerBench do
  @moduledoc false
  # Shared pieces of the mixer tests: per-channel strip designs, signals,
  # the Nx reference of a strip and helpers that turn lists of events into
  # per-cycle stimulus maps for ExHdl.RTL.Cosim.
  import Bitwise

  alias ExAudio.{Biquad, Filter, Q, Strip}

  @fs 48_000

  # -- strips -------------------------------------------------------------------------------

  @doc "Distinct strip design for channel `c`; `bank` `:a` or `:b` (a different set)."
  def strip_design(c, bank) do
    k = if bank == :a, do: 0, else: 1
    r = rem(c, 7)

    bands =
      [
        Filter.design(:highpass, 30 + 0.4 * c + 40 * k, @fs, q: 0.7 + 0.1 * r),
        Filter.design(:lowshelf, 120 + 1.5 * c, @fs, gain_db: 5 - 3 * k - r),
        Filter.design(:peaking, 300 + 3.1 * c + 500 * k, @fs,
          q: 0.5 + 0.4 * r,
          gain_db: 8 - 2 * r
        ),
        Filter.design(:highshelf, 3000 + 5 * c + 100 * k, @fs, gain_db: -4 + 2 * k + r)
      ]
      |> Enum.map(&Biquad.quantize/1)

    opts = [
      dynamics: true,
      gate: [open_db: -70 + rem(c, 13) + 6 * k, hold_ms: 1 + rem(c, 3), release_ms: 4],
      compressor: [
        threshold_db: -30 + rem(c, 11) - 6 * k,
        ratio: 2 + rem(c, 5),
        knee_db: rem(c, 3) * 4,
        attack_ms: 0.5,
        release_ms: 10 + k * 30
      ]
    ]

    {bands, opts}
  end

  @doc "The 35 parameter words of `strip_design/2`, as unsigned 32-bit values."
  def strip_words(c, bank) do
    {bands, opts} = strip_design(c, bank)
    bands |> Strip.channel_words(opts) |> Enum.map(&(&1 &&& 0xFFFF_FFFF))
  end

  @doc "A test signal for channel `c`: tones, noise, a loud burst and a quiet tail; `n` samples."
  def signal(n, c) do
    :rand.seed(:exsss, {c, 11, 5})
    f1 = 150 + 37 * c
    quiet_from = div(n * 3, 4)

    for i <- 0..(n - 1) do
      t = i / @fs
      amp = if i < quiet_from, do: 2.2e6 * (1 + rem(c, 3)), else: 3.0e3

      v =
        amp * :math.sin(2 * :math.pi() * f1 * t) +
          0.4 * amp * :math.sin(2 * :math.pi() * 5200 * t) + 2.0e4 * (:rand.uniform() - 0.5)

      v = if rem(c, 5) == 0 and i in 3..5, do: 9.0e6, else: v
      v |> round() |> max(-8_388_608) |> min(8_388_607)
    end
  end

  @doc """
  Nx reference of the strip of channel `c` over `segments`, a list of
  `{bank, samples}` that run on one state (a bank swap between them).
  Returns one output list per segment.
  """
  def strip_reference(c, segments) do
    {outs, _} =
      Enum.map_reduce(segments, nil, fn {bank, xs}, state ->
        {bands, opts} = strip_design(c, bank)
        spec = Strip.spec(bands, opts)
        {y, st} = Q.run(spec, xs, if(state, do: [state: state], else: []))
        {Nx.to_flat_list(y), st}
      end)

    outs
  end

  @doc "`strip_reference/2` for many channels in parallel; a map `channel => outputs per segment`."
  def strip_references(channels, segments_of) do
    channels
    |> Task.async_stream(fn c -> {c, strip_reference(c, segments_of.(c))} end,
      timeout: :infinity,
      ordered: false
    )
    |> Map.new(fn {:ok, {c, r}} -> {c, r} end)
  end

  @doc "The parameter structure of a strip kernel from its 35 words (unsigned 32-bit values)."
  def params_from_words(words) do
    words =
      Enum.map(words, fn w -> if w >= 0x8000_0000, do: w - 0x1_0000_0000, else: w end)

    {eq, rest} = Enum.split(words, 20)
    {gate, comp} = Enum.split(rest, 8)
    coefs = eq |> Enum.chunk_every(5) |> Enum.map(&List.to_tuple/1) |> List.to_tuple()
    Q.tensors({coefs, List.to_tuple(gate), List.to_tuple(comp)})
  end

  # rows with 0, 1, a few and all slots used; gains of both signs, some large enough to saturate
  def random_matrix(cfg, seed) do
    :rand.seed(:exsss, {seed, 4, 2})
    n = cfg.channels

    Enum.reduce(0..(n - 1), ExAudio.Matrix.new(n_in: n, n_out: n, slots: cfg.slots), fn out, m ->
      count =
        case rem(out, 5) do
          0 -> 0
          1 -> 1
          2 -> cfg.slots
          _ -> :rand.uniform(cfg.slots)
        end

      srcs = Enum.take_random(0..(n - 1), count)

      Enum.reduce(srcs, m, fn src, m ->
        g =
          if rem(out, 7) == 6,
            do: 3.9 * (:rand.uniform() - 0.5),
            else: 1.6 * (:rand.uniform() - 0.5)

        ExAudio.Matrix.connect(m, out, src, g)
      end)
    end)
  end

  def random_frame(cfg, seed) do
    :rand.seed(:exsss, {seed, 8, 6})

    for _ <- 1..cfg.channels do
      case :rand.uniform(12) do
        1 -> 8_388_607
        2 -> -8_388_608
        _ -> :rand.uniform(1 <<< 24) - 1 - (1 <<< 23)
      end
    end
  end

  # -- stimulus ---------------------------------------------------------------------------

  def s24(v), do: v &&& 0xFFFFFF

  @doc "Signed value of a 24-bit pattern."
  def signed24(v) when v >= 0x800000, do: v - 0x1000000
  def signed24(v), do: v

  @doc "Cycles that reset the design for `n` cycles, then release."
  def reset(n \\ 3), do: List.duplicate(%{rst_n: 0}, n) ++ [%{rst_n: 1}]

  @doc "Samples (`{value, channel, user}`) on consecutive cycles with random idle gaps."
  def beats(list, seed, gap_pct \\ 0) do
    :rand.seed(:exsss, {seed, 3, 9})

    Enum.flat_map(list, fn {x, c, u} ->
      gap = if gap_pct > 0 and :rand.uniform(100) <= gap_pct, do: [%{s_axis_tvalid: 0}], else: []
      gap ++ [%{s_axis_tvalid: 1, s_axis_tdata: s24(x), s_axis_tid: c, s_axis_tuser: u}]
    end)
  end

  @doc "Events with `tvalid` low on the cycle after the last beat (so the stream ends)."
  def stop_stream, do: [%{s_axis_tvalid: 0}]
end

defmodule ExAudio.MixerBench.Axi do
  @moduledoc false
  # Non-reactive AXI4-Lite master stimulus for ExHdl.Regs slaves (bready and
  # rready held high). Timing from the slave's protocol (ExHdl.Regs.RTL): a
  # write takes 3 cycles (valid, valid with the ready, response), a read 6.
  # `check_writes/2` and `read_data/1` verify from the recorded outputs that
  # every transaction went through.
  import Bitwise

  @idle %{
    s_axil_awvalid: 0,
    s_axil_wvalid: 0,
    s_axil_arvalid: 0,
    s_axil_bready: 1,
    s_axil_rready: 1,
    s_axil_wstrb: 15,
    s_axil_awprot: 0,
    s_axil_arprot: 0
  }

  def idle, do: @idle

  def writes(list) do
    Enum.flat_map(list, fn {addr, data} ->
      w = %{
        s_axil_awvalid: 1,
        s_axil_wvalid: 1,
        s_axil_awaddr: addr,
        s_axil_wdata: data &&& 0xFFFF_FFFF
      }

      [Map.merge(@idle, w), w, @idle]
    end)
  end

  def reads(list) do
    Enum.flat_map(list, fn addr ->
      r = %{s_axil_arvalid: 1, s_axil_araddr: addr}
      [Map.merge(@idle, r), r, @idle, @idle, @idle, @idle]
    end)
  end

  @doc "Merges per-cycle map lists: cycle i is the union of element i of every list."
  def merge(tracks) do
    n = tracks |> Enum.map(&length/1) |> Enum.max()

    tracks
    |> Enum.map(&Stream.concat(&1, Stream.repeatedly(fn -> %{} end)))
    |> Enum.map(&Enum.take(&1, n))
    |> Enum.zip_with(fn maps -> Enum.reduce(maps, %{}, &Map.merge(&2, &1)) end)
  end

  @doc "Number of completed write handshakes (aw and w together) in the recorded outputs."
  def write_handshakes(outs, held) do
    Enum.count(Enum.zip(outs, held), fn {o, i} ->
      i.s_axil_awvalid == 1 and i.s_axil_wvalid == 1 and o.s_axil_awready == 1 and
        o.s_axil_wready == 1
    end)
  end

  @doc "Read data words in order (`rready` is always high, so every `rvalid` cycle is one read)."
  def read_data(outs), do: for(o <- outs, o.s_axil_rvalid == 1, do: o.s_axil_rdata)
end

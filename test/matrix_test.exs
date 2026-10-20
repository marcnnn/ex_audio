defmodule ExAudio.MatrixTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  import ExAudio.TestHelpers

  alias ExAudio.{Matrix, Q}

  doctest ExAudio.Matrix

  @slots 6

  defp matrix_gen do
    gen all n_in <- integer(@slots..16),
            connections <-
              list_of({integer(0..1), integer(0..(n_in - 1)), float(min: -3.9, max: 3.9)},
                max_length: 12
              ) do
      m =
        Enum.reduce(connections, Matrix.new(n_in: n_in, n_out: 2, slots: @slots), fn {o, s, g},
                                                                                     m ->
          try do
            Matrix.connect(m, o, s, g)
          rescue
            ArgumentError -> m
          end
        end)

      {m, n_in}
    end
  end

  test "connect, replace, disconnect, limits" do
    m = Matrix.new(n_in: 8, n_out: 2, slots: 2)
    m = m |> Matrix.connect(0, 1, 1.0) |> Matrix.connect(0, 1, 0.5)
    assert Matrix.row(m, 0) == {[1, 0], [16_384, 0]}
    m = Matrix.connect(m, 0, 2, 1.0)
    assert_raise ArgumentError, ~r/already has 2/, fn -> Matrix.connect(m, 0, 3, 1.0) end
    assert_raise ArgumentError, fn -> Matrix.connect(m, 2, 0, 1.0) end
    m = m |> Matrix.disconnect(0, 1) |> Matrix.connect(0, 3, 1.0) |> Matrix.connect(0, 2, 0.0)
    assert Matrix.row(m, 0) == {[3, 0], [32_768, 0]}
    assert Matrix.row(m, 1) == {[0, 0], [0, 0]}
    assert Matrix.gain(10.0) == (1 <<< 17) - 1
    assert_in_delta Matrix.db(-6.0206), 0.5, 1.0e-4
  end

  property "mix matches the exact weighted sum to half an LSB (when it does not saturate)" do
    check all {m, n_in} <- matrix_gen(),
              frame <- list_of(integer(-1_000_000..1_000_000), length: n_in) do
      reference = Matrix.mix_float(m, frame)

      if Enum.all?(reference, &(abs(&1) < 8_388_000)) do
        for {y, r} <- Enum.zip(Matrix.mix(m, frame), reference),
            do: assert(abs(y - r) <= 0.5 + 1.0e-9)
      end
    end
  end

  property "mix saturates instead of wrapping and flags it" do
    check all {m, n_in} <- matrix_gen(),
              frame <- list_of(integer(-8_388_608..8_388_607), length: n_in) do
      {ys, clips} = Matrix.mix_clip(m, frame)

      for {y, c, r} <-
            Enum.zip([ys, clips, Matrix.mix_float(m, frame)]) do
        assert y in -8_388_608..8_388_607
        assert c == (r > 8_388_607.5 or r < -8_388_608.5)
        if c, do: assert(y in [-8_388_608, 8_388_607])
      end
    end
  end

  property "the kernel row is bit-identical to mix" do
    check all {m, n_in} <- matrix_gen(),
              frames <-
                list_of(list_of(integer(-8_388_608..8_388_607), length: n_in),
                  min_length: 3,
                  max_length: 6
                ),
              max_runs: 15 do
      {srcs, gains} = Matrix.row(m, 0)
      spec = Matrix.spec(gains)
      x = frames |> Enum.map(fn f -> Enum.map(srcs, &Enum.at(f, &1)) end) |> Nx.tensor(type: :s32)
      {y, clips} = Q.run(spec, x)
      expected = Enum.map(frames, &hd(Matrix.mix(m, &1)))
      assert Nx.to_flat_list(y) == expected

      saturated =
        frames
        |> Enum.map(&(&1 |> then(fn f -> Matrix.mix_clip(m, f) end) |> elem(1) |> hd()))
        |> Enum.count(& &1)

      assert Nx.to_number(clips) == saturated
    end
  end

  property "the streaming multiply-accumulate is bit-identical to mix, with the clip flags" do
    check all {m, n_in} <- matrix_gen(),
              frames <-
                list_of(list_of(integer(-8_388_608..8_388_607), length: n_in),
                  min_length: 2,
                  max_length: 5
                ),
              max_runs: 15 do
      for out <- 0..1 do
        {ys, clips} = Matrix.run_mac(m, out, frames)
        expected = Enum.map(frames, &Matrix.mix_clip(m, &1))
        assert ys == Enum.map(expected, &(&1 |> elem(0) |> Enum.at(out)))
        assert Enum.map(clips, &(&1 == 1)) == Enum.map(expected, &(&1 |> elem(1) |> Enum.at(out)))
      end
    end
  end

  test "the multiply-accumulate row: state closed, one multiplier, loop of two cycles" do
    scan = assert_state_closed(Matrix.mac_spec(8), ii: :auto)
    assert scan.loop_latency == 2
    {:ok, design} = Q.to_sv(Matrix.mac_spec(8), name: "mac8", channels: 2)
    assert design.lanes == 1
  end

  test "64 sources per output fit the accumulator proof" do
    spec = Matrix.spec(List.duplicate(Matrix.gain(3.9), 64))
    assert {:ok, scan} = Q.analyze(spec)

    {_, bits} =
      NxFixed.IntSet.bit_width(
        scan.graph.nodes
        |> Map.values()
        |> Enum.filter(&(&1.op == :dot))
        |> hd()
        |> Map.fetch!(:range)
      )

    assert bits <= 48
  end

  test "state closed" do
    assert_state_closed(Matrix.spec([0, 0, 0, 0]))
  end
end

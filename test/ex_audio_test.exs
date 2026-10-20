defmodule ExAudioTest do
  use ExUnit.Case, async: true

  doctest ExAudio
  doctest ExAudio.Q
  doctest ExAudio.Strip

  test "every ExAudio.Kernels entry generates SystemVerilog" do
    for entry <- ExAudio.Kernels.ex_hdl_kernels() do
      {fun, entry} = Keyword.pop!(entry, :fun)
      {args, entry} = Keyword.pop!(entry, :args)
      assert {:ok, design} = ExHdl.DSP.scan_to_sv(fun, args, entry)
      assert design.source =~ "module #{entry[:name]}"
    end
  end
end

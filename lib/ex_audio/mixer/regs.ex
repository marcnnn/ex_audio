defmodule ExAudio.Mixer.Regs do
  @moduledoc """
  Register map of the default 1024 channel mixer (`ExAudio.Mixer.Layout`
  has the table): the AXI4-Lite slave (`rtl/0`), `offset/2`,
  `window_offset/2`, `encode/2`, `decode/2`, a C header (`c_header/0`) and
  Markdown (`markdown/0`). For other sizes use `ExAudio.Mixer.Layout.map/1`
  with the functions of `ExHdl.Regs`.
  """
  use ExHdl.Regs

  defregs "ea_mixer_regs", doc: "ExAudio mixer" do
    ExAudio.Mixer.Layout.declare(ExAudio.Mixer.Config.new())
  end
end

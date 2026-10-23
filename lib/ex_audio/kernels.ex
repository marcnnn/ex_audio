defmodule ExAudio.Kernels do
  @moduledoc """
  The kernels as `mix ex_hdl.gen.sv` entries (`ex_hdl_kernels/0`):

      mix ex_hdl.gen.sv ExAudio.Kernels --out hdl/generated --synth

  writes SystemVerilog for each and prints Yosys `synth_xilinx` resource
  estimates. Entries with `channels: n` hold `n` interleaved streams in
  registers, one sample per cycle; the others take one sample every `ii`
  cycles (`ii: :auto`: the feedback loop's latency).
  """
  alias ExAudio.{Biquad, Dynamics, Filter, Matrix, Meter, Strip}

  def ex_hdl_kernels do
    peaking = Filter.design(:peaking, 1000, 48_000, q: 1.0, gain_db: 6) |> Biquad.quantize()

    strip_bands =
      [
        Filter.design(:highpass, 80, 48_000),
        Filter.design(:lowshelf, 200, 48_000, gain_db: 4),
        Filter.design(:peaking, 1000, 48_000, q: 2, gain_db: 6),
        Filter.design(:highshelf, 6000, 48_000, gain_db: -5)
      ]
      |> Enum.map(&Biquad.quantize/1)

    [
      {"biquad", Biquad.spec(peaking), ii: :auto},
      {"biquad_ch8", Biquad.spec(peaking), channels: 8},
      {"gate", Dynamics.spec(:gate), ii: :auto},
      {"gate_ch7", Dynamics.spec(:gate), channels: 7},
      {"compressor", Dynamics.spec(:compressor, knee_db: 6), ii: :auto},
      {"compressor_ch7", Dynamics.spec(:compressor, knee_db: 6), channels: 7},
      {"peak_meter", Meter.spec(:peak), ii: :auto},
      {"rms_meter", Meter.spec(:rms), ii: :auto},
      {"rms_meter_ch7", Meter.spec(:rms), channels: 7},
      {"mixer_row8", Matrix.spec(List.duplicate(Matrix.gain(1.0), 8)), ii: 1},
      {"mixer_mac8_ch2", Matrix.mac_spec(8), channels: 2},
      {"strip_eq4", Strip.spec(strip_bands, baked: true), ii: :auto},
      {"strip_full", Strip.spec(strip_bands, dynamics: true, baked: true), ii: :auto}
    ]
    |> Enum.map(fn {name, spec, timing} ->
      [name: "ex_audio_" <> name] ++ Keyword.drop(spec, [:params, :kernel_opts]) ++ timing
    end)
  end
end

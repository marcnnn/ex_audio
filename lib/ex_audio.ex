defmodule ExAudio do
  @moduledoc """
  Audio DSP kernels written once as fixed-point step functions
  `step(x, state, params) -> {y, next_state}`: they run as Nx on the BEAM
  (`NxFixed.run_scan_stacked/5`, width-checked) and go through ExHdl's scan
  backend (`ExHdl.DSP.scan_to_sv/3`) into time-multiplexed hardware,
  bit-identical (co-simulated with Verilator in the tests).

  | Module | Content |
  |---|---|
  | `ExAudio.Filter` | Audio EQ Cookbook designs in floats, magnitude and phase |
  | `ExAudio.Biquad` | coefficient quantisation, the direct form I kernel |
  | `ExAudio.Strip` | cascade of biquads, optionally gate and compressor |
  | `ExAudio.Dynamics` | envelope follower, gate, compressor/limiter, designs and float references |
  | `ExAudio.Meter` | peak hold and RMS meters |
  | `ExAudio.Matrix` | sparse crosspoint mixer: BEAM model and the kernel for one output row |
  | `ExAudio.Q` | formats, log2/exp2 tables, kernel specifications |
  | `ExAudio.Kernels` | the kernels as `mix ex_hdl.gen.sv` entries |

  Samples are 24-bit integers (Q1.23) in `s32` tensors. Every kernel comes
  with `spec/n`, a keyword list with the function, argument templates,
  `param_ranges:` (narrowing the tensors to what they hold, which the width
  check needs) and the initial state:

      iex> coef = ExAudio.Filter.design(:peaking, 1000, 48_000, q: 1.0, gain_db: 6)
      iex> spec = ExAudio.Biquad.spec(ExAudio.Biquad.quantize(coef))
      iex> {:ok, scan} = ExAudio.Q.analyze(spec, ii: :auto)
      iex> scan.loop_latency
      8
      iex> {:ok, design} = ExAudio.Q.to_sv(spec, name: "peq", ii: :auto)
      iex> {design.latency, design.in_width, design.out_width}
      {16, 32, 32}
  """
end

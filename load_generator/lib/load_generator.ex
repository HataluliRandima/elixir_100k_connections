defmodule LoadGenerator do
  @moduledoc """
  WebSocket load generator for the 100k-connections experiment.

  Run it with `mix load_test --connections 1000` (see `Mix.Tasks.LoadTest`).
  The moving parts:

    * `LoadGenerator.Config` - CLI options and safety checks
    * `LoadGenerator.Runner` - ramp-up, hold, teardown, sampling
    * `LoadGenerator.Client` - one process per simulated connection
    * `LoadGenerator.Stats` / `LoadGenerator.Histogram` - lock-free counters
    * `LoadGenerator.Report` - JSON and CSV results
  """
end

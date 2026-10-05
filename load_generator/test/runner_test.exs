defmodule LoadGenerator.RunnerTest do
  use ExUnit.Case, async: true

  alias LoadGenerator.{Config, Runner}

  test "ramp-up starts clients at a steady rate" do
    config = %Config{connections: 1_000, ramp_up_s: 10.0}

    assert Runner.due_started(config, 0) == 0
    assert Runner.due_started(config, 1_000) == 100
    assert Runner.due_started(config, 5_000) == 500
    assert Runner.due_started(config, 10_000) == 1_000
    assert Runner.due_started(config, 60_000) == 1_000
  end

  test "zero ramp-up starts everything at once" do
    assert Runner.due_started(%Config{connections: 50, ramp_up_s: 0.0}, 0) == 50
  end
end

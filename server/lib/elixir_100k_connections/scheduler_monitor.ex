defmodule Elixir100kConnections.SchedulerMonitor do
  @moduledoc """
  Samples BEAM scheduler utilization once per interval.

  `:scheduler.utilization/2` needs two samples taken some time apart. Instead
  of blocking the metrics request for that window, this process keeps the
  previous sample and remembers the utilization of the last completed window,
  which the metrics endpoint can read instantly.

  Utilization is the fraction of wall time the normal schedulers spent doing
  work. It is a better signal of BEAM saturation than OS CPU%, because idle
  schedulers busy-wait briefly before sleeping, which inflates OS CPU usage.

  The result is kept in this process's state rather than `:persistent_term`:
  updating a persistent term triggers a scan of every process on the node,
  which is exactly the wrong thing to do once per second with 100k+ processes.
  """

  use GenServer

  @default_interval_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the most recent utilization window, or `nil` before the first window
  has completed (or if the monitor is not running).
  """
  @spec latest(GenServer.server()) :: map() | nil
  def latest(server \\ __MODULE__) do
    GenServer.call(server, :latest)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    schedule(interval)
    {:ok, %{interval: interval, previous: :scheduler.sample(), latest: nil}}
  end

  @impl true
  def handle_call(:latest, _from, state), do: {:reply, state.latest, state}

  @impl true
  def handle_info(:sample, %{interval: interval, previous: previous} = state) do
    current = :scheduler.sample()
    latest = summarize(:scheduler.utilization(previous, current), interval)
    schedule(interval)
    {:noreply, %{state | previous: current, latest: latest}}
  end

  @doc false
  def summarize(utilization, interval) do
    per_scheduler =
      for {:normal, id, util, _percent} <- utilization do
        {id, Float.round(util, 4)}
      end

    {:total, total, _} = List.keyfind(utilization, :total, 0)

    %{
      window_ms: interval,
      total: Float.round(total, 4),
      per_scheduler: per_scheduler |> Enum.sort() |> Enum.map(&elem(&1, 1))
    }
  end

  defp schedule(interval), do: Process.send_after(self(), :sample, interval)
end

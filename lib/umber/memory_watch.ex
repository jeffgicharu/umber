defmodule Umber.MemoryWatch do
  @moduledoc """
  Distribution is off, so nobody can attach to the running app to see what is
  using its memory. Every ten seconds this looks at the total, and when it is
  over 150 MB it logs the five processes holding the most, with what they are
  and how many messages they have waiting, so the journal can tell us.
  """

  use GenServer
  require Logger

  @every 10_000
  @threshold 150 * 1024 * 1024
  @top 5

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :check, @every)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, @every)
    total = :erlang.memory(:total)
    if total > @threshold, do: report(total)
    {:noreply, state}
  end

  defp report(total) do
    top =
      Process.list()
      |> Enum.map(
        &{&1,
         Process.info(&1, [
           :memory,
           :message_queue_len,
           :registered_name,
           :initial_call,
           :dictionary,
           :current_function
         ])}
      )
      |> Enum.reject(fn {_, info} -> is_nil(info) end)
      |> Enum.sort_by(fn {_, info} -> -info[:memory] end)
      |> Enum.take(@top)
      |> Enum.map_join("; ", fn {pid, info} ->
        "#{inspect(pid)} #{div(info[:memory], 1024)} KB queue #{info[:message_queue_len]} #{describe(info)}"
      end)

    Logger.warning("memory #{div(total, 1024 * 1024)} MB; largest: #{top}")
  end

  defp describe(info) do
    name = if info[:registered_name] not in [nil, []], do: inspect(info[:registered_name])
    # LiveViews and other proc_lib processes record what they really are here.
    initial = get_in(info, [:dictionary, :"$initial_call"]) || info[:initial_call]
    name || inspect(initial) <> " in " <> inspect(info[:current_function])
  end
end

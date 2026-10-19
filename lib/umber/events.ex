defmodule Umber.Events do
  @moduledoc """
  Broadcasts that reach every running copy of the app.

  During a release two copies run side by side for a few seconds, each with its
  own visitors connected. Erlang distribution is off on the server, so instead
  of clustering them, every broadcast is delivered to this copy's subscribers
  at once and sent to the others through PostgreSQL NOTIFY. `Umber.Events.Listener`
  hears it there and delivers it locally.
  """

  @channel "umber_events"
  # NOTIFY payloads are limited to 8000 bytes.
  @max_payload 7_900

  def channel, do: @channel

  @doc """
  Subscribes the calling process to `topic`, once. Phoenix.PubSub registers a
  process again each time it subscribes, so a page that subscribed on every
  reload received each broadcast once per reload, reloaded once per copy and
  subscribed again: its mailbox doubled with every event. Subscribing twice
  is now a no-op.
  """
  def subscribe(topic) do
    key = {__MODULE__, :subscribed, topic}

    if Process.get(key) do
      :ok
    else
      :ok = Phoenix.PubSub.subscribe(Umber.PubSub, topic)
      Process.put(key, true)
      :ok
    end
  end

  def unsubscribe(topic) do
    Process.delete({__MODULE__, :subscribed, topic})
    Phoenix.PubSub.unsubscribe(Umber.PubSub, topic)
  end

  @doc "Delivers `message` to `topic` here and on every other running copy."
  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Umber.PubSub, topic, message)
    notify(topic, message)
    :ok
  end

  @doc "Several broadcasts in one notification, delivered in order."
  def broadcast_many([]), do: :ok

  def broadcast_many(pairs) do
    Enum.each(pairs, fn {topic, message} ->
      Phoenix.PubSub.broadcast(Umber.PubSub, topic, message)
    end)

    notify_many(pairs)
    :ok
  end

  @doc false
  def deliver_remote(payload) do
    me = origin()

    with {:ok, bin} <- Base.decode64(payload),
         {origin, pairs} when origin != me <- :erlang.binary_to_term(bin, [:safe]) do
      Enum.each(pairs, fn {topic, message} ->
        Phoenix.PubSub.local_broadcast(Umber.PubSub, topic, message)
      end)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def origin do
    case :persistent_term.get({__MODULE__, :origin}, nil) do
      nil ->
        id = :crypto.strong_rand_bytes(8)
        :persistent_term.put({__MODULE__, :origin}, id)
        id

      id ->
        id
    end
  end

  defp notify(topic, message), do: notify_many([{topic, message}])

  defp notify_many(pairs) do
    payload = {origin(), pairs} |> :erlang.term_to_binary() |> Base.encode64()

    if byte_size(payload) <= @max_payload and
         Application.get_env(:umber, :cross_node_events, true) do
      # Callers broadcast after their change is committed, so this is never
      # inside a transaction that could still roll back.
      Umber.Repo.query("SELECT pg_notify($1, $2)", [@channel, payload])
    end

    :ok
  end
end

defmodule Umber.Events.Listener do
  @moduledoc "Hears other copies' broadcasts on the PostgreSQL channel and delivers them here."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Umber.Events.origin()
    config = Umber.Repo.config() |> Keyword.drop([:pool, :pool_size, :name])
    {:ok, pid} = Postgrex.Notifications.start_link(config)
    {:ok, ref} = Postgrex.Notifications.listen(pid, Umber.Events.channel())
    {:ok, %{pid: pid, ref: ref}}
  end

  @impl true
  def handle_info({:notification, _pid, _ref, _channel, payload}, state) do
    Umber.Events.deliver_remote(payload)
    {:noreply, state}
  end
end

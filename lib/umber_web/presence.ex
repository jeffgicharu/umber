defmodule UmberWeb.Presence do
  @moduledoc "Who is in a live room, for the watcher count. Counted per copy of the app."
  use Phoenix.Presence, otp_app: :umber, pubsub_server: Umber.PubSub
end

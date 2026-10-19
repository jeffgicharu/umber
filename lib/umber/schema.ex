defmodule Umber.Schema do
  @moduledoc "Ecto.Schema with UTC timestamps to the microsecond, as every table uses."

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end

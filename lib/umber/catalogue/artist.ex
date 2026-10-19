defmodule Umber.Catalogue.Artist do
  use Umber.Schema

  schema "artists" do
    field :slug, :string
    field :name, :string
    field :born, :integer
    field :died, :integer
    field :founded, :integer
    field :period, :string
    field :nationality, :string
    field :based, :string
    field :discipline, :string
    field :bio, :string

    has_many :works, Umber.Catalogue.Work
    timestamps()
  end

  @doc "The dates shown after a name: (1958–2019), (b. 1979), (founded 2014) or a period."
  def dates(%__MODULE__{born: b, died: d}) when is_integer(b) and is_integer(d), do: "#{b}–#{d}"
  def dates(%__MODULE__{born: b}) when is_integer(b), do: "b. #{b}"
  def dates(%__MODULE__{founded: f}) when is_integer(f), do: "founded #{f}"
  def dates(%__MODULE__{period: p}) when is_binary(p), do: p
  def dates(_), do: nil

  @doc "Anonymous makers (a workshop, a region) are not people and read differently."
  def anonymous?(%__MODULE__{born: nil, founded: nil}), do: true
  def anonymous?(_), do: false
end

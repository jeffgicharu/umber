defmodule Umber.Catalogue.Work do
  use Umber.Schema

  schema "works" do
    field :slug, :string
    field :image, :string
    field :title, :string
    field :year, :string
    field :medium, :string
    field :height_cm, :decimal
    field :width_cm, :decimal
    field :depth_cm, :decimal
    field :dimensions_note, :string
    field :edition, :string
    field :description, :string
    field :condition, :string
    field :provenance, :string
    field :exhibited, :string
    field :literature, :string
    field :image_width, :integer
    field :image_height, :integer
    field :second_view, :map
    field :category, :string

    belongs_to :artist, Umber.Catalogue.Artist
    timestamps()
  end

  @doc "Dimensions as a catalogue prints them: 76 × 100 cm, or the maker's own note."
  def dimensions(%__MODULE__{dimensions_note: note}) when is_binary(note), do: note

  def dimensions(%__MODULE__{} = w) do
    [w.height_cm, w.width_cm, w.depth_cm]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" × ", &format_cm/1)
    |> Kernel.<>(" cm")
  end

  defp format_cm(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  def aspect(%__MODULE__{image_width: w, image_height: h}), do: w / h
end

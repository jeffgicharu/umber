defmodule UmberWeb.PageController do
  use UmberWeb, :controller

  alias UmberWeb.Meta

  @pages %{
    buy:
      {"How to buy at Umber",
       "How to register, bid live and online, leave a maximum, and pay and collect at Umber in Nairobi.",
       "/buy"},
    about:
      {"About Umber",
       "Umber is an auction house in Nairobi for modern and contemporary East African art and collectable design.",
       "/about"},
    visit:
      {"Visit and contact",
       "Viewing hours, directions to Umber House on Lenana Road, and how to reach the specialists.",
       "/visit"},
    conditions:
      {"Conditions of sale",
       "The terms on which Umber sells: bidding, the buyer's premium, VAT, payment and collection.",
       "/conditions"},
    privacy: {"Privacy", "What Umber keeps about bidders and consignors, and why.", "/privacy"},
    terms: {"Terms of use", "The terms for using Umber's website.", "/terms"}
  }

  for {action, _} <- @pages do
    def unquote(action)(conn, _params) do
      {title, description, path} = Map.fetch!(@pages, unquote(action))

      conn
      |> Meta.put(title: title, description: description, path: path)
      |> assign(:active, unquote(action))
      |> render(unquote(action))
    end
  end
end

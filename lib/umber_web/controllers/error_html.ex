defmodule UmberWeb.ErrorHTML do
  @moduledoc "Umber's own error pages."
  use UmberWeb, :html

  embed_templates "error_html/*"

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end

defmodule UmberWeb.CoreComponents do
  @moduledoc "Form fields and small pieces shared by every page."

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values:
      ~w(checkbox email hidden number password select tel text textarea url search datetime-local)

  attr :field, Phoenix.HTML.FormField, doc: "a form field struct, for example @form[:email]"
  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options for select inputs"

  attr :rest, :global,
    include:
      ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step inputmode enterkeyhint)

  slot :inner_block

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn ->
      if assigns.type == "select" && assigns[:rest][:multiple],
        do: field.name <> "[]",
        else: field.name
    end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class={["field", @errors != [] && "invalid"]}>
      <label class="check">
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        />
        <span>{@label}{render_slot(@inner_block)}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={["field", @errors != [] && "invalid"]}>
      <label :if={@label} for={@id}>{@label}</label>
      <select
        id={@id}
        name={@name}
        class="select"
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@hint && "#{@id}-hint"}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint && @errors == []} id={"#{@id}-hint"} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={["field", @errors != [] && "invalid"]}>
      <label :if={@label} for={@id}>{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class="textarea"
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@hint && "#{@id}-hint"}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint && @errors == []} id={"#{@id}-hint"} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class={["field", @errors != [] && "invalid"]}>
      <label :if={@label} for={@id}>{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class="input"
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@hint && "#{@id}-hint"}
        {@rest}
      />
      <p :if={@hint && @errors == []} id={"#{@id}-hint"} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="error-text">{render_slot(@inner_block)}</p>
    """
  end

  @doc "Heart-shaped watch toggle icon, drawn as a bookmark: a catalogue's ribbon."
  attr :filled, :boolean, default: false

  def ribbon(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path
        d="M4 1.5h8v13l-4-3-4 3z"
        fill={if @filled, do: "currentColor", else: "none"}
        stroke="currentColor"
        stroke-width="1.4"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  def show(js \\ %JS{}, selector),
    do: JS.show(js, to: selector, transition: {"fade-in", "opacity-0", "opacity-100"})

  def hide(js \\ %JS{}, selector), do: JS.hide(js, to: selector)
end

defmodule ConsensusWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  These are the generic building blocks — flash, button, input, header, table, list —
  restyled onto Consensus's hand-rolled "sticker" design system (see
  `docs/design/DESIGN-SPEC.md` and `assets/css/app.css`). daisyUI has been removed; every
  colour, shadow and radius here comes from the `@theme` tokens in `app.css`.

  The design-specific primitives that don't come from the Phoenix generator — cards, chips,
  pills, the step-progress wizard header, and so on — live in `ConsensusWeb.Sticker` instead.

  For icons, see `icon/1` below.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: ConsensusWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  A fixed, top-centred sticker card: mint for `:info`, tangerine for `:error`. Must keep
  working with `Layouts.flash_group/1`, which passes `id`, `kind`, `title`, `flash` and the
  `phx-disconnected`/`phx-connected`/`hidden` attributes used for the connection-error flashes.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed left-1/2 top-4 z-50 w-[calc(100%-2rem)] max-w-sm -translate-x-1/2",
        "flex items-start gap-3 rounded-2xl border-2 border-ink p-4 shadow-sticker-3",
        @kind == :info && "bg-mint text-ink",
        @kind == :error && "bg-tangerine text-white"
      ]}
      {@rest}
    >
      <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
      <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
      <div class="flex-1">
        <p :if={@title} class="font-bold leading-5">{@title}</p>
        <p class="text-sm font-semibold leading-5">{msg}</p>
      </div>
      <button
        type="button"
        class="shrink-0 cursor-pointer opacity-70 hover:opacity-100"
        aria-label={gettext("close")}
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  Three variants, all driven by `variant`: the default (no `variant`) is the white secondary
  chrome; `variant="primary"` is the tangerine forward action; `variant="ink"` is the
  ink-filled style used for "Copy link" in the share sheet. Disabled buttons drop their
  shadow and fade to 45% opacity — `.press-N` (see app.css) already no-ops once `:disabled`
  is set, so no extra class is needed for that half.

  `rest` also accepts an explicit `type` (e.g. `type="submit"`) so a caller can be precise
  about form semantics; when omitted the browser's own default applies (submit inside a
  `<.form>`, a no-op button outside one) exactly as before this component grew a design.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
      <.button variant="ink">Copy link</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)

  # `class` is **added to** the button's own classes, not swapped for them.
  #
  # The generator ships this as `assign_new(assigns, :class, ...)`, i.e. "the class to use
  # over defaults" — pass anything and every default disappears. In a design system where
  # the defaults *are* the button (2px ink border, hard shadow, press, variant fill), a
  # caller who wants `w-full` gets an unstyled `<button>` instead, with no error and no
  # warning. That trap cost real time here: the account screens ended up wrapping buttons
  # in `<div class="grid">` to get full width rather than fight it. Nothing in `lib/` was
  # relying on the override behaviour when this changed, precisely because it was unusable.
  attr :class, :any, default: nil, doc: "extra classes, appended to the button's own"
  attr :variant, :string, values: ~w(primary ink)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "bg-tangerine text-white shadow-sticker-4 press-4",
      "ink" => "bg-ink text-white hover:bg-ink-soft",
      nil => "bg-white shadow-sticker-2 press-2 hover:bg-yellow"
    }

    assigns =
      assign(assigns, :class, [
        "inline-flex items-center justify-center gap-2 rounded-2xl border-2 border-ink p-4",
        "font-bold text-base transition-colors",
        "disabled:cursor-not-allowed disabled:opacity-[45%] disabled:shadow-none",
        Map.fetch!(variants, assigns[:variant]),
        assigns[:class]
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "extra classes, appended to the input's own"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
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
    <div class="mb-2">
      <label for={@id} class="inline-flex cursor-pointer items-start gap-2.5">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="relative mt-0.5 inline-grid size-[22px] shrink-0 place-items-center">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={
              [
                # `class` is appended, not substituted — see the note on `button/1`.
                "peer absolute inset-0 size-[22px] cursor-pointer appearance-none rounded-md border-2 border-ink bg-white checked:bg-mint focus-visible:outline-2 focus-visible:outline-violet focus-visible:outline-offset-2 disabled:cursor-not-allowed disabled:opacity-[45%]",
                @class
              ]
            }
            {@rest}
          />
          <.icon
            name="hero-check"
            class="pointer-events-none relative hidden size-[15px] text-ink peer-checked:block"
          />
        </span>
        <span class="text-sm font-semibold text-ink">{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-2 flex flex-col gap-1.5">
      <label for={@id} class="flex flex-col gap-1.5">
        <span :if={@label} class="eyebrow">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={
            [
              # `class` is appended, not substituted — see the note on `button/1`.
              "w-full rounded-2xl border-2 border-ink bg-white px-4 py-3.5 font-semibold shadow-field",
              @class,
              @errors != [] && (@error_class || "border-tangerine")
            ]
          }
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-2 flex flex-col gap-1.5">
      <label for={@id} class="flex flex-col gap-1.5">
        <span :if={@label} class="eyebrow">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={
            [
              # `class` is appended, not substituted — see the note on `button/1`.
              "min-h-[74px] w-full rounded-2xl border-2 border-ink bg-white px-4 py-3.5 text-[13.5px] font-normal leading-[1.45] shadow-field",
              @class,
              @errors != [] && (@error_class || "border-tangerine")
            ]
          }
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="mb-2 flex flex-col gap-1.5">
      <label for={@id} class="flex flex-col gap-1.5">
        <span :if={@label} class="eyebrow">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={
            [
              # `class` is appended, not substituted — see the note on `button/1`.
              "w-full rounded-2xl border-2 border-ink bg-white px-4 py-3.5 font-semibold shadow-field placeholder:text-faint",
              @class,
              @errors != [] && (@error_class || "border-tangerine")
            ]
          }
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-1.5 text-[11.5px] font-semibold text-tangerine">
      <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-bold leading-8 text-ink">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  Ink-bordered, `shadow-sticker-2` rows with `font-mono` uppercase column headers. Used by
  the admin user list.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <%!-- The table scrolls inside its own box so a wide row never makes the whole
          page scroll sideways on a narrow screen. --%>
    <div class="overflow-x-auto">
      <table class="w-full border-separate border-spacing-y-2">
        <thead>
          <tr>
            <th
              :for={col <- @col}
              class="px-4 pb-1 text-left font-mono text-[10.5px] font-semibold uppercase tracking-[0.06em] text-muted"
            >
              {col[:label]}
            </th>
            <th :if={@action != []} class="px-4 pb-1">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="rounded-2xl border-2 border-ink bg-white shadow-sticker-2"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[
                "px-4 py-3 font-semibold text-ink first:rounded-l-2xl last:rounded-r-2xl",
                @row_click && "cursor-pointer"
              ]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 px-4 py-3 font-semibold last:rounded-r-2xl">
              <div class="flex gap-3">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="flex flex-col gap-2">
      <li
        :for={item <- @item}
        class="flex items-center justify-between gap-4 rounded-2xl border-2 border-ink bg-white px-4 py-3 shadow-sticker-2"
      >
        <div>
          <div class="font-mono text-[10.5px] font-semibold uppercase tracking-[0.06em] text-muted">
            {item.title}
          </div>
          <div class="font-semibold text-ink">{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(ConsensusWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(ConsensusWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end

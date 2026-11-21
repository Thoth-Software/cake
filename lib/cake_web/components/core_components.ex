defmodule CakeWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: CakeWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

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

  @spec flash(map()) :: Phoenix.LiveView.Rendered.t()
  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-bottom toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  @spec button(map()) :: Phoenix.LiveView.Rendered.t()
  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

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
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  @spec input(map()) :: Phoenix.LiveView.Rendered.t()
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
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
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
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
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
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
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
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  # Not in the generator's file: the 1.7 header took a class (#374). The
  # auth pages passed one to centre theirs until #377; no page does now.
  attr :class, :any, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  @spec header(map()) :: Phoenix.LiveView.Rendered.t()
  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4", @class]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>

  A column may carry a `class`, which goes on its heading and on each of its
  cells. It is there for a column a phone has no room for (not in the
  generator's file, #380):

      <:col :let={user} label="Created" class="hidden sm:table-cell">{user.inserted_at}</:col>
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
    attr :class, :string, doc: "classes for the column's heading and each of its cells"
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  @spec table(map()) :: Phoenix.LiveView.Rendered.t()
  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col} class={col[:class]}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={[col[:class], @row_click && "hover:cursor-pointer"]}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
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

  @spec list(map()) :: Phoenix.LiveView.Rendered.t()
  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders an ingestion status as a badge: pending, processing, completed or
  failed, as `Cake.Books.ParsedBook`'s `embedding_status` has them.

  Every screen that shows a document's status uses this, so that a status
  reads and is coloured the same everywhere: done is `badge-success`, under
  way `badge-warning`, failed `badge-error` and not started `badge-ghost`.
  The badge shows the status it is given and nothing else.

  ## Examples

      <.status_badge status={@parsed_book.embedding_status} />
  """
  attr :id, :string, default: nil
  attr :status, :atom, required: true, values: [:pending, :processing, :completed, :failed]

  @spec status_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badge(assigns) do
    ~H"""
    <span id={@id} data-part="status" class={["badge badge-soft", status_class(@status)]}>
      {status_label(@status)}
    </span>
    """
  end

  # The class names are spelled out in full: Tailwind keeps only the classes
  # it finds written in the source.
  defp status_class(:pending), do: "badge-ghost"
  defp status_class(:processing), do: "badge-warning"
  defp status_class(:completed), do: "badge-success"
  defp status_class(:failed), do: "badge-error"

  defp status_label(:pending), do: "Pending"
  defp status_label(:processing), do: "Processing"
  defp status_label(:completed), do: "Completed"
  defp status_label(:failed), do: "Failed"

  @doc """
  Renders the empty state of a screen or a list: an icon, one sentence and,
  optionally, what to do about it.

  Every screen with nothing to show yet uses this, so that an empty chat, an
  empty document list and a search with no matches look alike.

  ## Examples

      <.empty_state id="no-documents">Nothing has been uploaded yet.</.empty_state>

      <.empty_state id="no-documents" icon="hero-document">
        Nothing has been uploaded yet.
        <:action><.link navigate={~p"/upload"} class="link link-primary">Upload a document</.link></:action>
      </.empty_state>
  """
  attr :id, :string, default: nil
  attr :icon, :string, default: "hero-inbox", doc: "a Heroicon name, as `icon/1` takes"

  slot :inner_block, required: true, doc: "the sentence"
  slot :action, doc: "a link or a button to what fills the screen"

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col items-center gap-3 px-4 py-10 text-center text-base-content/70">
      <.icon name={@icon} class="size-10 opacity-60" />
      <%!-- The sentence may quote what the user typed: a long unbroken
      word wraps instead of pushing the page sideways. --%>
      <p class="max-w-full wrap-anywhere">{render_slot(@inner_block)}</p>
      <div :if={@action != []} data-part="action">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  Renders a line saying that something is under way, beside an indicator
  that shows no progress: searching, retrieving, ingesting.

  The line is marked as a status (`role="status"`) and the indicator, which
  is decoration, is hidden from a screen reader. Whether the line is spoken
  when it appears depends on the screen reader: a status that is put on the
  page with its text already in it is not announced by all of them. That has
  not been checked with one.

  ## Examples

      <.working :if={@loading} id="search-loading">Searching...</.working>
  """
  attr :id, :string, default: nil

  slot :inner_block, required: true, doc: "what is under way"

  @spec working(map()) :: Phoenix.LiveView.Rendered.t()
  def working(assigns) do
    ~H"""
    <div id={@id} role="status" class="flex items-center gap-2 text-base-content/70">
      <span
        data-part="indicator"
        class="loading loading-spinner loading-sm shrink-0"
        aria-hidden="true"
      >
      </span>
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc """
  Renders a message that is part of a page: something to know, something
  that worked, a warning, or an error.

  `flash/1` is for the passing message after an action, which the user
  dismisses. A notice stays where the page puts it. An error or a warning is
  marked as an alert (`role="alert"`), which a screen reader speaks at once;
  information and success are marked as a status, with the caveat `working/1`
  describes.

  ## Examples

      <.notice :if={@error} id="search-error" kind={:error}>{@error}</.notice>

      <.notice id="rejected-archives" kind={:warning} title="These archives were not ingested">
        ...
      </.notice>
  """
  attr :id, :string, default: nil
  attr :kind, :atom, values: [:info, :success, :warning, :error], default: :info
  attr :title, :string, default: nil

  slot :inner_block, required: true, doc: "the message"

  @spec notice(map()) :: Phoenix.LiveView.Rendered.t()
  def notice(assigns) do
    ~H"""
    <div id={@id} role={notice_role(@kind)} class={["alert", notice_class(@kind)]}>
      <.icon name={notice_icon(@kind)} class="size-5 shrink-0" />
      <div class="min-w-0">
        <p :if={@title} data-part="title" class="font-semibold">{@title}</p>
        <div data-part="body">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  # The class names are spelled out in full: Tailwind keeps only the classes
  # it finds written in the source.
  defp notice_class(:info), do: "alert-info"
  defp notice_class(:success), do: "alert-success"
  defp notice_class(:warning), do: "alert-warning"
  defp notice_class(:error), do: "alert-error"

  defp notice_role(kind) when kind in [:warning, :error], do: "alert"
  defp notice_role(kind) when kind in [:info, :success], do: "status"

  defp notice_icon(:info), do: "hero-information-circle"
  defp notice_icon(:success), do: "hero-check-circle"
  defp notice_icon(:warning), do: "hero-exclamation-triangle"
  defp notice_icon(:error), do: "hero-exclamation-circle"

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

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  @spec show(Phoenix.LiveView.JS.t(), String.t()) :: Phoenix.LiveView.JS.t()
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

  @spec hide(Phoenix.LiveView.JS.t(), String.t()) :: Phoenix.LiveView.JS.t()
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
  @spec translate_error({String.t(), keyword()}) :: String.t()
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
      Gettext.dngettext(CakeWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(CakeWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  @spec translate_errors(keyword(), atom()) :: [String.t()]
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end

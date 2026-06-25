defmodule Dialup.Page do
  import Phoenix.Component, only: [render_slot: 1, sigil_H: 2]

  @moduledoc """
  The behaviour and macro for Dialup page modules.

  A page module handles a single route. Place it at the appropriate path under your
  `app_dir` and it will be routed automatically:

      # lib/app/page.ex         → /
      # lib/app/blog/[slug]/page.ex → /blog/:slug

  ## Usage

      defmodule MyApp.App.Page do
        use Dialup.Page

        def mount(_params, assigns) do
          {:ok, Map.put(assigns, :count, 0)}
        end

        def handle_event("increment", _, assigns) do
          {:update, Map.update!(assigns, :count, &(&1 + 1))}
        end

        def render(assigns) do
          ~H\"\"\"
          <h1>Count: {@count}</h1>
          <button ws-event="increment">+1</button>
          \"\"\"
        end
      end

  ## Callbacks

  - `mount/2` — called on every page navigation. Receives URL params and the current assigns
    (which already include session data set by layouts). Return `{:ok, new_assigns}`.
    Defining `mount/1` (assigns only) is also accepted as a convenience.
  - `render/1` — renders the page HTML using HEEx.
  - `handle_event/3` — called when a `ws-event`, `ws-submit`, or `ws-change` fires.
  - `handle_info/2` — called for Erlang process messages (e.g. PubSub, timers).
  - `page_title/1` — optional; return a string to set `<title>`. Return `nil` to use the
    application default.
  - `agent_state/1` — returns the allowlisted state projection visible to an attached agent.
  - `agent_message/1` — explains the page concept, operating flow, and safety constraints
    to an agent that has no source-code context.
  - `agent_grant/1` — defines capabilities, projections, expiry, and version requirements
    for HTTP MCP session tokens.

  ## Human and agent projections

  Use `<.dialup_action>` instead of a plain event button when the same operation should be
  available to an attached agent. Use `<.dialup_region>` for stable domain areas that need
  a semantic name, structured data, or action relationships.

  `<.dialup_action>` is the single boundary for what an agent can do: raw `ws-event`,
  `ws-submit`, `ws-change`, and `ws-href` elements are never auto-exposed as tools. To make a
  navigation link agent-operable, declare it with `<.dialup_action navigate="/path">`; the same
  declaration renders the human link and generates the navigation tool.

  Ordinary visible DOM elements remain available for human spatial references, but their
  generated selectors are less stable than region IDs. See
  `guides/agent-native-app-development.md` for the complete implementation workflow.

  ## Return values for `handle_event/3` and `handle_info/2`

  | Return value | Effect |
  |---|---|
  | `{:noreply, assigns}` | Update state, no re-render |
  | `{:update, assigns}` | Re-render the full page |
  | `{:patch, id, html, assigns}` | Replace only the element with the given `id` |
  | `{:redirect, path, assigns}` | Navigate to another page (session is preserved) |
  | `{:push_event, name, payload, assigns}` | Call a JS hook function and re-render |

  ## Module attributes

  - `@layout false` — disable all layout wrapping (useful for login/fullscreen pages).
  - `@static true` — serve the page without establishing a WebSocket connection.

  ## Colocation CSS

  Place a `page.css` file in the same directory as `page.ex`. It is automatically scoped
  to the page at compile time (no build tool required).

  ## Helpers

  `use Dialup.Page` imports `overwrite/2`, `set_default/2`, `subscribe/2`,
  `declare_action/1`, `declare_region/1`, `dialup_action/1`, and `dialup_region/1`.
  """

  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  # params: URLパラメータ
  # assigns: session の内容（current_user 等を読み取り可能）
  # 返り値の map が page assigns になる（session キーは自動的に除外される）
  @callback mount(params :: map(), assigns :: map()) :: {:ok, map()}
  @callback mount(assigns :: map()) :: {:ok, map()}

  # 再描画なし（状態のみ更新）
  @callback handle_event(event :: binary(), value :: any(), assigns :: map()) ::
              {:noreply, map()}
              | {:update, map()}
              | {:patch, target :: binary(), rendered :: any(), map()}
              | {:redirect, path :: binary(), map()}
              | {:push_event, event_name :: binary(), payload :: map(), map()}

  @callback handle_info(msg :: any(), assigns :: map()) ::
              {:noreply, map()}
              | {:update, map()}
              | {:patch, target :: binary(), rendered :: any(), map()}
              | {:redirect, path :: binary(), map()}
              | {:push_event, event_name :: binary(), payload :: map(), map()}

  # ページタイトルを動的に設定するためのオプショナルコールバック
  @callback page_title(assigns :: map()) :: binary() | nil
  @callback agent_state(assigns :: map()) :: map()
  @callback agent_grant(assigns :: map()) :: map() | keyword()
  @callback agent_message(assigns :: map()) :: binary() | map()

  @optional_callbacks mount: 1,
                      handle_info: 2,
                      page_title: 1,
                      agent_state: 1,
                      agent_grant: 1,
                      agent_message: 1

  @doc """
  Declares an action that is available to both the browser UI and an attached agent.

      declare_action name: :increment,
                     desc: "Increment the counter",
                     params: %{amount: {:integer, default: 1}}
  """
  defmacro declare_action(opts) do
    {opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)

    quote do
      @dialup_actions unquote(Macro.escape(Map.new(opts)))
    end
  end

  @doc """
  Declares a semantic region that an attached agent can reference.
  """
  defmacro declare_region(opts) do
    {opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)

    quote do
      @dialup_regions unquote(Macro.escape(Map.new(opts)))
    end
  end

  @doc """
  Renders an action button and serializes extra component attributes as event parameters.

      <.dialup_action name={:add_item} available={@status == :draft} sku="SKU-1" qty="1">
        Add item
      </.dialup_action>

  Pass `navigate` to render a navigation link instead of an event button. The same
  declaration becomes a navigation tool for an attached agent, so the agent can move
  between pages exactly where a human can click:

      <.dialup_action navigate="/docs/concepts">Concepts</.dialup_action>

  Navigation actions take no parameters; the destination is fixed at the declaration
  site. When `name` is omitted it is derived from the path (e.g. `/docs/concepts`
  becomes `:navigate_docs__concepts`).
  """
  def dialup_action(%{navigate: navigate} = assigns) when is_binary(navigate) do
    name =
      case Map.get(assigns, :name) do
        nil -> navigate_action_name(navigate)
        explicit -> explicit
      end
      |> to_string()

    assigns =
      assigns
      |> Phoenix.Component.assign(:action_name, name)
      |> Phoenix.Component.assign(:navigate_to, navigate)
      |> Phoenix.Component.assign(:available, Map.get(assigns, :available, true))
      |> Phoenix.Component.assign(:action_desc, Map.get(assigns, :desc))
      |> Phoenix.Component.assign_new(:class, fn -> nil end)
      |> Phoenix.Component.assign_new(:id, fn -> nil end)

    ~H"""
    <a
      id={@id}
      class={@class}
      href={@navigate_to}
      ws-href={@navigate_to}
      data-dialup-id={@action_name}
      data-dialup-kind="navigate"
      data-dialup-desc={@action_desc}
      aria-disabled={to_string(!@available)}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  def dialup_action(assigns) do
    name = assigns |> Map.fetch!(:name) |> to_string()
    available = Map.get(assigns, :available, true)
    confirm = Map.get(assigns, :confirm)

    params =
      assigns
      |> Map.drop([
        :__changed__,
        :inner_block,
        :name,
        :available,
        :confirm,
        :desc,
        :params,
        :agent_only,
        :risk,
        :effects,
        :reversible,
        :idempotent,
        :examples,
        :success,
        :class,
        :id,
        :type,
        :navigate
      ])
      |> Jason.encode!()

    assigns =
      assigns
      |> Phoenix.Component.assign(:action_name, name)
      |> Phoenix.Component.assign(:available, available)
      |> Phoenix.Component.assign(:confirm_name, confirm && to_string(confirm))
      |> Phoenix.Component.assign(:action_desc, Map.get(assigns, :desc))
      |> Phoenix.Component.assign(:encoded_params, params)
      |> Phoenix.Component.assign_new(:class, fn -> nil end)
      |> Phoenix.Component.assign_new(:id, fn -> nil end)
      |> Phoenix.Component.assign_new(:type, fn -> "button" end)

    ~H"""
    <button
      id={@id}
      type={@type}
      class={@class}
      ws-event={@action_name}
      data-dialup-id={@action_name}
      data-dialup-kind="action"
      data-dialup-params={@encoded_params}
      data-dialup-confirm={@confirm_name}
      data-dialup-desc={@action_desc}
      disabled={!@available}
      aria-disabled={to_string(!@available)}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Derives the canonical navigation action name for an app path.

  `/docs/concepts` becomes `:navigate_docs__concepts` and `/` becomes `:navigate_root`.
  Path segments are joined with `__` so `/foo-bar` and `/foo/bar` stay distinct.
  """
  def navigate_action_name(path) when is_binary(path) do
    trimmed = String.trim(path, "/")

    slug =
      if trimmed == "" do
        "root"
      else
        trimmed
        |> String.split("/")
        |> Enum.map(&segment_slug/1)
        |> Enum.join("__")
      end

    String.to_atom("navigate_" <> slug)
  end

  defp segment_slug(segment) do
    segment
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
  end

  @doc """
  Wraps content in a semantic region that agents can read through `read_scene`.
  """
  def dialup_region(assigns) do
    assigns =
      assigns
      |> Phoenix.Component.assign(:region_name, assigns.name |> to_string())
      |> Phoenix.Component.assign_new(:role, fn -> nil end)
      |> Phoenix.Component.assign_new(:desc, fn -> nil end)
      |> Phoenix.Component.assign_new(:class, fn -> nil end)
      |> Phoenix.Component.assign_new(:id, fn -> nil end)

    ~H"""
    <section
      id={@id}
      class={@class}
      role={@role}
      data-dialup-id={@region_name}
      data-dialup-kind="region"
      data-dialup-desc={@desc}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Merges `overwrite_map` into `assigns`, replacing any existing keys.

      assigns |> overwrite(%{user: user, loaded: true})
  """
  def overwrite(assigns, overwrite) when is_map(assigns) and is_map(overwrite) do
    Map.merge(assigns, overwrite)
  end

  @doc """
  Merges `defaults` into `assigns`, keeping existing values for keys that are already set.

      assigns |> set_default(%{count: 0, page: 1})
  """
  def set_default(assigns, defaults) when is_map(assigns) and is_map(defaults) do
    Map.merge(defaults, assigns)
  end

  @doc """
  Subscribes to a `Phoenix.PubSub` topic and registers it for automatic unsubscription
  on page navigation.

  Call this inside `mount/2` to ensure the subscription is cleaned up when the user
  navigates away.

      def mount(_params, assigns) do
        subscribe(MyApp.PubSub, "room:lobby")
        {:ok, %{messages: []}}
      end
  """
  def subscribe(pubsub, topic) do
    Phoenix.PubSub.subscribe(pubsub, topic)
    subs = Process.get(:dialup_subscriptions, [])
    Process.put(:dialup_subscriptions, [{pubsub, topic} | subs])
    :ok
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Dialup.Page

      import Phoenix.Component
      import Phoenix.HTML, only: [raw: 1]

      # ローカルでの使用も可能に（import）
      import Dialup.Page,
        only: [
          overwrite: 2,
          set_default: 2,
          subscribe: 2,
          declare_action: 1,
          declare_region: 1,
          dialup_action: 1,
          dialup_region: 1
        ]

      Module.register_attribute(__MODULE__, :dialup_actions, accumulate: true)
      Module.register_attribute(__MODULE__, :dialup_regions, accumulate: true)

      # デフォルト実装
      def handle_event(_event, _value, assigns), do: {:noreply, assigns}
      def handle_info(_msg, assigns), do: {:noreply, assigns}
      def page_title(_assigns), do: nil
      def agent_state(_assigns), do: %{}

      def agent_message(_assigns) do
        %{
          purpose: "This Dialup page exposes MCP tools generated from its UI declarations.",
          instructions: [
            "Read the semantic scene before acting.",
            "Use the returned state version for every mutating action.",
            "Actions marked confirm=human return an isError tool result over HTTP MCP."
          ]
        }
      end

      def agent_grant(_assigns) do
        %{
          capabilities: :all,
          projections: [:state, :regions, :actions],
          expires_in: :timer.minutes(15),
          require_version: true
        }
      end

      defoverridable handle_event: 3,
                     handle_info: 2,
                     page_title: 1,
                     agent_state: 1,
                     agent_grant: 1,
                     agent_message: 1

      @before_compile Dialup.Page
    end
  end

  defmacro __before_compile__(env) do
    template_path = env.file |> Path.rootname(".ex") |> Kernel.<>(".html.heex")
    has_render = Module.defines?(env.module, {:render, 1})
    has_template = File.exists?(template_path)

    # mount/1 と mount/2 の定義をチェック
    has_mount_1 = Module.defines?(env.module, {:mount, 1})
    has_mount_2 = Module.defines?(env.module, {:mount, 2})

    # mount関数の生成
    mount_quote =
      cond do
        has_mount_2 ->
          quote do
            # mount/2 が定義済み
          end

        # mount/2 ラッパーを生成
        has_mount_1 and not has_mount_2 ->
          quote do
            def mount(_params, assigns) do
              mount(assigns)
            end
          end

        # デフォルトの mount/2 を生成
        true ->
          quote do
            def mount(_params, assigns), do: {:ok, assigns}
          end
      end

    # テンプレート用のrender関数
    render_quote =
      cond do
        has_render ->
          quote do
            # render/1 が定義済み
          end

        has_template ->
          source = File.read!(template_path)

          compiled =
            EEx.compile_string(source,
              engine: Phoenix.LiveView.TagEngine,
              line: 1,
              file: template_path,
              caller: __CALLER__,
              source: source,
              tag_handler: Phoenix.LiveView.HTMLEngine
            )

          quote do
            @external_resource unquote(template_path)

            def render(assigns) do
              _ = assigns
              unquote(compiled)
            end
          end

        true ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "#{inspect(env.module)} must define render/1 or provide #{Path.basename(template_path)}"
      end

    css_path = env.file |> Path.rootname(".ex") |> Kernel.<>(".css")

    css_quote =
      if File.exists?(css_path) do
        css_content = File.read!(css_path)

        scope_class =
          "d-" <>
            (env.module
             |> Atom.to_string()
             |> :erlang.md5()
             |> Base.encode16(case: :lower)
             |> binary_part(0, 7))

        scoped_css = ".#{scope_class} {\n#{css_content}\n}"

        quote do
          @external_resource unquote(css_path)
          def __css__, do: unquote(scoped_css)
          def __css_scope__, do: unquote(scope_class)
        end
      else
        quote do
          def __css__, do: nil
          def __css_scope__, do: nil
        end
      end

    use_layout = Module.get_attribute(env.module, :layout, true)
    actions = actions_from_env(env)
    declared_regions = env.module |> Module.get_attribute(:dialup_regions, []) |> Enum.reverse()
    regions = merge_regions!(env, declared_regions, extract_inline_regions!(env))
    validate_semantic_declarations!(env, actions, regions)

    layout_quote =
      quote do
        def __layout__, do: unquote(use_layout)
      end

    quote do
      unquote(mount_quote)
      unquote(render_quote)
      unquote(css_quote)
      unquote(layout_quote)
      def __dialup_actions__, do: unquote(Macro.escape(actions))
      def __dialup_regions__, do: unquote(Macro.escape(regions))
    end
  end

  @doc false
  def actions_from_env(env) do
    declared = env.module |> Module.get_attribute(:dialup_actions, []) |> Enum.reverse()
    merge_actions!(env, declared, extract_inline_actions!(env))
  end

  @doc false
  def validate_navigation_actions!(env, actions) do
    validate_unique!(env, actions, "action")

    Enum.each(actions, fn action ->
      for key <- [:name, :desc, :params], not Map.has_key?(action, key) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "Dialup action is missing required #{inspect(key)} metadata"
      end

      unless Map.has_key?(action, :navigate) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "layouts only support navigation actions; declare #{inspect(action.name)} with " <>
              "<.dialup_action navigate=\"/path\"> (event-handling actions belong on a page)"
      end
    end)
  end

  defp validate_semantic_declarations!(env, actions, regions) do
    validate_unique!(env, actions, "action")
    validate_unique!(env, regions, "region")
    validate_navigate_paths!(env, actions)

    Enum.each(actions, fn action ->
      for key <- [:name, :desc, :params], not Map.has_key?(action, key) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "Dialup action is missing required #{inspect(key)} metadata"
      end
    end)

    Enum.each(regions, fn region ->
      for key <- [:name, :role, :desc], not Map.has_key?(region, key) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "Dialup region is missing required #{inspect(key)} metadata"
      end
    end)

    validate_rendered_actions!(env, actions)
  end

  defp validate_unique!(env, declarations, kind) do
    names = Enum.map(declarations, &Map.get(&1, :name))
    duplicates = names -- Enum.uniq(names)

    if duplicates != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "duplicate Dialup #{kind} declarations: #{inspect(Enum.uniq(duplicates))}"
    end
  end

  defp validate_navigate_paths!(env, actions) do
    navigates = Enum.filter(actions, &Map.has_key?(&1, :navigate))

    collisions =
      navigates
      |> Enum.group_by(& &1.name)
      |> Enum.flat_map(fn {name, group} ->
        paths = group |> Enum.map(& &1.navigate) |> Enum.uniq()

        if length(paths) > 1 do
          [{name, paths}]
        else
          []
        end
      end)

    if collisions != [] do
      {name, paths} = hd(collisions)

      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "conflicting navigate paths for action #{inspect(name)}: #{inspect(paths)}. " <>
            "Use distinct paths or explicit name={...} overrides."
    end
  end

  defp validate_rendered_actions!(env, actions) do
    rendered =
      env
      |> semantic_source()
      |> component_openings("<.dialup_action")
      |> Enum.map(&component_action_name!(&1, env))
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    declared = actions |> Enum.map(&to_string(&1.name)) |> MapSet.new()
    undeclared = MapSet.difference(rendered, declared) |> MapSet.to_list()

    if undeclared != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "rendered Dialup actions are not declared: #{inspect(undeclared)}"
    end

    missing =
      actions
      |> Enum.reject(&Map.get(&1, :agent_only, false))
      |> Enum.map(&to_string(&1.name))
      |> Enum.reject(&MapSet.member?(rendered, &1))

    if missing != [] do
      IO.warn(
        "Dialup actions are declared but not rendered; add agent_only: true if intentional: #{inspect(missing)}",
        Macro.Env.stacktrace(env)
      )
    end
  end

  defp extract_inline_actions!(env) do
    env
    |> semantic_source()
    |> component_openings("<.dialup_action")
    |> Enum.flat_map(fn attrs ->
      navigate = component_attr(attrs, "navigate", env)
      name = component_action_name!(attrs, env)
      desc = component_attr(attrs, "desc", env)
      params = component_attr(attrs, "params", env)

      cond do
        not is_nil(navigate) ->
          [navigate_declaration(attrs, env, name, navigate, desc)]

        is_nil(desc) and is_nil(params) ->
          []

        is_nil(desc) or is_nil(params) ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description: "inline Dialup action #{inspect(name)} must provide both desc and params"

        true ->
          [
            %{
              name: name,
              desc: desc,
              params: params,
              confirm: component_attr(attrs, "confirm", env),
              agent_only: component_attr(attrs, "agent_only", env) || false,
              risk: component_attr(attrs, "risk", env),
              effects: component_attr(attrs, "effects", env),
              reversible: component_attr(attrs, "reversible", env),
              idempotent: component_attr(attrs, "idempotent", env),
              examples: component_attr(attrs, "examples", env),
              success: component_attr(attrs, "success", env)
            }
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)
            |> Map.new()
          ]
      end
    end)
  end

  defp navigate_declaration(attrs, env, name, navigate, desc) do
    %{
      name: name,
      navigate: navigate,
      desc: desc || "Open #{navigate}",
      params: %{},
      confirm: component_attr(attrs, "confirm", env),
      risk: component_attr(attrs, "risk", env),
      effects: component_attr(attrs, "effects", env)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp extract_inline_regions!(env) do
    env
    |> semantic_source()
    |> component_openings("<.dialup_region")
    |> Enum.map(fn attrs ->
      name = required_component_name!(attrs, env)
      role = component_attr(attrs, "role", env)
      desc = component_attr(attrs, "desc", env)

      if is_nil(role) or is_nil(desc) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "inline Dialup region #{inspect(name)} must provide compile-time role and desc"
      end

      %{
        name: name,
        role: role,
        desc: desc,
        data: component_attr(attrs, "data", env),
        actions: component_attr(attrs, "actions", env),
        parent: component_attr(attrs, "parent", env)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp merge_actions!(env, declared, inline) do
    declared_names = MapSet.new(declared, & &1.name)
    conflicts = inline |> Enum.map(& &1.name) |> Enum.filter(&MapSet.member?(declared_names, &1))

    if conflicts != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "Dialup action metadata is defined both inline and with declare_action: #{inspect(Enum.uniq(conflicts))}"
    end

    declared ++ inline
  end

  defp merge_regions!(env, declared, inline) do
    Enum.reduce(inline, declared, fn region, acc ->
      case Enum.find_index(acc, &(&1.name == region.name)) do
        nil ->
          acc ++ [region]

        index ->
          existing = Enum.at(acc, index)

          if existing.role != region.role or existing.desc != region.desc do
            raise CompileError,
              file: env.file,
              line: env.line,
              description: "conflicting Dialup region metadata for #{inspect(region.name)}"
          end

          List.replace_at(acc, index, Map.merge(region, existing))
      end
    end)
  end

  defp semantic_source(env) do
    template_path = env.file |> Path.rootname(".ex") |> Kernel.<>(".html.heex")

    File.read!(env.file) <>
      if(File.exists?(template_path), do: File.read!(template_path), else: "")
  end

  defp component_openings(source, marker), do: component_openings(source, marker, [])

  defp component_openings(source, marker, acc) do
    case :binary.match(source, marker) do
      :nomatch ->
        Enum.reverse(acc)

      {index, length} ->
        rest = binary_part(source, index + length, byte_size(source) - index - length)
        {attrs, remainder} = take_opening(rest, 0, nil, [])
        component_openings(remainder, marker, [attrs | acc])
    end
  end

  defp take_opening(<<>>, _depth, _quote, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp take_opening(<<char::utf8, rest::binary>>, depth, quote, acc) do
    cond do
      quote && char == quote ->
        take_opening(rest, depth, nil, [<<char::utf8>> | acc])

      quote ->
        take_opening(rest, depth, quote, [<<char::utf8>> | acc])

      char in [?", ?'] ->
        take_opening(rest, depth, char, [<<char::utf8>> | acc])

      char == ?{ ->
        take_opening(rest, depth + 1, nil, ["{" | acc])

      char == ?} ->
        take_opening(rest, max(depth - 1, 0), nil, ["}" | acc])

      char == ?> and depth == 0 ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

      true ->
        take_opening(rest, depth, nil, [<<char::utf8>> | acc])
    end
  end

  defp required_component_name!(attrs, env) do
    case component_attr(attrs, "name", env) do
      nil ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "Dialup action name must be a compile-time constant"

      name ->
        name
    end
  end

  # Like required_component_name!/2, but derives the name from a navigate target
  # when no explicit name is given.
  defp component_action_name!(attrs, env) do
    case component_attr(attrs, "name", env) do
      nil ->
        case component_attr(attrs, "navigate", env) do
          path when is_binary(path) ->
            navigate_action_name(path)

          nil ->
            raise CompileError,
              file: env.file,
              line: env.line,
              description: "Dialup action must provide a compile-time name or navigate target"

          _other ->
            raise CompileError,
              file: env.file,
              line: env.line,
              description: "Dialup action navigate target must be a compile-time string"
        end

      name ->
        name
    end
  end

  defp component_attr(attrs, key, env) do
    braced = ~r/\b#{Regex.escape(key)}\s*=\s*\{/

    case Regex.run(braced, attrs, return: :index) do
      [{start, length}] ->
        expression_and_rest =
          binary_part(attrs, start + length, byte_size(attrs) - start - length)

        {expression, _rest} = take_expression(expression_and_rest, 1, nil, [])
        {value, _binding} = Code.eval_string(expression, [], env)
        value

      nil ->
        quoted = ~r/\b#{Regex.escape(key)}\s*=\s*"([^"]*)"/

        case Regex.run(quoted, attrs, capture: :all_but_first) do
          [value] -> value
          nil -> nil
        end
    end
  end

  defp take_expression(<<>>, _depth, _quote, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp take_expression(<<char::utf8, rest::binary>>, depth, quote, acc) do
    cond do
      quote && char == quote ->
        take_expression(rest, depth, nil, [<<char::utf8>> | acc])

      quote ->
        take_expression(rest, depth, quote, [<<char::utf8>> | acc])

      char in [?", ?'] ->
        take_expression(rest, depth, char, [<<char::utf8>> | acc])

      char == ?{ ->
        take_expression(rest, depth + 1, nil, ["{" | acc])

      char == ?} and depth == 1 ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

      char == ?} ->
        take_expression(rest, depth - 1, nil, ["}" | acc])

      true ->
        take_expression(rest, depth, nil, [<<char::utf8>> | acc])
    end
  end
end

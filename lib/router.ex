defmodule Dialup.Router do
  defmacro __using__(opts) do
    app_dir = Keyword.fetch!(opts, :app_dir)

    quote bind_quoted: [app_dir: app_dir] do
      @_dialup_app_dir app_dir

      @page_files Path.wildcard(Path.join(@_dialup_app_dir, "**/page.ex"))
      @layout_files Path.wildcard(Path.join(@_dialup_app_dir, "**/layout.ex"))
      @error_files Path.wildcard(Path.join(@_dialup_app_dir, "**/error.ex"))

      @external_resource @_dialup_app_dir
      for file <- @page_files ++ @layout_files ++ @error_files do
        @external_resource file
      end

      #   app/layout.ex           → {".",     Dialup.App.Layout}
      #   app/user/layout.ex      → {"user",  Dialup.App.User.Layout}
      @layout_map Map.new(@layout_files, fn file ->
                    relative = Path.relative_to(file, @_dialup_app_dir)
                    dir = Path.dirname(relative)

                    module =
                      dir
                      |> String.split("/")
                      |> Enum.reject(&(&1 == "."))
                      |> Enum.map(&Macro.camelize/1)
                      |> then(fn parts -> parts ++ ["Layout"] end)
                      |> then(fn parts -> Module.concat(["Dialup", "App"] ++ parts) end)

                    {dir, module}
                  end)

      @error_map Map.new(@error_files, fn file ->
                   relative = Path.relative_to(file, @_dialup_app_dir)
                   dir = Path.dirname(relative)

                   module =
                     dir
                     |> String.split("/")
                     |> Enum.reject(&(&1 == "."))
                     |> Enum.map(&Macro.camelize/1)
                     |> then(fn parts -> parts ++ ["Error"] end)
                     |> then(fn parts -> Module.concat(["Dialup", "App"] ++ parts) end)

                   {dir, module}
                 end)

      # lambda内でも参照できるよう変数に束縛
      layout_map_snapshot = @layout_map

      # ルート情報を生成（静的・動的を分離）
      route_infos =
        Enum.map(@page_files, fn file ->
          relative = Path.relative_to(file, @_dialup_app_dir)
          dir = Path.dirname(relative)

          {url_path, is_dynamic} =
            case dir do
              "." ->
                {"/", false}

              d ->
                # [id] 形式の動的セグメントを検出
                segments = String.split(d, "/")

                has_dynamic =
                  Enum.any?(segments, fn seg ->
                    String.starts_with?(seg, "[") and String.ends_with?(seg, "]")
                  end)

                {"/" <> d, has_dynamic}
            end

          page_module =
            dir
            |> String.split("/")
            |> Enum.reject(&(&1 == "."))
            |> Enum.map(fn segment ->
              # [id] → Id, [slug] → Slug に変換
              if String.starts_with?(segment, "[") and String.ends_with?(segment, "]") do
                segment
                |> String.slice(1..-2//1)
                |> Macro.camelize()
              else
                Macro.camelize(segment)
              end
            end)
            |> then(fn parts -> parts ++ ["Page"] end)
            |> then(fn parts -> Module.concat(["Dialup", "App"] ++ parts) end)

          # 親ディレクトリのレイアウトを収集
          ancestor_dirs =
            case dir do
              "." ->
                ["."]

              d ->
                parts = String.split(d, "/")

                ["."] ++
                  for i <- 1..length(parts), do: Enum.take(parts, i) |> Enum.join("/")
            end

          layouts =
            Enum.flat_map(ancestor_dirs, fn d ->
              case Map.get(layout_map_snapshot, d) do
                nil -> []
                mod -> [mod]
              end
            end)

          # パターンマッチング用情報
          pattern =
            if is_dynamic do
              segments = String.split(dir, "/")

              Enum.map(segments, fn seg ->
                if String.starts_with?(seg, "[") and String.ends_with?(seg, "]") do
                  param_name = String.slice(seg, 1..-2//1)
                  {:param, param_name}
                else
                  {:static, seg}
                end
              end)
            else
              nil
            end

          {url_path,
           %{
             page: page_module,
             layouts: layouts,
             is_dynamic: is_dynamic,
             pattern: pattern,
             dir: dir
           }}
        end)

      @routes Map.new(route_infos)

      # 静的ルートと動的ルートを分離
      @static_routes Map.filter(@routes, fn {_, v} -> not v.is_dynamic end)
      @dynamic_routes Map.filter(@routes, fn {_, v} -> v.is_dynamic end)

      @doc false
      def __routes__, do: @routes

      def layouts_for(path) do
        {clean_path, _} = split_path_query(path)

        case Map.get(@static_routes, clean_path) do
          nil ->
            case match_dynamic_route(clean_path) do
              nil -> []
              {_, info} -> info.layouts
            end

          %{layouts: layouts} ->
            layouts
        end
      end

      def error_page_for(path) do
        {clean_path, _} = split_path_query(path || "/")
        segments = String.split(String.trim_leading(clean_path, "/"), "/", trim_empty: true)

        candidate_dirs =
          ["."] ++
            for i <- 1..length(segments), do: Enum.take(segments, i) |> Enum.join("/")

        candidate_dirs
        |> Enum.reverse()
        |> Enum.find_value(fn d ->
          Map.get(@error_map, d)
        end)
      end

      def page_for(path) do
        {clean_path, _} = split_path_query(path)

        case Map.get(@static_routes, clean_path) do
          nil ->
            case match_dynamic_route(clean_path) do
              nil -> nil
              {_, info} -> info.page
            end

          %{page: mod} ->
            mod
        end
      end

      def path_params(path) do
        {clean_path, query} = split_path_query(path)
        query_params = parse_query_string(query)

        path_only_params =
          case Map.get(@static_routes, clean_path) do
            nil ->
              case match_dynamic_route(clean_path) do
                nil -> %{}
                {_, info} -> extract_params(clean_path, info.pattern)
              end

            _ ->
              %{}
          end

        # パスパラメータがクエリパラメータより優先される
        Map.merge(query_params, path_only_params)
      end

      def dispatch(path, assigns) do
        {clean_path, _} = split_path_query(path)

        case Map.get(@static_routes, clean_path) do
          nil ->
            case match_dynamic_route(clean_path) do
              nil -> {:error, :not_found}
              {_, info} -> {:ok, Dialup.Router.render_with_layouts(info.page, info.layouts, assigns)}
            end

          %{page: page_mod, layouts: layouts} ->
            {:ok, Dialup.Router.render_with_layouts(page_mod, layouts, assigns)}
        end
      end

      defp split_path_query(path) do
        case String.split(path, "?", parts: 2) do
          [p, q] -> {p, q}
          [p] -> {p, ""}
        end
      end

      defp parse_query_string(""), do: %{}
      defp parse_query_string(query), do: URI.decode_query(query)

      # 動的ルートマッチング
      defp match_dynamic_route(path) do
        request_segments = String.split(String.trim_leading(path, "/"), "/", trim_empty: true)

        Enum.find_value(@dynamic_routes, nil, fn {route_path, info} ->
          route_segments =
            String.split(String.trim_leading(route_path, "/"), "/", trim_empty: true)

          if length(request_segments) == length(route_segments) do
            matched =
              Enum.zip(request_segments, route_segments)
              |> Enum.all?(fn {req_seg, route_seg} ->
                # 動的セグメントは任意の値にマッチ、静的セグメントは完全一致
                String.starts_with?(route_seg, "[") or req_seg == route_seg
              end)

            if matched, do: {route_path, info}, else: nil
          else
            nil
          end
        end)
      end

      # パラメータ抽出
      defp extract_params(path, pattern) do
        request_segments = String.split(String.trim_leading(path, "/"), "/", trim_empty: true)

        Enum.zip(request_segments, pattern)
        |> Enum.reduce(%{}, fn {req_seg, pat_seg}, acc ->
          case pat_seg do
            {:param, name} -> Map.put(acc, name, req_seg)
            {:static, _} -> acc
          end
        end)
      end
    end
  end

  def render_with_layouts(page_mod, layouts, assigns) do
    page_html = page_mod.render(assigns) |> to_html()
    page_html = wrap_with_scope(page_html, page_mod)

    use_layout =
      if function_exported?(page_mod, :__layout__, 0), do: page_mod.__layout__(), else: true

    if use_layout do
      wrapped =
        layouts
        |> Enum.reverse()
        |> Enum.reduce(page_html, fn layout_mod, inner ->
          html = layout_mod.render(Map.put(assigns, :inner_content, inner)) |> to_html()
          wrap_with_scope(html, layout_mod)
        end)

      css = collect_css(layouts, page_mod)

      case css do
        "" -> wrapped
        _ -> ~s(<style data-dialup-css>) <> css <> "</style>" <> wrapped
      end
    else
      css = collect_css([], page_mod)

      case css do
        "" -> page_html
        _ -> ~s(<style data-dialup-css>) <> css <> "</style>" <> page_html
      end
    end
  end

  def render_with_layouts_raw(inner_html, inner_mod, layouts, assigns) do
    inner_html = wrap_with_scope(inner_html, inner_mod)

    wrapped =
      layouts
      |> Enum.reverse()
      |> Enum.reduce(inner_html, fn layout_mod, inner ->
        html = layout_mod.render(Map.put(assigns, :inner_content, inner)) |> to_html()
        wrap_with_scope(html, layout_mod)
      end)

    css_mods = layouts ++ [inner_mod]
    css = collect_css_from(css_mods)

    case css do
      "" -> wrapped
      _ -> ~s(<style data-dialup-css>) <> css <> "</style>" <> wrapped
    end
  end

  defp wrap_with_scope(html, mod) do
    if function_exported?(mod, :__css_scope__, 0) do
      case mod.__css_scope__() do
        nil -> html
        scope -> ~s(<div class="#{scope}">) <> html <> "</div>"
      end
    else
      html
    end
  end

  defp collect_css(layouts, page_mod) do
    collect_css_from(layouts ++ [page_mod])
  end

  defp collect_css_from(modules) do
    modules
    |> Enum.map(fn mod ->
      if function_exported?(mod, :__css__, 0), do: mod.__css__() || "", else: ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp to_html(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end

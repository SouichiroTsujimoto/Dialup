defmodule Dialup.Router do
  defmacro __using__(opts) do
    app_dir = Keyword.fetch!(opts, :app_dir)

    quote bind_quoted: [app_dir: app_dir] do
      @_dialup_app_dir app_dir

      @page_files Path.wildcard(Path.join(@_dialup_app_dir, "**/page.ex"))
      @layout_files Path.wildcard(Path.join(@_dialup_app_dir, "**/layout.ex"))

      @external_resource @_dialup_app_dir
      for file <- @page_files ++ @layout_files do
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
            |> then(fn
              [] -> ["Root"]
              parts -> parts
            end)
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

      def page_for(path) do
        case Map.get(@static_routes, path) do
          nil ->
            # 静的ルートにない場合、動的ルートを検索
            case match_dynamic_route(path) do
              nil -> nil
              {_, info} -> info.page
            end

          %{page: mod} ->
            mod
        end
      end

      def path_params(path) do
        case Map.get(@static_routes, path) do
          nil ->
            case match_dynamic_route(path) do
              nil -> %{}
              {_, info} -> extract_params(path, info.pattern)
            end

          _ ->
            %{}
        end
      end

      def dispatch(path, assigns) do
        case Map.get(@static_routes, path) do
          nil ->
            # 静的にない場合、動的ルートを試す
            case match_dynamic_route(path) do
              nil ->
                {:error, :not_found}

              {_route_path, info} ->
                # パラメータを抽出してassignsに追加
                params = extract_params(path, info.pattern)
                assigns_with_params = Map.put(assigns, :params, params)

                {:ok,
                 Dialup.Router.render_with_layouts(info.page, info.layouts, assigns_with_params)}
            end

          %{page: page_mod, layouts: layouts} ->
            {:ok, Dialup.Router.render_with_layouts(page_mod, layouts, assigns)}
        end
      end

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

    layouts
    |> Enum.reverse()
    |> Enum.reduce(page_html, fn layout_mod, inner ->
      layout_mod.render(Map.put(assigns, :inner_content, inner)) |> to_html()
    end)
  end

  defp to_html(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end

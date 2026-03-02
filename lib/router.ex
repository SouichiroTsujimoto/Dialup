defmodule Dialup.Router do
  @app_dir Path.join([__DIR__, "app"])

  @page_files Path.wildcard(Path.join(@app_dir, "**/page.ex"))
  @layout_files Path.wildcard(Path.join(@app_dir, "**/layout.ex"))

  @external_resource @app_dir
  for file <- @page_files ++ @layout_files do
    @external_resource file
  end

  #   app/layout.ex           → {".",     Dialup.App.Layout}
  #   app/user/layout.ex      → {"user",  Dialup.App.User.Layout}
  @layout_map Map.new(@layout_files, fn file ->
                relative = Path.relative_to(file, @app_dir)
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

  @routes Map.new(@page_files, fn file ->
            relative = Path.relative_to(file, @app_dir)
            dir = Path.dirname(relative)

            url_path =
              case dir do
                "." -> "/"
                d -> "/" <> d
              end

            page_module =
              dir
              |> String.split("/")
              |> Enum.reject(&(&1 == "."))
              |> Enum.map(&Macro.camelize/1)
              |> then(fn
                [] -> ["Root"]
                parts -> parts
              end)
              |> then(fn parts -> Module.concat(["Dialup", "App"] ++ parts) end)

            # "user/profile" → [".", "user", "user/profile"]
            # それぞれのディレクトリに layout.ex があるか確認
            ancestor_dirs =
              case dir do
                "." ->
                  ["."]

                d ->
                  parts = String.split(d, "/")
                  ["."] ++ for i <- 1..length(parts), do: Enum.take(parts, i) |> Enum.join("/")
              end

            layouts =
              Enum.flat_map(ancestor_dirs, fn d ->
                case Map.get(layout_map_snapshot, d) do
                  nil -> []
                  mod -> [mod]
                end
              end)

            {url_path, %{page: page_module, layouts: layouts}}
          end)

  @doc false
  def __routes__, do: @routes

  def page_for(path) do
    case Map.get(@routes, path) do
      nil -> nil
      %{page: mod} -> mod
    end
  end

  def dispatch(path, assigns) do
    case Map.get(@routes, path) do
      nil ->
        {:error, :not_found}

      %{page: page_mod, layouts: layouts} ->
        {:ok, render_with_layouts(page_mod, layouts, assigns)}
    end
  end

  defp render_with_layouts(page_mod, layouts, assigns) do
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

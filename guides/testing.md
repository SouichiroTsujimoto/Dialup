# Testing

`Dialup.Test` モジュールを使ったページのユニットテスト。

## 概要

WebSocket や GenServer を起動せず、ページモジュールの関数を直接呼び出してテストする。Phoenix LiveViewTest の `render_component` に近いアプローチ。

## API

### mount_page/3

ページを mount して `{assigns, rendered_html}` を返す。

```elixir
{assigns, html} = Dialup.Test.mount_page(MyApp.App.Page)
{assigns, html} = Dialup.Test.mount_page(MyApp.App.Users.Id.Page, %{"id" => "123"})
{assigns, html} = Dialup.Test.mount_page(MyApp.App.Page, %{}, %{current_user: user})
```

- 第1引数: ページモジュール
- 第2引数: params（デフォルト `%{}`）
- 第3引数: session（デフォルト `%{}`）

### send_event/4

`handle_event` を呼び出して `{result_tuple, rendered_html}` を返す。

```elixir
{result, html} = Dialup.Test.send_event(MyApp.App.Page, "increment", "", assigns)
```

- 第1引数: ページモジュール
- 第2引数: イベント名
- 第3引数: イベント値
- 第4引数: 現在の assigns

### send_info/3

`handle_info` を呼び出して `{result_tuple, rendered_html}` を返す。

```elixir
{result, html} = Dialup.Test.send_info(MyApp.App.Page, :tick, assigns)
```

### render/2

assigns を渡して HTML 文字列を返す。

```elixir
html = Dialup.Test.render(MyApp.App.Page, assigns)
```

## テスト例

### カウンターのテスト

```elixir
defmodule MyApp.App.PageTest do
  use ExUnit.Case

  test "mount sets initial count to 0" do
    {assigns, html} = Dialup.Test.mount_page(MyApp.App.Page)
    assert assigns.count == 0
    assert html =~ "0"
  end

  test "increment increases count" do
    {assigns, _html} = Dialup.Test.mount_page(MyApp.App.Page)

    {{:patch, "counter", _rendered, new_assigns}, html} =
      Dialup.Test.send_event(MyApp.App.Page, "increment", "", assigns)

    assert new_assigns.count == 1
    assert html =~ "1"
  end

  test "reset sets count back to 0" do
    {assigns, _html} = Dialup.Test.mount_page(MyApp.App.Page)

    # increment twice
    {{:patch, _, _, assigns}, _} =
      Dialup.Test.send_event(MyApp.App.Page, "increment", "", assigns)
    {{:patch, _, _, assigns}, _} =
      Dialup.Test.send_event(MyApp.App.Page, "increment", "", assigns)
    assert assigns.count == 2

    # reset
    {{:patch, _, _, assigns}, _} =
      Dialup.Test.send_event(MyApp.App.Page, "reset", "", assigns)
    assert assigns.count == 0
  end
end
```

### フォーム送信のテスト

```elixir
test "form submission creates item" do
  {assigns, _html} = Dialup.Test.mount_page(MyApp.App.Items.Page)

  {result, html} =
    Dialup.Test.send_event(
      MyApp.App.Items.Page,
      "create",
      %{"title" => "New Item", "body" => "Content"},
      assigns
    )

  assert {:update, new_assigns} = result
  assert new_assigns.item.title == "New Item"
  assert html =~ "New Item"
end
```

### page_title のテスト

```elixir
test "page_title returns user name" do
  {assigns, _html} = Dialup.Test.mount_page(
    MyApp.App.Users.Id.Page,
    %{"id" => "1"},
    %{current_user: %{name: "Admin"}}
  )

  assert MyApp.App.Users.Id.Page.page_title(assigns) == "User Name | My App"
end
```

## 注意事項

- `Dialup.Test` はレイアウトを適用しない。ページ単体のレンダリングのみをテストする
- `subscribe/2` を使うページをテストする場合、PubSub の起動が必要
- session に依存するページでは、第3引数に必要な session データを渡す

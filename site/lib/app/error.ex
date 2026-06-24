defmodule Dialup.App.Error do
  use Dialup.Error

  import Dialup.Page, only: [dialup_action: 1]

  def render(404, assigns) do
    ~H"""
    <div class="error-page">
      <div class="error-status">404</div>
      <h1 class="error-title">Page Not Found</h1>
      <p class="error-message">お探しのページは存在しないか、移動された可能性があります。</p>
      <div class="error-actions">
        <.dialup_action navigate="/" class="btn btn-ghost-dark">トップページに戻る</.dialup_action>
      </div>
    </div>
    """
  end

  def render(500, assigns) do
    ~H"""
    <div class="error-page">
      <div class="error-status">500</div>
      <h1 class="error-title">Internal Server Error</h1>
      <p class="error-message">サーバーで問題が発生しました。しばらくしてからもう一度お試しください。</p>
      <div class="error-actions">
        <.dialup_action navigate="/" class="btn btn-ghost-dark">トップページに戻る</.dialup_action>
      </div>
    </div>
    """
  end

  def render(_status, assigns) do
    ~H"""
    <div class="error-page">
      <div class="error-status">{@status}</div>
      <h1 class="error-title">Error</h1>
      <p class="error-message">予期しないエラーが発生しました。</p>
      <div class="error-actions">
        <.dialup_action navigate="/" class="btn btn-ghost-dark">トップページに戻る</.dialup_action>
      </div>
    </div>
    """
  end
end

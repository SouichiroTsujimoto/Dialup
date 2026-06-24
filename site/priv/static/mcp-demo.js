(() => {
  if (window.__mcpDemoInstalled) return;
  window.__mcpDemoInstalled = true;

  let endpoint = null; // "/agent/TOKEN"
  let version = 0;
  let reqId = 1;
  let busy = false;

  // 現実的なタスク分解（外部 LLM の代わりにキーワードで提案）
  const PLANS = [
    {
      kw: ["引っ越", "引越"],
      tasks: [
        { title: "不用品をリストアップして処分方法を決める", priority: "high" },
        { title: "粗大ごみの回収を予約する" },
        { title: "ダンボールと梱包材を調達する" },
        { title: "インターネット回線の移転を申し込む", priority: "high" },
        { title: "新住所の住民票・郵便転送を手続きする" },
      ],
    },
    {
      kw: ["勉強会", "イベント", "セミナー", "ミートアップ", "懇親"],
      tasks: [
        { title: "日程と会場を確定する", priority: "high" },
        { title: "発表者を募集する" },
        { title: "告知ページと参加登録フォームを作る" },
        { title: "当日の進行表とタイムキープ担当を決める" },
        { title: "アンケートで振り返りを集める" },
      ],
    },
    {
      kw: ["ローンチ", "リリース", "サービス", "ロンチ", "プロダクト"],
      tasks: [
        { title: "ランディングページを作成する", priority: "high" },
        { title: "価格プランを決める" },
        { title: "プレスリリースとSNS告知を準備する" },
        { title: "ベータユーザーを募集する" },
        { title: "アクセス解析と問い合わせ窓口を設定する" },
      ],
    },
    {
      kw: ["旅行", "旅", "ツアー", "出張"],
      tasks: [
        { title: "行き先と日程を決める", priority: "high" },
        { title: "交通と宿を予約する", priority: "high" },
        { title: "1日ごとの行程を作る" },
        { title: "持ち物リストを用意する" },
        { title: "現地の予算を見積もる" },
      ],
    },
  ];

  const FALLBACK = [
    { title: "ゴールと成功条件を定義する", priority: "high" },
    { title: "必要なタスクを洗い出す" },
    { title: "担当と期限を割り当てる" },
    { title: "進捗を確認する仕組みを作る" },
    { title: "リスクと対策を整理する" },
  ];

  function planFor(project) {
    const p = (project || "").toString();
    const hit = PLANS.find((plan) => plan.kw.some((k) => p.includes(k)));
    return hit ? hit.tasks : FALLBACK;
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const absoluteEndpoint = () => (endpoint ? location.origin + endpoint : "");

  async function rpc(method, params = {}) {
    const id = reqId++;
    const res = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
    });
    const body = await res.json();
    if (body.error) throw new Error(body.error.message || "RPC failed");
    return body.result;
  }

  function setStatus(text) {
    const el = document.querySelector("[data-mcp-status]");
    if (el) el.textContent = text || "";
  }

  async function doHandoff(btn) {
    const dialup = window.DialupApp;
    if (!dialup?.tabId) {
      setStatus("セッションの準備中です。少し待って再度お試しください。");
      return;
    }

    btn.disabled = true;
    setStatus("エンドポイントを発行中…");

    try {
      const res = await fetch(
        `/_dialup/agent-handoff?tab_id=${encodeURIComponent(dialup.tabId)}`,
        { method: "POST", credentials: "same-origin" }
      );

      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.error || `発行に失敗しました (${res.status})`);
      }

      const handoff = await res.json();
      endpoint = handoff.endpoint;

      // セッション情報をページ状態に保存して、サーバー側で詳細を描画させる。
      // url はフル URL（オリジン込み）。表示・コピーともこの値を使う。
      dialup.send("register_handoff", {
        endpoint: handoff.endpoint,
        url: absoluteEndpoint(),
        expiresInMs: handoff.grant?.expiresInMs,
      });
    } catch (error) {
      setStatus(error.message);
      btn.disabled = false;
    }
  }

  async function runDemo(btn) {
    if (busy || !endpoint) return;
    busy = true;
    const label = btn.textContent;
    btn.disabled = true;
    btn.textContent = "🤖 AI が作業中…";

    try {
      // 作業中は人間が画面を操作できないようロックする
      await rpc("tools/call", {
        name: "lock_ui",
        arguments: { reason: "AI がタスクを追加しています…" },
      });

      const scene = await rpc("tools/call", { name: "read_scene", arguments: {} });
      const content = scene.structuredContent ?? {};
      version = content.version ?? version;
      const project = content.state?.project ?? "";
      const tasks = planFor(project);

      for (const task of tasks) {
        const result = await rpc("tools/call", {
          name: "add_task",
          arguments: {
            title: task.title,
            priority: task.priority || "normal",
            _version: version,
          },
        });
        version = result.structuredContent?.version ?? version + 1;
        await sleep(650);
      }
      btn.textContent = "✓ 完了（もう一度実行できます）";
    } catch (error) {
      btn.textContent = `エラー: ${error.message}`;
    } finally {
      // 必ず人間に操作を返す
      try {
        await rpc("tools/call", { name: "unlock_ui", arguments: {} });
      } catch (_error) {
        // ignore
      }
      busy = false;
      btn.disabled = false;
      setTimeout(() => {
        btn.textContent = label;
      }, 2500);
    }
  }

  async function copyFrom(btn) {
    const card = btn.closest("[data-mcp-card]");
    const sel = btn.getAttribute("data-mcp-copy");
    const el = card?.querySelector(`[data-mcp-text="${sel}"]`);
    const text = el ? el.textContent.trim() : "";

    try {
      await navigator.clipboard.writeText(text);
      const prev = btn.textContent;
      btn.textContent = "コピーしました";
      setTimeout(() => {
        btn.textContent = prev;
      }, 1200);
    } catch (_error) {
      // クリップボード非対応環境は無視
    }
  }

  document.addEventListener("click", (event) => {
    const handoff = event.target.closest('[data-mcp="handoff"]');
    if (handoff) return doHandoff(handoff);

    const run = event.target.closest('[data-mcp="run-demo"]');
    if (run) return runDemo(run);

    const copy = event.target.closest("[data-mcp-copy]");
    if (copy) return copyFrom(copy);
  });

  // 再接続後など、すでにカードがエンドポイントを持っていれば JS 状態を復元する
  function syncEndpoint() {
    const card = document.querySelector("[data-mcp-card]");
    const path = card?.getAttribute("data-mcp-endpoint");
    if (path && !endpoint) endpoint = path;
  }

  new MutationObserver(syncEndpoint).observe(document.documentElement, {
    childList: true,
    subtree: true,
  });
  syncEndpoint();
})();

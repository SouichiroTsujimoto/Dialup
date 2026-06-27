(() => {
  if (window.__mcpDemoInstalled) return;
  window.__mcpDemoInstalled = true;

  let version = 0;
  let reqId = 1;
  let busy = false;

  const handoff = () => window.MCPHandoff;

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

  async function rpc(method, params = {}) {
    const endpoint = handoff()?.endpoint;
    if (!endpoint) throw new Error("MCP エンドポイントが未発行です");

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
    btn.disabled = true;
    setStatus("エンドポイントを発行中…");

    try {
      const result = await handoff().issueHandoff();

      window.DialupApp.send("register_handoff", {
        endpoint: result.endpoint,
        url: result.url,
        expiresInMs: result.grant?.expiresInMs,
      });
    } catch (error) {
      setStatus(error.message);
      btn.disabled = false;
    }
  }

  async function runDemo(btn) {
    if (busy || !handoff()?.endpoint) return;
    busy = true;
    const label = btn.textContent;
    btn.disabled = true;
    btn.textContent = "🤖 AI が作業中…";

    try {
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

  document.addEventListener("click", (event) => {
    const handoffBtn = event.target.closest('[data-mcp="handoff"]');
    if (handoffBtn) return doHandoff(handoffBtn);

    const run = event.target.closest('[data-mcp="run-demo"]');
    if (run) return runDemo(run);

    const copy = event.target.closest("[data-mcp-copy]");
    if (copy?.closest("[data-mcp-card]")) return handoff()?.copyFrom(copy);
  });
})();

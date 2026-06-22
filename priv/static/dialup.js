const Dialup = (() => {
    let socket = null;
    let currentPath = null;
    let isPopstateNavigation = false;
    let isReconnecting = false;
    let reconnectAttempts = 0;
    let reconnectTimer = null;
    let hooks = {};
    let agent = null;
    let agentFocusTarget = null;
    let handoffUi = null;
    let locationSelection = null;
    let handoffRequestTimer = null;
    let handoffRequestButton = null;
    const debounceTimers = new WeakMap();

    // タブごとに一意なIDをインメモリで保持する
    // sessionStorage はタブ複製時にコピーされるブラウザがあるため使用しない
    // インメモリであれば複製タブは必ず別のIDを持ち、ネットワーク再接続時は同じIDを再利用できる
    // Math.random() は予測可能なため crypto.randomUUID() を使用する
    const tabId = crypto.randomUUID();

    function send(event, value) {
        if (socket && socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify({ event, value }));
            return true;
        }
        return false;
    }

    function callHook(el, lifecycle) {
        const name = el.getAttribute("ws-hook");
        if (!name) return;
        const hook = hooks[name];
        if (hook && typeof hook === "object" && typeof hook[lifecycle] === "function") {
            hook[lifecycle](el);
        }
    }

    // idiomorph による差分適用
    function applyHtml(html) {
        const root = document.getElementById("dialup-root");
        if (root) {
            Idiomorph.morph(root, html, {
                morphStyle: "innerHTML",
                callbacks: {
                    afterNodeAdded(node) {
                        if (node.getAttribute?.("ws-hook")) callHook(node, "mounted");
                    },
                    afterNodeMorphed(_old, node) {
                        if (node.getAttribute?.("ws-hook")) callHook(node, "updated");
                    },
                    beforeNodeRemoved(node) {
                        if (node.getAttribute?.("ws-hook")) callHook(node, "destroyed");
                    }
                }
            });
        }
    }

    function applyUpdate(html, path, pushEvent, payload) {
        const isNavigation = path !== currentPath;

        applyHtml(html);
        reapplyAgentFocus();
        // morph 後に接続状態を再適用（idiomorph が data-ws-state をリセットするため）
        setConnectionState(socket?.readyState === WebSocket.OPEN);
        if (isNavigation) window.scrollTo(0, 0);
        if (pushEvent) {
            // push_event ハンドラは関数のみ（lifecycle hook オブジェクトは対象外）
            const handler = hooks[pushEvent];
            if (typeof handler === "function") handler(payload ?? {});
        }
    }

    function navigate(path) {
        if (path === currentPath) return;
        send("__navigate", path);
    }

    function setupDelegation() {
        const root = document.getElementById("dialup-root");
        if (!root) return;

        // ws-event, ws-href: クリックイベント
        root.addEventListener("click", (e) => {
            // ws-href
            const linkEl = e.target.closest("[ws-href]");
            if (linkEl) {
                e.preventDefault();
                navigate(linkEl.getAttribute("ws-href"));
                return;
            }

            // ws-event
            const eventEl = e.target.closest("[ws-event]");
            if (eventEl) {
                e.preventDefault();
                const semanticId = eventEl.getAttribute("data-dialup-id");
                if (semanticId) send("__focus", semanticId);
                const event = eventEl.getAttribute("ws-event");
                const encodedParams = eventEl.getAttribute("data-dialup-params");
                let value = eventEl.getAttribute("ws-value") ?? "";
                if (encodedParams) {
                    try { value = JSON.parse(encodedParams); } catch (_error) {}
                }
                send(event, value);
                return;
            }

            const semanticEl = e.target.closest("[data-dialup-id]");
            if (semanticEl) send("__focus", semanticEl.getAttribute("data-dialup-id"));
        });

        // ws-submit: フォーム送信（全フィールドをオブジェクトとして送信）
        root.addEventListener("submit", (e) => {
            const formEl = e.target.closest("[ws-submit]");
            if (formEl) {
                e.preventDefault();
                const event = formEl.getAttribute("ws-submit");
                const value = Object.fromEntries(new FormData(formEl));
                send(event, value);
            }
        });

        // ws-change: 入力のたびにイベント送信（ws-debounce で遅延可能）
        root.addEventListener("input", (e) => {
            const inputEl = e.target.closest("[ws-change]");
            if (inputEl) {
                const event = inputEl.getAttribute("ws-change");
                const debounceMs = parseInt(inputEl.getAttribute("ws-debounce"), 10);

                if (debounceMs > 0) {
                    const prev = debounceTimers.get(inputEl);
                    if (prev) clearTimeout(prev);
                    debounceTimers.set(inputEl, setTimeout(() => {
                        debounceTimers.delete(inputEl);
                        send(event, e.target.value);
                    }, debounceMs));
                } else {
                    send(event, e.target.value);
                }
            }
        });
    }

    // redo/undo
    function setupPopstate() {
        window.addEventListener("popstate", (e) => {
            const path = e.state?.path ?? window.location.pathname;
            isPopstateNavigation = true;
            send("__navigate", path);
        });
    }

    function setConnectionState(connected) {
        const el = document.getElementById("ws-status");
        if (el) el.dataset.wsState = connected ? "connected" : "disconnected";
    }

    function connectSocket(opts = {}) {
        const proto = location.protocol === "https:" ? "wss:" : "ws:";
        const url = `${proto}//${location.host}/ws?tab_id=${encodeURIComponent(tabId)}`;

        socket = new WebSocket(url);

        socket.onopen = () => {
            if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
            reconnectAttempts = 0;
            setConnectionState(true);
            updateHandoffConnectionState(true);

            if (isReconnecting) {
                if (opts.onReconnect) opts.onReconnect();
                send("__reconnect", currentPath);
                isReconnecting = false;
            } else {
                if (opts.onConnect) opts.onConnect();
                send("__init", currentPath);
            }
        };

        socket.onmessage = (e) => {
            const msg = JSON.parse(e.data);

            if (msg.dialup === "handoff_issued") {
                clearHandoffRequest();
                showHandoffUrl(msg.handoff);
                return;
            }

            if (msg.dialup === "handoff_error") {
                clearHandoffRequest();
                showHandoffError(msg.message);
                return;
            }

            if (msg.agent) {
                agent = msg.agent;
                updateAgentContext(msg.agent);
            }

            if (msg.dialup === "focus") {
                showFocus(msg.target);
                return;
            }

            if (msg.dialup === "approval_requested") {
                showApproval(msg.approval);
                return;
            }

            if (msg.target) {
                // 指定IDの要素だけを更新
                const el = document.getElementById(msg.target);
                if (el) Idiomorph.morph(el, msg.html);

            } else if (msg.html !== undefined && msg.path !== undefined) {
                // history と currentPath を更新してから applyUpdate へ
                if (msg.path !== currentPath) {
                    if (!isPopstateNavigation) {
                        history.pushState({ path: msg.path }, "", msg.path);
                    }
                }
                isPopstateNavigation = false;

                applyUpdate(msg.html, msg.path, msg.push_event, msg.payload);
                if (msg.title !== undefined) document.title = msg.title;
                currentPath = msg.path;
            }
        };

        socket.onclose = () => {
            isReconnecting = true;
            failHandoffRequest("接続が切れました。再接続後にもう一度お試しください。");
            updateHandoffConnectionState(false);
            scheduleReconnect(opts);
        };

        // onerror の後は必ず onclose が発火するため、ここでは何もしない
        socket.onerror = () => {};
    }

    function scheduleReconnect(opts) {
        // 指数バックオフ: 1s → 2s → 4s → 8s → ... 最大30s
        const delay = Math.min(1000 * (2 ** reconnectAttempts), 30000);
        reconnectAttempts++;
        setConnectionState(false);
        if (opts.onDisconnect) opts.onDisconnect(reconnectAttempts);
        reconnectTimer = setTimeout(() => connectSocket(opts), delay);
    }

    function connect(opts = {}) {
        hooks = opts.hooks ?? {};
        currentPath = window.location.pathname;
        history.replaceState({ path: currentPath }, "", currentPath);
        setupPopstate();
        setupDelegation();
        setupHandoffControls();
        connectSocket(opts);
    }

    function showFocus(target) {
        agentFocusTarget = String(target);
        reapplyAgentFocus(true);
        showAgentFocusStatus(agentFocusTarget);
    }

    function reapplyAgentFocus(scroll = false) {
        document.querySelectorAll("[data-dialup-focused]").forEach((node) => {
            node.removeAttribute("data-dialup-focused");
            node.style.removeProperty("outline");
            node.style.removeProperty("outline-offset");
        });

        if (!agentFocusTarget) return;

        const escaped = CSS.escape(agentFocusTarget);
        const el = document.querySelector(`[data-dialup-id="${escaped}"]`);
        if (!el) return;

        el.setAttribute("data-dialup-focused", "true");
        el.style.setProperty("outline", "4px solid #7c3aed");
        el.style.setProperty("outline-offset", "4px");
        if (scroll) el.scrollIntoView({ behavior: "smooth", block: "center" });
    }

    function clearAgentFocus() {
        agentFocusTarget = null;
        reapplyAgentFocus();
        handoffUi?.root.querySelector(".agent-focus-result")?.remove();
    }

    function showAgentFocusStatus(target) {
        if (!handoffUi) setupHandoffControls();
        handoffUi.root.querySelector(".agent-focus-result")?.remove();

        const result = document.createElement("div");
        result.className = "agent-focus-result";

        const label = document.createElement("span");
        label.textContent = `AIが注目中: ${target}`;

        const clear = document.createElement("button");
        clear.type = "button";
        clear.textContent = "解除";
        clear.addEventListener("click", clearAgentFocus);

        result.append(label, clear);
        handoffUi.panel.append(result);
    }

    function agentEndpoint() {
        return null;
    }

    function updateAgentContext(liveAgent) {
        const el = document.getElementById("dialup-agent-context");
        if (!el) return;

        try {
            const context = JSON.parse(el.textContent || "{}");
            context.connection = {
                ...(context.connection || {}),
                status: "user_handoff_required",
                sessionOrigin: "this_browser_tab",
                stateVersion: liveAgent.version,
                grant: liveAgent.grant,
                accessWarning:
                    "No agent endpoint is exposed by the ordinary page. For existing user work, " +
                    "ask the user to click Hand off to AI and send the generated /agent/ URL."
            };
            el.textContent = JSON.stringify(context);
        } catch (_error) {}
    }

    function setupHandoffControls() {
        if (document.getElementById("dialup-handoff-host")) return;

        const host = document.createElement("div");
        host.id = "dialup-handoff-host";
        host.style.cssText = "position:fixed;right:20px;bottom:20px;z-index:2147483646";
        const root = host.attachShadow({ mode: "open" });

        const style = document.createElement("style");
        style.textContent = `
            * { box-sizing: border-box; }
            .panel {
                width: min(390px, calc(100vw - 32px));
                color: #171717;
                font: 14px/1.45 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }
            button {
                border: 2px solid #171717;
                background: #a3e635;
                color: #171717;
                padding: 11px 15px;
                font: inherit;
                font-weight: 800;
                cursor: pointer;
                box-shadow: 4px 4px 0 #171717;
            }
            button:disabled { cursor: wait; opacity: .65; }
            .card {
                margin-bottom: 12px;
                padding: 16px;
                border: 2px solid #171717;
                background: #fff;
                box-shadow: 6px 6px 0 #7c3aed;
            }
            .title { margin: 0 0 6px; font-size: 16px; font-weight: 900; }
            .help { margin: 0 0 12px; color: #525252; }
            .url {
                display: block;
                width: 100%;
                margin: 10px 0;
                padding: 9px;
                border: 1px solid #a3a3a3;
                background: #f5f5f5;
                color: #171717;
                font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
                overflow-wrap: anywhere;
                user-select: all;
            }
            .row { display: flex; gap: 8px; align-items: center; }
            .row button { flex: 1; box-shadow: none; }
            .launcher-row { display: flex; gap: 10px; align-items: stretch; }
            .launcher-row button { flex: 1; }
            .secondary { background: #fff; }
            .location { background: #ddd6fe; }
            .warning { margin: 10px 0 0; color: #7c2d12; font-size: 12px; }
            .status { margin: 10px 0 0; font-weight: 700; }
            .selection-result {
                margin: 10px 0 0;
                padding: 10px;
                border: 1px solid #7c3aed;
                background: #f5f3ff;
                font-size: 12px;
            }
            .agent-focus-result {
                display: flex;
                align-items: center;
                justify-content: space-between;
                gap: 10px;
                margin: 10px 0 0;
                padding: 10px;
                border: 2px solid #7c3aed;
                background: #ede9fe;
                font-weight: 800;
            }
            .agent-focus-result button {
                flex: 0 0 auto;
                padding: 5px 9px;
                background: #fff;
                box-shadow: none;
                font-size: 12px;
            }
        `;

        const panel = document.createElement("div");
        panel.className = "panel";
        const launcher = document.createElement("div");
        launcher.className = "launcher-row";
        const issue = document.createElement("button");
        issue.type = "button";
        issue.setAttribute("aria-haspopup", "dialog");
        issue.addEventListener("click", () => requestHandoff(issue));

        const location = locationButton();

        root.append(style, panel);
        launcher.append(issue, location);
        panel.append(launcher);
        document.body.append(host);
        handoffUi = { host, root, panel, launcher, issue, location };
        updateHandoffConnectionState(socket?.readyState === WebSocket.OPEN);
    }

    function showHandoffUrl(handoff) {
        if (!handoffUi) setupHandoffControls();

        const absoluteUrl = new URL(handoff.endpoint, location.origin).href;
        const expiresInMs = handoff.grant?.expiresInMs;
        const minutes = expiresInMs == null ? null : Math.max(1, Math.ceil(expiresInMs / 60000));

        handoffUi.panel.replaceChildren();
        const card = document.createElement("div");
        card.className = "card";
        card.setAttribute("role", "dialog");
        card.setAttribute("aria-label", "AI session handoff");

        const title = document.createElement("p");
        title.className = "title";
        title.textContent = "セッション引き継ぎURL";

        const help = document.createElement("p");
        help.className = "help";
        help.textContent = "このURLをAI Agentに送ると、現在の作業状態を引き継げます。";

        const url = document.createElement("code");
        url.className = "url";
        url.textContent = absoluteUrl;

        const row = document.createElement("div");
        row.className = "row";

        const copy = document.createElement("button");
        copy.type = "button";
        copy.textContent = "URLをコピー";
        copy.addEventListener("click", async () => {
            const copied = await copyText(absoluteUrl);
            copy.textContent = copied ? "コピーしました" : "URLを選択してください";
            if (!copied) selectNodeText(url);
        });

        const reissue = document.createElement("button");
        reissue.type = "button";
        reissue.className = "secondary";
        reissue.textContent = "再発行";
        reissue.addEventListener("click", () => requestHandoff(reissue));

        const warning = document.createElement("p");
        warning.className = "warning";
        warning.textContent =
            `このURLは操作権限を含みます。信頼できる相手だけに共有してください。` +
            (minutes ? ` 有効時間の目安: ${minutes}分。` : "");

        const locationControl = locationButton();
        locationControl.style.width = "100%";
        locationControl.style.marginTop = "10px";
        locationControl.style.boxShadow = "none";

        row.append(copy, reissue);
        card.append(title, help, url, row, locationControl, warning);
        handoffUi.panel.append(card);
        if (agentFocusTarget) showAgentFocusStatus(agentFocusTarget);
    }

    function showHandoffError(message) {
        if (!handoffUi) setupHandoffControls();
        updateHandoffConnectionState(socket?.readyState === WebSocket.OPEN);

        const status = document.createElement("p");
        status.className = "status";
        status.textContent = message || "発行できませんでした。もう一度お試しください。";
        handoffUi.panel.replaceChildren(handoffUi.launcher, status);
        if (agentFocusTarget) showAgentFocusStatus(agentFocusTarget);
    }

    async function requestHandoff(button) {
        clearHandoffRequest();
        handoffRequestButton = button;
        button.disabled = true;
        button.textContent = "発行中…";
        const controller = new AbortController();
        handoffRequestTimer = setTimeout(() => controller.abort(), 8000);

        try {
            const response = await fetch(
                `/_dialup/agent-handoff?tab_id=${encodeURIComponent(tabId)}`,
                {
                    method: "POST",
                    credentials: "same-origin",
                    headers: { "accept": "application/json" },
                    signal: controller.signal
                }
            );
            const payload = await response.json();

            if (!response.ok) {
                throw new Error(payload.error || `HTTP ${response.status}`);
            }

            clearHandoffRequest();
            showHandoffUrl(payload);
        } catch (error) {
            clearHandoffRequest();
            const message = error?.name === "AbortError"
                ? "発行処理がタイムアウトしました。ページを再読み込みして再試行してください。"
                : `発行できませんでした: ${error?.message || "接続エラー"}`;
            showHandoffError(message);
        }
    }

    function clearHandoffRequest() {
        if (handoffRequestTimer) clearTimeout(handoffRequestTimer);
        handoffRequestTimer = null;
        handoffRequestButton = null;
    }

    function failHandoffRequest(message) {
        if (!handoffRequestButton && !handoffRequestTimer) return;
        clearHandoffRequest();
        showHandoffError(message);
    }

    function updateHandoffConnectionState(connected) {
        if (!handoffUi || handoffRequestButton) return;
        handoffUi.issue.disabled = !connected;
        handoffUi.issue.textContent = connected
            ? "AIに引き継ぐ / Hand off to AI"
            : "接続中…";
    }

    function locationButton() {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "location";
        button.textContent = "AIに場所を伝える";
        button.addEventListener("click", beginLocationSelection);
        return button;
    }

    function beginLocationSelection() {
        if (locationSelection) return;

        const overlay = document.createElement("div");
        overlay.id = "dialup-location-selector";
        overlay.style.cssText = [
            "position:fixed", "inset:0", "z-index:2147483647",
            "cursor:crosshair", "touch-action:none", "user-select:none",
            "background:rgba(124,58,237,.06)"
        ].join(";");

        const instruction = document.createElement("div");
        instruction.textContent =
            "クリックで要素を選択、またはドラッグで矩形選択 · Escでキャンセル";
        instruction.style.cssText = [
            "position:fixed", "left:50%", "top:18px", "transform:translateX(-50%)",
            "max-width:calc(100vw - 32px)", "padding:10px 14px",
            "background:#171717", "color:#fff", "border:2px solid #a3e635",
            "font:700 13px/1.4 system-ui,sans-serif", "pointer-events:none"
        ].join(";");

        const box = document.createElement("div");
        box.style.cssText = [
            "position:fixed", "display:none", "border:3px solid #7c3aed",
            "background:rgba(124,58,237,.16)", "pointer-events:none"
        ].join(";");

        overlay.append(instruction, box);
        document.body.append(overlay);

        const state = { overlay, box, start: null, current: null };
        locationSelection = state;

        const cancel = () => finishLocationSelection();
        const onKeydown = (event) => {
            if (event.key === "Escape") cancel();
        };
        state.onKeydown = onKeydown;
        window.addEventListener("keydown", onKeydown);

        overlay.addEventListener("pointerdown", (event) => {
            if (event.button !== 0) return;
            event.preventDefault();
            state.start = { x: event.clientX, y: event.clientY };
            state.current = state.start;
            overlay.setPointerCapture(event.pointerId);
        });

        overlay.addEventListener("pointermove", (event) => {
            if (!state.start) return;
            state.current = { x: event.clientX, y: event.clientY };
            renderSelectionBox(state);
        });

        overlay.addEventListener("pointerup", (event) => {
            if (!state.start) return;
            state.current = { x: event.clientX, y: event.clientY };
            const rect = normalizedSelectionRect(state.start, state.current);
            const mode = rect.width < 6 && rect.height < 6 ? "point" : "rectangle";
            const targets =
                mode === "point"
                    ? selectableTargetsAt(event.clientX, event.clientY, overlay)
                    : selectableTargetsIn(rect, overlay);

            if (targets.length === 0) {
                instruction.textContent =
                    "選択できる要素が見つかりません。別の場所を選ぶかEscでキャンセル";
                state.start = null;
                state.current = null;
                box.style.display = "none";
                return;
            }

            const selection = {
                mode,
                targets,
                rectangle: {
                    ...rect,
                    documentX: rect.x + window.scrollX,
                    documentY: rect.y + window.scrollY
                },
                pointer: { x: event.clientX, y: event.clientY },
                viewport: {
                    width: window.innerWidth,
                    height: window.innerHeight,
                    scrollX: window.scrollX,
                    scrollY: window.scrollY
                }
            };

            markHumanSelection(targets);
            if (send("__focus", selection)) {
                showLocationResult(selection);
                finishLocationSelection();
            } else {
                instruction.textContent =
                    "サーバーへ接続中です。接続後にもう一度選択してください";
                state.start = null;
                state.current = null;
                box.style.display = "none";
            }
        });
    }

    function finishLocationSelection() {
        if (!locationSelection) return;
        window.removeEventListener("keydown", locationSelection.onKeydown);
        locationSelection.overlay.remove();
        locationSelection = null;
    }

    function renderSelectionBox(state) {
        const rect = normalizedSelectionRect(state.start, state.current);
        state.box.style.display = "block";
        state.box.style.left = `${rect.x}px`;
        state.box.style.top = `${rect.y}px`;
        state.box.style.width = `${rect.width}px`;
        state.box.style.height = `${rect.height}px`;
    }

    function normalizedSelectionRect(start, end) {
        const x = Math.min(start.x, end.x);
        const y = Math.min(start.y, end.y);
        return {
            x,
            y,
            width: Math.abs(end.x - start.x),
            height: Math.abs(end.y - start.y)
        };
    }

    function selectableTargetsAt(x, y, overlay) {
        overlay.style.pointerEvents = "none";
        const elements = document.elementsFromPoint(x, y)
            .filter((element) => !element.closest?.("#dialup-handoff-host"))
            .filter((element) => element !== document.documentElement && element !== document.body);
        overlay.style.pointerEvents = "";

        const semantic = elements
            .map((element) => element.closest?.("[data-dialup-id]"))
            .find(Boolean);

        if (semantic) return [semanticTarget(semantic)];

        const element = elements.find(isSelectableElement);
        return element ? [domTarget(element)] : [];
    }

    function selectableTargetsIn(selectionRect, overlay) {
        overlay.style.pointerEvents = "none";

        const semanticElements = [...document.querySelectorAll("[data-dialup-id]")];
        const semanticTargets = intersectingTargets(semanticElements, selectionRect)
            .map((candidate) => semanticTarget(candidate.element));

        const semanticSet = new Set(semanticElements);
        const domElements = [...document.querySelectorAll("#dialup-root *")]
            .filter((element) => !semanticSet.has(element))
            .filter((element) => !element.closest("#dialup-handoff-host"))
            .filter(isSelectableElement)
            .filter(isMeaningfulDomElement);

        const domTargets = intersectingTargets(domElements, selectionRect)
            .slice(0, Math.max(0, 30 - semanticTargets.length))
            .map((candidate) => domTarget(candidate.element));

        overlay.style.pointerEvents = "";
        return dedupeTargets([...semanticTargets, ...domTargets]);
    }

    function intersectingTargets(elements, selectionRect) {
        return elements
            .map((element) => {
                const rect = element.getBoundingClientRect();
                const intersection = intersectionArea(selectionRect, rect);
                const area = Math.max(rect.width * rect.height, 1);
                return { element, intersection, coverage: intersection / area, area };
            })
            .filter((candidate) => candidate.intersection > 0)
            .sort((a, b) => b.coverage - a.coverage || a.area - b.area);
    }

    function intersectionArea(a, b) {
        const width = Math.max(0, Math.min(a.x + a.width, b.right) - Math.max(a.x, b.left));
        const height = Math.max(0, Math.min(a.y + a.height, b.bottom) - Math.max(a.y, b.top));
        return width * height;
    }

    function semanticTarget(element) {
        const rect = element.getBoundingClientRect();
        return {
            id: element.getAttribute("data-dialup-id"),
            kind: element.getAttribute("data-dialup-kind") || "unknown",
            description: element.getAttribute("data-dialup-desc") || "",
            text: (element.innerText || "").replace(/\s+/g, " ").trim().slice(0, 500),
            rect: {
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
                documentX: rect.x + window.scrollX,
                documentY: rect.y + window.scrollY
            }
        };
    }

    function domTarget(element) {
        const rect = element.getBoundingClientRect();
        const selector = stableSelector(element);
        const text = element.matches("input,textarea,select")
            ? ""
            : (element.innerText || element.getAttribute("alt") || "")
                .replace(/\s+/g, " ").trim().slice(0, 500);

        return {
            id: `dom:${selector}`,
            kind: "dom",
            selector,
            tag: element.tagName.toLowerCase(),
            role: element.getAttribute("role") || implicitRole(element),
            description:
                element.getAttribute("aria-label") ||
                element.getAttribute("alt") ||
                element.getAttribute("title") ||
                "",
            text,
            rect: {
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
                documentX: rect.x + window.scrollX,
                documentY: rect.y + window.scrollY
            }
        };
    }

    function isSelectableElement(element) {
        if (!(element instanceof HTMLElement) && !(element instanceof SVGElement)) return false;
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 2 && rect.height > 2 &&
            style.display !== "none" && style.visibility !== "hidden" &&
            style.pointerEvents !== "none";
    }

    function isMeaningfulDomElement(element) {
        if (element.matches(
            "button,a,input,select,textarea,label,[role],h1,h2,h3,h4,h5,h6,p,li,img,video,canvas,iframe,svg,table,th,td,form,article,nav,main,aside,header,footer,[aria-label],[data-testid],[id]"
        )) return true;

        const ownText = [...element.childNodes]
            .filter((node) => node.nodeType === Node.TEXT_NODE)
            .map((node) => node.textContent)
            .join("")
            .trim();

        return ownText.length > 0;
    }

    function stableSelector(element) {
        if (element.id) return `#${CSS.escape(element.id)}`;

        const testId = element.getAttribute("data-testid");
        if (testId) return `[data-testid="${CSS.escape(testId)}"]`;

        const path = [];
        let current = element;
        const root = document.getElementById("dialup-root");

        while (current && current !== root && current !== document.body) {
            let part = current.tagName.toLowerCase();
            const siblings = current.parentElement
                ? [...current.parentElement.children].filter((node) => node.tagName === current.tagName)
                : [];
            if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
            path.unshift(part);
            current = current.parentElement;
        }

        return `#dialup-root > ${path.join(" > ")}`;
    }

    function implicitRole(element) {
        const tag = element.tagName.toLowerCase();
        if (tag === "button") return "button";
        if (tag === "a" && element.hasAttribute("href")) return "link";
        if (/^h[1-6]$/.test(tag)) return "heading";
        if (tag === "img") return "img";
        if (["input", "textarea", "select"].includes(tag)) return "form-control";
        return "";
    }

    function dedupeTargets(targets) {
        const seen = new Set();
        return targets.filter((target) => {
            if (seen.has(target.id)) return false;
            seen.add(target.id);
            return true;
        });
    }

    function markHumanSelection(targets) {
        document.querySelectorAll("[data-dialup-human-selected]").forEach((element) => {
            element.removeAttribute("data-dialup-human-selected");
            element.style.removeProperty("box-shadow");
        });

        targets.forEach((target) => {
            const element = target.kind === "dom"
                ? document.querySelector(target.selector)
                : document.querySelector(
                    `[data-dialup-id="${CSS.escape(String(target.id))}"]`
                );
            if (!element) return;
            element.setAttribute("data-dialup-human-selected", "true");
            element.style.setProperty("box-shadow", "0 0 0 4px #f97316");
        });
    }

    function showLocationResult(selection) {
        if (!handoffUi) setupHandoffControls();
        const previous = handoffUi.root.querySelector(".selection-result");
        previous?.remove();

        const result = document.createElement("p");
        result.className = "selection-result";
        const labels = selection.targets
            .map((target) => target.kind === "dom" ? target.id : `${target.kind}:${target.id}`)
            .join(", ");
        result.textContent = `AIへ場所を共有しました: ${labels}`;
        handoffUi.panel.append(result);
    }

    async function copyText(text) {
        try {
            await navigator.clipboard.writeText(text);
            return true;
        } catch (_error) {
            const input = document.createElement("textarea");
            input.value = text;
            input.style.cssText = "position:fixed;left:-9999px";
            document.body.append(input);
            input.select();
            const copied = document.execCommand("copy");
            input.remove();
            return copied;
        }
    }

    function selectNodeText(node) {
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(node);
        selection.removeAllRanges();
        selection.addRange(range);
    }

    function showApproval(approval) {
        document.getElementById("dialup-approval")?.remove();

        const overlay = document.createElement("div");
        overlay.id = "dialup-approval";
        overlay.style.cssText = [
            "position:fixed", "inset:0", "z-index:2147483647",
            "display:grid", "place-items:center", "padding:24px",
            "background:rgba(0,0,0,.55)", "font-family:system-ui,sans-serif"
        ].join(";");

        const dialog = document.createElement("div");
        dialog.setAttribute("role", "dialog");
        dialog.setAttribute("aria-modal", "true");
        dialog.style.cssText = [
            "width:min(520px,100%)", "padding:24px", "border:3px solid #111",
            "background:#fff", "color:#111", "box-shadow:8px 8px 0 #7c3aed"
        ].join(";");

        const title = document.createElement("h2");
        title.textContent = "AI action requires approval";
        title.style.marginTop = "0";

        const description = document.createElement("p");
        description.textContent = approval.description || approval.action;

        const details = document.createElement("pre");
        details.textContent = JSON.stringify(approval.arguments || {}, null, 2);
        details.style.cssText = "padding:12px;background:#f5f5f5;overflow:auto";

        const actions = document.createElement("div");
        actions.style.cssText = "display:flex;gap:12px;justify-content:flex-end";

        const reject = approvalButton("Reject", "#fff", "#111");
        const approve = approvalButton("Approve", "#a3e635", "#111");

        reject.addEventListener("click", () => resolveApproval(approval.id, "reject", overlay));
        approve.addEventListener("click", () => resolveApproval(approval.id, "approve", overlay));

        actions.append(reject, approve);
        dialog.append(title, description, details, actions);
        overlay.append(dialog);
        document.body.append(overlay);
    }

    function approvalButton(label, background, color) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = label;
        button.style.cssText = `padding:10px 16px;border:2px solid #111;background:${background};color:${color};font-weight:800;cursor:pointer`;
        return button;
    }

    function resolveApproval(id, decision, overlay) {
        send("__agent_approval", { id, decision });
        overlay.remove();
    }

    return {
        connect,
        send,
        agentEndpoint,
        focus(target) { send("__focus", target); },
        focusAt(x, y) {
            const el = document.elementFromPoint(x, y)?.closest?.("[data-dialup-id]");
            if (el) send("__focus", el.getAttribute("data-dialup-id"));
        }
    };
})();

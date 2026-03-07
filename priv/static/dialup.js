const Dialup = (() => {
    let socket = null;
    let currentPath = null;
    let isPopstateNavigation = false;
    let isReconnecting = false;
    let reconnectAttempts = 0;
    let reconnectTimer = null;

    function send(event, value) {
        if (socket && socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify({ event, value }));
        }
    }

    // idiomorph による差分適用
    function applyHtml(html) {
        const root = document.getElementById("dialup-root");
        if (root) {
            Idiomorph.morph(root, html, { morphStyle: "innerHTML" });
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
                const event = eventEl.getAttribute("ws-event");
                const value = eventEl.getAttribute("ws-value") ?? "";
                send(event, value);
            }
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

        // ws-change: 入力のたびにイベント送信（リアルタイムバリデーション等）
        root.addEventListener("input", (e) => {
            const inputEl = e.target.closest("[ws-change]");
            if (inputEl) {
                const event = inputEl.getAttribute("ws-change");
                send(event, e.target.value);
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

    function setStatus(text) {
        const el = document.getElementById("ws-status");
        if (el) el.textContent = text;
    }

    function connectSocket() {
        const proto = location.protocol === "https:" ? "wss:" : "ws:";
        const url = `${proto}//${location.host}/ws`;

        socket = new WebSocket(url);

        socket.onopen = () => {
            if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
            reconnectAttempts = 0;

            if (isReconnecting) {
                setStatus("再接続しました ✓");
                send("__reconnect", currentPath);
                isReconnecting = false;
            } else {
                setStatus("接続済み ✓");
                send("__init", currentPath);
            }
        };

        socket.onmessage = (e) => {
            const msg = JSON.parse(e.data);

            if (msg.target) {
                // 指定IDの要素だけを更新
                const el = document.getElementById(msg.target);
                if (el) Idiomorph.morph(el, msg.html);

            } else if (msg.html !== undefined && msg.path !== undefined) {
                // #dialup-root 全体を差し替え
                applyHtml(msg.html);

                if (msg.path !== currentPath) {
                    if (!isPopstateNavigation) {
                        history.pushState({ path: msg.path }, "", msg.path);
                    }
                    currentPath = msg.path;
                }
                isPopstateNavigation = false;
            }
        };

        socket.onclose = () => {
            isReconnecting = true;
            scheduleReconnect();
        };

        // onerror の後は必ず onclose が発火するため、ここでは何もしない
        socket.onerror = () => {};
    }

    function scheduleReconnect() {
        // 指数バックオフ: 1s → 2s → 4s → 8s → ... 最大30s
        const delay = Math.min(1000 * (2 ** reconnectAttempts), 30000);
        reconnectAttempts++;
        setStatus(`再接続中... (${reconnectAttempts}回目)`);
        reconnectTimer = setTimeout(connectSocket, delay);
    }

    function connect() {
        currentPath = window.location.pathname;
        history.replaceState({ path: currentPath }, "", currentPath);
        setupPopstate();
        setupDelegation();
        connectSocket();
    }

    return { connect };
})();

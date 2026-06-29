const Dialup = (() => {
    let socket = null;
    let currentPath = null;
    let isPopstateNavigation = false;
    let isReconnecting = false;
    let reconnectAttempts = 0;
    let reconnectTimer = null;
    let hooks = {};
    const debounceTimers = new WeakMap();

    function loadTabId() {
        const key = "dialup_tab_id";

        try {
            let id = sessionStorage.getItem(key);

            if (!id) {
                id = crypto.randomUUID();
                sessionStorage.setItem(key, id);
            }

            return id;
        } catch {
            return crypto.randomUUID();
        }
    }

    const tabId = loadTabId();
    let joinToken = new URLSearchParams(window.location.search).get("_join");
    let joinRetryCount = 0;
    const maxJoinRetries = 3;

    function clearJoinFromUrl() {
        joinToken = null;
        joinRetryCount = 0;
        const clean = new URL(location.href);
        if (!clean.searchParams.has("_join")) return;
        clean.searchParams.delete("_join");
        history.replaceState({ path: currentPath }, "", clean.pathname + clean.search);
    }

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
        setConnectionState(socket?.readyState === WebSocket.OPEN);
        if (isNavigation) window.scrollTo(0, 0);
        if (pushEvent) {
            const handler = hooks[pushEvent];
            if (typeof handler === "function") handler(payload ?? {});
        }
    }

    function setUiLock(locked, reason) {
        const id = "dialup-ui-lock";
        let overlay = document.getElementById(id);

        if (!locked) {
            if (overlay) overlay.remove();
            document.body?.removeAttribute("data-dialup-ui-locked");
            return;
        }

        if (!overlay) {
            overlay = document.createElement("div");
            overlay.id = id;
            overlay.setAttribute("role", "alertdialog");
            overlay.setAttribute("aria-live", "assertive");
            overlay.style.cssText = [
                "position:fixed", "inset:0", "z-index:2147483647",
                "display:flex", "flex-direction:column", "align-items:center",
                "justify-content:center", "gap:14px", "text-align:center",
                "padding:24px", "background:rgba(15,23,42,0.55)",
                "backdrop-filter:blur(2px)", "-webkit-backdrop-filter:blur(2px)",
                "color:#fff", "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif",
                "cursor:not-allowed", "user-select:none"
            ].join(";");
            // Swallow all interaction so the human cannot operate the page.
            ["click", "pointerdown", "mousedown", "keydown", "wheel", "touchstart", "submit"]
                .forEach((type) =>
                    overlay.addEventListener(type, (e) => { e.preventDefault(); e.stopPropagation(); }, true)
                );

            const badge = document.createElement("div");
            badge.style.cssText = "font-size:13px;font-weight:700;letter-spacing:0.08em;opacity:0.85";
            badge.textContent = "AI AGENT IN CONTROL";

            const title = document.createElement("div");
            title.style.cssText = "font-size:20px;font-weight:700";
            title.textContent = "AI が操作中です";

            const msg = document.createElement("div");
            msg.id = id + "-reason";
            msg.style.cssText = "font-size:14px;max-width:32rem;line-height:1.6;opacity:0.9";

            const spinner = document.createElement("div");
            spinner.style.cssText = [
                "width:28px", "height:28px", "border-radius:50%",
                "border:3px solid rgba(255,255,255,0.3)", "border-top-color:#fff",
                "animation:dialup-spin 0.8s linear infinite"
            ].join(";");

            if (!document.getElementById("dialup-ui-lock-style")) {
                const style = document.createElement("style");
                style.id = "dialup-ui-lock-style";
                style.textContent = "@keyframes dialup-spin{to{transform:rotate(360deg)}}";
                document.head.appendChild(style);
            }

            overlay.append(spinner, badge, title, msg);
            document.body.appendChild(overlay);
        }

        const reasonEl = document.getElementById(id + "-reason");
        if (reasonEl) {
            reasonEl.textContent = reason || "完了するまでしばらくお待ちください。";
        }
        document.body?.setAttribute("data-dialup-ui-locked", "true");
    }

    function navigate(path) {
        if (path === currentPath) return;
        send("__navigate", path);
    }

    function setupDelegation() {
        const root = document.getElementById("dialup-root");
        if (!root) return;

        root.addEventListener("click", (e) => {
            const linkEl = e.target.closest("[ws-href]");
            if (linkEl) {
                e.preventDefault();
                navigate(linkEl.getAttribute("ws-href"));
                return;
            }

            const eventEl = e.target.closest("[ws-event]");
            if (eventEl) {
                e.preventDefault();
                const event = eventEl.getAttribute("ws-event");
                const encodedParams = eventEl.getAttribute("data-dialup-params");
                let value = eventEl.getAttribute("ws-value") ?? "";
                if (encodedParams) {
                    try { value = JSON.parse(encodedParams); } catch (_error) {}
                }
                send(event, value);
            }
        });

        root.addEventListener("submit", (e) => {
            const formEl = e.target.closest("[ws-submit]");
            if (formEl) {
                e.preventDefault();
                const event = formEl.getAttribute("ws-submit");
                const value = Object.fromEntries(new FormData(formEl));
                send(event, value);
            }
        });

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

    function showJoinFailure() {
        setConnectionState(false);
        const el = document.getElementById("ws-status");
        if (el) {
            el.dataset.wsState = "join-failed";
            el.textContent = "Could not join the live session. Request a new link from the agent.";
        }
    }

    async function finalizeBrowserJoin(nonce) {
        const params = new URLSearchParams({
            tab_id: tabId,
            nonce,
        });

        const response = await fetch(`/_dialup/finalize-join?${params.toString()}`, {
            method: "POST",
            credentials: "same-origin",
        });

        if (!response.ok) {
            throw new Error("browser join finalize failed");
        }
    }

    function connectSocket(opts = {}) {
        const proto = location.protocol === "https:" ? "wss:" : "ws:";
        const tokenForThisConnection = joinToken;
        let awaitingJoinFinalize = false;
        let joinFinalizePromise = null;

        let url = `${proto}//${location.host}/ws?tab_id=${encodeURIComponent(tabId)}`;
        if (tokenForThisConnection) {
            url += `&join_token=${encodeURIComponent(tokenForThisConnection)}`;
        }

        socket = new WebSocket(url);
        let joinOpened = false;

        socket.onopen = () => {
            if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
            reconnectAttempts = 0;
            setConnectionState(true);

            if (tokenForThisConnection) {
                joinOpened = true;
                joinRetryCount = 0;
                awaitingJoinFinalize = true;
            } else if (isReconnecting) {
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

            const handlePagePayload = () => {
                if (msg.target) {
                    const el = document.getElementById(msg.target);
                    if (el) Idiomorph.morph(el, msg.html);
                } else if (msg.html !== undefined && msg.path !== undefined) {
                    if (msg.path !== currentPath) {
                        if (!isPopstateNavigation) {
                            history.pushState({ path: msg.path }, "", msg.path);
                        }
                    }
                    isPopstateNavigation = false;

                    applyUpdate(msg.html, msg.path, msg.push_event, msg.payload);
                    if (msg.title !== undefined) document.title = msg.title;
                    if (msg.ui_locked !== undefined) setUiLock(msg.ui_locked, msg.lock_reason);
                    currentPath = msg.path;
                }
            };

            if (awaitingJoinFinalize && msg.join_finalize_nonce) {
                handlePagePayload();
                joinFinalizePromise = finalizeBrowserJoin(msg.join_finalize_nonce)
                    .then(() => {
                        awaitingJoinFinalize = false;
                        clearJoinFromUrl();
                        if (socket?.readyState === WebSocket.OPEN) {
                            send("__reconnect", currentPath);
                        }
                    })
                    .catch(() => {
                        awaitingJoinFinalize = false;
                        socket?.close();
                        showJoinFailure();
                    });
                return;
            }

            handlePagePayload();
        };

        socket.onclose = () => {
            if (awaitingJoinFinalize) {
                if (joinFinalizePromise) {
                    joinFinalizePromise
                        .then(() => {
                            isReconnecting = true;
                            scheduleReconnect(opts);
                        })
                        .catch(() => showJoinFailure());
                } else {
                    showJoinFailure();
                }
                return;
            }

            if (tokenForThisConnection && !joinOpened) {
                joinRetryCount += 1;
                if (joinRetryCount >= maxJoinRetries) {
                    clearJoinFromUrl();
                    showJoinFailure();
                    return;
                }
                joinToken = tokenForThisConnection;
            }
            isReconnecting = true;
            scheduleReconnect(opts);
        };

        socket.onerror = () => {};
    }

    function scheduleReconnect(opts) {
        const delay = Math.min(1000 * (2 ** reconnectAttempts), 30000);
        reconnectAttempts++;
        setConnectionState(false);
        if (opts.onDisconnect) opts.onDisconnect(reconnectAttempts);
        reconnectTimer = setTimeout(() => connectSocket(opts), delay);
    }

    function connectUrlPath() {
        const params = new URLSearchParams(window.location.search);
        const join = params.get("_join") || joinToken;

        if (join && !params.has("_join")) {
            params.set("_join", join);
        }

        const search = params.toString();
        return search ? `${currentPath}?${search}` : currentPath;
    }

    function connect(opts = {}) {
        hooks = opts.hooks ?? {};
        currentPath = window.location.pathname;
        joinToken = new URLSearchParams(window.location.search).get("_join") || joinToken;
        history.replaceState({ path: currentPath }, "", connectUrlPath());
        setupPopstate();
        setupDelegation();
        connectSocket(opts);
    }

    return { connect, send, navigate, tabId };
})();

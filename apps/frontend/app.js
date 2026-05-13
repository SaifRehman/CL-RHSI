const cfg = window.CFG;
const tierSel = document.getElementById("tier");
const todoForm = document.getElementById("todo-form");
const todoInput = document.getElementById("todo-input");
const todoList = document.getElementById("todo-list");
const todoStatus = document.getElementById("todo-status");
const weatherForm = document.getElementById("weather-form");
const cityInput = document.getElementById("city-input");
const weatherCard = document.getElementById("weather-card");
const weatherStatus = document.getElementById("weather-status");

const currentKey = () => (tierSel.value === "premium" ? cfg.KEY_PREMIUM : cfg.KEY_FREE);

const authHeaders = () => ({
  "Authorization": `APIKEY ${currentKey()}`,
  "Content-Type": "application/json",
});

function showStatus(el, msg, kind) {
  el.textContent = msg;
  el.className = "status " + (kind || "");
}

async function handleResp(resp, statusEl) {
  if (resp.status === 401) { showStatus(statusEl, "401 Unauthorized — bad/missing API key", "error"); throw new Error("401"); }
  if (resp.status === 429) { showStatus(statusEl, "429 Too Many Requests — rate limit hit", "warn"); throw new Error("429"); }
  if (!resp.ok) { showStatus(statusEl, `HTTP ${resp.status}`, "error"); throw new Error(String(resp.status)); }
  return resp;
}

async function loadTodos() {
  showStatus(todoStatus, "");
  try {
    const r = await fetch(`${cfg.TODO_URL}/api/todos`, { headers: authHeaders() });
    await handleResp(r, todoStatus);
    const todos = await r.json();
    todoList.innerHTML = "";
    for (const t of todos) {
      const li = document.createElement("li");
      if (t.completed) li.classList.add("done");
      const span = document.createElement("span");
      span.textContent = t.title;
      const right = document.createElement("div");
      const toggle = document.createElement("button");
      toggle.textContent = t.completed ? "Undo" : "Done";
      toggle.onclick = () => toggleTodo(t);
      const del = document.createElement("button");
      del.textContent = "Delete";
      del.style.marginLeft = "0.25rem";
      del.style.background = "#c00";
      del.onclick = () => deleteTodo(t.id);
      right.append(toggle, del);
      li.append(span, right);
      todoList.append(li);
    }
  } catch (_) { /* status already shown */ }
}

async function addTodo(title) {
  showStatus(todoStatus, "Adding…");
  const r = await fetch(`${cfg.TODO_URL}/api/todos`, {
    method: "POST", headers: authHeaders(), body: JSON.stringify({ title }),
  });
  try { await handleResp(r, todoStatus); showStatus(todoStatus, ""); await loadTodos(); }
  catch (_) {}
}

async function toggleTodo(t) {
  const r = await fetch(`${cfg.TODO_URL}/api/todos/${t.id}`, {
    method: "PUT", headers: authHeaders(), body: JSON.stringify({ completed: !t.completed }),
  });
  try { await handleResp(r, todoStatus); await loadTodos(); } catch (_) {}
}

async function deleteTodo(id) {
  const r = await fetch(`${cfg.TODO_URL}/api/todos/${id}`, { method: "DELETE", headers: authHeaders() });
  try { await handleResp(r, todoStatus); await loadTodos(); } catch (_) {}
}

async function fetchWeather(city) {
  showStatus(weatherStatus, "Fetching…");
  weatherCard.textContent = "";
  const r = await fetch(`${cfg.WEATHER_URL}/current?city=${encodeURIComponent(city)}`, { headers: authHeaders() });
  try {
    await handleResp(r, weatherStatus);
    const w = await r.json();
    weatherCard.textContent = `${w.city}: ${w.temp_c}°C, wind ${w.wind_kph} km/h — ${w.description}`;
    showStatus(weatherStatus, "");
  } catch (_) {}
}

todoForm.addEventListener("submit", e => { e.preventDefault(); const v = todoInput.value.trim(); if (v) { addTodo(v); todoInput.value = ""; } });
weatherForm.addEventListener("submit", e => { e.preventDefault(); const c = cityInput.value.trim(); if (c) fetchWeather(c); });

loadTodos();

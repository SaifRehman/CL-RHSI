# CL-RHSI Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a 3-tier todo+weather demo spanning OpenShift and a RHEL VM that showcases Kuadrant AuthPolicy, RateLimitPolicy, DNSPolicy, and TLSPolicy applied via the existing Istio gateway, with the RHEL weather service joined into the cluster via Skupper v2.

**Architecture:** Three OCP namespaces hold the frontend (nginx serving static JS/HTML/CSS), the todo backend (FastAPI + asyncpg), and Postgres. A fourth namespace `demo-weather` hosts a Skupper v2 Site and Listener that materializes a cluster Service whose traffic is carried via the VAN to a podman-hosted weather container on the RHEL VM. Three HTTPRoutes attached to the pre-existing `prod-web` Gateway expose the three hosts; AuthPolicy (tiered API keys) and RateLimitPolicy are attached to the todo and weather HTTPRoutes; the frontend route is anonymous.

**Tech Stack:** Python 3.12 + FastAPI + asyncpg + pytest, PostgreSQL 16, nginx-unprivileged, Skupper v2 (CLI 2.1.1 / cluster 2.0.1-rh-2), Gateway API v1 + Istio gatewayclass, Kuadrant v1 (AuthPolicy, RateLimitPolicy), Quay.io for image hosting, OpenShift 4.x.

---

## File Structure

```
apps/
  frontend/
    index.html           # UI shell (todo list + weather card + tier dropdown)
    style.css            # minimal styling
    app.js               # fetch logic + DOM updates
    config.js.template   # window.CFG = { TODO_URL, WEATHER_URL, KEY_FREE, KEY_PREMIUM }
  todo-backend/
    main.py              # FastAPI app, CORS, routes
    db.py                # asyncpg pool + schema-init helper
    models.py            # pydantic Todo, TodoCreate, TodoUpdate
    requirements.txt
    Containerfile
    tests/
      conftest.py        # pytest fixture: in-memory dict DB monkey-patched onto db.py
      test_main.py       # endpoint behavior tests
  weather/
    main.py              # FastAPI app: /current?city= via Open-Meteo
    requirements.txt
    Containerfile
    tests/
      test_main.py       # behavior tests with httpx mocking
manifests/
  00-namespaces.yaml
  10-db/
    01-secret.yaml
    02-pvc.yaml
    03-init-configmap.yaml
    04-deployment.yaml
    05-service.yaml
  20-todo/
    01-secret.yaml
    02-deployment.yaml
    03-service.yaml
  30-frontend/
    01-configmap.yaml        # static files; replaced by deploy script with real keys
    02-deployment.yaml
    03-service.yaml
  40-weather-skupper/
    01-site.yaml             # Skupper Site
    02-listener.yaml         # routingKey=weather, host=weather, port=8080
    03-access-grant.yaml     # for RHEL to redeem
  50-routes/
    01-reference-grants.yaml # one per app namespace
    02-app-route.yaml
    03-todo-route.yaml
    04-weather-route.yaml
  60-policies/
    01-api-keys.yaml         # two API key Secrets in kuadrant-system
    02-todo-auth.yaml
    03-todo-ratelimit.yaml
    04-weather-auth.yaml
    05-weather-ratelimit.yaml
rhel/
  setup.sh                   # idempotent: install podman if needed, pull weather image, run container, set up Skupper podman site, redeem AccessToken, create connector
  weather.container          # systemd Quadlet for autostart (optional)
scripts/
  build-push.sh              # podman login + build/push both images to Quay
  deploy-ocp.sh              # apply manifests in order, render config.js, wait for ready
  deploy-rhel.sh             # rsync rhel/ + AccessToken yaml to VM, run setup.sh
  test-policies.sh           # curl sequence asserting 401/429/200 expectations
  cleanup.sh                 # delete namespaces + RHEL teardown
.gitignore
README.md
```

---

## Phase 0 — Repo bootstrap

### Task 1: Initialize repo layout

**Files:**
- Create: `.gitignore`
- Create: `apps/.gitkeep`, `manifests/.gitkeep`, `rhel/.gitkeep`, `scripts/.gitkeep`
- Modify: `README.md` (placeholder line so the existing file is preserved)

- [ ] **Step 1: Create directory skeleton and .gitignore**

Run:
```bash
cd /Users/saif/Desktop/CL-RHSI
mkdir -p apps/frontend apps/todo-backend/tests apps/weather/tests
mkdir -p manifests/10-db manifests/20-todo manifests/30-frontend manifests/40-weather-skupper manifests/50-routes manifests/60-policies
mkdir -p rhel scripts
```

Write `.gitignore`:
```
__pycache__/
*.pyc
.venv/
.pytest_cache/
.DS_Store
rhel/link-token.yaml
manifests/30-frontend/01-configmap.rendered.yaml
*.local.yaml
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore apps manifests rhel scripts
git commit -m "Bootstrap CL-RHSI repo layout"
```

---

## Phase 1 — Todo backend (Python, TDD)

### Task 2: Define pydantic models and DB layer skeleton

**Files:**
- Create: `apps/todo-backend/requirements.txt`
- Create: `apps/todo-backend/models.py`
- Create: `apps/todo-backend/db.py`
- Create: `apps/todo-backend/tests/__init__.py`

- [ ] **Step 1: Write requirements.txt**

```
fastapi==0.115.0
uvicorn[standard]==0.30.6
asyncpg==0.29.0
pydantic==2.9.2
httpx==0.27.2
pytest==8.3.3
pytest-asyncio==0.24.0
```

- [ ] **Step 2: Write models.py**

```python
from pydantic import BaseModel, Field
from typing import Optional

class TodoCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)

class TodoUpdate(BaseModel):
    title: Optional[str] = Field(default=None, min_length=1, max_length=200)
    completed: Optional[bool] = None

class Todo(BaseModel):
    id: int
    title: str
    completed: bool
```

- [ ] **Step 3: Write db.py with a swappable backend interface**

```python
import os
import asyncpg
from typing import Optional

_pool: Optional[asyncpg.Pool] = None

async def init_pool() -> None:
    global _pool
    _pool = await asyncpg.create_pool(
        host=os.environ["PG_HOST"],
        port=int(os.environ.get("PG_PORT", "5432")),
        database=os.environ["PG_DB"],
        user=os.environ["PG_USER"],
        password=os.environ["PG_PASSWORD"],
        min_size=1,
        max_size=5,
    )
    async with _pool.acquire() as conn:
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS todos (
                id SERIAL PRIMARY KEY,
                title TEXT NOT NULL,
                completed BOOLEAN NOT NULL DEFAULT FALSE
            )
        """)

async def close_pool() -> None:
    global _pool
    if _pool:
        await _pool.close()
        _pool = None

async def list_todos() -> list[dict]:
    async with _pool.acquire() as conn:
        rows = await conn.fetch("SELECT id, title, completed FROM todos ORDER BY id")
        return [dict(r) for r in rows]

async def create_todo(title: str) -> dict:
    async with _pool.acquire() as conn:
        row = await conn.fetchrow(
            "INSERT INTO todos (title) VALUES ($1) RETURNING id, title, completed",
            title,
        )
        return dict(row)

async def update_todo(todo_id: int, title: Optional[str], completed: Optional[bool]) -> Optional[dict]:
    async with _pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            UPDATE todos
            SET title = COALESCE($2, title),
                completed = COALESCE($3, completed)
            WHERE id = $1
            RETURNING id, title, completed
            """,
            todo_id, title, completed,
        )
        return dict(row) if row else None

async def delete_todo(todo_id: int) -> bool:
    async with _pool.acquire() as conn:
        result = await conn.execute("DELETE FROM todos WHERE id = $1", todo_id)
        return result.endswith(" 1")
```

- [ ] **Step 4: Create empty test package marker**

Write `apps/todo-backend/tests/__init__.py` as an empty file.

- [ ] **Step 5: Commit**

```bash
git add apps/todo-backend/
git commit -m "todo: add models, requirements, and db layer"
```

### Task 3: Write failing tests for todo endpoints

**Files:**
- Create: `apps/todo-backend/tests/conftest.py`
- Create: `apps/todo-backend/tests/test_main.py`

- [ ] **Step 1: Write conftest.py with in-memory DB monkey-patch**

```python
import pytest
import pytest_asyncio
from fastapi.testclient import TestClient
from unittest.mock import AsyncMock

@pytest.fixture
def fake_store():
    """An in-memory store the test patches into db.* functions."""
    return {"next_id": 1, "rows": {}}

@pytest.fixture
def client(monkeypatch, fake_store):
    """Imports main with db.* functions replaced by in-memory implementations."""
    from apps.todo_backend import db, main

    async def init_pool(): pass
    async def close_pool(): pass

    async def list_todos():
        return [dict(r) for r in fake_store["rows"].values()]

    async def create_todo(title):
        i = fake_store["next_id"]
        fake_store["next_id"] += 1
        row = {"id": i, "title": title, "completed": False}
        fake_store["rows"][i] = row
        return dict(row)

    async def update_todo(todo_id, title, completed):
        row = fake_store["rows"].get(todo_id)
        if not row:
            return None
        if title is not None:
            row["title"] = title
        if completed is not None:
            row["completed"] = completed
        return dict(row)

    async def delete_todo(todo_id):
        return fake_store["rows"].pop(todo_id, None) is not None

    monkeypatch.setattr(db, "init_pool", init_pool)
    monkeypatch.setattr(db, "close_pool", close_pool)
    monkeypatch.setattr(db, "list_todos", list_todos)
    monkeypatch.setattr(db, "create_todo", create_todo)
    monkeypatch.setattr(db, "update_todo", update_todo)
    monkeypatch.setattr(db, "delete_todo", delete_todo)

    # Re-import main to ensure it uses the patched db
    return TestClient(main.app)
```

- [ ] **Step 2: Write test_main.py covering CRUD + health**

```python
def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"ok": True}

def test_list_initially_empty(client):
    r = client.get("/api/todos")
    assert r.status_code == 200
    assert r.json() == []

def test_create_then_list(client):
    r = client.post("/api/todos", json={"title": "buy milk"})
    assert r.status_code == 201
    body = r.json()
    assert body["title"] == "buy milk"
    assert body["completed"] is False
    assert isinstance(body["id"], int)

    r = client.get("/api/todos")
    assert len(r.json()) == 1

def test_create_rejects_empty_title(client):
    r = client.post("/api/todos", json={"title": ""})
    assert r.status_code == 422

def test_update_completed(client):
    r = client.post("/api/todos", json={"title": "x"})
    tid = r.json()["id"]
    r = client.put(f"/api/todos/{tid}", json={"completed": True})
    assert r.status_code == 200
    assert r.json()["completed"] is True

def test_update_missing_returns_404(client):
    r = client.put("/api/todos/9999", json={"completed": True})
    assert r.status_code == 404

def test_delete(client):
    r = client.post("/api/todos", json={"title": "x"})
    tid = r.json()["id"]
    r = client.delete(f"/api/todos/{tid}")
    assert r.status_code == 204
    r = client.get("/api/todos")
    assert r.json() == []

def test_delete_missing_returns_404(client):
    r = client.delete("/api/todos/9999")
    assert r.status_code == 404
```

- [ ] **Step 3: Run tests to confirm they fail**

```bash
cd /Users/saif/Desktop/CL-RHSI
python3 -m venv .venv
source .venv/bin/activate
pip install -r apps/todo-backend/requirements.txt
# Make apps/todo-backend importable as a package
touch apps/__init__.py apps/todo-backend/__init__.py
# rename module dashes -> use a pyproject root path
PYTHONPATH=. pytest apps/todo-backend/tests/ -v
```
Expected: ImportError/ModuleNotFoundError because `main.py` doesn't exist yet — or AttributeError on `main.app`.

**Note for next task:** Python module names can't contain dashes. We import via `apps.todo_backend`. That requires the directory to be `apps/todo-backend` on disk but a symlink or `sys.path` insertion will be used. Simplest path: rename module to `apps/todo_backend` on disk and reference dashed name only in the Containerfile if needed. **Use `apps/todo_backend` (underscore) as the directory name** — fix file paths in Tasks 2 and 3 by renaming, then in remaining tasks use the underscore form.

- [ ] **Step 4: Rename the directory to use underscores and re-run**

```bash
git mv apps/todo-backend apps/todo_backend
touch apps/__init__.py apps/todo_backend/__init__.py
PYTHONPATH=. pytest apps/todo_backend/tests/ -v
```
Expected: still fail (no main.py yet).

- [ ] **Step 5: Commit failing tests**

```bash
git add apps/todo_backend/ apps/__init__.py
git commit -m "todo: failing tests for CRUD + healthz"
```

### Task 4: Implement FastAPI app to satisfy tests

**Files:**
- Create: `apps/todo_backend/main.py`

- [ ] **Step 1: Write main.py**

```python
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Response, status
from fastapi.middleware.cors import CORSMiddleware
from . import db, models

ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "https://app.travels.sandbox3259.opentlc.com")

@asynccontextmanager
async def lifespan(_app: FastAPI):
    await db.init_pool()
    yield
    await db.close_pool()

app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[ALLOWED_ORIGIN],
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

@app.get("/healthz")
async def healthz():
    return {"ok": True}

@app.get("/api/todos", response_model=list[models.Todo])
async def list_todos():
    return await db.list_todos()

@app.post("/api/todos", response_model=models.Todo, status_code=status.HTTP_201_CREATED)
async def create_todo(payload: models.TodoCreate):
    return await db.create_todo(payload.title)

@app.put("/api/todos/{todo_id}", response_model=models.Todo)
async def update_todo(todo_id: int, payload: models.TodoUpdate):
    row = await db.update_todo(todo_id, payload.title, payload.completed)
    if row is None:
        raise HTTPException(status_code=404, detail="not found")
    return row

@app.delete("/api/todos/{todo_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_todo(todo_id: int):
    ok = await db.delete_todo(todo_id)
    if not ok:
        raise HTTPException(status_code=404, detail="not found")
    return Response(status_code=204)
```

- [ ] **Step 2: Run tests, fix any remaining issues until green**

```bash
cd /Users/saif/Desktop/CL-RHSI
source .venv/bin/activate
PYTHONPATH=. pytest apps/todo_backend/tests/ -v
```
Expected: 8 passed.

If failures: fix in `main.py`, re-run until green.

- [ ] **Step 3: Commit passing implementation**

```bash
git add apps/todo_backend/main.py
git commit -m "todo: implement CRUD endpoints"
```

### Task 5: Write Containerfile for todo backend

**Files:**
- Create: `apps/todo_backend/Containerfile`

- [ ] **Step 1: Write Containerfile**

```Dockerfile
FROM registry.access.redhat.com/ubi9/python-312:latest

USER 0
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py ./
# Make this a package-importable module under /app
RUN mkdir -p /app/todo_backend && mv *.py /app/todo_backend/ && touch /app/todo_backend/__init__.py && \
    echo "" > /app/__init__.py

USER 1001
EXPOSE 8000
CMD ["uvicorn", "todo_backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 2: Build locally to validate**

```bash
cd apps/todo_backend
podman build -t todo:test -f Containerfile .
podman images | grep todo:test
```
Expected: image present.

- [ ] **Step 3: Commit**

```bash
cd /Users/saif/Desktop/CL-RHSI
git add apps/todo_backend/Containerfile
git commit -m "todo: add Containerfile"
```

---

## Phase 2 — Weather service (Python, TDD)

### Task 6: Define weather requirements and failing tests

**Files:**
- Create: `apps/weather/requirements.txt`
- Create: `apps/weather/__init__.py`
- Create: `apps/weather/tests/__init__.py`
- Create: `apps/weather/tests/test_main.py`

- [ ] **Step 1: Write requirements.txt**

```
fastapi==0.115.0
uvicorn[standard]==0.30.6
httpx==0.27.2
pytest==8.3.3
pytest-asyncio==0.24.0
respx==0.21.1
```

- [ ] **Step 2: Write tests/test_main.py**

```python
import respx
import httpx
from fastapi.testclient import TestClient
import importlib

@respx.mock
def test_current_returns_weather(monkeypatch):
    geo = respx.get("https://geocoding-api.open-meteo.com/v1/search").mock(
        return_value=httpx.Response(200, json={
            "results": [{"name": "Berlin", "latitude": 52.52, "longitude": 13.41}]
        })
    )
    forecast = respx.get("https://api.open-meteo.com/v1/forecast").mock(
        return_value=httpx.Response(200, json={
            "current": {"temperature_2m": 12.3, "wind_speed_10m": 7.5, "weather_code": 3}
        })
    )
    from apps.weather import main
    importlib.reload(main)
    client = TestClient(main.app)
    r = client.get("/current?city=Berlin")
    assert r.status_code == 200
    body = r.json()
    assert body["city"] == "Berlin"
    assert body["temp_c"] == 12.3
    assert body["wind_kph"] == 7.5
    assert body["weather_code"] == 3
    assert "description" in body
    assert geo.called and forecast.called

@respx.mock
def test_current_404_when_city_unknown():
    respx.get("https://geocoding-api.open-meteo.com/v1/search").mock(
        return_value=httpx.Response(200, json={})  # no "results" key
    )
    from apps.weather import main
    importlib.reload(main)
    client = TestClient(main.app)
    r = client.get("/current?city=Atlantis")
    assert r.status_code == 404

def test_healthz():
    from apps.weather import main
    importlib.reload(main)
    client = TestClient(main.app)
    r = client.get("/healthz")
    assert r.status_code == 200
```

- [ ] **Step 3: Run tests to confirm they fail**

```bash
cd /Users/saif/Desktop/CL-RHSI
source .venv/bin/activate
pip install -r apps/weather/requirements.txt
touch apps/weather/__init__.py apps/weather/tests/__init__.py
PYTHONPATH=. pytest apps/weather/tests/ -v
```
Expected: ImportError on `apps.weather.main`.

- [ ] **Step 4: Commit failing tests**

```bash
git add apps/weather/
git commit -m "weather: failing tests for /current and /healthz"
```

### Task 7: Implement weather FastAPI app

**Files:**
- Create: `apps/weather/main.py`

- [ ] **Step 1: Write main.py**

```python
import os
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "https://app.travels.sandbox3259.opentlc.com")
GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"

WEATHER_CODES = {
    0: "Clear sky", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
    45: "Fog", 48: "Rime fog", 51: "Light drizzle", 53: "Drizzle",
    55: "Dense drizzle", 61: "Light rain", 63: "Rain", 65: "Heavy rain",
    71: "Light snow", 73: "Snow", 75: "Heavy snow", 80: "Rain showers",
    81: "Heavy rain showers", 95: "Thunderstorm", 96: "Thunderstorm w/ hail",
}

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=[ALLOWED_ORIGIN],
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

@app.get("/healthz")
async def healthz():
    return {"ok": True}

@app.get("/current")
async def current(city: str):
    async with httpx.AsyncClient(timeout=10.0) as http:
        geo_r = await http.get(GEOCODE_URL, params={"name": city, "count": 1})
        geo_r.raise_for_status()
        geo = geo_r.json()
        results = geo.get("results") or []
        if not results:
            raise HTTPException(status_code=404, detail=f"unknown city: {city}")
        place = results[0]
        forecast_r = await http.get(FORECAST_URL, params={
            "latitude": place["latitude"],
            "longitude": place["longitude"],
            "current": "temperature_2m,wind_speed_10m,weather_code",
        })
        forecast_r.raise_for_status()
        cur = forecast_r.json().get("current", {})
        code = cur.get("weather_code", 0)
        return {
            "city": place["name"],
            "temp_c": cur.get("temperature_2m"),
            "wind_kph": cur.get("wind_speed_10m"),
            "weather_code": code,
            "description": WEATHER_CODES.get(code, "Unknown"),
        }
```

- [ ] **Step 2: Run tests until green**

```bash
PYTHONPATH=. pytest apps/weather/tests/ -v
```
Expected: 3 passed.

- [ ] **Step 3: Commit**

```bash
git add apps/weather/main.py
git commit -m "weather: implement /current proxying Open-Meteo"
```

### Task 8: Write Containerfile for weather

**Files:**
- Create: `apps/weather/Containerfile`

- [ ] **Step 1: Write Containerfile**

```Dockerfile
FROM registry.access.redhat.com/ubi9/python-312:latest

USER 0
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py ./
USER 1001
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

- [ ] **Step 2: Build locally**

```bash
cd apps/weather
podman build -t weather:test -f Containerfile .
podman run --rm -d -p 18080:8080 --name weather-smoke weather:test
sleep 2
curl -sf localhost:18080/healthz
podman stop weather-smoke
```
Expected: `{"ok":true}`.

- [ ] **Step 3: Commit**

```bash
cd /Users/saif/Desktop/CL-RHSI
git add apps/weather/Containerfile
git commit -m "weather: add Containerfile"
```

---

## Phase 3 — Frontend (vanilla JS)

### Task 9: Write frontend static files

**Files:**
- Create: `apps/frontend/index.html`
- Create: `apps/frontend/style.css`
- Create: `apps/frontend/app.js`
- Create: `apps/frontend/config.js.template`

- [ ] **Step 1: Write config.js.template**

```javascript
// Rendered by scripts/deploy-ocp.sh into a ConfigMap as config.js
window.CFG = {
  TODO_URL: "__TODO_URL__",
  WEATHER_URL: "__WEATHER_URL__",
  KEY_FREE: "__KEY_FREE__",
  KEY_PREMIUM: "__KEY_PREMIUM__",
};
```

- [ ] **Step 2: Write index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>CL-RHSI Demo</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header>
    <h1>CL-RHSI Demo</h1>
    <div class="tier">
      <label for="tier">Identity tier:</label>
      <select id="tier">
        <option value="free">free (5/min)</option>
        <option value="premium">premium (30/min)</option>
      </select>
    </div>
  </header>

  <main>
    <section id="todo-section">
      <h2>Todos</h2>
      <form id="todo-form">
        <input id="todo-input" placeholder="What needs doing?" maxlength="200" required>
        <button type="submit">Add</button>
      </form>
      <ul id="todo-list"></ul>
      <div id="todo-status" class="status"></div>
    </section>

    <section id="weather-section">
      <h2>Weather</h2>
      <form id="weather-form">
        <input id="city-input" placeholder="City (e.g. Berlin)" required>
        <button type="submit">Fetch</button>
      </form>
      <div id="weather-card"></div>
      <div id="weather-status" class="status"></div>
    </section>
  </main>

  <script src="config.js"></script>
  <script src="app.js"></script>
</body>
</html>
```

- [ ] **Step 3: Write style.css**

```css
body { font-family: -apple-system, Segoe UI, sans-serif; max-width: 780px; margin: 2rem auto; padding: 0 1rem; color: #222; }
header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #ddd; padding-bottom: 1rem; }
main { display: grid; gap: 2rem; margin-top: 2rem; }
section { background: #fafafa; padding: 1rem 1.25rem; border-radius: 8px; }
form { display: flex; gap: 0.5rem; }
input { flex: 1; padding: 0.5rem; border: 1px solid #ccc; border-radius: 4px; }
button { padding: 0.5rem 1rem; background: #0066cc; color: white; border: 0; border-radius: 4px; cursor: pointer; }
button:hover { background: #0052a3; }
ul { list-style: none; padding: 0; }
li { display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid #eee; }
li.done span { text-decoration: line-through; color: #999; }
.status { margin-top: 0.5rem; font-size: 0.9rem; min-height: 1.2rem; }
.status.error { color: #c00; }
.status.warn { color: #c80; }
#weather-card { padding: 0.5rem 0; font-size: 1.1rem; }
```

- [ ] **Step 4: Write app.js**

```javascript
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
```

- [ ] **Step 5: Sanity check the HTML loads locally**

```bash
cd apps/frontend
# Render a dummy config.js so loading the page doesn't 404 on the script
cp config.js.template config.js
sed -i.bak 's|__TODO_URL__|http://localhost:8000|g; s|__WEATHER_URL__|http://localhost:8081|g; s|__KEY_FREE__|fake|g; s|__KEY_PREMIUM__|fake|g' config.js
rm config.js.bak
python3 -m http.server 18000 &
SERVE_PID=$!
sleep 1
curl -sf localhost:18000/ | grep -q "CL-RHSI Demo"
kill $SERVE_PID
rm config.js
```
Expected: grep matches; clean exit code 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/saif/Desktop/CL-RHSI
git add apps/frontend/
git commit -m "frontend: vanilla JS UI for todos and weather"
```

---

## Phase 4 — Build & push images to Quay

### Task 10: Write build-push script and push images

**Files:**
- Create: `scripts/build-push.sh`

- [ ] **Step 1: Write build-push.sh**

```bash
#!/usr/bin/env bash
# Build and push todo + weather images to Quay.
# Requires: QUAY_USER and QUAY_TOKEN env vars.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${QUAY_USER:?set QUAY_USER}"
: "${QUAY_TOKEN:?set QUAY_TOKEN}"

echo ">>> podman login quay.io"
echo "$QUAY_TOKEN" | podman login quay.io -u "$QUAY_USER" --password-stdin

echo ">>> build + push todo"
podman build --platform=linux/amd64 -t quay.io/rh-ee-srehman/todo:latest -f "$HERE/apps/todo_backend/Containerfile" "$HERE/apps/todo_backend"
podman push quay.io/rh-ee-srehman/todo:latest

echo ">>> build + push weather"
podman build --platform=linux/amd64 -t quay.io/rh-ee-srehman/weather:latest -f "$HERE/apps/weather/Containerfile" "$HERE/apps/weather"
podman push quay.io/rh-ee-srehman/weather:latest

echo ">>> done."
```

- [ ] **Step 2: Make executable and run**

```bash
chmod +x scripts/build-push.sh
export QUAY_USER='rh-ee-srehman'
export QUAY_TOKEN='IjGCfOGJrFzcVSq5RVt6mMjxndBtnXO+J/HcS4zAGOv7XevmTj/eP+92dJ83kSfs'
./scripts/build-push.sh
```
Expected: both pushes succeed; final line `>>> done.`

- [ ] **Step 3: Make Quay repos public**

The robot account already has push, but pulls from OpenShift must be unauthenticated. After first push, in Quay UI, set both `rh-ee-srehman/todo` and `rh-ee-srehman/weather` repositories to **Public**. If they're already public from earlier setup, skip. If not, do this in the browser.

Verify with:
```bash
podman logout quay.io
podman pull --quiet quay.io/rh-ee-srehman/todo:latest
podman pull --quiet quay.io/rh-ee-srehman/weather:latest
```
Expected: both pull anonymously.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-push.sh
git commit -m "scripts: build and push images to Quay"
```

---

## Phase 5 — Cluster: namespaces, DB

### Task 11: Namespaces manifest

**Files:**
- Create: `manifests/00-namespaces.yaml`

- [ ] **Step 1: Write namespaces.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo-frontend
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo-todo
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo-db
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo-weather
```

- [ ] **Step 2: Apply and verify**

```bash
oc apply -f manifests/00-namespaces.yaml
oc get ns demo-frontend demo-todo demo-db demo-weather
```
Expected: all four `Active`.

- [ ] **Step 3: Commit**

```bash
git add manifests/00-namespaces.yaml
git commit -m "manifests: create four demo namespaces"
```

### Task 12: PostgreSQL deployment

**Files:**
- Create: `manifests/10-db/01-secret.yaml`
- Create: `manifests/10-db/02-pvc.yaml`
- Create: `manifests/10-db/03-init-configmap.yaml`
- Create: `manifests/10-db/04-deployment.yaml`
- Create: `manifests/10-db/05-service.yaml`

- [ ] **Step 1: Write secret.yaml**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-creds
  namespace: demo-db
type: Opaque
stringData:
  POSTGRESQL_USER: todo
  POSTGRESQL_PASSWORD: clrhsi-demo-2026
  POSTGRESQL_DATABASE: todos
```

- [ ] **Step 2: Write pvc.yaml**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: demo-db
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 3: Write init-configmap.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
  namespace: demo-db
data:
  init.sql: |
    CREATE TABLE IF NOT EXISTS todos (
        id SERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        completed BOOLEAN NOT NULL DEFAULT FALSE
    );
```

- [ ] **Step 4: Write deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: demo-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: registry.redhat.io/rhel9/postgresql-16:latest
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgres-creds
          volumeMounts:
            - name: data
              mountPath: /var/lib/pgsql/data
            - name: init
              mountPath: /opt/app-root/src/postgresql-start
          readinessProbe:
            exec:
              command: ["bash", "-c", "psql -U $POSTGRESQL_USER -d $POSTGRESQL_DATABASE -c 'select 1'"]
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
        - name: init
          configMap:
            name: postgres-init
```

- [ ] **Step 5: Write service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: demo-db
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
```

- [ ] **Step 6: Apply and verify**

```bash
oc apply -f manifests/10-db/
oc -n demo-db rollout status deploy/postgres --timeout=180s
oc -n demo-db rsh deploy/postgres psql -U todo -d todos -c '\dt'
```
Expected: rollout succeeds; `\dt` shows `todos` table (or "Did not find any relations" — the init script runs only on first init; if so, drop into psql and run the CREATE manually, or delete PVC and re-init).

If `\dt` shows nothing, the rhel9 image expects init scripts in `/opt/app-root/src/postgresql-start/*.sh`, not `.sql`. Fix by changing the ConfigMap key to `init.sh`:

```yaml
data:
  init.sh: |
    #!/bin/bash
    psql -d $POSTGRESQL_DATABASE <<'SQL'
    CREATE TABLE IF NOT EXISTS todos (
        id SERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        completed BOOLEAN NOT NULL DEFAULT FALSE
    );
    SQL
```
Re-apply, delete the postgres pod, wait for re-roll. The backend's `init_pool()` also runs CREATE TABLE IF NOT EXISTS, so this is belt-and-suspenders.

- [ ] **Step 7: Commit**

```bash
git add manifests/10-db/
git commit -m "manifests: PostgreSQL with init schema"
```

---

## Phase 6 — Cluster: todo backend deploy

### Task 13: Todo backend manifests

**Files:**
- Create: `manifests/20-todo/01-secret.yaml`
- Create: `manifests/20-todo/02-deployment.yaml`
- Create: `manifests/20-todo/03-service.yaml`

- [ ] **Step 1: Write secret.yaml (mirrors DB creds into the todo namespace)**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
  namespace: demo-todo
type: Opaque
stringData:
  PG_HOST: postgres.demo-db.svc.cluster.local
  PG_PORT: "5432"
  PG_DB: todos
  PG_USER: todo
  PG_PASSWORD: clrhsi-demo-2026
```

- [ ] **Step 2: Write deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: todo-backend
  namespace: demo-todo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: todo-backend
  template:
    metadata:
      labels:
        app: todo-backend
    spec:
      containers:
        - name: app
          image: quay.io/rh-ee-srehman/todo:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 8000
          envFrom:
            - secretRef:
                name: db-creds
          env:
            - name: ALLOWED_ORIGIN
              value: https://app.travels.sandbox3259.opentlc.com
          readinessProbe:
            httpGet: { path: /healthz, port: 8000 }
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: 8000 }
            initialDelaySeconds: 20
            periodSeconds: 10
```

- [ ] **Step 3: Write service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: todo-backend
  namespace: demo-todo
spec:
  selector:
    app: todo-backend
  ports:
    - port: 8000
      targetPort: 8000
```

- [ ] **Step 4: Apply and verify**

```bash
oc apply -f manifests/20-todo/
oc -n demo-todo rollout status deploy/todo-backend --timeout=180s
oc -n demo-todo run curlpod --image=curlimages/curl --rm -i --restart=Never -- \
  curl -sf http://todo-backend:8000/healthz
```
Expected: `{"ok":true}`.

- [ ] **Step 5: Commit**

```bash
git add manifests/20-todo/
git commit -m "manifests: todo-backend deployment + service"
```

---

## Phase 7 — Cluster: Skupper site + Listener for weather

### Task 14: Skupper Site, Listener, AccessGrant

**Files:**
- Create: `manifests/40-weather-skupper/01-site.yaml`
- Create: `manifests/40-weather-skupper/02-listener.yaml`
- Create: `manifests/40-weather-skupper/03-access-grant.yaml`

- [ ] **Step 1: Write site.yaml**

```yaml
apiVersion: skupper.io/v2alpha1
kind: Site
metadata:
  name: demo-weather
  namespace: demo-weather
spec:
  linkAccess: default
```

- [ ] **Step 2: Write listener.yaml**

```yaml
apiVersion: skupper.io/v2alpha1
kind: Listener
metadata:
  name: weather
  namespace: demo-weather
spec:
  routingKey: weather
  host: weather
  port: 8080
```

- [ ] **Step 3: Write access-grant.yaml**

```yaml
apiVersion: skupper.io/v2alpha1
kind: AccessGrant
metadata:
  name: weather-grant
  namespace: demo-weather
spec:
  redemptionsAllowed: 5
  expirationWindow: 24h
```

- [ ] **Step 4: Apply and verify**

```bash
oc apply -f manifests/40-weather-skupper/
oc -n demo-weather wait --for=condition=Ready site/demo-weather --timeout=180s
oc -n demo-weather get listener weather
oc -n demo-weather get svc weather
```
Expected: Site Ready=True; Listener present; Service `weather` exists on port 8080.

`oc -n demo-weather get svc weather` should show a ClusterIP and port 8080 — Skupper's controller creates the Service to match the Listener's `host` field. At this point the Listener has no matching connector so calls will hang; we wire that on RHEL in Phase 9.

- [ ] **Step 5: Extract the AccessToken for RHEL**

```bash
oc -n demo-weather wait --for=condition=Resolved accessgrant/weather-grant --timeout=60s
oc -n demo-weather get accessgrant weather-grant -o yaml > /tmp/grant.yaml
# The controller issues a Secret named after the grant or stamps url/code/ca on the grant status.
# Generate a portable AccessToken document:
URL=$(oc -n demo-weather get accessgrant weather-grant -o jsonpath='{.status.url}')
CODE=$(oc -n demo-weather get accessgrant weather-grant -o jsonpath='{.status.code}')
CA=$(oc -n demo-weather get accessgrant weather-grant -o jsonpath='{.status.ca}')
cat > rhel/link-token.yaml <<EOF
apiVersion: skupper.io/v2alpha1
kind: AccessToken
metadata:
  name: link-to-cluster
spec:
  url: ${URL}
  code: ${CODE}
  ca: |
$(echo "${CA}" | sed 's/^/    /')
EOF
echo "Wrote rhel/link-token.yaml"
```
Expected: file `rhel/link-token.yaml` written; spec contains URL, code, and CA block. The token is gitignored so we don't commit it.

- [ ] **Step 6: Commit**

```bash
git add manifests/40-weather-skupper/
git commit -m "manifests: Skupper Site, Listener, AccessGrant in demo-weather"
```

---

## Phase 8 — RHEL: weather container + Skupper podman site

### Task 15: RHEL setup script

**Files:**
- Create: `rhel/setup.sh`
- Create: `scripts/deploy-rhel.sh`

- [ ] **Step 1: Write rhel/setup.sh**

```bash
#!/usr/bin/env bash
# Run ON the RHEL VM. Idempotent.
set -euo pipefail
echo "==> [rhel] start setup"

# 1. Tools
if ! command -v podman >/dev/null; then sudo dnf install -y podman; fi
if ! command -v skupper >/dev/null; then
  curl -fL https://github.com/skupperproject/skupper/releases/download/2.1.1/skupper-cli-2.1.1-linux-amd64.tgz -o /tmp/skupper.tgz
  tar -xzf /tmp/skupper.tgz -C /tmp
  mkdir -p ~/.local/bin && mv /tmp/skupper ~/.local/bin/skupper
  export PATH="$HOME/.local/bin:$PATH"
fi
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# 2. Enable user systemd lingering so podman survives logout
sudo loginctl enable-linger "$(whoami)"

# 3. Pull and run weather (idempotent)
podman pull quay.io/rh-ee-srehman/weather:latest
podman rm -f weather-app 2>/dev/null || true
podman run -d --name weather-app --restart=unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -e ALLOWED_ORIGIN='https://app.travels.sandbox3259.opentlc.com' \
  quay.io/rh-ee-srehman/weather:latest

# Smoke test
sleep 2
curl -sf http://127.0.0.1:8080/healthz | grep -q '"ok":true'
echo "==> [rhel] weather container healthy"

# 4. Skupper podman site
export PATH="$HOME/.local/bin:$PATH"
export SKUPPER_PLATFORM=podman
mkdir -p ~/.local/share/skupper
skupper site create cl-rhsi-rhel || true
skupper token redeem ~/cl-rhsi/link-token.yaml
# Determine the host podman exposes to containers
HOSTIP="$(ip -4 addr show podman0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
[ -z "$HOSTIP" ] && HOSTIP="$(hostname -I | awk '{print $1}')"
skupper connector create weather 8080 --routing-key weather --host "$HOSTIP" || \
  skupper connector update weather --port 8080 --host "$HOSTIP"
skupper status
echo "==> [rhel] done"
```

- [ ] **Step 2: Write scripts/deploy-rhel.sh (driver from laptop)**

```bash
#!/usr/bin/env bash
# Copies rhel/ to the VM and runs setup.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${RHEL_HOST:=rhel.rfztg.sandbox2786.opentlc.com}"
: "${RHEL_USER:=lab-user}"
: "${RHEL_PASS:=MjM4Mjcy}"

if ! command -v sshpass >/dev/null; then
  echo "sshpass required: brew install hudochenkov/sshpass/sshpass (or use ssh-key auth and unset RHEL_PASS)" >&2
  exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
RSYNC_RSH="sshpass -p '$RHEL_PASS' ssh $SSH_OPTS"

echo ">>> rsync rhel/ to $RHEL_USER@$RHEL_HOST:~/cl-rhsi"
sshpass -p "$RHEL_PASS" ssh $SSH_OPTS "$RHEL_USER@$RHEL_HOST" "mkdir -p ~/cl-rhsi"
sshpass -p "$RHEL_PASS" rsync -az -e "ssh $SSH_OPTS" "$HERE/rhel/" "$RHEL_USER@$RHEL_HOST:~/cl-rhsi/"

echo ">>> running rhel/setup.sh"
sshpass -p "$RHEL_PASS" ssh $SSH_OPTS "$RHEL_USER@$RHEL_HOST" "bash ~/cl-rhsi/setup.sh"
```

- [ ] **Step 3: Make executable and run**

```bash
chmod +x rhel/setup.sh scripts/deploy-rhel.sh
brew install hudochenkov/sshpass/sshpass 2>/dev/null || true
./scripts/deploy-rhel.sh
```
Expected: final lines show `skupper status` reporting site `cl-rhsi-rhel` and 2 sites in network.

- [ ] **Step 4: Verify cluster side sees the link**

```bash
oc -n demo-weather get sites.skupper.io demo-weather -o jsonpath='{.status.sitesInNetwork}'; echo
oc -n demo-weather get listener weather -o jsonpath='{.status.hasMatchingConnector}'; echo
oc -n demo-weather run curlpod --image=curlimages/curl --rm -i --restart=Never -- \
  curl -sf http://weather:8080/healthz
```
Expected: `2`, `true`, `{"ok":true}`.

- [ ] **Step 5: Commit**

```bash
git add rhel/setup.sh scripts/deploy-rhel.sh
git commit -m "rhel: weather container + skupper podman site setup"
```

---

## Phase 9 — Cluster: frontend deploy

### Task 16: Frontend manifests with ConfigMap rendering

**Files:**
- Create: `manifests/30-frontend/01-configmap.yaml` (template — placeholders replaced at deploy)
- Create: `manifests/30-frontend/02-deployment.yaml`
- Create: `manifests/30-frontend/03-service.yaml`

- [ ] **Step 1: Write configmap.yaml**

This file is a placeholder; `scripts/deploy-ocp.sh` will overwrite it with one containing the actual static files and rendered config.js before applying.

```yaml
# Placeholder. Regenerated by scripts/deploy-ocp.sh at apply time.
apiVersion: v1
kind: ConfigMap
metadata:
  name: frontend-static
  namespace: demo-frontend
data:
  index.html: "placeholder"
```

- [ ] **Step 2: Write deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: demo-frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.27-alpine
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: static
              mountPath: /usr/share/nginx/html
          readinessProbe:
            httpGet: { path: /, port: 8080 }
            initialDelaySeconds: 3
            periodSeconds: 5
      volumes:
        - name: static
          configMap:
            name: frontend-static
```

- [ ] **Step 3: Write service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: demo-frontend
spec:
  selector:
    app: frontend
  ports:
    - port: 80
      targetPort: 8080
```

- [ ] **Step 4: Commit**

```bash
git add manifests/30-frontend/
git commit -m "manifests: frontend nginx deployment and service"
```

Apply is intentionally deferred until after Phase 10's API keys are created (so we can render `config.js` with the real keys).

---

## Phase 10 — Cluster: Kuadrant policies (API keys, auth, ratelimit)

### Task 17: API key Secrets

**Files:**
- Create: `manifests/60-policies/01-api-keys.yaml`

- [ ] **Step 1: Write api-keys.yaml**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: api-key-free
  namespace: kuadrant-system
  labels:
    kuadrant.io/auth-secret: "true"
    app: clrhsi-demo
  annotations:
    kuadrant.io/groups: free
    secret.kuadrant.io/user-id: alice
type: Opaque
stringData:
  api_key: ALICEFREE-3f8a7c2d-2b6e-4c0f-9a1d
---
apiVersion: v1
kind: Secret
metadata:
  name: api-key-premium
  namespace: kuadrant-system
  labels:
    kuadrant.io/auth-secret: "true"
    app: clrhsi-demo
  annotations:
    kuadrant.io/groups: premium
    secret.kuadrant.io/user-id: bob
type: Opaque
stringData:
  api_key: BOBPREMIUM-8d4e1a6f-4c9b-4b2e-b3c5
```

- [ ] **Step 2: Apply and verify**

```bash
oc apply -f manifests/60-policies/01-api-keys.yaml
oc -n kuadrant-system get secret -l app=clrhsi-demo
```
Expected: both secrets present.

- [ ] **Step 3: Commit**

```bash
git add manifests/60-policies/01-api-keys.yaml
git commit -m "policies: tiered API key secrets"
```

### Task 18: AuthPolicies for todo and weather routes

**Files:**
- Create: `manifests/60-policies/02-todo-auth.yaml`
- Create: `manifests/60-policies/04-weather-auth.yaml`

- [ ] **Step 1: Write todo-auth.yaml**

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: todo-auth
  namespace: demo-todo
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: todo-route
  rules:
    authentication:
      api-key-users:
        apiKey:
          selector:
            matchLabels:
              kuadrant.io/auth-secret: "true"
          allNamespaces: true
        credentials:
          authorizationHeader:
            prefix: APIKEY
    response:
      success:
        filters:
          identity:
            json:
              properties:
                userid:
                  selector: 'auth.identity.metadata.annotations.secret\.kuadrant\.io/user-id'
                groups:
                  selector: 'auth.identity.metadata.annotations.kuadrant\.io/groups'
```

- [ ] **Step 2: Write weather-auth.yaml**

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: weather-auth
  namespace: demo-weather
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: weather-route
  rules:
    authentication:
      api-key-users:
        apiKey:
          selector:
            matchLabels:
              kuadrant.io/auth-secret: "true"
          allNamespaces: true
        credentials:
          authorizationHeader:
            prefix: APIKEY
    response:
      success:
        filters:
          identity:
            json:
              properties:
                userid:
                  selector: 'auth.identity.metadata.annotations.secret\.kuadrant\.io/user-id'
                groups:
                  selector: 'auth.identity.metadata.annotations.kuadrant\.io/groups'
```

Apply deferred to after HTTPRoutes exist (Phase 11).

- [ ] **Step 3: Commit**

```bash
git add manifests/60-policies/02-todo-auth.yaml manifests/60-policies/04-weather-auth.yaml
git commit -m "policies: AuthPolicy for todo and weather (deferred apply)"
```

### Task 19: RateLimitPolicies

**Files:**
- Create: `manifests/60-policies/03-todo-ratelimit.yaml`
- Create: `manifests/60-policies/05-weather-ratelimit.yaml`

- [ ] **Step 1: Write todo-ratelimit.yaml**

```yaml
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: todo-ratelimit
  namespace: demo-todo
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: todo-route
  limits:
    free-tier:
      rates:
        - limit: 5
          window: 1m
      when:
        - predicate: "auth.identity.groups == 'free'"
      counters:
        - expression: auth.identity.userid
    premium-tier:
      rates:
        - limit: 30
          window: 1m
      when:
        - predicate: "auth.identity.groups == 'premium'"
      counters:
        - expression: auth.identity.userid
```

- [ ] **Step 2: Write weather-ratelimit.yaml**

```yaml
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: weather-ratelimit
  namespace: demo-weather
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: weather-route
  limits:
    per-ip:
      rates:
        - limit: 10
          window: 1m
      counters:
        - expression: 'request.headers["x-forwarded-for"].split(",")[0]'
```

Apply deferred until HTTPRoutes + AuthPolicies are present.

- [ ] **Step 3: Commit**

```bash
git add manifests/60-policies/03-todo-ratelimit.yaml manifests/60-policies/05-weather-ratelimit.yaml
git commit -m "policies: RateLimitPolicy for todo (tiered) and weather (per-IP)"
```

---

## Phase 11 — Cluster: HTTPRoutes + ReferenceGrants

### Task 20: ReferenceGrants and HTTPRoutes

**Files:**
- Create: `manifests/50-routes/01-reference-grants.yaml`
- Create: `manifests/50-routes/02-app-route.yaml`
- Create: `manifests/50-routes/03-todo-route.yaml`
- Create: `manifests/50-routes/04-weather-route.yaml`

- [ ] **Step 1: Write reference-grants.yaml**

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-frontend
  namespace: demo-frontend
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: ingress-gateway
  to:
    - group: ""
      kind: Service
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-todo
  namespace: demo-todo
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: ingress-gateway
  to:
    - group: ""
      kind: Service
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-weather
  namespace: demo-weather
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: ingress-gateway
  to:
    - group: ""
      kind: Service
```

- [ ] **Step 2: Write app-route.yaml**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-route
  namespace: demo-frontend
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: prod-web
      namespace: ingress-gateway
  hostnames:
    - app.travels.sandbox3259.opentlc.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend
          port: 80
```

- [ ] **Step 3: Write todo-route.yaml**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: todo-route
  namespace: demo-todo
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: prod-web
      namespace: ingress-gateway
  hostnames:
    - todo.travels.sandbox3259.opentlc.com
  rules:
    - matches:
        - path: { type: PathPrefix, value: /api/todos }
        - path: { type: PathPrefix, value: /healthz }
      backendRefs:
        - name: todo-backend
          port: 8000
```

- [ ] **Step 4: Write weather-route.yaml**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: weather-route
  namespace: demo-weather
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: prod-web
      namespace: ingress-gateway
  hostnames:
    - weather.travels.sandbox3259.opentlc.com
  rules:
    - matches:
        - path: { type: PathPrefix, value: /current }
        - path: { type: PathPrefix, value: /healthz }
      backendRefs:
        - name: weather
          port: 8080
```

- [ ] **Step 5: Commit (apply happens via deploy-ocp.sh)**

```bash
git add manifests/50-routes/
git commit -m "manifests: HTTPRoutes and ReferenceGrants for three demo hosts"
```

---

## Phase 12 — Orchestration: deploy-ocp.sh

### Task 21: deploy-ocp.sh that renders configmap and applies everything in order

**Files:**
- Create: `scripts/deploy-ocp.sh`

- [ ] **Step 1: Write deploy-ocp.sh**

```bash
#!/usr/bin/env bash
# Deploy everything to OpenShift in dependency order.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOMAIN="travels.sandbox3259.opentlc.com"
TODO_URL="https://todo.${DOMAIN}"
WEATHER_URL="https://weather.${DOMAIN}"

step() { echo; echo "=== $* ==="; }

step "00 namespaces"
oc apply -f "$HERE/manifests/00-namespaces.yaml"

step "10 postgres"
oc apply -f "$HERE/manifests/10-db/"
oc -n demo-db rollout status deploy/postgres --timeout=180s

step "20 todo backend"
oc apply -f "$HERE/manifests/20-todo/"
oc -n demo-todo rollout status deploy/todo-backend --timeout=180s

step "40 skupper site + listener + grant"
oc apply -f "$HERE/manifests/40-weather-skupper/"
oc -n demo-weather wait --for=condition=Ready site/demo-weather --timeout=180s
oc -n demo-weather wait --for=condition=Resolved accessgrant/weather-grant --timeout=120s

step "extract AccessToken for RHEL"
URL=$(oc -n demo-weather get accessgrant weather-grant -o jsonpath='{.status.url}')
CODE=$(oc -n demo-weather get accessgrant weather-grant -o jsonpath='{.status.code}')
CA=$(oc -n demo-weather get accessgrant weather-grant -o jsonpath='{.status.ca}')
{
  echo "apiVersion: skupper.io/v2alpha1"
  echo "kind: AccessToken"
  echo "metadata:"
  echo "  name: link-to-cluster"
  echo "spec:"
  echo "  url: ${URL}"
  echo "  code: ${CODE}"
  echo "  ca: |"
  echo "${CA}" | sed 's/^/    /'
} > "$HERE/rhel/link-token.yaml"
echo "wrote $HERE/rhel/link-token.yaml"

step "60 api-key secrets"
oc apply -f "$HERE/manifests/60-policies/01-api-keys.yaml"

step "render frontend configmap with real api keys"
KEY_FREE=$(oc -n kuadrant-system get secret api-key-free -o jsonpath='{.data.api_key}' | base64 -d)
KEY_PREMIUM=$(oc -n kuadrant-system get secret api-key-premium -o jsonpath='{.data.api_key}' | base64 -d)
CFG=$(mktemp)
cp "$HERE/apps/frontend/config.js.template" "$CFG"
sed -i.bak "s|__TODO_URL__|${TODO_URL}|g; s|__WEATHER_URL__|${WEATHER_URL}|g; s|__KEY_FREE__|${KEY_FREE}|g; s|__KEY_PREMIUM__|${KEY_PREMIUM}|g" "$CFG"
rm -f "${CFG}.bak"

oc -n demo-frontend create configmap frontend-static \
  --from-file=index.html="$HERE/apps/frontend/index.html" \
  --from-file=style.css="$HERE/apps/frontend/style.css" \
  --from-file=app.js="$HERE/apps/frontend/app.js" \
  --from-file=config.js="$CFG" \
  --dry-run=client -o yaml | oc apply -f -
rm -f "$CFG"

step "30 frontend deployment + service"
oc apply -f "$HERE/manifests/30-frontend/02-deployment.yaml" -f "$HERE/manifests/30-frontend/03-service.yaml"
oc -n demo-frontend rollout restart deploy/frontend
oc -n demo-frontend rollout status deploy/frontend --timeout=120s

step "50 reference grants + httproutes"
oc apply -f "$HERE/manifests/50-routes/"

step "60 auth + rate-limit policies"
oc apply -f "$HERE/manifests/60-policies/02-todo-auth.yaml"
oc apply -f "$HERE/manifests/60-policies/03-todo-ratelimit.yaml"
oc apply -f "$HERE/manifests/60-policies/04-weather-auth.yaml"
oc apply -f "$HERE/manifests/60-policies/05-weather-ratelimit.yaml"

step "wait for policies enforced"
for ns in demo-todo demo-weather; do
  oc -n "$ns" wait --for=condition=Enforced authpolicy --all --timeout=120s
  oc -n "$ns" wait --for=condition=Enforced ratelimitpolicy --all --timeout=120s
done

step "summary"
oc get httproute -A
oc get authpolicy -A
oc get ratelimitpolicy -A

echo
echo "Frontend:  https://app.${DOMAIN}"
echo "Todo API:  https://todo.${DOMAIN}"
echo "Weather:   https://weather.${DOMAIN}"
echo
echo "Run RHEL setup next:  ./scripts/deploy-rhel.sh"
```

- [ ] **Step 2: Make executable and dry-validate (oc apply --dry-run)**

```bash
chmod +x scripts/deploy-ocp.sh
oc apply --dry-run=client -f manifests/00-namespaces.yaml
oc apply --dry-run=client -f manifests/10-db/
oc apply --dry-run=client -f manifests/20-todo/
oc apply --dry-run=client -f manifests/40-weather-skupper/
oc apply --dry-run=client -f manifests/50-routes/
oc apply --dry-run=client -f manifests/60-policies/
```
Expected: all `configured (dry run)` with no errors.

- [ ] **Step 3: Commit**

```bash
git add scripts/deploy-ocp.sh
git commit -m "scripts: deploy-ocp.sh full apply with configmap rendering"
```

---

## Phase 13 — End-to-end deploy and verify

### Task 22: Run full deploy and verify each layer

- [ ] **Step 1: Run deploy-ocp.sh**

```bash
./scripts/deploy-ocp.sh
```
Expected: each `=== step ===` succeeds; final summary lists all routes.

- [ ] **Step 2: Run deploy-rhel.sh**

```bash
./scripts/deploy-rhel.sh
```
Expected: weather container running on RHEL, Skupper link operational.

- [ ] **Step 3: Verify Skupper end-to-end**

```bash
oc -n demo-weather get sites.skupper.io demo-weather -o jsonpath='{.status.sitesInNetwork}'; echo
oc -n demo-weather get listener weather -o jsonpath='{.status.hasMatchingConnector}'; echo
oc -n demo-weather run curlpod --image=curlimages/curl --rm -i --restart=Never -- \
  curl -sf http://weather:8080/healthz
```
Expected: `2`, `true`, `{"ok":true}`.

- [ ] **Step 4: Verify HTTPRoutes accepted**

```bash
oc get httproute -A -o wide
```
Expected: all four HTTPRoutes (`echo-api` + ours) show `Accepted: True`, `ResolvedRefs: True`.

- [ ] **Step 5: Verify external reachability**

```bash
curl -skI https://app.travels.sandbox3259.opentlc.com/
curl -sk https://app.travels.sandbox3259.opentlc.com/ | grep -q "CL-RHSI Demo"
curl -skI https://todo.travels.sandbox3259.opentlc.com/healthz | head -1
curl -skI https://weather.travels.sandbox3259.opentlc.com/healthz | head -1
```
Expected: `HTTP/2 200` for frontend; the API hosts return `401` for `/healthz` only if it's also under AuthPolicy — AuthPolicy targets the whole HTTPRoute. We expect `401` for /healthz on todo and weather hosts (that's intentional — only authenticated calls reach the backends). Frontend serves the HTML on `/`.

If you want `/healthz` reachable for liveness from external, add a route-level rule to exclude `/healthz` from auth via `routeSelectors` — out of scope for the demo, but call it out in README.

---

## Phase 14 — Demo test script

### Task 23: test-policies.sh — assert the full policy story

**Files:**
- Create: `scripts/test-policies.sh`

- [ ] **Step 1: Write test-policies.sh**

```bash
#!/usr/bin/env bash
# Runs the full demo policy assertion sequence.
set -euo pipefail
TODO="https://todo.travels.sandbox3259.opentlc.com"
WEATHER="https://weather.travels.sandbox3259.opentlc.com"

KEY_FREE=$(oc -n kuadrant-system get secret api-key-free -o jsonpath='{.data.api_key}' | base64 -d)
KEY_PREMIUM=$(oc -n kuadrant-system get secret api-key-premium -o jsonpath='{.data.api_key}' | base64 -d)

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; exit 1; }

assert_code() {
  local expected="$1"; shift
  local got
  got=$(curl -sk -o /dev/null -w "%{http_code}" "$@")
  [ "$got" = "$expected" ] || { echo "  expected $expected, got $got for: $*"; return 1; }
}

echo "==> A. Anonymous request to todo → 401"
assert_code 401 "$TODO/api/todos" && pass "401 without API key on /api/todos" || fail "anon not blocked"

echo "==> B. Free key → 200 then 429"
ok_count=0; limit_count=0
for i in $(seq 1 7); do
  code=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: APIKEY $KEY_FREE" "$TODO/api/todos")
  if [ "$code" = "200" ]; then ok_count=$((ok_count+1)); fi
  if [ "$code" = "429" ]; then limit_count=$((limit_count+1)); fi
  sleep 0.1
done
[ "$ok_count" = "5" ] && [ "$limit_count" = "2" ] && pass "free tier: 5x 200, 2x 429" || fail "free tier counts: 200=$ok_count 429=$limit_count"

echo "==> C. Wait 65s for free window to reset"
sleep 65

echo "==> D. Premium key → 30x 200"
ok_count=0
for i in $(seq 1 30); do
  code=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: APIKEY $KEY_PREMIUM" "$TODO/api/todos")
  [ "$code" = "200" ] && ok_count=$((ok_count+1))
  sleep 0.1
done
[ "$ok_count" = "30" ] && pass "premium tier: 30x 200" || fail "premium tier: only $ok_count succeeded"

echo "==> E. Weather IP rate-limit (10/min)"
sleep 65
ok=0; lim=0
for i in $(seq 1 12); do
  code=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: APIKEY $KEY_FREE" "$WEATHER/current?city=Berlin")
  [ "$code" = "200" ] && ok=$((ok+1))
  [ "$code" = "429" ] && lim=$((lim+1))
  sleep 0.1
done
[ "$ok" -ge "10" ] && [ "$lim" -ge "2" ] && pass "weather IP-limit: 200=$ok 429=$lim" || fail "weather counts: 200=$ok 429=$lim"

echo
echo "ALL CHECKS PASS"
```

- [ ] **Step 2: Make executable and run**

```bash
chmod +x scripts/test-policies.sh
./scripts/test-policies.sh
```
Expected: all checks PASS; final line `ALL CHECKS PASS`.

If any failure: inspect `oc -n demo-todo describe authpolicy todo-auth` and `ratelimitpolicy todo-ratelimit` — look for `Enforced: True` and resolved counter expressions. Common pitfalls: API key prefix mismatch (must be `APIKEY ` with trailing space), missing `Enforced` condition (Limitador pod not ready in `kuadrant-system`).

- [ ] **Step 3: Commit**

```bash
git add scripts/test-policies.sh
git commit -m "scripts: end-to-end policy assertions"
```

---

## Phase 15 — Cleanup script

### Task 24: cleanup.sh

**Files:**
- Create: `scripts/cleanup.sh`

- [ ] **Step 1: Write cleanup.sh**

```bash
#!/usr/bin/env bash
# Tear down the CL-RHSI demo.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== delete cluster policies, routes, manifests ==="
oc delete -f "$HERE/manifests/60-policies/" --ignore-not-found
oc delete -f "$HERE/manifests/50-routes/" --ignore-not-found
oc delete -f "$HERE/manifests/40-weather-skupper/" --ignore-not-found
oc delete -f "$HERE/manifests/30-frontend/" --ignore-not-found
oc delete configmap frontend-static -n demo-frontend --ignore-not-found
oc delete -f "$HERE/manifests/20-todo/" --ignore-not-found
oc delete -f "$HERE/manifests/10-db/" --ignore-not-found
oc delete -f "$HERE/manifests/00-namespaces.yaml" --ignore-not-found

echo "=== teardown on RHEL ==="
: "${RHEL_HOST:=rhel.rfztg.sandbox2786.opentlc.com}"
: "${RHEL_USER:=lab-user}"
: "${RHEL_PASS:=MjM4Mjcy}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
if command -v sshpass >/dev/null; then
  sshpass -p "$RHEL_PASS" ssh $SSH_OPTS "$RHEL_USER@$RHEL_HOST" '
    export PATH="$HOME/.local/bin:$PATH"
    podman rm -f weather-app || true
    skupper site delete --all || true
    rm -rf ~/cl-rhsi
  '
else
  echo "sshpass not installed — skipping RHEL teardown; run manually:"
  echo "  podman rm -f weather-app; skupper site delete --all; rm -rf ~/cl-rhsi"
fi

rm -f "$HERE/rhel/link-token.yaml"
echo "done."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/cleanup.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/cleanup.sh
git commit -m "scripts: cleanup teardown for cluster + RHEL"
```

---

## Phase 16 — README documentation

### Task 25: Write the final README capturing the as-built system

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Inspect what was actually built**

Before writing the README, capture the current state so it reflects reality, not aspirations:

```bash
oc get httproute -A
oc get authpolicy,ratelimitpolicy -A
oc -n demo-weather get sites.skupper.io,listeners.skupper.io,accessgrants.skupper.io
oc -n kuadrant-system get secret -l app=clrhsi-demo
```

Note any deviations from the spec (image tags pinned to specific shas, RHEL bridge IP discovery quirks, init.sh vs init.sql, etc.).

- [ ] **Step 2: Write README.md**

```markdown
# CL-RHSI Demo

A 3-tier demo that showcases **Red Hat Connectivity Link (Kuadrant)** gateway policies — AuthPolicy, RateLimitPolicy, DNSPolicy, TLSPolicy — applied to microservices that span an OpenShift cluster and an external RHEL VM. The RHEL workload is joined into the cluster network with **Red Hat Service Interconnect (Skupper v2)**. No Service Mesh sidecars are used: the Istio Gateway is the only dataplane at the cluster edge.

## Architecture

```
                       ┌─────────────────────────────┐
       Client ───────► │ Istio Ingress Gateway (OCP) │
                       │ + Kuadrant policies         │
                       │   AuthPolicy                │
                       │   RateLimitPolicy           │
                       │   DNSPolicy / TLSPolicy     │
                       └──┬──────────┬───────────┬──┘
                          │          │           │
            HTTPRoute app │  HTTPRoute /todo    HTTPRoute /weather
                          │          │           │
                          ▼          ▼           ▼
                      frontend  todo-backend   weather (Skupper svc)
                     (nginx)    (FastAPI)           │ VAN
                                    │               ▼
                                Postgres     RHEL VM (podman): weather
                                                     │
                                                     ▼
                                                Open-Meteo
```

## Hosts (all on the existing `prod-web` Istio gateway)

| Host | Backend |
|---|---|
| `app.travels.sandbox3259.opentlc.com` | frontend nginx |
| `todo.travels.sandbox3259.opentlc.com` | todo-backend FastAPI |
| `weather.travels.sandbox3259.opentlc.com` | weather (via Skupper → RHEL podman) |

DNS records and TLS certificates for these hosts are managed by the existing gateway-attached `prod-web-dnspolicy` and `prod-web-tls-policy` (wildcard `*.travels.sandbox3259.opentlc.com`).

## Prereqs

- `oc` CLI logged into the target cluster (`oc login --token=...`)
- `podman` locally (for building images)
- `skupper` CLI v2 (`~/.local/bin/skupper`) — also installed on RHEL by `rhel/setup.sh`
- `sshpass` for the RHEL deploy step (`brew install hudochenkov/sshpass/sshpass`)
- Quay.io creds for pushing images (already wired into `scripts/build-push.sh`)

## One-shot deploy

```bash
# 1. Build images and push to Quay (first time only, or when app code changes)
export QUAY_USER='rh-ee-srehman'
export QUAY_TOKEN='<your Quay robot token>'
./scripts/build-push.sh

# 2. Deploy everything to OpenShift
./scripts/deploy-ocp.sh

# 3. Deploy weather + Skupper on RHEL
./scripts/deploy-rhel.sh

# 4. End-to-end policy verification
./scripts/test-policies.sh
```

## Demo flow

1. Open https://app.travels.sandbox3259.opentlc.com — frontend loads anonymously; show the TLS padlock and explain it comes from the gateway-level `TLSPolicy`.
2. Use the **tier dropdown** to choose `free`; add a few todos; try to add 6+ within a minute — UI surfaces the **429** from `RateLimitPolicy`.
3. Switch to `premium` — same actions succeed up to 30/min.
4. Type a city into the weather card — see weather data fetched from the RHEL pod over Skupper.
5. `ssh lab-user@rhel...` and tail `podman logs -f weather-app` — show that the request landed locally.
6. From a terminal: `curl -k https://todo.travels.../api/todos` (no header) returns **401** from `AuthPolicy`.

## Files

```
apps/                Application code (todo backend, weather, frontend)
manifests/           OpenShift YAML in numeric apply order
rhel/                RHEL-side setup script and Quadlet
scripts/             build-push, deploy-ocp, deploy-rhel, test-policies, cleanup
docs/superpowers/    Spec and implementation plan
```

## Troubleshooting

| Symptom | Look at |
|---|---|
| 401 even with API key | `oc -n demo-todo describe authpolicy todo-auth` → `Enforced=True`; check secret labels in `kuadrant-system` |
| 429 immediately on first call | Limitador may have stale counters: `oc -n kuadrant-system rollout restart deploy/limitador-limitador` |
| Weather call hangs | `oc -n demo-weather get listener weather -o jsonpath='{.status.hasMatchingConnector}'` should be `true`; on RHEL `skupper status` |
| Pod ImagePullBackOff | Confirm `rh-ee-srehman/todo` and `rh-ee-srehman/weather` Quay repos are **public** |
| Frontend 404 | Check `oc -n demo-frontend get configmap frontend-static -o yaml` contains all four files |
| HTTPRoute `Accepted: False` | `oc describe httproute <name>` — usually a missing ReferenceGrant or wrong parentRef namespace |

## Cleanup

```bash
./scripts/cleanup.sh
```

## What was actually built

(Update this section after the first successful deploy. Capture deviations from the spec — e.g., if init.sh path differed, if a Quay image needed re-tagging, if the AccessGrant CA had to be base64-decoded before pasting into AccessToken.)
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: final README capturing the as-built demo"
```

---

## Self-review check

Before claiming the implementation complete, run through the verification gates from the spec:

- [ ] Postgres `todos` table present (`oc -n demo-db rsh deploy/postgres psql -U todo -d todos -c '\dt'`)
- [ ] todo-backend `/healthz` returns `{"ok":true}` (`oc -n demo-todo rsh deploy/todo-backend curl -sf localhost:8000/healthz`)
- [ ] frontend `/` returns HTML containing `CL-RHSI Demo`
- [ ] Skupper sites in network = 2; link operational; weather Listener has matching Connector
- [ ] All three HTTPRoutes `Accepted=True`, `ResolvedRefs=True`
- [ ] AuthPolicy and RateLimitPolicy `Enforced=True` on both target routes
- [ ] `scripts/test-policies.sh` exits 0 with `ALL CHECKS PASS`

If any check fails, fix before declaring done. After the final pass, update README's "What was actually built" section with any deviations from this plan.

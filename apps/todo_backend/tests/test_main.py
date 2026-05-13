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

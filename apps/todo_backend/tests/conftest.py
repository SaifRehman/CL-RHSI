import pytest
from fastapi.testclient import TestClient

@pytest.fixture
def fake_store():
    return {"next_id": 1, "rows": {}}

@pytest.fixture
def client(monkeypatch, fake_store):
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

    return TestClient(main.app)

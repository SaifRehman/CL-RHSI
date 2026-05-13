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

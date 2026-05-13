import os
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Response, status
from fastapi.middleware.cors import CORSMiddleware
from . import db, models

ALLOWED_ORIGIN = os.environ["ALLOWED_ORIGIN"]

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

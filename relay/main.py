"""
云端中继（P1 · 多用户隔离）
FastAPI 单 worker；
- 自注册账号系统：/api/register + /api/login，签发随机 32B token，云端 SQLite 持久化
- 多用户隔离：token -> user_id；/api/voices 按 user_id 过滤；audio_store 按 user 隔离
- 音色命名空间：voice 字段传 remote_name(userID::voiceName)，守护进程按该名注册 CosyVoice
- /api/voice/clone 后端：multipart -> WS 推电脑 clone -> 落库 -> 返回
单台电脑 = 单 WS 连接；多用户音色用 remote_name 命名空间隔离（v3 §11）。
"""
import asyncio
from contextlib import asynccontextmanager
import base64
import hashlib
import json
import os
import secrets
import sqlite3
import struct
import threading
from collections import OrderedDict

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response

# ------------------------- 配置 -------------------------
TTS_TIMEOUT = 120                         # 合成超时（秒）
CLONE_TIMEOUT = 120                       # 克隆超时（秒）
MAX_STORE_PER_USER = 10                   # 云每用户音频暂存上限（LRU）
DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai_voice.db")
PBKDF2_ITERS = 100_000

# ------------------------- 电脑端 WS 鉴权（上云前必配）-------------------------
def _load_computer_token() -> "str | None":
    """电脑守护进程反连 /ws/computer 的共享密钥。

    优先级：环境变量 COMPUTER_TOKEN > 项目根 .computer_token 文件（首行）。
    返回 None 表示未配置 -> 拒绝任何电脑连接（安全默认，绝不允许公网零鉴权）。
    """
    t = os.environ.get("COMPUTER_TOKEN")
    if t:
        return t.strip()
    for cand in (
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".computer_token"),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), ".computer_token"),
    ):
        try:
            with open(cand, encoding="utf-8") as f:
                return f.read().strip()
        except Exception:
            pass
    return None


COMPUTER_TOKEN = _load_computer_token()

# ------------------------- 全局状态（单进程单 worker）-------------------------
computer_ws = None
computer_online = False
pending_tts = {}                          # task_id(int) -> asyncio.Future[bytes]
pending_clone = {}                        # task_id(int) -> asyncio.Future[bool]
_task_counter = 0
audio_store = {}                          # user -> OrderedDict(task_id -> wav) LRU 暂存
_db_lock = threading.Lock()               # 串行护 SQLite 写

@asynccontextmanager
async def lifespan(app):
    init_db()
    asyncio.create_task(_heartbeat())
    yield


app = FastAPI(title="Voice Relay (P1)", lifespan=lifespan)


# ------------------------- SQLite -------------------------
def _conn():
    c = sqlite3.connect(DB_PATH, check_same_thread=False)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    with _db_lock, _conn() as c:
        c.execute(
            """CREATE TABLE IF NOT EXISTS users (
                user_id TEXT PRIMARY KEY,
                username TEXT UNIQUE NOT NULL,
                pw_hash TEXT NOT NULL,
                salt TEXT NOT NULL,
                token TEXT NOT NULL,
                created_at INTEGER
            )"""
        )
        c.execute(
            """CREATE TABLE IF NOT EXISTS voices (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                remote_name TEXT NOT NULL,
                user_id TEXT NOT NULL,
                status TEXT DEFAULT 'active',
                created_at INTEGER
            )"""
        )


def _hash_pw(password: str, salt: bytes) -> str:
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ITERS).hex()


def create_user(username: str, password: str) -> str:
    """返回 token；用户名重复抛 ValueError"""
    salt = secrets.token_bytes(16)
    pw_hash = _hash_pw(password, salt)
    token = secrets.token_hex(32)
    user_id = username
    with _db_lock, _conn() as c:
        try:
            c.execute(
                "INSERT INTO users(user_id, username, pw_hash, salt, token, created_at) "
                "VALUES(?,?,?,?,?,?)",
                (user_id, username, pw_hash, salt.hex(), token, int(__import__("time").time() * 1000)),
            )
        except sqlite3.IntegrityError:
            raise ValueError("username_taken")
    return token


def verify_user(username: str, password: str):
    """成功返回 token，失败返回 None"""
    with _conn() as c:
        row = c.execute(
            "SELECT pw_hash, salt, token FROM users WHERE username=?", (username,)
        ).fetchone()
    if row is None:
        return None
    salt = bytes.fromhex(row["salt"])
    if _hash_pw(password, salt) != row["pw_hash"]:
        return None
    return row["token"]


def user_id_by_token(token: str):
    if not token:
        return None
    with _conn() as c:
        row = c.execute("SELECT user_id FROM users WHERE token=?", (token,)).fetchone()
    return row["user_id"] if row else None


def upsert_voice(remote_name: str, name: str, user_id: str):
    with _db_lock, _conn() as c:
        c.execute(
            "INSERT OR REPLACE INTO voices(id, name, remote_name, user_id, status, created_at) "
            "VALUES(?,?,?,?,?,?)",
            (remote_name, name, remote_name, user_id, "active", int(__import__("time").time() * 1000)),
        )


def list_voices(user_id: str):
    with _conn() as c:
        rows = c.execute(
            "SELECT id, name, remote_name FROM voices WHERE user_id=?", (user_id,)
        ).fetchall()
    return [dict(r) for r in rows]


def count_voices(user_id: str) -> int:
    with _conn() as c:
        row = c.execute(
            "SELECT COUNT(*) AS n FROM voices WHERE user_id=?", (user_id,)
        ).fetchone()
    return row["n"] if row else 0


def sync_voices_from_computer(names):
    """守护重连时上报的 remote_name 清单，按 userID:: 前缀回写 voices 表（幂等）。"""
    for name in names or []:
        if "::" not in name:
            # 旧格式（无命名空间）跳过，避免污染；P1 起 daemon 一律带前缀
            print(f"[voices] skip legacy voice name (no '::'): {name}", flush=True)
            continue
        user_id = name.split("::", 1)[0]
        upsert_voice(name, name.split("::", 1)[1], user_id)


# ------------------------- 鉴权 -------------------------
def get_user(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing token")
    uid = user_id_by_token(authorization[7:])
    if uid is None:
        raise HTTPException(status_code=401, detail="invalid token")
    return uid


def next_task_id() -> int:
    global _task_counter
    _task_counter = (_task_counter + 1) & 0xFFFFFFFF
    return _task_counter


# ------------------------- 心跳（云->电脑）-------------------------
async def _heartbeat():
    while True:
        await asyncio.sleep(30)
        if computer_online and computer_ws is not None:
            try:
                await computer_ws.send_text(json.dumps({"type": "ping"}))
            except Exception:
                pass


# ------------------------- REST 接口 -------------------------
@app.get("/api/status")
async def status(user: str = Depends(get_user)):
    return {"online": computer_online, "has_voice": count_voices(user) > 0}


@app.get("/api/voices")
async def voices(user: str = Depends(get_user)):
    return {"voices": list_voices(user)}


@app.post("/api/register")
async def register(req: Request):
    body = await req.json()
    username = (body.get("username") or "").strip()
    password = body.get("password") or ""
    if not username or not password:
        raise HTTPException(status_code=400, detail="username and password required")
    if len(password) < 6:
        raise HTTPException(status_code=400, detail="password too short (>=6)")
    try:
        token = create_user(username, password)
    except ValueError:
        raise HTTPException(status_code=409, detail="username already taken")
    return {"user_id": username, "token": token}


@app.post("/api/login")
async def login(req: Request):
    body = await req.json()
    username = (body.get("username") or "").strip()
    password = body.get("password") or ""
    token = verify_user(username, password)
    if token is None:
        raise HTTPException(status_code=401, detail="invalid username or password")
    return {"user_id": username, "token": token}


@app.post("/api/tts")
async def tts(req: Request, user: str = Depends(get_user)):
    body = await req.json()
    voice = body.get("voice")
    texts = body.get("texts")
    text = body.get("text")
    if not voice:
        raise HTTPException(status_code=400, detail="voice required")
    # 音色归属隔离：请求的 remote_name 必须属于当前用户（防越权用他人音色）
    if "::" in voice:
        owner = voice.split("::", 1)[0]
        if owner != user:
            raise HTTPException(status_code=403, detail="voice not owned by user")
    if not texts and not text:
        raise HTTPException(status_code=400, detail="text or texts required")
    if not computer_online or computer_ws is None:
        return JSONResponse(status_code=503, content={"error": "tts_unavailable"})

    tid = next_task_id()
    loop = asyncio.get_event_loop()
    fut = loop.create_future()
    pending_tts[tid] = fut
    try:
        if texts:
            await computer_ws.send_text(
                json.dumps({"type": "tts_multi", "task_id": tid, "texts": texts, "voice": voice})
            )
        else:
            await computer_ws.send_text(
                json.dumps({"type": "tts", "task_id": tid, "text": text, "voice": voice})
            )
        wav = await asyncio.wait_for(fut, timeout=TTS_TIMEOUT)
    except asyncio.TimeoutError:
        pending_tts.pop(tid, None)
        return JSONResponse(status_code=504, content={"error": "tts_timeout"})
    except Exception as e:  # noqa
        pending_tts.pop(tid, None)
        return JSONResponse(status_code=500, content={"error": str(e)})
    pending_tts.pop(tid, None)

    # LRU 暂存（每用户最多 MAX_STORE_PER_USER 条，超则删最旧）
    store = audio_store.setdefault(user, OrderedDict())
    store[tid] = wav
    while len(store) > MAX_STORE_PER_USER:
        store.popitem(last=False)

    return Response(content=wav, media_type="audio/wav")


@app.post("/api/voice/clone")
async def clone_voice(
    user: str = Depends(get_user),
    file: UploadFile = File(...),
    text: str = Form(...),
    voiceName: str = Form(...),
):
    if not computer_online or computer_ws is None:
        return JSONResponse(status_code=503, content={"error": "tts_unavailable"})
    voiceName = (voiceName or "").strip()
    if not voiceName:
        raise HTTPException(status_code=400, detail="voiceName required")
    wav_bytes = await file.read()
    if not wav_bytes:
        raise HTTPException(status_code=400, detail="empty audio")
    remote_name = f"{user}::{voiceName}"

    tid = next_task_id()
    loop = asyncio.get_event_loop()
    fut = loop.create_future()
    pending_clone[tid] = fut
    try:
        await computer_ws.send_text(
            json.dumps({
                "type": "clone",
                "task_id": tid,
                "text": text,
                "voice_name": remote_name,
                "wav": base64.b64encode(wav_bytes).decode("ascii"),
            })
        )
        await asyncio.wait_for(fut, timeout=CLONE_TIMEOUT)
    except asyncio.TimeoutError:
        pending_clone.pop(tid, None)
        return JSONResponse(status_code=504, content={"error": "clone_timeout"})
    except Exception as e:  # noqa
        pending_clone.pop(tid, None)
        return JSONResponse(status_code=500, content={"error": str(e)})
    pending_clone.pop(tid, None)

    # 落库：本用户命名空间下新增音色
    upsert_voice(remote_name, voiceName, user)
    return {"id": remote_name, "remote_name": remote_name, "name": voiceName}


# ------------------------- WS 服务端（电脑<->云）-------------------------
@app.websocket("/ws/computer")
async def ws_computer(ws: WebSocket, token: str = Query(None)):
    global computer_ws, computer_online
    # 上云安全：未配置 token 或 token 不符 -> 直接拒绝，绝不允许零鉴权暴露公网
    if not COMPUTER_TOKEN or token != COMPUTER_TOKEN:
        await ws.close(code=1008, reason="unauthorized computer")
        print("[ws_computer] rejected: unauthorized (missing/wrong token)", flush=True)
        return
    await ws.accept()
    computer_ws = ws
    computer_online = True
    print("[ws_computer] computer connected", flush=True)
    try:
        while True:
            data = await ws.receive()
            if data.get("type") == "websocket.disconnect":
                break
            try:
                if "text" in data and data.get("text") is not None:
                    await _handle_text(data["text"], ws)
                elif "bytes" in data and data.get("bytes") is not None:
                    b = data["bytes"]
                    tid = struct.unpack(">I", b[:4])[0]
                    print(f"[ws_computer] binary tid={tid} len={len(b)}", flush=True)
                    _handle_binary(b)
            except Exception as _e:
                import traceback as _tb
                print(f"[ws_computer] handler error: {_e}\n{_tb.format_exc()}", flush=True)
    except WebSocketDisconnect:
        pass
    finally:
        print("[ws_computer] computer disconnected", flush=True)
        computer_online = False
        computer_ws = None


async def _handle_text(text: str, ws: WebSocket):
    try:
        msg = json.loads(text)
    except Exception:
        return
    t = msg.get("type")
    if t == "register":
        names = msg.get("voices", [])
        sync_voices_from_computer(names)
        await ws.send_text(json.dumps({"type": "registered"}))
    elif t == "ping":
        await ws.send_text(json.dumps({"type": "pong"}))
    elif t == "tts_error":
        tid = msg.get("task_id")
        fut = pending_tts.get(tid)
        if fut and not fut.done():
            fut.set_exception(RuntimeError(msg.get("error", "tts_error")))
    elif t == "clone_done":
        tid = msg.get("task_id")
        fut = pending_clone.get(tid)
        if fut and not fut.done():
            fut.set_result(True)
    elif t == "clone_error":
        tid = msg.get("task_id")
        fut = pending_clone.get(tid)
        if fut and not fut.done():
            fut.set_exception(RuntimeError(msg.get("error", "clone_error")))


def _handle_binary(data: bytes):
    if len(data) < 4:
        return
    tid = struct.unpack(">I", data[:4])[0]
    wav = data[4:]
    fut = pending_tts.get(tid)
    if fut and not fut.done():
        fut.set_result(wav)


if __name__ == "__main__":
    import uvicorn

    # 单 worker（WS 不能跨 worker 共享）；生产用命令行:
    #   uvicorn main:app --host 0.0.0.0 --port 8000 --workers 1 --limit-concurrency 20
    uvicorn.run(app, host="0.0.0.0", port=8000, workers=1)

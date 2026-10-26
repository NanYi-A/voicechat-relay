"""
电脑守护进程（P0）
包在 api.py 外面的一层：WS 反连云端 + 串行队列防 CosyVoice 并发崩 + 句级合成回传 + 开机重注册音色。
调用 api.py 的 OpenAI 风格端点：
  POST /v1/audio/speech  json={input, model:'tts-1', voice, response_format:'wav', stream:false}
  POST /v1/audio/voice/clone  files={'file':wav}  data={'name', 'text'}
"""
import base64
import json
import os
import queue
import struct
import threading
import time

import requests
import websocket  # websocket-client

RELAY_WS = os.environ.get("RELAY_WS", "ws://127.0.0.1:8000/ws/computer")
# 电脑端共享密钥：环境变量 COMPUTER_TOKEN 优先，否则读项目根 .computer_token 文件
COMPUTER_TOKEN = os.environ.get("COMPUTER_TOKEN")
if not COMPUTER_TOKEN:
    for _cand in (
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".computer_token"),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), ".computer_token"),
    ):
        try:
            with open(_cand, encoding="utf-8") as _f:
                COMPUTER_TOKEN = _f.read().strip()
                break
        except Exception:
            pass
if COMPUTER_TOKEN:
    _sep = "&" if "?" in RELAY_WS else "?"
    RELAY_WS = f"{RELAY_WS}{_sep}token={COMPUTER_TOKEN}"
API_BASE = os.environ.get("API_BASE", "http://127.0.0.1:9996")
FIXED_TOKEN = "p0-dev-token-change-me"
VOICES_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "voices.json")

# 串行任务队列（防 CosyVoice 并发崩溃：model_lock 不保护 chunk 迭代）
task_queue: "queue.Queue" = queue.Queue()
running = True
ws_app = None
send_lock = threading.Lock()  # 多线程发送保护


def load_voices():
    if not os.path.exists(VOICES_JSON):
        return []
    try:
        with open(VOICES_JSON, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def _owner_account():
    """读项目根 .owner_account，返回命名空间 owner（无则 None）。
    把 voices.json 里写死的命名空间(如 olduser::)统一替换成本机实际服务的手机账号，
    避免 CosyVoice 注册名与手机账号前缀不一致导致 400。"""
    for _cand in (
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".owner_account"),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), ".owner_account"),
    ):
        try:
            with open(_cand, encoding="utf-8") as _f:
                _v = _f.read().strip()
                if _v:
                    return _v
        except Exception:
            pass
    return None


def _remap_voice_name(remote_name, owner):
    """用 owner 替换 remote_name 的命名空间，保证与手机账号一致。
    例：('other::voice_a','user1') -> 'user1::voice_a'；('voice_a','user1') -> 'user1::voice_a'。"""
    if not owner:
        return remote_name
    bare = remote_name.split("::", 1)[1] if "::" in remote_name else remote_name
    return f"{owner}::{bare}"


def reregister_voices():
    """开机重注册所有音色（防 api.py 内存态重启丢失）。
    注册名统一用 .owner_account 做命名空间（若配置），保证与手机账号前缀一致。"""
    owner = _owner_account()
    voices = load_voices()
    names = []
    for v in voices:
        ap = v.get("audio_path", "")
        rn = _remap_voice_name(v.get("remote_name", ""), owner)
        if not ap or not os.path.exists(ap):
            print(f"[clone] 跳过 {rn}：参考音频不存在 ({ap})", flush=True)
            continue
        try:
            with open(ap, "rb") as af:
                r = requests.post(
                    f"{API_BASE}/v1/audio/voice/clone",
                    files={"file": af},
                    data={"name": rn, "text": v.get("text", "")},
                    timeout=60,
                )
            if r.status_code == 200:
                names.append(rn)
                print(f"[clone] {rn} 注册成功")
            else:
                print(f"[clone] {rn} 失败 {r.status_code} {r.text[:200]}")
        except Exception as e:
            print(f"[clone] {rn} 错误 {e}")
    return names


def synthesize(task_id, text, voice):
    # 严格按 app 指定的 remote_name 合成，不跨用户回落（防 A 用 B 音色）。
    # 若音色未注册，CosyVoice 返回 400 -> 抛错 -> relay 转 500；
    # 因此必须保证 daemon 启动时 reregister_voices 已把该音色注册进 CosyVoice。
    candidates = [voice]  # 单候选：请求的 remote_name
    last_err = None
    for cand in candidates:
        try:
            r = requests.post(
                f"{API_BASE}/v1/audio/speech",
                headers={"Content-Type": "application/json", "Authorization": "Bearer sk-none"},
                json={
                    "input": text,
                    "model": "tts-1",
                    "voice": cand,
                    "response_format": "wav",
                    "stream": False,
                },
                timeout=120,
            )
            if r.status_code == 200:
                return r.content
            last_err = f"speech {r.status_code} {r.text[:200]}"
            if r.status_code != 400:  # 仅音色不支持(400)才回落，其它错误直接放弃
                break
        except Exception as e:
            last_err = str(e)
            break
    raise RuntimeError(last_err)


import io
import wave

# 句间自然停顿（秒）：真人说话句间有间隙，拼接时补一点静音更自然
SENTENCE_GAP = 0.35


def _wav_to_pcm(wav_bytes):
    """解析 WAV 返回 (pcm_bytes, nch, sw, fr)。"""
    with wave.open(io.BytesIO(wav_bytes), "rb") as w:
        nch = w.getnchannels()
        sw = w.getsampwidth()
        fr = w.getframerate()
        pcm = w.readframes(w.getnframes())
    return pcm, nch, sw, fr


def _pcm_to_wav(pcm, nch, sw, fr):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(nch)
        w.setsampwidth(sw)
        w.setframerate(fr)
        w.writeframes(pcm)
    return buf.getvalue()


def synthesize_multi(texts, voice):
    """逐句合成（单句质量高）+ 拼接为一段连续 WAV。

    单句合成经 CosyVoice 质量优于整段长文本；句间补 SENTENCE_GAP 秒静音，
    拼成单个 WAV 回传手机，手机一次收到即可连贯播放，无句间网络等待。
    """
    pcms = []
    fmt = None
    for t in texts:
        t = (t or "").strip()
        if not t:
            continue
        wav = synthesize(None, t, voice)
        pcm, nch, sw, fr = _wav_to_pcm(wav)
        if fmt is None:
            fmt = (nch, sw, fr)
            gap = b"\x00" * (sw * int(fr * SENTENCE_GAP))
        elif (nch, sw, fr) != fmt:
            raise RuntimeError(
                f"合成格式不一致：首句 {fmt} 当前句 {(nch, sw, fr)}"
            )
        pcms.append(pcm)
    if not pcms:
        raise RuntimeError("没有有效句子可合成")
    combined = pcms[0]
    for p in pcms[1:]:
        combined = combined + gap + p
    return _pcm_to_wav(combined, *fmt)


def worker():
    """串行消费 TTS / clone 任务"""
    while running:
        item = task_queue.get()
        if item is None:
            task_queue.task_done()
            break
        try:
            if isinstance(item, tuple) and item and item[0] == "clone":
                _, tid, text, voice_name, wav = item
                _handle_clone(tid, text, voice_name, wav)
            else:
                tid, payload, voice, multi = item
                print(f"[worker] got task tid={tid} multi={multi} n={len(payload) if isinstance(payload, list) else len(payload)}", flush=True)
                try:
                    if multi:
                        wav = synthesize_multi(payload, voice)
                    else:
                        wav = synthesize(tid, payload, voice)
                    if isinstance(wav, str):
                        wav = wav.encode("utf-8")
                    print(f"[worker] synthesized tid={tid} wav_len={len(wav)}", flush=True)
                    with send_lock:
                        frame = struct.pack(">I", tid) + wav
                        print(f"[worker] sending binary tid={tid} payload_len={len(frame)}", flush=True)
                        ws_app.send_bytes(frame)
                        print(f"[worker] binary sent tid={tid}", flush=True)
                        ws_app.send(json.dumps({"type": "tts_done", "task_id": tid}))
                        print(f"[worker] tts_done sent tid={tid}", flush=True)
                except Exception as e:
                    print(f"[worker] ERROR tid={tid} {e!r}", flush=True)
                    import traceback as _tb
                    print(_tb.format_exc(), flush=True)
                    try:
                        with send_lock:
                            ws_app.send(json.dumps({"type": "tts_error", "task_id": tid, "error": str(e)}))
                    except Exception as e2:
                        print(f"[worker] tts_error send failed {e2!r}", flush=True)
        finally:
            task_queue.task_done()


def _handle_clone(tid, text, voice_name, wav_bytes):
    """处理云端推来的克隆任务：注册到 api.py + 持久化本地 voices.json + 回报。"""
    print(f"[clone] start tid={tid} voice={voice_name} wav_len={len(wav_bytes)}", flush=True)
    try:
        r = requests.post(
            f"{API_BASE}/v1/audio/voice/clone",
            files={"file": ("voice.wav", wav_bytes, "audio/wav")},
            data={"name": voice_name, "text": text or ""},
            timeout=120,
        )
        if r.status_code != 200:
            print(f"[clone] api failed {r.status_code} {r.text[:200]}", flush=True)
            with send_lock:
                ws_app.send(json.dumps({"type": "clone_error", "task_id": tid, "error": f"clone_api_{r.status_code}"}))
            return
        save_voice(voice_name, text, wav_bytes)
        print(f"[clone] {voice_name} 注册成功", flush=True)
        with send_lock:
            ws_app.send(json.dumps({"type": "clone_done", "task_id": tid}))
    except Exception as e:
        print(f"[clone] ERROR tid={tid} {e!r}", flush=True)
        try:
            with send_lock:
                ws_app.send(json.dumps({"type": "clone_error", "task_id": tid, "error": str(e)}))
        except Exception:
            pass


def save_voice(remote_name, text, wav_bytes):
    """把克隆音色追加到本地 voices.json（D1 重启重注册用）"""
    voices = [v for v in load_voices() if v.get("remote_name") != remote_name]
    tmp_path = f"{VOICES_JSON}.{int(time.time() * 1000)}.wav"
    with open(tmp_path, "wb") as f:
        f.write(wav_bytes)
    voices.append({"remote_name": remote_name, "text": text or "", "audio_path": tmp_path})
    with open(VOICES_JSON, "w", encoding="utf-8") as f:
        json.dump(voices, f, ensure_ascii=False, indent=2)


def on_message(ws, message):
    if isinstance(message, bytes):
        return
    try:
        msg = json.loads(message)
    except Exception:
        return
    t = msg.get("type")
    if t == "tts":
        task_queue.put((msg["task_id"], msg["text"], msg["voice"], False))
    elif t == "tts_multi":
        task_queue.put((msg["task_id"], msg["texts"], msg["voice"], True))
    elif t == "clone":
        try:
            wav = base64.b64decode(msg.get("wav", "") or "")
        except Exception:
            wav = b""
        task_queue.put(("clone", msg["task_id"], msg.get("text", ""), msg["voice_name"], wav))
    elif t == "ping":
        with send_lock:
            ws.send(json.dumps({"type": "pong"}))


def on_open(ws):
    global ws_app
    ws_app = ws
    names = reregister_voices()
    with send_lock:
        ws.send(json.dumps({"type": "register", "voices": names}))
    threading.Thread(target=heartbeat, args=(ws,), daemon=True).start()


def heartbeat(ws):
    while running:
        time.sleep(30)
        try:
            with send_lock:
                ws.send(json.dumps({"type": "ping"}))
        except Exception:
            break


def on_close(ws, *a):
    print("[ws] 连接关闭")


def on_error(ws, e):
    print(f"[ws] 错误 {e}")


def main():
    global running
    backoff = 1
    threading.Thread(target=worker, daemon=True).start()
    while True:
        try:
            ws = websocket.WebSocketApp(
                RELAY_WS,
                on_open=on_open,
                on_message=on_message,
                on_close=on_close,
                on_error=on_error,
            )
            ws.run_forever()
        except Exception as e:
            print(f"[ws] run_forever 异常 {e}")
        print(f"[ws] {backoff}s 后重连（指数退避）")
        time.sleep(backoff)
        backoff = min(backoff * 2, 30)
    running = False
    task_queue.put(None)


if __name__ == "__main__":
    main()

import time, urllib.request, urllib.error, json

BASE = "http://127.0.0.1:8000"
TOKEN = "p0-dev-token-change-me"
H = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def get(path):
    req = urllib.request.Request(BASE + path, headers=H)
    return urllib.request.urlopen(req, timeout=10)


def post(path, payload):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload).encode("utf-8"), headers=H, method="POST"
    )
    return urllib.request.urlopen(req, timeout=90)


print("=== wait 4s for WS register ===")
time.sleep(4)

try:
    r = get("/api/status")
    print("STATUS", r.status, r.read().decode())
except Exception as e:
    print("STATUS ERR", repr(e))

try:
    r = get("/api/voices")
    print("VOICES", r.status, r.read().decode())
except Exception as e:
    print("VOICES ERR", repr(e))

tests = [
    "你好，我是你的语音助手。",
    "今天天气不错，我们出去走走吧。",
    "这是第三句测试，验证串行合成是否正常。",
]
for i, t in enumerate(tests):
    try:
        r = post("/api/tts", {"text": t, "voice": "zxy"})
        data = r.read()
        is_riff = data[:4] == b"RIFF"
        print(f"TTS[{i}] status={r.status} bytes={len(data)} riff={is_riff} head={data[:8]!r}")
    except urllib.error.HTTPError as e:
        print(f"TTS[{i}] HTTP {e.code} {e.read().decode()[:200]}")
    except Exception as e:
        print(f"TTS[{i}] ERR {repr(e)}")

print("=== DONE ===")

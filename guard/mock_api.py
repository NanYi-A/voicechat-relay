"""
Mock api.py（仅本地联调用，不依赖 CosyVoice）
模拟 api.py 的 OpenAI 风格端点，返回测试 WAV，用于验证云端<->守护 WS 转发链路。
真实部署时停掉本 mock，启动 <project-root>\CosyVoice-Enhanced\api\api.py（默认 :9996）即可。
"""
import io
import time
import wave

from flask import Flask, Response, request

app = Flask(__name__)


def make_wav(seconds=1, rate=16000):
    n = int(seconds * rate)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * n)
    return buf.getvalue()


@app.route("/v1/audio/speech", methods=["POST"])
def speech():
    # 模拟合成延迟
    time.sleep(0.3)
    text = (request.get_json(silent=True) or {}).get("input", "")
    # 长度随文本变化，验证多句各自合成
    secs = max(1, min(len(text) // 5, 3))
    return Response(make_wav(secs), mimetype="audio/wav")


@app.route("/v1/audio/voice/clone", methods=["POST"])
def clone():
    name = (request.form or {}).get("name", "unknown")
    return {"message": "ok", "voice": name}, 200


@app.route("/spklist", methods=["GET"])
def spklist():
    return {"voices": []}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=9996)

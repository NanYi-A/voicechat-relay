"""
clone_voice.py —— 通用：把任意参考音克隆成独立音色，不覆盖已有音色。

逻辑：
  1. 读取源音频（任意长度，<=30s 硬上限）
  2. 能量检测语音起点 + 强制跳过前导（避开开头底噪/爆音）
  3. 截 TARGET_SEC 秒干净段（转单声道）
  4. whisper 转写真实文本（prompt_text 必须与音频对齐，否则合成夹杂乱码）
  5. 注册到 http://localhost:9996 ，音色名 = --name（不同名互不覆盖）
  6. 生成对比音频 test_<name>.wav
  7. 验证原有音色（--keep）仍可正常合成

用法（cosyvoice-env 已激活的 Git Bash）：
  /d/ai-voice/cosyvoice-env/Scripts/python D:/ai-voice/clone_voice.py \
      --src /path/to/your/sample.wav --name voice_a
"""
import argparse, os, torchaudio, torch, requests
import whisper


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default='D:/ai-voice/zxy/my_voice.wav')
    ap.add_argument('--name', default='myvoice')
    ap.add_argument('--sec', type=float, default=12)
    ap.add_argument('--skip-head', type=float, default=1.0)
    ap.add_argument('--skip-lead', type=float, default=0.3)
    ap.add_argument('--keep', default='myvoice', help='验证此已有音色未被影响')
    ap.add_argument('--url', default='http://localhost:9996')
    ap.add_argument('--model', default='tiny', help='whisper 模型: tiny/base/small')
    ap.add_argument('--retranscribe', action='store_true',
                    help='强制重新 whisper 转写(否则优先用已存的 <name>_transcript.txt)')
    args = ap.parse_args()

    clean_out = f'D:/ai-voice/{args.name}/{args.name}_clean.wav'

    # 1) 加载
    wav, sr = torchaudio.load(args.src)
    if wav.shape[0] > 1:
        wav = wav.mean(dim=0, keepdim=True)
    wav = wav.squeeze(0)
    total = wav.shape[0] / sr
    print(f'[1] {args.src}: {total:.1f}s, sr={sr}')

    # 2) 能量检测语音起点
    frame = int(0.025 * sr)
    hop = int(0.010 * sr)
    n = (wav.shape[0] - frame) // hop + 1
    rms = torch.zeros(n)
    for i in range(n):
        seg = wav[i * hop:i * hop + frame]
        rms[i] = torch.sqrt((seg ** 2).mean() + 1e-10)
    noise = torch.quantile(rms, 0.05)
    thr = max(noise * 4, 1e-3)
    sf = (rms > thr).nonzero().flatten()
    detected = (int(sf[0]) * hop / sr) if len(sf) else 0.0
    print(f'[2] noiseRMS={noise:.4f} thr={thr:.4f} speechStart={detected:.2f}s')

    # 3) 截干净段（start 仅由 skip 参数决定；skip 皆为 0 时即"从头取前 N 秒"）
    start = args.skip_head + args.skip_lead
    cs = int(start * sr)
    ce = min(cs + int(args.sec * sr), wav.shape[0])
    clip = wav[cs:ce]
    print(f'[3] clip {cs/sr:.2f}~{ce/sr:.2f}s ({(ce-cs)/sr:.1f}s) -> {clean_out}')
    torchaudio.save(clean_out, clip.unsqueeze(0), sr)

    # 4) whisper 转写真实文本（已存 transcript 优先，便于手改对齐）
    transcript_path = f'D:/ai-voice/{args.name}/{args.name}_transcript.txt'
    text = None
    if (not args.retranscribe) and os.path.exists(transcript_path):
        with open(transcript_path, encoding='utf-8') as f:
            cand = f.read().strip()
        if cand:
            text = cand
            print(f'[4] 使用已存转写文本: {transcript_path!r}')
    if text is None:
        print('[4] whisper 转写中...')
        m = whisper.load_model(args.model)
        text = m.transcribe(clean_out, language='zh')['text'].strip()
        with open(transcript_path, 'w', encoding='utf-8') as f:
            f.write(text)
        print(f'    已保存转写到 {transcript_path}')
    print(f'    TEXT: {text!r}')

    # 5) 注册（不同名互不覆盖，不影响 myvoice）
    r = requests.post(f'{args.url}/v1/audio/voice/clone',
                      files={'file': open(clean_out, 'rb')},
                      data={'name': args.name, 'text': text})
    print(f'[5] clone {args.name}: {r.status_code} {r.json().get("message","")}')

    # 6) 生成新音色对比音频
    r2 = requests.post(f'{args.url}/v1/audio/speech',
                       headers={'Content-Type': 'application/json', 'Authorization': 'Bearer sk-none'},
                       json={'input': '你好，今天天气真不错，我们一起去公园散步吧。',
                             'model': 'tts-1', 'voice': args.name, 'response_format': 'wav'})
    out = f'D:/ai-voice/{args.name}/test_{args.name}.wav'
    if r2.status_code == 200:
        open(out, 'wb').write(r2.content)
        print(f'[6] 已保存 {out} ✅')
    else:
        print(f'[6] TTS err {r2.status_code} {r2.text[:300]}')

    # 7) 验证原有音色未被影响
    r3 = requests.post(f'{args.url}/v1/audio/speech',
                       headers={'Content-Type': 'application/json', 'Authorization': 'Bearer sk-none'},
                       json={'input': '我是原来的音色，测试一下还在不在。',
                             'model': 'tts-1', 'voice': args.keep, 'response_format': 'wav'})
    if r3.status_code == 200:
        print(f'[7] 原有音色 {args.keep} 仍正常合成 (HTTP {r3.status_code}) ✅ 未受影响')
    else:
        print(f'[7] 警告：原有音色 {args.keep} 返回 {r3.status_code}，可能需重新注册')


if __name__ == '__main__':
    main()

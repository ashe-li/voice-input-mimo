"""A/B backtest for the Chinese refine system prompt.

Compares the refined output of two system prompts (old vs new) against the
same ASR inputs. Prints a side-by-side markdown table.

Usage:
    python scripts/bench_refine_prompt_ab.py \\
        --base-url http://127.0.0.1:8082/v1 \\
        --model qwen3-8b-mlx \\
        --runs 1

Default endpoint targets Rapid-MLX (the project's primary LLM backend); any
OpenAI-compatible /v1/chat/completions service works (LM Studio, ollama, etc.).

Inputs are baked from the user's clipboard-archive.txt at the times noted —
real long-form ASR transcripts of mixed Chinese/English voice dictation that
revealed the v0 prompt under-corrects.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
import urllib.error


PROMPT_V0 = """/no_think You are a conservative speech recognition error corrector. ONLY fix clear, obvious transcription mistakes. When in doubt, leave the text unchanged.

What to fix:
- English words/acronyms wrongly rendered as Chinese characters (e.g. "配森" → "Python", "杰森" → "JSON", "阿皮爱" → "API")
- Obvious Chinese homophone errors where context makes the correct character clear
- Broken English words or phrases split/merged incorrectly by the recognizer

What NOT to do:
- Do NOT rephrase, rewrite, or "improve" any text
- Do NOT add or remove words beyond fixing recognition errors
- Do NOT change text that could plausibly be correct
- Do NOT alter punctuation unless clearly wrong

If the input appears correct, return it exactly as-is. Return ONLY the text, nothing else.
"""

_V1_STORE_BASE = """/no_think You clean up a noisy Chinese ASR transcript.

Examples
Input: 嗯，打字真的蠻慢的，所以如果以後大家都假假定啊，大家都用語音輸入的話。
Output: 打字真的蠻慢的，所以如果以後大家都假定，大家都用語音輸入的話。

Input: 那目前大多數問問題會是語語音輸入的準確度。
Output: 那目前大多數問題會是語音輸入的準確度。

Input: 呃，創作者或或者使用者還可以決定我要不要用，比如說我們的，呃，skill。
Output: 創作者或者使用者還可以決定我要不要用，比如說我們的 skill。

Input: 呃，我的問題是，我遇到一個 bug。
Output: 我的問題是，我遇到一個 bug。

Input: 嗯，這個版本應該可以 work。
Output: 這個版本應該可以 work。

If the input already reads cleanly, return it exactly as-is. Output ONLY the cleaned text — no preamble, no quotes, no explanations."""

# Mirrors Sources/VoiceInputMimo/Prompts/BuiltinPromptCatalog.swift Default Refine
# profile: basePrompt above + these 5 skill snippets appended in order with "\n\n"
# separators (matches PromptComposer.render). Source of truth is the Swift
# catalog; if catalog content changes, update both.
_V1_STORE_SKILLS = [
    # builtin-output-same-language
    "Output the SAME LANGUAGE as input — never translate to English. Mixed Chinese/English must stay mixed.",
    # builtin-drop-fillers
    "Always drop verbal fillers when they carry no meaning: 嗯, 呃, 啊, 欸, 那個, 就是說.",
    # builtin-collapse-stutter
    "Always collapse immediate stutter or repetition: 假假定→假定, 或或者→或者, 問問題→問題, 語語音→語音, 需要需要→需要.",
    # builtin-recover-en-cn-homophones
    "Restore English words misheard as Chinese: 配森→Python, 杰森→JSON, 阿皮愛→API, 瑞克特→React, 康波奈特→component, 肉特→route. Also fix obvious Chinese homophone errors when context makes the correct character clear, and fix English/Chinese mix split incorrectly by the recognizer. Stuttered acronyms also collapse: L M K→LLM, A P I→API, J S→JS.",
    # builtin-no-rephrase
    'Never rephrase, rewrite, or "improve" the wording. Never substitute synonyms. Never add or remove content words (nouns, verbs, adjectives). Never change tone or register (casual stays casual). Never alter punctuation unless clearly wrong. Never collapse meaningful repetitions used for emphasis (e.g. "很多很多").',
]

PROMPT_V1_STORE = "\n\n".join([_V1_STORE_BASE.strip()] + _V1_STORE_SKILLS)


PROMPT_V1 = """/no_think You clean up a noisy Chinese ASR transcript. Output the SAME LANGUAGE as input — never translate to English. Mixed Chinese/English must stay mixed.

Always fix:
- Drop verbal fillers when they carry no meaning: 嗯, 呃, 啊, 欸, 那個, 就是說
- Collapse immediate stutter / repetition: 假假定→假定, 或或者→或者, 問問題→問題, 語語音→語音, 需要需要→需要
- Restore English-misheard-as-Chinese: 配森→Python, 杰森→JSON, 阿皮愛→API, 瑞克特→React, 康波奈特→component, 肉特→route
- Obvious Chinese homophone errors when context makes the correct character clear
- Broken or merged English/Chinese mix split incorrectly by the recognizer

Never:
- Never translate Chinese to English
- Never rephrase, rewrite, or "improve" the wording
- Never substitute synonyms
- Never add or remove content words (nouns, verbs, adjectives)
- Never change tone or register (casual stays casual)
- Never alter punctuation unless clearly wrong
- Never collapse meaningful repetitions used for emphasis (e.g. "很多很多")

Examples
Input: 嗯，打字真的蠻慢的，所以如果以後大家都假假定啊，大家都用語音輸入的話。
Output: 打字真的蠻慢的，所以如果以後大家都假定，大家都用語音輸入的話。

Input: 那目前大多數問問題會是語語音輸入的準確度。
Output: 那目前大多數問題會是語音輸入的準確度。

Input: 呃，創作者或或者使用者還可以決定我要不要用，比如說我們的，呃，skill。
Output: 創作者或者使用者還可以決定我要不要用，比如說我們的 skill。

Input: 呃，我的問題是，我遇到一個 bug。
Output: 我的問題是，我遇到一個 bug。

Input: 嗯，這個版本應該可以 work。
Output: 這個版本應該可以 work。

If the input already reads cleanly, return it exactly as-is. Output ONLY the cleaned text — no preamble, no quotes, no explanations.
"""


# Real ASR captures from ~/Library/Application Support/VoiceInputMimo/clipboard-archive.txt
TEST_CASES = [
    {
        "id": "S1-short",
        "label": "短句 / 多 filler",
        "asr": "幫我確認一下，我即便是用了呃中文，然後LM需要enforce的功能，但是它還是會有一個階段是英文的時間，然後幫我確認一下這個是是不是有bug。",
    },
    {
        "id": "S2-short",
        "label": "短句 / 中英混雜 filler",
        "asr": "呃，我的問題是，我遇到我當我選擇中文LM修正（括號不翻譯）這個選項的時候，它還是會有一個英文翻譯的互動出現在畫面上。",
    },
    {
        "id": "S3-mid",
        "label": "中等 / customize prompt 描述",
        "asr": "然後幫我給到一個設計，是我希望我的，嗯，中文LM修正，以及我的英文翻譯，這兩個都可以是我可以customize我的prompt，然後我可以prompt可以，比如說用我自己額外的skill去修正它，或是類別似的方法，可以讓使用者自己客、客製化自己的prompt要用怎麼樣輸入。",
    },
    {
        "id": "S4-long",
        "label": "長段 / 多 stutter (假假定 / 問問題 / 語語音 / 需要需要)",
        "asr": "嗯，打字真的蠻慢的，所以如果以後大家都假假定啊，大家都用語音輸入的話，那我們可以在這個平臺上面先測試用語音輸入作為改變創作者寫文章的那種方式。然後，呃，目前大多數問問題會是語語音輸入的準確度跟語音輸入的時間，以及語音輸入的，呃，中英文混雜的問題。那這個問題可以用模型去解決。那早期的階段會太多，修正完之後需要需要，呃，創作者或是輸入者自己去手動 fix 的部分。那現在就可以藉由，呃， LM 的模型迭代，然後得到更好的使用者體驗。",
    },
    {
        "id": "S5-long",
        "label": "長段 / raw 字密集 + 多 filler",
        "asr": "然後還有一個點會是，呃，假定我的輸入會是 raw 的，就是我講什麼它就輸出什麼。那在下一個階段才會是，呃，我把我 raw 的，就是很生硬的字顯示出來之後，呃，創作者或或者使用者還可以決定我要不要用，比如說我們的，呃，skill，我們的語法修正去 refine，呃，LM refine 它的，它的整體的結構。那雖然他說的話可能 raw 的字會很多很多，呃，比如說口語化的那種嗯、呃、啊這種字，但是它整體的表現可以做得更好，然後可以更像是一個文章，就他講完就彷彿是他寫完文章這種體驗，我覺得應該是哈濛濛這樣。",
    },
    {
        "id": "S6-meta",
        "label": "Meta / 自我參照 + skill 一詞",
        "asr": "然後同時幫我確認我現在的錄音的log裡面應該會有原始的音檔跟我的輸出，然後我有大量的，應該至少有三份以上的是長時間的錄音，然後幫我依照這個結果先修正第一版的中文LM enforce的強呃skill的修正，因為現在會變成是我使用中文的LM enforce修正，它並沒有修正太多。",
    },
]


def call_llm(base_url: str, model: str, system: str, user: str, timeout: float) -> tuple[str, float]:
    url = f"{base_url.rstrip('/')}/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0.3,
        "max_tokens": 600,
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer local-api-key",
        },
        method="POST",
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as e:
        return f"<ERROR: {e}>", 0.0
    dt = time.perf_counter() - t0
    content = (data.get("choices") or [{}])[0].get("message", {}).get("content", "") or ""
    return content.strip(), dt


def char_diff_count(a: str, b: str) -> int:
    """Approximate edit count: |len_a - len_b| + simple diff fallback."""
    return abs(len(a) - len(b))


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default="http://127.0.0.1:8082/v1")
    p.add_argument("--model", default="qwen3-8b-mlx")
    p.add_argument("--timeout", type=float, default=120.0)
    p.add_argument("--out-md", default=None, help="Write markdown report to this path")
    args = p.parse_args()

    rows: list[dict] = []
    for case in TEST_CASES:
        out_v0, t_v0 = call_llm(args.base_url, args.model, PROMPT_V0, case["asr"], args.timeout)
        out_v1, t_v1 = call_llm(args.base_url, args.model, PROMPT_V1, case["asr"], args.timeout)
        out_v1s, t_v1s = call_llm(args.base_url, args.model, PROMPT_V1_STORE, case["asr"], args.timeout)
        rows.append(
            {
                **case,
                "v0_out": out_v0,
                "v0_ms": int(t_v0 * 1000),
                "v0_changed": out_v0 != case["asr"],
                "v0_delta_chars": len(out_v0) - len(case["asr"]),
                "v1_out": out_v1,
                "v1_ms": int(t_v1 * 1000),
                "v1_changed": out_v1 != case["asr"],
                "v1_delta_chars": len(out_v1) - len(case["asr"]),
                "v1s_out": out_v1s,
                "v1s_ms": int(t_v1s * 1000),
                "v1s_changed": out_v1s != case["asr"],
                "v1s_delta_chars": len(out_v1s) - len(case["asr"]),
            }
        )

    print(f"\n# Refine prompt A/B/C backtest — {args.model}\n")
    print(f"Endpoint: `{args.base_url}`  ·  Cases: {len(rows)}\n")
    print(
        "Variants:\n"
        "- **v0**: legacy conservative prompt (pre-v1)\n"
        "- **v1**: hardcoded v1.1 prompt currently in `LLMRefiner.defaultRefinePrompt`\n"
        "- **v1-store**: builtin Default Refine profile rendered via `PromptComposer.render` "
        "(basePrompt + 5 skills appended) — Phase 1 acceptance gate\n"
    )

    print("## Summary\n")
    v0_changed = sum(1 for r in rows if r["v0_changed"])
    v1_changed = sum(1 for r in rows if r["v1_changed"])
    v1s_changed = sum(1 for r in rows if r["v1s_changed"])
    v0_avg_ms = sum(r["v0_ms"] for r in rows) / len(rows) if rows else 0
    v1_avg_ms = sum(r["v1_ms"] for r in rows) / len(rows) if rows else 0
    v1s_avg_ms = sum(r["v1s_ms"] for r in rows) / len(rows) if rows else 0
    v0_total_delta = sum(r["v0_delta_chars"] for r in rows)
    v1_total_delta = sum(r["v1_delta_chars"] for r in rows)
    v1s_total_delta = sum(r["v1s_delta_chars"] for r in rows)
    print("| Metric | v0 (legacy) | v1 (hardcoded) | v1-store (composed) |")
    print("|---|---|---|---|")
    print(f"| Cases changed | {v0_changed}/{len(rows)} | {v1_changed}/{len(rows)} | {v1s_changed}/{len(rows)} |")
    print(f"| Avg latency | {v0_avg_ms:.0f} ms | {v1_avg_ms:.0f} ms | {v1s_avg_ms:.0f} ms |")
    print(f"| Total Δchars | {v0_total_delta:+d} | {v1_total_delta:+d} | {v1s_total_delta:+d} |")
    print()
    print(f"**Acceptance**: v1-store changed = {v1s_changed}/{len(rows)} (must equal {v1_changed}/{len(rows)} v1 baseline).")
    print()

    print("## Per-case comparison\n")
    for r in rows:
        print(f"### {r['id']} — {r['label']}\n")
        print(f"**ASR ({len(r['asr'])} chars)**: {r['asr']}\n")
        v0_tag = "🟰 unchanged" if not r["v0_changed"] else f"✏️ {r['v0_delta_chars']:+d}"
        v1_tag = "🟰 unchanged" if not r["v1_changed"] else f"✏️ {r['v1_delta_chars']:+d}"
        v1s_tag = "🟰 unchanged" if not r["v1s_changed"] else f"✏️ {r['v1s_delta_chars']:+d}"
        print(f"**v0 ({r['v0_ms']} ms, {v0_tag})**: {r['v0_out']}\n")
        print(f"**v1 ({r['v1_ms']} ms, {v1_tag})**: {r['v1_out']}\n")
        print(f"**v1-store ({r['v1s_ms']} ms, {v1s_tag})**: {r['v1s_out']}\n")
        print()

    if args.out_md:
        # Re-print to file
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            # Reuse render — re-run prints
            print(f"# Refine prompt A/B/C backtest — {args.model}\n")
            print(f"Endpoint: `{args.base_url}`  ·  Cases: {len(rows)}\n")
            print("## Summary\n")
            print("| Metric | v0 | v1 | v1-store |")
            print("|---|---|---|---|")
            print(f"| Cases changed | {v0_changed}/{len(rows)} | {v1_changed}/{len(rows)} | {v1s_changed}/{len(rows)} |")
            print(f"| Avg latency | {v0_avg_ms:.0f} ms | {v1_avg_ms:.0f} ms | {v1s_avg_ms:.0f} ms |")
            print(f"| Total Δchars | {v0_total_delta:+d} | {v1_total_delta:+d} | {v1s_total_delta:+d} |\n")
            print("## Per-case comparison\n")
            for r in rows:
                print(f"### {r['id']} — {r['label']}\n")
                print(f"**ASR**: {r['asr']}\n")
                print(f"**v0**: {r['v0_out']}\n")
                print(f"**v1**: {r['v1_out']}\n")
                print(f"**v1-store**: {r['v1s_out']}\n")
        from pathlib import Path
        Path(args.out_md).write_text(buf.getvalue(), encoding="utf-8")
        print(f"Wrote markdown to: {args.out_md}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())

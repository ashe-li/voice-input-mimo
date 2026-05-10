"""Generate Polish-Chinese few-shot candidates via two strategies.

For each ASR test case in bench_refine_prompt_ab.TEST_CASES, this script produces
candidate "polished written Chinese" outputs using:

    A) EN-pivot:    ASR (ZH) --[ClaudeCode prompt]--> EN
                          EN --[back-translate prompt]--> polished ZH
    B) Direct polish: ASR (ZH) --[polish-zh prompt]--> polished ZH

It then writes a markdown side-by-side report so a human can pick the best
candidate per case before baking into BuiltinPromptCatalog.polishZhProfile's
basePrompt few-shot section.

Recommended: point --base-url at a stronger model than qwen3-8b for both passes
since few-shot is generated once and quality compounds. The local qwen endpoint
works as a sanity check but tends to produce translation-flavored Chinese.

Usage
    python scripts/gen_polish_zh_fewshot.py \\
        --base-url http://127.0.0.1:8082/v1 \\
        --model qwen3-8b-mlx \\
        --out-md docs/polish-zh-fewshot-candidates.md

Environment
    Reads OPENAI_API_KEY (or hardcoded "local-api-key" for local servers).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Reuse the curated ASR captures.
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from bench_refine_prompt_ab import TEST_CASES  # noqa: E402

# Mirror BuiltinPromptCatalog.defaultClaudeCodeProfile basePrompt.
PROMPT_TRANSLATE_TO_EN = """/no_think You translate a developer's mixed Chinese/English voice input into clean English text for a coding assistant.

CRITICAL: Your output MUST be English. Never echo Chinese characters back in the output. If the input is already pure English, return it cleaned. If the input is Chinese or mixed, translate the Chinese parts to English while preserving inline English identifiers (camelCase, snake_case, tech names) verbatim.

Decision rule
- Translate only what was said — never add information that wasn't there.
- Keep the same level of detail; don't summarize, don't elaborate.
- When the speaker self-corrects, prefer the final form.
- If a fragment is too garbled to translate confidently, keep the original wording rather than guessing.

Output ONLY the translation — no preamble, no quotes, no explanations."""

# Tuned to avoid translationese ("翻譯腔"). Explicitly asks for natural written
# Taiwanese Chinese, identifier preservation, and speech-act fidelity.
PROMPT_BACK_TRANSLATE = """/no_think You translate clean English text back into natural written Traditional Chinese (Taiwan) for a developer audience.

Decision rule
- Output natural 書面語 — avoid 翻譯腔: no over-use of "它", no English-style passive voice, no awkward word order.
- Preserve every code identifier, English tech name, and proper noun verbatim (component, useState, API, JSON, LLM, refactor, refine, raw, bug — keep these in English, do NOT translate to 組件/介面/etc).
- Preserve the speech act:
  - imperative ("Please verify X", "Refactor X") → 祈使 ("幫我確認 X" / "請確認 X" / "重構 X")
  - declarative ("I'm currently X", "Actually X") → 敘述 ("我現在 X" / "其實 X")
  - question ("Will X", "Why X") → 疑問 ("會不會 X" / "為什麼 X")
- Match register: casual stays casual, technical stays technical.
- Do not add or remove information.

Output ONLY the Chinese translation — no preamble, no quotes, no explanations."""

# Mirror BuiltinPromptCatalog.polishZhProfile basePrompt (without skill suffix
# — composed prompt would be even longer; this is the minimal direct test).
PROMPT_POLISH_ZH_DIRECT = """/no_think You polish a developer's noisy spoken Chinese into clean written Chinese.

Output language: SAME AS INPUT — Chinese with inline English identifiers preserved verbatim. Never translate to English.

Decision rule
- Preserve every content word, identifier, and proper noun.
- Allow light spoken-to-written normalization (tighten redundant connectives, drop conversational scaffolding) only when it does not change meaning.
- Preserve the speaker's speech act (request stays request, description stays description, question stays question).
- When the speaker self-corrects, prefer the final form.
- If a fragment is too garbled to clean up confidently, keep the original wording rather than guessing.
- Drop verbal fillers (嗯, 呃, 啊, 欸, 那個, 就是說) and collapse stutter (假假定→假定, 問問題→問題).

Output ONLY the polished text — no preamble, no quotes, no explanations."""


def call_llm(
    base_url: str,
    api_key: str,
    model: str,
    system: str,
    user: str,
    timeout: float,
    temperature: float = 0.3,
) -> tuple[str, float]:
    url = f"{base_url.rstrip('/')}/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": temperature,
        "max_tokens": 800,
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
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


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default="http://127.0.0.1:8082/v1")
    p.add_argument("--model", default="qwen3-8b-mlx")
    p.add_argument("--api-key", default=os.environ.get("OPENAI_API_KEY", "local-api-key"))
    p.add_argument("--timeout", type=float, default=180.0)
    p.add_argument("--out-md", default=None, help="Write markdown report to this path")
    p.add_argument("--temperature", type=float, default=0.3)
    p.add_argument(
        "--strategy",
        choices=["both", "pivot", "direct"],
        default="both",
        help="Which generation strategies to run",
    )
    args = p.parse_args()

    rows: list[dict] = []
    for case in TEST_CASES:
        asr = case["asr"]
        en_out = ""
        en_ms = 0
        pivot_zh = ""
        pivot_zh_ms = 0
        direct_zh = ""
        direct_zh_ms = 0

        if args.strategy in ("both", "pivot"):
            en_out, t_en = call_llm(
                args.base_url, args.api_key, args.model,
                PROMPT_TRANSLATE_TO_EN, asr, args.timeout, args.temperature,
            )
            en_ms = int(t_en * 1000)
            pivot_zh, t_back = call_llm(
                args.base_url, args.api_key, args.model,
                PROMPT_BACK_TRANSLATE, en_out, args.timeout, args.temperature,
            )
            pivot_zh_ms = int(t_back * 1000)

        if args.strategy in ("both", "direct"):
            direct_zh, t_direct = call_llm(
                args.base_url, args.api_key, args.model,
                PROMPT_POLISH_ZH_DIRECT, asr, args.timeout, args.temperature,
            )
            direct_zh_ms = int(t_direct * 1000)

        rows.append({
            **case,
            "en_out": en_out,
            "en_ms": en_ms,
            "pivot_zh": pivot_zh,
            "pivot_zh_ms": pivot_zh_ms,
            "direct_zh": direct_zh,
            "direct_zh_ms": direct_zh_ms,
        })

    lines: list[str] = []
    lines.append(f"# Polish-ZH few-shot candidates — {args.model}\n")
    lines.append(f"Endpoint: `{args.base_url}`  ·  Cases: {len(rows)}\n")
    lines.append(
        "Strategies:\n"
        "- **EN-pivot**: ASR → ClaudeCode translate → back-translate to ZH (risk: 翻譯腔)\n"
        "- **Direct**: ASR → polish-zh prompt directly (risk: under-edits like Default Refine)\n"
    )
    lines.append("\nReview each pair and pick the best version (or hand-edit) before "
                 "pasting into `BuiltinPromptCatalog.polishZhProfile.basePrompt`.\n")

    for r in rows:
        lines.append(f"\n## {r['id']} — {r['label']}\n")
        lines.append("**ASR (input):**\n")
        lines.append(f"> {r['asr']}\n")
        if r["en_out"]:
            lines.append(f"\n**EN pivot ({r['en_ms']}ms):**\n")
            lines.append(f"> {r['en_out']}\n")
            lines.append(f"\n**EN-pivot back-translated ({r['pivot_zh_ms']}ms):**\n")
            lines.append(f"> {r['pivot_zh']}\n")
        if r["direct_zh"]:
            lines.append(f"\n**Direct polish ({r['direct_zh_ms']}ms):**\n")
            lines.append(f"> {r['direct_zh']}\n")

    report = "\n".join(lines)
    print(report)
    if args.out_md:
        out_path = Path(args.out_md)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(report, encoding="utf-8")
        print(f"\n[wrote] {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

import Foundation

/// Out-of-box skills + profiles. First launch writes these to App Support.
/// Built-ins are read-only; users duplicate to customize.
enum BuiltinPromptCatalog {

    /// Reference timestamp baked into builtin profiles so that JSON dumps are deterministic
    /// across machines (no per-install drift in createdAt/updatedAt).
    private static let referenceDate = Date(timeIntervalSince1970: 1_762_700_400)  // 2025-11-09 09:00:00Z

    static let skills: [PromptSkill] = [
        // Format
        PromptSkill(
            id: "builtin-output-same-language",
            name: "Output same language",
            category: .format,
            content: "Output the SAME LANGUAGE as input — never translate to English. Mixed Chinese/English must stay mixed.",
            description: "Refine mode: forbid Chinese→English translation; preserve original language exactly.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-output-english-only",
            name: "Output English only",
            category: .format,
            content: "Output ONLY the English translation. No quotes, no preamble, no Chinese characters, no trailing newline.",
            description: "ClaudeCode mode: enforce English-only output suitable for a coding assistant.",
            isBuiltin: true
        ),

        // Style
        PromptSkill(
            id: "builtin-drop-fillers",
            name: "Drop verbal fillers",
            category: .style,
            content: "Always drop verbal fillers when they carry no meaning: 嗯, 呃, 啊, 欸, 那個, 就是說.",
            description: "Removes meaningless filler tokens introduced by hesitation or speech rhythm.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-no-rephrase",
            name: "No rephrasing",
            category: .style,
            content: """
                Never rephrase, rewrite, or "improve" the wording. \
                Never substitute synonyms. \
                Never add or remove content words (nouns, verbs, adjectives). \
                Never change tone or register (casual stays casual). \
                Never alter punctuation unless clearly wrong. \
                Never collapse meaningful repetitions used for emphasis (e.g. "很多很多").
                """,
            description: "Locks the model to ASR-faithful cleanup; forbids stylistic edits.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-style-preserve-identifiers",
            name: "Preserve code identifiers",
            category: .style,
            content: """
                Preserve identifiers verbatim (camelCase / snake_case). \
                Keep tech names in English (component, useState, API). \
                Match original tone and intent. \
                Avoid redundant words (整套流程 → workflow, not "workflow flow").
                """,
            description: "ClaudeCode mode: keep code identifiers and technical names exact.",
            isBuiltin: true
        ),

        // Recovery
        PromptSkill(
            id: "builtin-collapse-stutter",
            name: "Collapse stutter / repetition",
            category: .recovery,
            content: "Always collapse immediate stutter or repetition: 假假定→假定, 或或者→或者, 問問題→問題, 語語音→語音, 需要需要→需要.",
            description: "Removes accidental syllable doubling caused by ASR.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-recover-en-cn-homophones",
            name: "Recover EN-CN homophones",
            category: .recovery,
            content: """
                Restore English words misheard as Chinese: \
                配森→Python, 杰森→JSON, 阿皮愛→API, 瑞克特→React, 康波奈特→component, 肉特→route. \
                Also fix obvious Chinese homophone errors when context makes the correct character clear, \
                and fix English/Chinese mix split incorrectly by the recognizer. \
                Stuttered acronyms also collapse: L M K→LLM, A P I→API, J S→JS.
                """,
            description: "Repairs phonetic transliteration mistakes when the speaker said an English word.",
            isBuiltin: true
        ),

        // Speech act
        PromptSkill(
            id: "builtin-speech-act-detection",
            name: "Speech act detection",
            category: .speechAct,
            content: """
                Speech act detection (CRITICAL — preserve speaker's intent):
                - REQUEST ("幫我X", "請X", "可以X嗎") → imperative ("Refactor X", "Add X")
                - DESCRIPTION/STATEMENT ("我現在X", "其實是X", "目前X") → declarative ("I'm currently X", "Actually X")
                - QUESTION ("會不會X", "為什麼X", "X嗎") → question ("Will X", "Why X")
                """,
            description: "ClaudeCode mode: keep speaker's intent (request vs description vs question) intact in translation.",
            isBuiltin: true
        ),
        PromptSkill(
            id: "builtin-speech-act-zh",
            name: "Speech act detection (Chinese)",
            category: .speechAct,
            content: """
                Speech act detection (CRITICAL — preserve speaker's intent in Chinese output):
                - REQUEST ("幫我X", "請X", "可以X嗎") → keep imperative form ("幫我X", "請X")
                - DESCRIPTION/STATEMENT ("我現在X", "其實是X", "目前X") → keep declarative
                - QUESTION ("會不會X", "為什麼X", "X嗎") → keep question form
                Do NOT convert between forms (e.g. do not turn "幫我確認" into "請確認", and do not flatten a request into a description).
                """,
            description: "Polish mode: keep request / description / question register intact in cleaned Chinese output.",
            isBuiltin: true
        ),

        // Light rewrite (polish-mode only — explicitly NOT used by Default Refine, which keeps no-rephrase lock)
        PromptSkill(
            id: "builtin-light-rewrite-zh",
            name: "Light spoken-to-written rewrite (Chinese)",
            category: .style,
            content: """
                Allow light spoken-to-written normalization while preserving content:
                - Tighten redundant connectives ("即便是" → "即使", "所以如果...的話" can fold into "假定...的話").
                - Drop conversational scaffolding that carries no content ("就是說", "比如說啊", "那個", "我會說", "那種").
                - Reorder fragments ONLY when the spoken order yields ungrammatical written Chinese.
                - When self-correction occurs ("我即便...其實是..."), keep the corrected form.
                - Never substitute synonyms for content words. Never add or remove content nouns / verbs / adjectives. Never summarize, never expand.
                - Match the speaker's register (casual stays casual, formal stays formal).
                - Preserve code identifiers, English tech names, and proper nouns verbatim.
                """,
            description: "Polish mode: permits light written-form normalization while keeping content and register intact.",
            isBuiltin: true
        ),
    ]

    static let profiles: [PromptProfile] = [
        defaultRefineProfile,
        defaultClaudeCodeProfile,
        polishZhProfile,
    ]

    /// Default Refine profile: keeps few-shot examples + final closing in basePrompt;
    /// rules live as appended skills (matches plan's append-mode v1).
    static let defaultRefineProfile = PromptProfile(
        id: "builtin-default-refine",
        name: "Default Refine",
        mode: .refine,
        basePrompt: """
            /no_think You are a high-precision cleanup pass for a noisy Chinese ASR transcript.

            Your job is to repair obvious recognition noise while preserving exactly what the speaker meant.

            Decision rule
            - Change text only when the corrected form is clearly more likely from local context.
            - If two readings are both plausible, keep the original wording.
            - Prefer the speaker's final correction over earlier partial words.

            Examples
            Input: 嗯，打字真的蠻慢的，所以如果以後大家都假假定啊，大家都用語音輸入的話。
            Output: 打字真的蠻慢的，所以如果以後大家都假定，大家都用語音輸入的話。

            Input: 那目前大多數問問題會是語語音輸入的準確度。
            Output: 那目前大多數問題會是語音輸入的準確度。

            Input: 呃，創作者或或者使用者還可以決定我要不要用，比如說我們的，呃，skill。
            Output: 創作者或者使用者還可以決定我要不要用，比如說我們的 skill。

            Input: 他會先顯示 raw 的字，之後再讓使用者決定要不要 refine。
            Output: 他會先顯示 raw 的字，之後再讓使用者決定要不要 refine。

            Input: 我想確認這個 A P I 是不是還有 bug。
            Output: 我想確認這個 API 是不是還有 bug。

            If the input already reads cleanly, return it exactly as-is. \
            Output ONLY the cleaned text — no preamble, no quotes, no explanations.
            """,
        skillIDs: [
            "builtin-output-same-language",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-recover-en-cn-homophones",
            "builtin-no-rephrase",
        ],
        displayLabel: "Refining (Default Refine)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    /// Default ClaudeCode profile: opening line in basePrompt, rules appended as skills.
    /// `output-english-only` is FIRST so the model commits to translating before
    /// any of the cleanup-style skills (which mostly discuss preserving Chinese)
    /// can drag it into a "process this Chinese" mindset and skip translation.
    static let defaultClaudeCodeProfile = PromptProfile(
        id: "builtin-default-claude-code",
        name: "Default ClaudeCode",
        mode: .claudeCode,
        basePrompt: """
            /no_think You translate a developer's mixed Chinese/English voice input \
            into clean English text for a coding assistant.

            CRITICAL: Your output MUST be English. Never echo Chinese characters back \
            in the output. If the input is already pure English, return it cleaned. \
            If the input is Chinese or mixed, translate the Chinese parts to English \
            while preserving inline English identifiers (camelCase, snake_case, \
            tech names) verbatim.

            Decision rule
            - Translate only what was said — never add information that wasn't there.
            - Keep the same level of detail; don't summarize, don't elaborate.
            - When the speaker self-corrects, prefer the final form.
            - If a fragment is too garbled to translate confidently, keep the original wording rather than guessing.
            """,
        skillIDs: [
            "builtin-output-english-only",
            "builtin-speech-act-detection",
            "builtin-recover-en-cn-homophones",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Translating (Default ClaudeCode)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )

    /// Polish profile: mirrors Default ClaudeCode philosophy (light rewriting allowed)
    /// but outputs natural written Chinese instead of translating to English.
    /// Differs from Default Refine: drops the `no-rephrase` lock, adds light-rewrite +
    /// Chinese speech-act preservation. Few-shot examples drawn from real ASR captures
    /// in `scripts/bench_refine_prompt_ab.py` TEST_CASES.
    static let polishZhProfile = PromptProfile(
        id: "builtin-polish-zh",
        name: "Polish (Chinese)",
        mode: .refine,
        basePrompt: """
            /no_think You polish a developer's noisy spoken Chinese into clean written Chinese.

            Output language: SAME AS INPUT — Chinese with inline English identifiers preserved verbatim. Never translate to English.

            Decision rule
            - Preserve every content word, identifier, and proper noun.
            - Allow light spoken-to-written normalization (tighten redundant connectives, drop conversational scaffolding) only when it does not change meaning.
            - Preserve the speaker's speech act (request stays request, description stays description, question stays question).
            - When the speaker self-corrects, prefer the final form.
            - If a fragment is too garbled to clean up confidently, keep the original wording rather than guessing.

            Examples
            Input: 幫我確認一下，我即便是用了呃中文，然後LM需要enforce的功能，但是它還是會有一個階段是英文的時間，然後幫我確認一下這個是是不是有bug。
            Output: 幫我確認，即使我用了中文 LM enforce 的功能，它還是會有一段時間出現英文，幫我確認這個是不是 bug。

            Input: 嗯，打字真的蠻慢的，所以如果以後大家都假假定啊，大家都用語音輸入的話。
            Output: 打字真的蠻慢，假定以後大家都用語音輸入的話。

            Input: 那個假定我的輸入會是 raw 的，就是說我講什麼它就輸出什麼。
            Output: 假定我的輸入是 raw 的，我講什麼它就輸出什麼。

            Input: 那目前大多數問問題會是語語音輸入的準確度。
            Output: 目前大多數問題是語音輸入的準確度。

            If the input already reads cleanly, return it exactly as-is. Output ONLY the polished text — no preamble, no quotes, no explanations.
            """,
        skillIDs: [
            "builtin-output-same-language",
            "builtin-speech-act-zh",
            "builtin-light-rewrite-zh",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-recover-en-cn-homophones",
            "builtin-style-preserve-identifiers",
        ],
        displayLabel: "Refining (Polish Chinese)",
        createdAt: referenceDate,
        updatedAt: referenceDate,
        isBuiltin: true
    )
}

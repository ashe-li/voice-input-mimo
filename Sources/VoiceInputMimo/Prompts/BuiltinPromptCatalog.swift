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
    ]

    static let profiles: [PromptProfile] = [
        defaultRefineProfile,
        defaultClaudeCodeProfile,
    ]

    /// Default Refine profile: keeps few-shot examples + final closing in basePrompt;
    /// rules live as appended skills (matches plan's append-mode v1).
    static let defaultRefineProfile = PromptProfile(
        id: "builtin-default-refine",
        name: "Default Refine",
        mode: .refine,
        basePrompt: """
            /no_think You clean up a noisy Chinese ASR transcript.

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
}

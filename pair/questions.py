"""The original question IDs are stable and must not be reused."""

CATEGORIES = [
    ("Communication", [
        "I prefer to discuss problems as soon as they arise.",
        "I need time alone before discussing difficult feelings.",
        "I express affection openly.",
        "I prefer direct communication over hints.",
        "I am comfortable discussing uncomfortable topics.",
        "I value frequent communication throughout the day.",
        "I prefer resolving disagreements through calm conversation.",
        "I need a partner who listens without immediately offering solutions.",
    ]),
    ("Emotional needs", [
        "I find it easy to express vulnerability.",
        "I need regular reassurance in a relationship.",
        "I value emotional independence.",
        "I feel comfortable relying on a partner.",
        "I need personal space even when a relationship is going well.",
        "I prefer a partner who shares feelings openly.",
        "I can remain emotionally present during conflict.",
        "I value consistency more than grand romantic gestures.",
    ]),
    ("Lifestyle", [
        "I enjoy a busy and socially active lifestyle.",
        "I prefer quiet evenings at home.",
        "I like planning activities in advance.",
        "I enjoy spontaneous plans.",
        "I value maintaining a regular daily routine.",
        "I enjoy trying unfamiliar experiences.",
        "I prefer spending most free time with my partner.",
        "I need substantial independent time and hobbies.",
    ]),
    ("Values", [
        "Shared core values are essential in a relationship.",
        "Financial responsibility is important to me.",
        "Family plays a central role in my life.",
        "Personal growth is a major priority for me.",
        "I value tradition in important life decisions.",
        "I prefer a partner who challenges my perspectives respectfully.",
        "Honesty matters more than avoiding uncomfortable truths.",
        "I want my partner and me to support each other’s ambitions.",
    ]),
    ("Conflict", [
        "I can apologize when I realize I am wrong.",
        "I need time to cool down before resolving an argument.",
        "I prefer to address disagreements directly.",
        "I can accept that my partner and I may never agree on everything.",
        "I avoid bringing up issues to keep the peace.",
        "I can discuss criticism without feeling personally attacked.",
        "I believe both partners should compromise during conflict.",
        "I need disagreements to be resolved before I can relax.",
    ]),
    ("Romance and affection", [
        "Physical affection is essential to me.",
        "Verbal expressions of love are important to me.",
        "Small everyday gestures make me feel loved.",
        "I enjoy frequent romantic dates.",
        "I value practical acts of care more than romantic surprises.",
        "I prefer a relationship that develops gradually.",
        "Sexual compatibility is important to relationship satisfaction.",
        "I am comfortable discussing intimacy and boundaries openly.",
    ]),
    ("Future and commitment", [
        "I want a long-term committed relationship.",
        "I want to get married someday.",
        "I want children or to raise a family.",
        "I prefer to establish commitment before making major shared decisions.",
        "Career opportunities may influence where I live.",
        "I want to share major financial goals with my partner.",
        "I value a relationship that continually evolves and grows.",
        "I want a partner whose long-term plans closely align with mine.",
    ]),
    ("Social and personality", [
        "I gain energy from spending time with other people.",
        "I prefer small gatherings to large social events.",
        "I enjoy meeting my partner’s friends and family.",
        "I want a partner who is comfortable socializing independently.",
        "I enjoy deep conversations more than casual small talk.",
        "I value humor and playfulness in a relationship.",
        "I am comfortable with a partner whose personality differs from mine.",
        "I want to share most important social experiences with my partner.",
    ]),
]

QUESTIONS = [
    {"id": category * 8 + index + 1, "category": name, "text": text}
    for category, (name, questions) in enumerate(CATEGORIES)
    for index, text in enumerate(questions)
]

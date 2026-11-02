"""Initial profile data for a useful first-run demo."""

from __future__ import annotations

from schemas import ContextItem


SEED_PROFILE: list[ContextItem] = [
    ContextItem(type="fact", category="identity", key="full_name", value="Vasu Yogeshwar"),
    ContextItem(
        type="fact",
        category="identity",
        key="professional_email",
        value="vasu.yogeshwar@proton.me",
    ),
    ContextItem(
        type="fact",
        category="identity",
        key="personal_email",
        value="vasuyogeshwar@gmail.com",
    ),
    ContextItem(type="fact", category="identity", key="phone", value="+91 98765 43210"),
    ContextItem(type="fact", category="identity", key="city", value="Bengaluru, India"),
    ContextItem(
        type="fact",
        category="identity",
        key="linkedin",
        value="https://www.linkedin.com/in/vasuyogeshwar",
    ),
    ContextItem(
        type="fact",
        category="education",
        key="university",
        value="Manipal Institute of Technology",
    ),
    # Deliberately incomplete: true as far as it goes, but omits the minor.
    # The live demo corrects this, which is why it isn't stated in full here.
    ContextItem(
        type="fact",
        category="education",
        key="degree",
        value="B.Tech in Mechanical Engineering",
    ),
    ContextItem(type="fact", category="education", key="graduation_year", value="2025"),
    # Work history is NOT seeded. It comes from the uploaded resume via OCR,
    # which is both the honest source and the better demo: the vault fills
    # itself from a real document rather than from facts we typed in.
    ContextItem(
        type="fact",
        category="experience",
        key="current_startup",
        value="Currently building Swara, a voice-native personal context layer.",
    ),
    ContextItem(
        type="preference",
        category="preferences",
        key="writing_style",
        value="professional, natural, concise",
    ),
    ContextItem(
        type="preference",
        category="preferences",
        key="application_tone",
        value="Confident and specific, without exaggeration or buzzwords.",
    ),
    ContextItem(
        type="preference",
        category="preferences",
        key="job_preferences",
        value="Roles involving applied AI, developer tools, or automation.",
    ),
]


def _apply_local_overrides(profile: list[ContextItem]) -> list[ContextItem]:
    """Replace placeholder entries with real details from `seed_local.py`.

    That file is gitignored, so the committed seed carries only placeholders
    while the running demo uses genuine contact details.
    """
    try:
        from seed_local import OVERRIDES
    except ImportError:
        return profile

    by_key = {item.key: item for item in OVERRIDES}
    merged = [by_key.pop(item.key, item) for item in profile]
    return [*merged, *by_key.values()]


SEED_PROFILE = _apply_local_overrides(SEED_PROFILE)

from tinytalk.object_recognition import ObjectTracker


def test_record_seen_then_consume_returns_weave_in_guidance():
    tracker = ObjectTracker()
    tracker.record_seen("teddy bear")

    guidance = tracker.consume_guidance()

    assert "teddy bear" in guidance
    assert "inspire" in guidance.lower()


def test_consume_guidance_returns_empty_string_when_nothing_pending():
    tracker = ObjectTracker()

    assert tracker.consume_guidance() == ""


def test_consume_guidance_clears_the_pending_label():
    tracker = ObjectTracker()
    tracker.record_seen("teddy bear")

    tracker.consume_guidance()

    assert tracker.consume_guidance() == ""


def test_second_record_seen_before_consumption_overwrites_the_first():
    tracker = ObjectTracker()
    tracker.record_seen("elephant")
    tracker.record_seen("backpack")

    guidance = tracker.consume_guidance()

    assert "backpack" in guidance
    assert "elephant" not in guidance


def test_unsafe_label_is_discarded_and_produces_no_guidance():
    tracker = ObjectTracker()
    tracker.record_seen("a bloody knife")

    assert tracker.consume_guidance() == ""


def test_weave_in_guidance_requires_a_recognizable_trait_to_carry_through():
    # Regression guard for real on-device behavior: a recognized "golden
    # retriever" once produced a story reply that introduced an unrelated
    # "elephant" -- technically satisfying the child's own "another animal
    # comes" request, but keeping nothing (species, size, color,
    # personality) of the actual recognized object. The guidance now says
    # so explicitly rather than leaving it fully to the model's judgment.
    tracker = ObjectTracker()
    tracker.record_seen("golden retriever")

    guidance = tracker.consume_guidance()

    assert "recognizable" in guidance.lower()


def test_weave_in_guidance_discourages_an_unrelated_substitute():
    tracker = ObjectTracker()
    tracker.record_seen("golden retriever")

    guidance = tracker.consume_guidance()

    assert "unrelated" in guidance.lower()


def test_unsafe_label_does_not_clear_an_already_pending_safe_label():
    # record_seen's job on an unsafe candidate is to discard THAT
    # candidate, not to wipe out whatever safe label was already pending
    # from an earlier photo -- see object_recognition.py's own doc
    # comment on record_seen for the reasoning.
    tracker = ObjectTracker()
    tracker.record_seen("teddy bear")
    tracker.record_seen("a bloody knife")

    guidance = tracker.consume_guidance()

    assert "teddy bear" in guidance

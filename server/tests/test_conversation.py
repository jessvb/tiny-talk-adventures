from storyadventure.conversation import Conversation, Turn

SYSTEM = "You tell stories to children."


def test_starts_empty():
    assert Conversation().turns == ()


def test_records_child_and_agent_turns_in_order():
    conversation = Conversation()
    conversation.add_child("tell me about a fox")
    conversation.add_agent("Once upon a time there was a fox.")
    assert conversation.turns == (
        Turn(speaker="child", text="tell me about a fox", interrupted=False),
        Turn(
            speaker="agent",
            text="Once upon a time there was a fox.",
            interrupted=False,
        ),
    )


def test_to_messages_starts_with_system_prompt():
    conversation = Conversation()
    conversation.add_child("hello")
    messages = conversation.to_messages(SYSTEM)
    assert messages[0] == {"role": "system", "content": SYSTEM}
    assert messages[1] == {"role": "user", "content": "hello"}


def test_agent_turns_map_to_assistant_role():
    conversation = Conversation()
    conversation.add_agent("Once upon a time.")
    assert conversation.to_messages(SYSTEM)[1] == {
        "role": "assistant",
        "content": "Once upon a time.",
    }


def test_interrupted_agent_turn_is_marked_for_the_llm():
    conversation = Conversation()
    conversation.add_agent("The fox crept through the forest and", interrupted=True)
    conversation.add_child("wait, make it a dragon!")
    messages = conversation.to_messages(SYSTEM)
    assert messages[1] == {
        "role": "assistant",
        "content": "The fox crept through the forest and [interrupted by the child]",
    }
    assert messages[2] == {"role": "user", "content": "wait, make it a dragon!"}


def test_empty_interrupted_agent_turn_is_not_recorded():
    conversation = Conversation()
    conversation.add_agent("   ", interrupted=True)
    assert conversation.turns == ()


def test_history_is_capped_at_max_turns():
    conversation = Conversation(max_turns=4)
    for index in range(10):
        conversation.add_child(f"line {index}")
    assert len(conversation.turns) == 4
    assert conversation.turns[0].text == "line 6"
    assert conversation.turns[-1].text == "line 9"

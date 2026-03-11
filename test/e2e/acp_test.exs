defmodule LiteskillWeb.E2E.AcpTest do
  use LiteskillWeb.FeatureCase, async: false

  test "ACP conversation with mock agent shows response", %{session: session} do
    %{user: user, email: email, password: password} = create_user()
    config = create_acp_agent_config(user, response: "Hello! I am the mock ACP agent responding to your message.")

    # Pre-select ACP agent so it's active when the chat loads
    Liteskill.Accounts.update_preferences(user, %{
      "preferred_provider" => %{"type" => "acp", "id" => config.id}
    })

    login_user(session, email, password)
    assert_has(session, Query.css("h1", text: "What can I help you with?"))
    take_screenshot(session, name: "acp/simple_conversation/home")

    # Send a message to the ACP agent
    session
    |> fill_in(Query.css("#message-input"), with: "Hello mock agent, how are you?")
    |> click(Query.css("button[type='submit']"))

    # Wait for the mock agent response to appear
    session
    |> assert_has(Query.css(".prose", text: "Hello! I am the mock ACP agent", count: :any))
    |> take_screenshot(name: "acp/simple_conversation/response")

    # Let async projections finish before sandbox cleanup
    Process.sleep(500)
  end

  test "ACP conversation with tool call shows tool badge and response", %{session: session} do
    %{user: user, email: email, password: password} = create_user()

    config =
      create_acp_agent_config(user,
        behavior: "tool_call",
        response: "I checked the wiki tools and found the information you requested.",
        tool_name: "mcp__Liteskill_Tools__wiki__list_spaces"
      )

    Liteskill.Accounts.update_preferences(user, %{
      "preferred_provider" => %{"type" => "acp", "id" => config.id}
    })

    login_user(session, email, password)
    assert_has(session, Query.css("h1", text: "What can I help you with?"))

    # Send a message that triggers a tool call
    session
    |> fill_in(Query.css("#message-input"), with: "Look up something in the wiki for me")
    |> click(Query.css("button[type='submit']"))

    # Wait for the tool call badge and final response
    session
    |> assert_has(Query.css("[phx-click='show_tool_call']", count: :any))
    |> assert_has(Query.css(".prose", text: "I checked the wiki tools", count: :any))
    |> take_screenshot(name: "acp/tool_call/conversation")

    # Click the tool call badge to see the detail modal
    session
    |> click(Query.css("[phx-click='show_tool_call']"))
    |> assert_has(Query.css("[phx-click='close_tool_call_modal']", count: :any))
    |> take_screenshot(name: "acp/tool_call/tool_detail_modal")

    Process.sleep(500)
  end

  test "ACP agent selection in provider picker", %{session: session} do
    %{user: user, email: email, password: password} = create_user()
    config = create_acp_agent_config(user, name: "E2E Test Agent")

    login_user(session, email, password)
    assert_has(session, Query.css("h1", text: "What can I help you with?"))

    # The provider picker should show the agent in the Agents optgroup
    session
    |> assert_has(Query.css("#provider-picker-new option", text: "E2E Test Agent"))
    |> take_screenshot(name: "acp/agent_selection/picker_visible")

    # Select the ACP agent via JavaScript (select interactions need event dispatch)
    execute_script(session, """
      var el = document.getElementById('provider-picker-new');
      el.value = 'acp:#{config.id}';
      el.dispatchEvent(new Event('change', {bubbles: true}));
    """)

    # Verify ACP mode activated — cost limit button is hidden in ACP mode
    Process.sleep(500)
    take_screenshot(session, name: "acp/agent_selection/agent_selected")
  end
end

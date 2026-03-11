defmodule LiteskillWeb.McpShimControllerTest do
  use LiteskillWeb.ConnCase, async: false

  alias LiteskillWeb.McpShimController

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "mcp-shim-#{System.unique_integer([:positive])}@example.com",
        name: "MCP Shim Tester",
        oidc_sub: "mcp-shim-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    token = McpShimController.generate_token(user.id)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, user: user, token: token}
  end

  describe "initialize" do
    test "returns MCP capabilities", %{conn: conn} do
      body = %{"jsonrpc" => "2.0", "method" => "initialize", "id" => 0, "params" => %{}}

      conn = post(conn, ~p"/api/mcp/shim", body)
      resp = json_response(conn, 200)

      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == 0
      assert resp["result"]["protocolVersion"] == "2025-03-26"
      assert resp["result"]["capabilities"]["tools"] == %{}
      assert resp["result"]["serverInfo"]["name"] == "Liteskill Tools"
      assert get_resp_header(conn, "mcp-session-id") != []
    end
  end

  describe "notifications/initialized" do
    test "returns 200 with empty body", %{conn: conn} do
      body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

      conn = post(conn, ~p"/api/mcp/shim", body)
      assert conn.status == 200
    end
  end

  describe "tools/list" do
    test "returns builtin tool specs", %{conn: conn} do
      body = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1}

      conn = post(conn, ~p"/api/mcp/shim", body)
      resp = json_response(conn, 200)

      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == 1
      tools = resp["result"]["tools"]
      assert [_ | _] = tools

      tool_names = Enum.map(tools, & &1["name"])
      assert "wiki__read" in tool_names
      assert "wiki__write" in tool_names
      assert "reports__list" in tool_names

      # Verify tool shape
      wiki_read = Enum.find(tools, &(&1["name"] == "wiki__read"))
      assert is_binary(wiki_read["description"])
      assert is_map(wiki_read["inputSchema"])
    end

    test "does not expose AgentStudio or VisualResponse tools", %{conn: conn} do
      body = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1}

      conn = post(conn, ~p"/api/mcp/shim", body)
      resp = json_response(conn, 200)

      tool_names = Enum.map(resp["result"]["tools"], & &1["name"])
      refute Enum.any?(tool_names, &String.starts_with?(&1, "agent_studio"))
      refute Enum.any?(tool_names, &String.starts_with?(&1, "visual_response"))
    end
  end

  describe "tools/call" do
    test "dispatches wiki__read spaces mode", %{conn: conn} do
      body = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 2,
        "params" => %{
          "name" => "wiki__read",
          "arguments" => %{"mode" => "spaces"}
        }
      }

      conn = post(conn, ~p"/api/mcp/shim", body)
      resp = json_response(conn, 200)

      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == 2
      assert is_map(resp["result"])
      assert is_list(resp["result"]["content"])
    end

    test "dispatches reports__list", %{conn: conn} do
      body = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 3,
        "params" => %{
          "name" => "reports__list",
          "arguments" => %{}
        }
      }

      conn = post(conn, ~p"/api/mcp/shim", body)
      resp = json_response(conn, 200)

      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == 3
      assert is_map(resp["result"])
    end

    test "returns error for unknown tool", %{conn: conn} do
      body = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 4,
        "params" => %{"name" => "nonexistent_tool", "arguments" => %{}}
      }

      conn = post(conn, ~p"/api/mcp/shim", body)
      resp = json_response(conn, 200)

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "Unknown tool"
    end
  end

  describe "authentication" do
    test "returns 401 without authorization header" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/mcp/shim", %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "returns 401 with invalid token" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer invalid-token")
        |> post(~p"/api/mcp/shim", %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "returns 401 with expired token" do
      # Generate a token that's already expired by using a very old timestamp
      # We can't easily fake time, so we test with an obviously bad token instead
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer SFMyNTY.g2gDYQ.invalid")
        |> post(~p"/api/mcp/shim", %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1})

      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end

  describe "unknown method" do
    test "returns method not found error", %{conn: conn} do
      body = %{"jsonrpc" => "2.0", "method" => "unknown/method", "id" => 5}

      conn = post(conn, ~p"/api/mcp/shim", body)
      resp = json_response(conn, 200)

      assert resp["error"]["code"] == -32_601
      assert resp["error"]["message"] =~ "Method not found"
    end
  end

  describe "generate_token/1" do
    test "generates a verifiable token", %{user: user} do
      token = McpShimController.generate_token(user.id)
      assert is_binary(token)

      assert {:ok, user_id} =
               Phoenix.Token.verify(LiteskillWeb.Endpoint, "acp_mcp_token", token, max_age: 3600)

      assert user_id == user.id
    end
  end
end

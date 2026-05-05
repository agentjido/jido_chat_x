defmodule Jido.Chat.X.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.X.Adapter

  @moduletag :live

  test "verifies live X credentials through XDK" do
    if run_live?() and oauth1_ready?() do
      client = live_client()

      assert {:ok, %{"data" => %{"id" => id}}} = Xdk.Users.get_me(client)
      assert is_binary(id)
      assert id != ""
    else
      refute run_live?() and oauth1_ready?()
    end
  end

  test "sends a live X direct message through XDK" do
    recipient_id = System.get_env("X_TEST_RECIPIENT_ID")

    if run_live_send?() and oauth1_ready?() and recipient_id not in [nil, ""] do
      client = live_client()
      text = "jido x live #{System.system_time(:millisecond)}"

      assert {:ok, response} = Adapter.send_message(recipient_id, text, xdk_client: client)

      assert response.external_message_id
    else
      refute run_live_send?() and oauth1_ready?() and recipient_id not in [nil, ""]
    end
  end

  defp run_live?, do: System.get_env("RUN_LIVE_X_TESTS") in ["1", "true", "TRUE", "yes"]

  defp run_live_send?,
    do: run_live?() and System.get_env("RUN_LIVE_X_SEND_TESTS") in ["1", "true", "TRUE", "yes"]

  defp oauth1_ready? do
    Enum.all?(
      ~w(X_CONSUMER_KEY X_CONSUMER_SECRET X_ACCESS_TOKEN X_ACCESS_TOKEN_SECRET),
      &(System.get_env(&1) not in [nil, ""])
    )
  end

  defp live_client do
    finch_name = :"Jido.Chat.X.LiveIntegrationTest.Finch.#{System.unique_integer([:positive])}"
    {:ok, _pid} = Finch.start_link(name: finch_name)

    credentials =
      OAuther.credentials(
        consumer_key: System.fetch_env!("X_CONSUMER_KEY"),
        consumer_secret: System.fetch_env!("X_CONSUMER_SECRET"),
        token: System.fetch_env!("X_ACCESS_TOKEN"),
        token_secret: System.fetch_env!("X_ACCESS_TOKEN_SECRET")
      )

    Xdk.new(finch: finch_name, auth: {:oauth1, credentials})
  end
end

defmodule Jido.Chat.X.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.X.Adapter

  @moduletag :live

  test "sends a live X direct message through XDK" do
    recipient_id = System.get_env("X_TEST_RECIPIENT_ID")

    if run_live?() and recipient_id not in [nil, ""] do
      credentials =
        OAuther.credentials(
          consumer_key: System.fetch_env!("X_CONSUMER_KEY"),
          consumer_secret: System.fetch_env!("X_CONSUMER_SECRET"),
          token: System.fetch_env!("X_ACCESS_TOKEN"),
          token_secret: System.fetch_env!("X_ACCESS_TOKEN_SECRET")
        )

      client = Xdk.new(auth: {:oauth1, credentials})
      text = "jido x live #{System.system_time(:millisecond)}"

      assert {:ok, response} = Adapter.send_message(recipient_id, text, xdk_client: client)

      assert response.external_message_id
    else
      refute run_live?() and recipient_id not in [nil, ""]
    end
  end

  defp run_live?, do: System.get_env("RUN_LIVE_X_TESTS") in ["1", "true", "TRUE", "yes"]
end

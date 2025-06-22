defmodule WebRTCHandler do
  require Logger

  defstruct [:peer_connection, :room_id, :user_id, :parent_pid, :decoder_pid]

  def start(peer_connection, room_id, user_id, parent_pid) do
    {:ok, _pid} =
      Task.start(fn ->
        loop(%WebRTCHandler{
          peer_connection: peer_connection,
          room_id: room_id,
          user_id: user_id,
          parent_pid: parent_pid
        })
      end)
  end

  defp loop(
         %{
           peer_connection: pc,
           room_id: room_id,
           user_id: user_id,
           parent_pid: parent_pid,
           decoder_pid: decoder_pid
         } = state
       ) do
    receive do
      {:data, _data_channel, data} ->
        Logger.warning("Received data from #{room_id} #{user_id}")

        {new_state, decoder_pid} =
          if decoder_pid == nil do
            {:ok, decoder_pid} = WebRTCMessageDecoder.start_link(parent_pid, room_id, user_id)
            {Map.put(state, :decoder_pid, decoder_pid), decoder_pid}
          else
            {state, decoder_pid}
          end

        send(decoder_pid, {:receive_message, data})
        loop(new_state)

      {:data_channel, data_channel} ->
        send(parent_pid, {:opened_data_channel, room_id, user_id, Map.get(data_channel, :ref)})

        loop(state)

      {:ice_candidate, candidate} ->
        request_id = UUID.uuid4()

        message =
          JSON.encode!(%Messages.SendICE{
            requestId: request_id,
            roomId: room_id,
            targetUserId: user_id,
            iceCandidate: candidate |> ExWebRTC.ICECandidate.to_json() |> JSON.encode!()
          })

        send(parent_pid, {:send_message, message})

        loop(state)

      {:ice_connection_state_change, :completed} ->
        IO.inspect("CONNECTION ESTABLISHED")
        loop(state)

      unknown ->
        IO.inspect("unknown message received #{inspect(unknown)}")
        loop(state)
    end
  end
end

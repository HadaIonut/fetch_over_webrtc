import gleam/erlang/process
import gleam/json
import gleam/otp/actor
import mist

pub type Message {
  Broadcast(String)

  SendNotifications(String)
  SendSdpCert(source_user_id: String, source_room_id: String, sdp_cert: String)
  SendSdpCertReply(
    source_user_id: String,
    source_room_id: String,
    sdp_cert: String,
  )
  SendICECandidate(
    ice_candidate: String,
    source_user_id: String,
    source_room_id: String,
  )
}

pub type State {
  State(user_id: String, rooms: List(String), self: process.Subject(Message))
}

pub fn handle_custom_broadcast(message: Message, conn, state) {
  case message {
    Broadcast(text) -> {
      let assert Ok(_) = mist.send_text_frame(conn, text)
      actor.continue(state)
    }
    SendNotifications(text) -> {
      let _ = mist.send_text_frame(conn, text)
      actor.continue(state)
    }
    SendSdpCert(source_user_id, source_room_id, sdp_cert) -> {
      let _ =
        json.object([
          #("type", json.string("userOffer")),
          #("sourceUserId", json.string(source_user_id)),
          #("roomId", json.string(source_room_id)),
          #("sdpCert", json.string(sdp_cert)),
        ])
        |> json.to_string()
        |> mist.send_text_frame(conn, _)

      actor.continue(state)
    }
    SendSdpCertReply(source_user_id, source_room_id, sdp_cert) -> {
      let _ =
        json.object([
          #("type", json.string("userOfferReply")),
          #("sourceUserId", json.string(source_user_id)),
          #("roomId", json.string(source_room_id)),
          #("sdpCert", json.string(sdp_cert)),
        ])
        |> json.to_string()
        |> mist.send_text_frame(conn, _)

      actor.continue(state)
    }
    SendICECandidate(ice_candidate, source_user_id, source_room_id) -> {
      let _ =
        json.object([
          #("type", json.string("ICECandidate")),
          #("sourceUserId", json.string(source_user_id)),
          #("sourceRoomId", json.string(source_room_id)),
          #("ICECandidate", json.string(ice_candidate)),
        ])
        |> json.to_string()
        |> mist.send_text_frame(conn, _)

      actor.continue(state)
    }
  }
}

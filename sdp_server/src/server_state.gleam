import gleam/erlang/process

pub type Message {
  Broadcast(String)

  SendNotifications(String)
  SendSdpCert(source_user_id: String, source_room_id: String, sdp_cert: String)
  SendSdpCertReply(
    source_user_id: String,
    source_room_id: String,
    sdp_cert: String,
  )
}

pub type State {
  State(user_id: String, rooms: List(String), self: process.Subject(Message))
}

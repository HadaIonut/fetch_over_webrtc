import gleam/dynamic/decode
import gleam/string

pub type Messages {
  Join(request_id: String, room_id: String)
  Leave(request_id: String, room_id: String)
  Create(request_id: String)
  Offer(request_id: String, room_id: String, sdp_cert: String)
  OfferReply(
    request_id: String,
    room_id: String,
    to_user: String,
    sdp_cert: String,
  )

  Err
}

pub fn decoder() {
  use msg_type <- decode.field("type", decode.string)
  use req_id <- decode.field("requestId", decode.string)

  case string.lowercase(msg_type) {
    "join" -> {
      use room_id <- decode.field("roomId", decode.string)
      decode.success(Join(req_id, room_id))
    }
    "leave" -> {
      use room_id <- decode.field("roomId", decode.string)
      decode.success(Leave(req_id, room_id))
    }
    "create" -> decode.success(Create(req_id))
    "offer" -> {
      use sdp_cert <- decode.field("sdpCert", decode.string)
      use room_id <- decode.field("roomId", decode.string)

      decode.success(Offer(req_id, room_id, sdp_cert))
    }
    "offerReply" -> {
      use sdp_cert <- decode.field("sdpCert", decode.string)
      use room_id <- decode.field("roomId", decode.string)
      use to_user <- decode.field("toUser", decode.string)

      decode.success(OfferReply(req_id, room_id, to_user, sdp_cert))
    }
    _ -> decode.failure(Err, "unknown message type")
  }
}

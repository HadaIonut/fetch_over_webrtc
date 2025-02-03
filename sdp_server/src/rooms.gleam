import gleam/bool
import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gluid
import server_state

pub type RoomMessage {
  Join(
    room_id: String,
    user: User,
    reply_with: process.Subject(Result(Room, String)),
  )
  Create(
    owner_id: String,
    connection: process.Subject(server_state.Message),
    reply_with: process.Subject(Room),
  )
  Destroy(room_id: String)
  Leave(
    room_id: String,
    user_id: String,
    reply_with: process.Subject(Result(Room, String)),
  )
  DropUser(user_id: String, rooms: List(String))
  Offer(
    user_id: String,
    room_id: String,
    sdp_cert: String,
    reply_with: process.Subject(Result(Room, String)),
  )
  OfferReply(
    user_id: String,
    room_id: String,
    to_user_id: String,
    sdp_cert: String,
    reply_with: process.Subject(Result(Room, String)),
  )
  SendICE(
    source_user_id: String,
    user_id: String,
    room_id: String,
    ice_candidate: String,
    reply_with: process.Subject(Result(Room, String)),
  )
}

pub type User {
  User(id: String, connection: process.Subject(server_state.Message))
}

pub type Room {
  Room(owner_id: String, members: List(User), room_id: String)
}

pub type Rooms =
  dict.Dict(String, Room)

pub fn room_encoder(room: Room) {
  json.object([
    #("owner_id", json.string(room.owner_id)),
    #("room_id", json.string(room.room_id)),
    #("members", json.array(room.members, of: user_encoder)),
  ])
}

fn user_encoder(user: User) {
  json.object([#("id", json.string(user.id))])
}

pub fn notify_connections(users: List(User), filter_user_id, msg) {
  list.each(users, fn(usr) {
    use <- bool.guard(usr.id == filter_user_id, Nil)

    process.send(usr.connection, server_state.SendNotifications(msg))
  })
}

fn user_can_join_room(rooms: Rooms, user_id, room_id) {
  case dict.get(rooms, room_id) {
    Ok(cur_room) ->
      case list.find(cur_room.members, fn(member) { member.id == user_id }) {
        Error(_) -> Ok(Nil)
        Ok(_) -> Error("user is already in the room")
      }
    Error(_) -> Error("room doesnt exist")
  }
}

fn handle_room_create(rooms, owner_id, connection, subject) {
  let room = Room(owner_id, [User(owner_id, connection)], gluid.guidv4())

  process.send(subject, room)

  room
  |> dict.insert(rooms, room.room_id, _)
  |> actor.continue()
}

fn handle_room_join(rooms, user: User, room_id, subject) {
  case user_can_join_room(rooms, user.id, room_id) {
    Error(err) -> {
      process.send(subject, Error(err))
      rooms
    }
    Ok(_) -> {
      let rooms =
        dict.upsert(rooms, room_id, fn(cur) {
          let assert option.Some(cur) = cur

          Room(..cur, members: list.prepend(cur.members, user))
        })
      let assert Ok(room) = dict.get(rooms, room_id)

      json.object([
        #("type", json.string("userJoined")),
        #("room", room_encoder(room)),
      ])
      |> json.to_string()
      |> notify_connections(room.members, user.id, _)

      process.send(subject, Ok(room))
      rooms
    }
  }
  |> actor.continue()
}

fn room_leave(rooms: Rooms, room_id, user_id) {
  case dict.get(rooms, room_id) {
    Error(_) -> #(rooms, Error("room not found"))
    Ok(old_room) -> {
      let user_in_room =
        list.find(old_room.members, fn(mem) { mem.id == user_id })
        |> result.is_error()

      use <- bool.guard(user_in_room, #(rooms, Error("Not in the room")))

      let new_rooms =
        dict.upsert(rooms, room_id, fn(cur) {
          let assert option.Some(cur) = cur

          Room(
            ..cur,
            members: list.filter(cur.members, fn(room) { room.id != user_id }),
          )
        })

      let assert Ok(room) =
        new_rooms
        |> dict.get(room_id)

      room
      |> room_encoder()
      |> json.to_string()
      |> notify_connections(room.members, user_id, _)

      #(rooms, Ok(room))
    }
  }
}

fn handle_room_leave(rooms: Rooms, room_id, subject, user_id) {
  let res = room_leave(rooms, room_id, user_id)
  process.send(subject, res.1)

  res.0
  |> actor.continue()
}

fn handle_drop_user(rooms, user_rooms, user_id) {
  dict.map_values(rooms, fn(room_id, room: Room) {
    case list.contains(user_rooms, room_id) {
      True -> {
        case room_leave(rooms, room_id, user_id).1 {
          Ok(room) -> room
          Error(_) -> room
        }
      }
      False -> room
    }
  })
  |> actor.continue()
}

fn handle_offer(rooms: Rooms, room_id, user_id, sdp_cert) {
  case dict.get(rooms, room_id) {
    Ok(room) -> {
      list.each(room.members, fn(mem) {
        use <- bool.guard(mem.id == user_id, Nil)

        process.send(
          mem.connection,
          server_state.SendSdpCert(user_id, room_id, sdp_cert),
        )
      })
      Ok(room)
    }
    Error(_) -> Error("room not found")
  }
}

fn handle_offer_reply(rooms: Rooms, room_id, user_id, to_user_id, sdp_cert) {
  case dict.get(rooms, room_id) {
    Ok(room) ->
      case list.find(room.members, fn(mem) { mem.id == to_user_id }) {
        Ok(usr) -> {
          process.send(
            usr.connection,
            server_state.SendSdpCertReply(user_id, room_id, sdp_cert),
          )
          Ok(room)
        }
        Error(_) -> Error("user not found")
      }
    Error(_) -> Error("room not found")
  }
}

fn handle_message(
  message: RoomMessage,
  rooms: Rooms,
) -> actor.Next(RoomMessage, Rooms) {
  case message {
    Create(owner_id, connection, subject) ->
      handle_room_create(rooms, owner_id, connection, subject)
    Destroy(room_id) -> dict.drop(rooms, [room_id]) |> actor.continue()
    Join(room_id, user, subject) ->
      handle_room_join(rooms, user, room_id, subject)
    Leave(room_id, user_id, subject) ->
      handle_room_leave(rooms, room_id, subject, user_id)
    DropUser(user_id, user_rooms) ->
      handle_drop_user(rooms, user_rooms, user_id)
    Offer(user_id, room_id, sdp_cert, subject) -> {
      handle_offer(rooms, room_id, user_id, sdp_cert)
      |> process.send(subject, _)

      actor.continue(rooms)
    }
    OfferReply(user_id, room_id, to_user_id, sdp_cert, subject) -> {
      handle_offer_reply(rooms, room_id, user_id, to_user_id, sdp_cert)
      |> process.send(subject, _)

      actor.continue(rooms)
    }
    SendICE(source_user_id, user_id, room_id, ice_candidate, subject) -> {
      case dict.get(rooms, room_id) {
        Ok(room) -> {
          let user = list.find(room.members, fn(usr) { usr.id == user_id })

          case user {
            Ok(user) -> {
              process.send(
                user.connection,
                server_state.SendICECandidate(
                  ice_candidate,
                  source_user_id,
                  room_id,
                ),
              )
              Ok(room)
            }
            Error(_) -> Error("user not found")
          }
        }
        Error(_) -> Error("room not found")
      }
      |> process.send(subject, _)

      actor.continue(rooms)
    }
  }
}

pub fn start_rooms() {
  let assert Ok(rooms_state) = actor.start(dict.new(), handle_message)
  rooms_state
}

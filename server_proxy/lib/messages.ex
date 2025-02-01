defmodule Messages do
  defmodule CreateRoom do
    @derive JSON.Encoder
    defstruct [:requestId, type: "create"]
  end

  defmodule JoinRoom do
    @derive JSON.Encoder
    defstruct [:requestId, :roomId, type: "join"]
  end

  defmodule Offer do
    @derive JSON.Encoder
    defstruct [:requestId, :roomId, :sdpCert, type: "offer"]
  end

  defmodule OfferReply do
    @derive JSON.Encoder
    defstruct [:requestId, :roomId, :toUser, :sdpCert, type: "offerReply"]
  end
end

{-# LANGUAGE OverloadedStrings #-}

-- | Provides logic code for interacting with the Discord websocket
--   gateway. Realistically, this is probably lower level than most
--   people will need
module Discord.Internal.Gateway.EventLoop where

import Prelude hiding (log)

import Control.Monad (forever, void)
import Control.Monad.Random (getRandomR)
import Control.Concurrent.Async (race)
import Control.Concurrent.Chan
import Control.Concurrent (threadDelay, killThread, forkIO)
import Control.Exception.Safe (try, finally, SomeException)
import Data.IORef
import Data.Aeson (eitherDecode, encode)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL

import Wuss (runSecureClient)
import Network.WebSockets (ConnectionException(..), Connection,
                           receiveData, sendTextData, sendClose)

import Discord.Internal.Types
import Discord.Internal.Rest.Prelude (apiVersion)


-- | Info the event processing loop needs to
data GatewayHandle = GatewayHandle
  { -- | Realtime events from discord
    gatewayHandleEvents         :: Chan (Either GatewayException EventInternalParse),
    -- | Events the user sends to discord
    gatewayHandleUserSendables  :: Chan GatewaySendable,
    -- | Recent set status (resent to discord on reconnect)
    gatewayHandleLastStatus     :: IORef (Maybe UpdateStatusOpts),
    -- | Recent sent event sequence (used to reconnect)
    gatewayHandleLastSequenceId :: IORef Integer,
    -- | Which discord server session (used to reconnect)
    gatewayHandleSessionId      :: IORef T.Text
  }

-- | Ways the gateway connection can fail with no possibility of recovery.
data GatewayException = GatewayExceptionIntent T.Text
  deriving (Show)

 
-- | State of the eventloop
data LoopState = LoopStart
               | LoopClosed
               | LoopReconnect
  deriving Show

-- | Info the sendableLoop reads when it writes to the websocket
data SendablesData = SendablesData
  { sendableConnection :: Connection
  , librarySendables :: Chan GatewaySendableInternal
  , startsendingUsers :: IORef Bool
  , heartbeatInterval :: Integer
  }


-- | Gateway connection infinite loop. Get events from websocket and send them to the library user
--
-- @
--  Auth                                                         needed to connect
--  GatewayIntent                                                needed to connect
--  GatewayHandle (eventsGives,status,usersends,seq,sesh)        needed all over
--  log :: Chan (T.Text)                                         needed all over
--
--  sendableConnection                                 set by setup,  need sendableLoop
--  librarySendables :: Chan (GatewaySendableInternal) set by setup,  need heartbeat
--  heartbeatInterval :: Int                           set by Hello,  need heartbeat
--
--  sequenceId :: Int id of last event received        set by Resume, need heartbeat and reconnect
--  sessionId :: Text                                  set by Ready,  need reconnect
-- @
connectionLoop :: Auth -> GatewayIntent -> GatewayHandle -> Chan T.Text -> IO ()
connectionLoop auth intent gatewayHandle log = outerloop LoopStart
    where

    -- | Main connection loop. Catch exceptions and reconnect.
    outerloop :: LoopState -> IO ()
    outerloop state = do
        mfirst <- firstmessage state -- construct first message
        case mfirst of
          Nothing -> pure () -- close

          Just message -> do
              nextstate <- try (startOneConnection message)  -- connection
              case nextstate :: Either SomeException LoopState of
                Left _ -> do t <- getRandomR (3,20)
                             threadDelay (t * (10^(6 :: Int)))
                             writeChan log ("gateway - trying to reconnect after failure(s)")
                             outerloop LoopReconnect
                Right n -> outerloop n

    -- | Construct the initial websocket message to send based on which state of the loop.
    --   Fresh start is Identify and a reconnect is Resume
    firstmessage :: LoopState -> IO (Maybe GatewaySendableInternal)
    firstmessage state =
      case state of
        LoopStart -> pure $ Just $ Identify auth intent (0, 1)
        LoopReconnect -> do seqId  <- readIORef (gatewayHandleLastSequenceId gatewayHandle)
                            seshId <- readIORef (gatewayHandleSessionId gatewayHandle)
                            if seshId == ""
                            then do writeChan log ("gateway - WARNING seshID was not set by READY?")
                                    pure $ Just $ Identify auth intent (0, 1)
                            else pure $ Just $ Resume auth seshId seqId
        LoopClosed -> pure Nothing

    startOneConnection :: GatewaySendableInternal -> IO LoopState
    startOneConnection message = runSecureClient "gateway.discord.gg" 443 ("/?v=" <> T.unpack apiVersion <>"&encoding=json") $ \conn -> do
                        msg <- getPayload conn log
                        case msg of
                            Right (Hello interval) -> do
                                -- setup sendables data
                                internal <- newChan :: IO (Chan GatewaySendableInternal)
                                sendingUser <- newIORef False
                                let sending = SendablesData { sendableConnection = conn
                                                            , librarySendables = internal
                                                            , startsendingUsers = sendingUser
                                                            , heartbeatInterval = interval
                                                            }
                                -- start websocket sending loop
                                sendsId <- forkIO $ sendableLoop conn gatewayHandle sending log
                                heart <- forkIO $ heartbeat sending (gatewayHandleLastSequenceId gatewayHandle)
                                writeChan internal message

                                -- run connection eventloop
                                finally (runEventLoop gatewayHandle sending log)
                                        (killThread heart >> killThread sendsId)

                            _ -> do
                                writeChan log "gateway - WARNING could not connect. Expected hello"
                                sendClose conn ("expected hello" :: BL.ByteString)
                                void $ forever $ void (receiveData conn :: IO BL.ByteString)
                                -- > after sendClose you should call receiveDataMessage until
                                -- > it throws an exception
                                -- haskell websockets documentation
                                threadDelay (3 * (10^(6 :: Int)))
                                pure LoopStart


-- | Process events from discord and write them to the onDiscordEvent Channel
runEventLoop :: GatewayHandle -> SendablesData -> Chan T.Text -> IO LoopState
runEventLoop thehandle sendablesData log = do loop
  where
  eventChan :: Chan (Either GatewayException EventInternalParse)
  eventChan = gatewayHandleEvents thehandle

  -- | Keep receiving Dispatch events until a reconnect or a restart
  loop = do
    eitherPayload <- getPayloadTimeout sendablesData log
    case eitherPayload :: Either ConnectionException GatewayReceivable of

      Right (Dispatch event sq) -> do -- GOT AN EVENT:
                                      writeIORef (gatewayHandleLastSequenceId thehandle) sq
                                      writeChan eventChan (Right event) -- send the event to user
                                      case event of
                                        (InternalReady _ _ _ _ seshID _ _) ->
                                            writeIORef (gatewayHandleSessionId thehandle) seshID
                                        _ -> writeIORef (startsendingUsers sendablesData) True
                                      loop
      Right (Hello _interval) -> do writeChan log ("eventloop - unexpected hello")
                                    loop
      Right (HeartbeatRequest sq) -> do writeIORef (gatewayHandleLastSequenceId thehandle) sq
                                        writeChan (librarySendables sendablesData) (Heartbeat sq)
                                        loop
      Right (InvalidSession retry) -> pure $ if retry then LoopReconnect else LoopStart
      Right (Reconnect)      -> pure LoopReconnect
      Right (HeartbeatAck)   -> loop
      Right (ParseError _e)  -> loop  -- getPayload logs the parse error. nothing to do here

      Left (CloseRequest code str) -> case code of
          -- see Discord and MDN documentation on gateway close event codes
          -- https://discord.com/developers/docs/topics/opcodes-and-status-codes#gateway-gateway-close-event-codes
          -- https://developer.mozilla.org/en-US/docs/Web/API/CloseEvent#properties
          1000 -> pure LoopReconnect
          1001 -> pure LoopReconnect
          4000 -> pure LoopReconnect
          4006 -> pure LoopStart
          4007 -> pure LoopStart
          4014 -> do writeChan eventChan (Left (GatewayExceptionIntent $
                           "Tried to declare an unauthorized GatewayIntent. " <>
                           "Use the discord app manager to authorize by following: " <>
                           "https://github.com/discord-haskell/discord-haskell/blob/master/docs/intents.md"))
                     pure LoopClosed
          _ -> do writeChan log ("gateway - unknown websocket close code " <> T.pack (show code)
                                  <> " [" <> TE.decodeUtf8 (BL.toStrict str) <> "]. Consider opening an issue "
                                  <> "https://github.com/discord-haskell/discord-haskell/issues")
                  pure LoopStart
      Left _ -> pure LoopReconnect


-- | Blocking wait for next payload from the websocket (returns "Reconnect" after 1.5*heartbeatInterval seconds)
getPayloadTimeout :: SendablesData -> Chan T.Text -> IO (Either ConnectionException GatewayReceivable)
getPayloadTimeout sendablesData log = do
  let interval = heartbeatInterval sendablesData
  res <- race (threadDelay (fromInteger ((interval * 1000 * 3) `div` 2)))
              (getPayload (sendableConnection sendablesData) log)
  case res of
    Left () -> pure (Right Reconnect)
    Right other -> pure other

-- | Blocking wait for next payload from the websocket
getPayload :: Connection -> Chan T.Text -> IO (Either ConnectionException GatewayReceivable)
getPayload conn log = try $ do
  msg' <- receiveData conn
  case eitherDecode msg' of
    Right msg -> pure msg
    Left  err -> do writeChan log ("gateway - received exception [" <> T.pack err <> "]"
                                      <> " while decoding " <> TE.decodeUtf8 (BL.toStrict msg'))
                    pure (ParseError (T.pack err))

-- | Infinite loop to send heartbeats to the chan
heartbeat :: SendablesData -> IORef Integer -> IO ()
heartbeat sendablesData seqKey = do
  threadDelay (3 * 10^(6 :: Int))
  forever $ do
    num <- readIORef seqKey
    writeChan (librarySendables sendablesData) (Heartbeat num)
    threadDelay (fromInteger (heartbeatInterval sendablesData * 1000))


-- | Infinite loop to send library/user events to discord with the actual websocket connection
sendableLoop :: Connection -> GatewayHandle -> SendablesData -> Chan T.Text -> IO ()
sendableLoop conn ghandle sendablesData _log = sendLoop
  where
  sendLoop = do
   -- send a ~120 events a min by delaying
      threadDelay $ round ((10^(6 :: Int)) * (62 / 120) :: Double)
   -- payload :: Either GatewaySendableInternal GatewaySendable
      payload <- race nextLibrary nextUser
   -- writeChan _log ("gateway - sending " <> TE.decodeUtf8 (BL.toStrict (either encode encode payload)))
      sendTextData conn (either encode encode payload)
      sendLoop

  -- | next event sent by library
  nextLibrary :: IO GatewaySendableInternal
  nextLibrary = readChan (librarySendables sendablesData)

  -- | next event sent by user (once startsendingUsers is set)
  nextUser :: IO GatewaySendable
  nextUser = do usersending <- readIORef (startsendingUsers sendablesData)
                if usersending
                then readChan (gatewayHandleUserSendables ghandle)
                else threadDelay (4 * (10^(6::Int))) >> nextUser



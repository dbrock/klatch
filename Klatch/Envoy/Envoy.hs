{-# LANGUAGE DeriveGeneric, OverloadedStrings #-}

module Main where

import Control.Applicative          ((<$>), (<*>))
import Control.Concurrent.STM       (atomically)
import Control.Concurrent.STM.TChan (newTChanIO, TChan)
import Control.Concurrent.STM.TVar  (newTVarIO, readTVar)
import Control.Monad.IO.Class       (MonadIO, liftIO)
import Pipes                        (Consumer, cat, for, (>->))

import qualified Data.Map  as Map
import qualified Data.Text as T

import Klatch.Common.AMQP   (Role (EnvoyRole), startAmqp)
import Klatch.Envoy.Queue  (writeTo, readFrom, writeEvent, writeError)
import Klatch.Envoy.Socket (handleConnect, handleSend)
import Klatch.Common.Types
import Klatch.Common.Util         (runEffectsConcurrently, contents, newline,
                            loggingWrites, loggingReads, encoder, decoder,
                            onCtrlC, writeLog, bolded)

main :: IO ()
main = do
  newline
  writeLog "Your illustrious fleet of envoys is setting up."

  (amqp, _) <- startAmqp EnvoyRole
  state@(_, channel) <- initialize

  writeEvent channel () Started

  onCtrlC $ do
    writeEvent channel () Stopping
    writeLog $ concat [ bolded "Stopping.\n\n"
                      , "  Please await a proper disconnect.\n"
                      , "  To quit immediately, hit Ctrl-C again." ]

  runEffectsConcurrently
    (contents channel >-> loggingWrites >-> encoder      >-> writeTo amqp)
    (readFrom amqp    >-> decoder       >-> loggingReads >-> handler state)

type State = (Fleet, TChan RawEvent)

initialize :: IO State
initialize = (,) <$> (newTVarIO Map.empty) <*> newTChanIO

handler :: State -> Consumer (Maybe Command) IO ()
handler s = for cat (liftIO . handle s)

handle :: State -> Maybe Command -> IO ()
handle (_, c) Nothing    = writeError "" c () "Parse error"
handle (f, c) (Just cmd) =
  case cmd of
    Connect name host port -> handleConnect f c name host port
    Send name line         -> handleSend f c name line
    Ping                   -> handlePing f c
    SaveClientEvent tag e  -> handleClientEvent c tag e
    Unknown (Just s)       -> writeError "" c () (T.append "Unknown command " s)
    Unknown Nothing        -> writeError "" c () "Unreadable command"

handlePing :: Fleet -> TChan RawEvent -> IO ()
handlePing f c = do
  n <- Map.size <$> atomically (readTVar f)
  writeEvent c () (Pong n)

handleClientEvent :: TChan RawEvent -> T.Text -> T.Text -> IO ()
handleClientEvent c tag stuff =
  writeEvent c () (ClientEvent tag stuff)

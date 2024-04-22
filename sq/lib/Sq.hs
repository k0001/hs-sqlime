{-# LANGUAGE StrictData #-}
{-# LANGUAGE NoFieldSelectors #-}

module Sq
   ( -- * Statement
    Statement
   , readStatement
   , writeStatement
   , bindStatement

    -- ** SQL
   , SQL
   , sql

    -- ** Input
   , Input
   , encode
   , input

    -- *** Encode
   , Encode (..)
   , encodeRefine
   , EncodeDefault (..)
   , encodeMaybe
   , encodeEither
   , encodeSizedIntegral
   , encodeBinary
   , encodeShow

    -- ** Output
   , Output
   , decode
   , output

    -- *** Decode
   , Decode (..)
   , decodeRefine
   , DecodeDefault (..)
   , decodeMaybe
   , decodeEither
   , decodeSizedIntegral
   , decodeBinary
   , decodeRead

    -- ** Name
   , Name
   , name

    -- * Transactional
   , Transactional
   , transactional
   , one
   , maybe
   , zero
   , some
   , list
   , fold
   , foldM
   , stream
   , Ref

    -- * Transaction
   , Transaction
   , read
   , commit
   , rollback

    -- * Pool
   , Pool
   , poolRead
   , poolWrite
   , poolTemp

    -- * Settings
   , Settings (..)
   , settings

    -- * Resources
    -- $resources
   , new
   , with
   , uith

    -- * Errors
   , ErrEncode (..)
   , ErrInput (..)
   , ErrDecode (..)
   , ErrOutput (..)
   , ErrStatement (..)
   , ErrRows (..)

    -- * Miscellaneuos
   , foldIO
   , streamIO
   , BindingName
   , Mode (..)
   , SubMode
   , Null (..)
   , S.SQLData (..)
   , S.SQLVFS (..)
   )
where

import Control.Exception.Safe qualified as Ex
import Control.Foldl qualified as F
import Control.Monad hiding (foldM)
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource qualified as R
import Control.Monad.Trans.Resource.Extra qualified as R
import Data.Acquire qualified as A
import Data.Function
import Data.Int
import Data.List.NonEmpty (NonEmpty)
import Database.SQLite3 qualified as S
import Di.Df1 qualified as Di
import System.FilePath
import Prelude hiding (Read, maybe, read)

import Sq.Connection
import Sq.Decoders
import Sq.Encoders
import Sq.Input
import Sq.Mode
import Sq.Names
import Sq.Null
import Sq.Output
import Sq.Pool
import Sq.Statement
import Sq.Support
import Sq.Transactional

--------------------------------------------------------------------------------

-- $resources
--
-- "Sq" relies heavily on 'A.Acquire' for safe resource management in light of
-- concurrency and dependencies between resources. Mostly, you don't have to
-- worry about it. Just do this:
--
-- 1. Import this library in a @qualified@ manner. It was designed to be used
--    that way.
--
-- @
-- import qualified "Sq"
-- @
--
-- 2. Initially, you will need access to a connection 'Pool'. You can
--    'A.Acquire' one through 'poolTemp', 'poolRead' or most commonly
--    __'poolWrite'__.
--
-- 3. In order to integrate your 'Pool' acquisition choice into your
--    application's resource management, you will most likely need to use one
--    of these functions:
--
--        * 'with' for integrating with 'Ex.MonadMask' from
--          the @exceptions@ library.
--
--        * 'new' for integrating with 'R.MonadResource' from
--          the @resourcet@ library.
--
--        * 'uith' for integrating with 'R.MonadUnliftIO' from
--          the @unliftio@ library.
--
--    If you have no idea what I'm talking about, just use 'with'.
--    Here is an example:
--
-- @
-- 'with' ('poolWrite' ('settings' \"\/my\/db.sqlite\")) \\(__pool__ :: 'Pool' \''Write') ->
--        /-- Here use __pool__ as necessary./
--        /-- The resources associated with it will be/
--        /-- automatically released after leaving this scope./
-- @
--
-- 4. Now that you have a 'Pool', try to solve your problems within
--    'Transactional'. For example:
--
-- @
--    "Sq".'transactional' @pool.write@ do
--        /-- Everything here happens in the same transaction./
--        markId <- "Sq".'one' getUserByEmail \"mark@example.com\"
--        'forM' friendIds \\friendId ->
--           "Sq".'one' makeFriends (markId, friendId)
--
-- @
--
-- 5. If you need to perform 'IO' actions while streaming result rows out
--    of the database, 'Transactional' won't be enough. You will need to
--    use 'foldIO' or 'streamIO'.
--
-- 6. If you have questions, just ask
--    at <https://github.com/k0001/hs-sq/issues>.

-- | 'A.Acquire' through 'R.MonadResource'.
--
-- @
-- 'new' = 'fmap' 'snd' . "Data.Acquire".'A.allocateAcquire'
-- @
new :: (R.MonadResource m) => A.Acquire a -> m a
new = fmap snd . A.allocateAcquire

-- | 'A.Acquire' through 'Ex.MonadMask'.
--
-- @
-- 'with' = "Control.Monad.Trans.Resource.Extra".'R.withAcquire'.
-- @
with :: (Ex.MonadMask m, MonadIO m) => A.Acquire a -> (a -> m b) -> m b
with = R.withAcquire

-- | 'A.Acquire' through 'R.MonadUnliftIO'.
--
-- @
-- 'uith' = "Data.Acquire".'A.with'
-- @
uith :: (R.MonadUnliftIO m) => A.Acquire a -> (a -> m b) -> m b
uith = A.with

--------------------------------------------------------------------------------

-- | Acquire a read-'Write' 'Pool' temporarily persisted in the file-system.
-- It will be deleted once released. This can be useful for testing.
--
-- Use "Di".'Di.new' to obtain the 'Di.Df1' parameter. Consider using
-- "Di.Core".'Di.Core.filter' to filter-out excessive logging.
poolTemp :: Di.Df1 -> A.Acquire (Pool Write)
poolTemp di0 = do
   d <- acquireTmpDir
   let di1 = Di.attr "mode" Write $ Di.push "pool" di0
   pool SWrite di1 $ settings (d </> "db.sqlite")

-- | Acquire a read-'Write' 'Pool' according to the given 'Settings'.
--
-- Use "Di".'Di.new' to obtain the 'Di.Df1' parameter. Consider using
-- "Di.Core".'Di.Core.filter' to filter-out excessive logging.
poolWrite :: Di.Df1 -> Settings -> A.Acquire (Pool Write)
poolWrite di0 s = do
   let di1 = Di.attr "mode" Write $ Di.push "pool" di0
   pool SWrite di1 s
{-# INLINE poolWrite #-}

-- | Acquire a 'Read'-only 'Pool' according to the given 'Settings'.
--
-- Use "Di".'Di.new' to obtain the 'Di.Df1' parameter. Consider using
-- "Di.Core".'Di.Core.filter' to filter-out excessive logging.
poolRead :: Di.Df1 -> Settings -> A.Acquire (Pool Read)
poolRead di0 s = do
   let di1 = Di.attr "mode" Read $ Di.push "pool" di0
   pool SRead di1 s
{-# INLINE poolRead #-}

--------------------------------------------------------------------------------

-- | Construct a 'Read'-only 'Statement'.
--
-- __WARNING__: This library doesn't __yet__ provide a safe way to construct
-- 'Statement's. Be responsible.
--
-- * The 'SQL' must be read-only.
--
-- * The 'SQL' must contain a single statement.
--
-- * The 'SQL' must not contain any transaction nor savepoint management
-- statements.
readStatement :: Input i -> Output o -> SQL -> Statement Read i o
readStatement = statement
{-# INLINE readStatement #-}

-- | Construct a 'Statement' that can only be executed as part of a 'Write'
-- 'Transaction'.
--
-- __WARNING__: This library doesn't __yet__ provide a safe way to construct
-- 'Statement's. Be responsible.
--
-- * The 'SQL' must contain a single statement.
--
-- * The 'SQL' must not contain any transaction nor savepoint management
-- statements.
writeStatement :: Input i -> Output o -> SQL -> Statement Write i o
writeStatement = statement
{-# INLINE writeStatement #-}

--------------------------------------------------------------------------------

-- | Executes a 'Statement' expected to return zero or one rows.
--
-- Throws 'ErrRows_TooMany' if more than one row.
maybe :: (SubMode t s) => Statement s i o -> i -> Transactional g t (Maybe o)
maybe = foldM $ foldMaybeM ErrRows_TooMany
{-# INLINE maybe #-}

-- | Executes a 'Statement' expected to return exactly one row.
--
-- Throws 'ErrRows_TooFew' if zero rows, 'ErrRows_TooMany' if more than one row.
one :: (SubMode t s) => Statement s i o -> i -> Transactional g t o
one = foldM $ foldOneM ErrRows_TooFew ErrRows_TooMany
{-# INLINE one #-}

-- | Executes a 'Statement' expected to return exactly zero rows.
--
-- Throws 'ErrRows_TooMany' if more than zero rows.
zero :: (SubMode t s) => Statement s i o -> i -> Transactional g t ()
zero = foldM $ foldZeroM ErrRows_TooMany
{-# INLINE zero #-}

-- | Executes a 'Statement' expected to return one or more rows.
-- Returns the length of the 'NonEmpty' list, too.
--
-- Throws 'ErrRows_TooFew' if zero rows.
some
   :: (SubMode t s)
   => Statement s i o
   -> i
   -> Transactional g t (Int64, NonEmpty o)
some = foldM $ foldNonEmptyM ErrRows_TooFew
{-# INLINE some #-}

-- | Executes a 'Statement' expected to return an arbitrary
-- number of rows.  Returns the length of the list, too.
list :: (SubMode t s) => Statement s i o -> i -> Transactional g t (Int64, [o])
list = fold foldList
{-# INLINE list #-}

-- | Executes a 'Statement' and folds the rows purely in a
-- streaming fashion.
fold
   :: (SubMode t s) => F.Fold o z -> Statement s i o -> i -> Transactional g t z
fold = foldM . F.generalize
{-# INLINE fold #-}

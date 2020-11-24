-- SPDX-FileCopyrightText: 2020 TQ Tezos
-- SPDX-License-Identifier: MIT

module Lorentz.Contracts.Stablecoin
  ( ConfigureMinterParam(..)
  , ChangeMasterMinterParam
  , ChangePauserParam
  , GetCounterParam
  , SetTransferlistParam
  , RemoveMinterParam
  , MetadataRegistryStorage'(..)
  , MetadataRegistryStorage
  , MetadataRegistryStorageView
  , mkMetadataRegistryStorage
  , defaultMetadataRegistryStorage
  , MintParams
  , MintParam(..)
  , BurnParams
  , ParameterC
  , Parameter (..)
  , Storage'(..)
  , Storage
  , StorageView
  , UserPermits(..)
  , PermitInfo(..)
  , Roles(..)

  , TransferOwnershipParam
  , Expiry
  , PermitHash(..)
  , mkPermitHash
  , PermitParam(..)
  , RevokeParam(..)
  , RevokeParams
  , SetExpiryParam(..)
  , GetDefaultExpiryParam
  , minterLimit

  -- * TZIP-16
  , metadataMap
  , metadataJSON

  -- * Embedded LIGO contracts
  , stablecoinContract
  , registryContract
  ) where

import qualified Data.Aeson as J
import qualified Data.ByteString.Lazy as BSL
import Data.FileEmbed (embedStringFile)
import qualified Data.Map as Map
import Data.Version (showVersion)
import Fmt
import qualified Text.Show

import Lorentz as L
import Michelson.Test.Import (readContract)
import qualified Michelson.Typed as T
import Morley.Client (BigMapId(..))
import Morley.Micheline (ToExpression(toExpression))
import qualified Tezos.Crypto as Hash

import qualified Lorentz.Contracts.Spec.FA2Interface as FA2
import Lorentz.Contracts.Spec.TZIP16Interface
  (Error(..), License(..), Metadata(..), MetadataMap, SomeMichelsonStorageView(..), Source(..),
  ViewImplementation(..), mkMichelsonStorageView)
import qualified Lorentz.Contracts.Spec.TZIP16Interface as TZ (View(..))
import Lorentz.Contracts.StablecoinPath (metadataRegistryContractPath, stablecoinPath)
import Paths_stablecoin (version)

------------------------------------------------------------------
-- Parameter

data ConfigureMinterParam = ConfigureMinterParam
 { cmpMinter :: Address
 , cmpCurrentMintingAllowance :: Maybe Natural
 , cmpNewMintingAllowance :: Natural
 }
 deriving stock (Generic, Show)
 deriving anyclass (IsoValue, HasAnnotation)

instance Buildable ConfigureMinterParam where
  build = genericF

type RemoveMinterParam = Address

data MintParam = MintParam
  { mpTo :: Address
  , mpAmount :: Natural
  }
  deriving stock (Show, Generic)
  deriving anyclass (IsoValue, HasAnnotation)

instance Buildable MintParam where
  build = genericF

type MintParams = [MintParam]

type BurnParams = List Natural

type TransferOwnershipParam = Address
type ChangeMasterMinterParam = Address
type ChangePauserParam = Address
type SetTransferlistParam = Maybe Address

newtype PermitHash = PermitHash ByteString
  deriving stock (Generic, Show)
  deriving newtype (IsoValue, L.HasAnnotation, Eq, Ord)

instance Buildable PermitHash where
  build (PermitHash bs) = base64F bs

data PermitParam = PermitParam
  { ppKey :: PublicKey
  , ppSignature :: Signature
  , ppPermitHash :: PermitHash
  }
 deriving stock (Generic, Show)
 deriving anyclass (IsoValue, HasAnnotation)

instance Buildable PermitParam where
  build = genericF

data RevokeParam = RevokeParam
  { rpPermitHash :: PermitHash
  , rpPermitIssuer :: Address
  }
  deriving stock (Show, Generic)

deriving anyclass instance IsoValue RevokeParam
deriving anyclass instance HasAnnotation RevokeParam
instance Buildable RevokeParam where
  build = genericF

type RevokeParams = [RevokeParam]

type Expiry = Natural

data SetExpiryParam = SetExpiryParam
  { sepExpiry :: Expiry
  , sepPermit :: Maybe (PermitHash, Address)
  }
  deriving stock (Show, Generic)

deriving anyclass instance IsoValue SetExpiryParam
deriving anyclass instance HasAnnotation SetExpiryParam
instance Buildable SetExpiryParam where
  build = genericF

type GetDefaultExpiryParam = View () Expiry

type GetCounterParam = View () Natural

-- | Parameter of Stablecoin contract
data Parameter
  = Accept_ownership
  | Burn BurnParams
  | Call_FA2 FA2.Parameter
  | Change_master_minter ChangeMasterMinterParam
  | Change_pauser ChangePauserParam
  | Configure_minter ConfigureMinterParam
  | Mint MintParams
  | Pause
  | Permit PermitParam
  | Remove_minter RemoveMinterParam
  | Revoke RevokeParams
  | Set_expiry SetExpiryParam
  | Set_transferlist SetTransferlistParam
  | Transfer_ownership TransferOwnershipParam
  | Unpause

-- | In order to be able to construct valid permits,
-- the shape of the @or@ tree generated
-- the Michelson representation of 'Parameter' must be an exact match
-- of the Michelson parameter generated by Ligo in @stablecoin.tz@.
--
-- To see the the Michelson representation of 'Parameter':
--
-- >>> import Data.Singletons (demote)
-- >>> import Michelson.Typed (ToT)
-- >>> import Fmt (pretty)
-- >>>
-- >>> pretty $ demote @(ToT Parameter)
$(customGeneric "Parameter" $ withDepths
    [ cstr @4 []       -- %accept_ownership
    , cstr @4 [fld @0] -- %burn
    , cstr @4 [fld @0] -- %call_FA2
    , cstr @4 [fld @0] -- %change_master_minter
    , cstr @4 [fld @0] -- %change_pauser
    , cstr @4 [fld @0] -- %configure_minter
    , cstr @4 [fld @0] -- %mint
    , cstr @4 []       -- %pause
    , cstr @4 [fld @0] -- %permit
    , cstr @4 [fld @0] -- %remove_minter
    , cstr @4 [fld @0] -- %revoke
    , cstr @4 [fld @0] -- %set_expiry
    , cstr @4 [fld @0] -- %set_transferlist
    , cstr @4 [fld @0] -- %transfer_ownership
    , cstr @3 []       -- %unpause
    ]
  )

deriving anyclass instance IsoValue Parameter

instance Buildable Parameter where
  build = genericF

instance Show Parameter where
  show = pretty

instance ParameterHasEntrypoints Parameter where
  type ParameterEntrypointsDerivation Parameter = EpdRecursive

type ManagementMichelsonEntrypoints =
    [ "Pause" :> ()
    , "Unpause" :> ()
    , "Configure_minter" :> ConfigureMinterParam
    , "Remove_minter" :> RemoveMinterParam
    , "Mint" :> MintParams
    , "Burn" :> BurnParams
    , "Transfer_ownership" :> TransferOwnershipParam
    , "Accept_ownership" :> ()
    , "Change_master_minter" :> ChangeMasterMinterParam
    , "Change_pauser" :> ChangePauserParam
    , "Set_transferlist" :> SetTransferlistParam
    ]

type PermitEntrypoints =
    [ "Permit" :> PermitParam
    , "Revoke" :> RevokeParams
    , "Set_expiry" :> SetExpiryParam
    ]

type ParameterC param =
  ( FA2.FA2ParameterC param
  , ParameterContainsEntrypoints param ManagementMichelsonEntrypoints
  , ParameterContainsEntrypoints param PermitEntrypoints
  )

-- | Crates a permit that can be issued via the @Permit@ entrypoint, allowing other users
-- to call the contract with the given 'Parameter' value.
mkPermitHash :: Parameter -> PermitHash
mkPermitHash = PermitHash . Hash.blake2b . lPackValue

------------------------------------------------------------------
--- Storage
------------------------------------------------------------------

data UserPermits = UserPermits
  { upExpiry :: Maybe Expiry
  , upPermits :: Map PermitHash PermitInfo
  }
  deriving stock (Show, Generic)
  deriving anyclass (IsoValue, HasAnnotation)

data PermitInfo = PermitInfo
  { piCreatedAt :: Timestamp
  , piExpiry :: Maybe Expiry
  }
  deriving stock (Show, Generic)
  deriving anyclass (IsoValue, HasAnnotation)

data Roles = Roles
  { rMasterMinter :: Address
  , rOwner :: Address
  , rPauser :: Address
  , rPendingOwner :: Maybe Address
  }
  deriving stock (Show)

deriving anyclass instance IsoValue Roles
deriving anyclass instance HasAnnotation Roles
$(customGeneric "Roles" $ withDepths
    [ cstr @0
      [ fld @2
      , fld @2
      , fld @2
      , fld @2
      ]
    ]
  )

data Storage' big_map = Storage
  { sDefaultExpiry :: Expiry
  , sLedger :: big_map Address Natural
  , sMetadata :: MetadataMap big_map
  , sMintingAllowances :: Map Address Natural
  , sOperators :: big_map (Address, Address) ()
  , sIsPaused :: Bool
  , sPermitCounter :: Natural
  , sPermits :: big_map Address UserPermits
  , sRoles :: Roles
  , sTokenMetadataRegistry :: Address
  , sTransferlistContract :: Maybe Address
  }

$(customGeneric "Storage'" $ withDepths
    [ cstr @0
      [ fld @4 -- sDefaultExpiry
      , fld @4 -- sLedger
      , fld @4 -- sMetadata
      , fld @4 -- sMintingAllowances
      , fld @4 -- sOperators
      , fld @4 -- sIsPaused
      , fld @4 -- sPermitCounter
      , fld @4 -- sPermits
      , fld @3 -- sRoles
      , fld @3 -- sTokenMetadataRegistry
      , fld @2 -- sTransferlistContract
      ]
    ]
  )

type Storage = Storage' BigMap
deriving stock instance Show Storage
deriving anyclass instance IsoValue Storage
deriving anyclass instance HasAnnotation Storage

-- | Represents a storage value retrieved using the Tezos RPC.
--
-- 'StorageView' is very similar to 'Storage',
-- except 'BigMap's have been replaced by 'BigMapId'.
-- This is because, when a contract's storage is queried, the Tezos RPC returns
-- big_maps' IDs instead of their contents.
type StorageView = Storage' BigMapId
deriving stock instance Show StorageView
deriving anyclass instance IsoValue StorageView

-- Currently the contract allows to add upto 12 minters.
minterLimit :: Int
minterLimit = 12

data MetadataRegistryStorage' big_map = MetadataRegistryStorage
  { mrsDummyField :: ()
  , mrsTokenMetadata :: big_map FA2.TokenId FA2.TokenMetadata
  }
  deriving stock Generic

type MetadataRegistryStorage = MetadataRegistryStorage' BigMap
type MetadataRegistryStorageView = MetadataRegistryStorage' BigMapId

deriving stock instance Show (MetadataRegistryStorage)
deriving stock instance Show (MetadataRegistryStorageView)

deriving anyclass instance IsoValue (MetadataRegistryStorage)
deriving anyclass instance IsoValue (MetadataRegistryStorageView)

-- | Construct the storage for the Metadata Registry contract.
mkMetadataRegistryStorage :: MText -> MText -> Natural -> MetadataRegistryStorage
mkMetadataRegistryStorage symbol name decimals =
  MetadataRegistryStorage
    { mrsDummyField = ()
    , mrsTokenMetadata = BigMap $ Map.singleton 0 $
        FA2.TokenMetadata
          { tmTokenId = 0
          , tmSymbol = symbol
          , tmName = name
          , tmDecimals = decimals
          , tmExtras = mempty
          }
    }

-- | The default storage for the Metadata Registry storage
-- with some hardcoded token metadata.
-- Useful for testing.
defaultMetadataRegistryStorage :: MetadataRegistryStorage
defaultMetadataRegistryStorage =
  mkMetadataRegistryStorage
    [mt|TEST|]
    [mt|Test|]
    8

-- This empty splice lets us workaround the GHC stage restriction, and refer to `Storage`
-- in the TH splices below.
$(pure [])

stablecoinContract :: T.Contract (ToT Parameter) (ToT Storage)
stablecoinContract =
  -- This TemplateHaskell splice is here to ensure the Michelson representation
  -- (i.e., the generated tree of `or` and `pair`) of these Haskell data
  -- types matches exactly the Michelson representation of the Ligo data types.
  --
  -- For example, if a Ligo data type generates a Michelson balanced tuple like
  -- ((a, b), (c, d)), but the corresponding Haskell data type generates a Michelson
  -- tuple like (a, (b, (c, d))), compilation should fail.
  --
  -- The reason they need to match is because of the way permits work.
  -- If we issue a permit for an entrypoint and the tree of `or`s is incorrect,
  -- then the permit will be unusable.
  -- See TZIP-17 for more info.
  --
  -- The splice attempts to parse the stablecoin.tz contract at compile-time.
  -- If, for example, the Michelson representation of Haskell's
  -- `Lorentz.Contracts.Stablecoin.Parameter` is different from Ligo's `parameter`,
  -- then this splice will raise a compilation error.
  --
  -- This can usually be fixed by writing a custom instance of Generic using `customGeneric`,
  -- and making sure the data type's layout matches the layout in stablecoin.tz.
  -- See examples in this module.
  $(case readContract @(ToT Parameter) @(ToT Storage) stablecoinPath $(embedStringFile stablecoinPath) of
      Left e ->
        -- Emit a compiler error if the contract cannot be read.
        fail (pretty e)
      Right _ ->
        -- Emit a haskell expression that reads the contract.
        [|
          -- Note: it's ok to use `error` here, because we just proved that the contract
          -- can be parsed+typechecked.
          either (error . pretty) snd $
            readContract
              stablecoinPath
              $(embedStringFile stablecoinPath)
        |]
  )

-- | Parse the metadata registry contract.
registryContract :: T.Contract (ToT ()) (ToT MetadataRegistryStorage)
registryContract =
  $(case readContract @(ToT ()) @(ToT MetadataRegistryStorage) metadataRegistryContractPath $(embedStringFile metadataRegistryContractPath) of
      Left e -> fail (pretty e)
      Right _ ->
        [|
          -- Note: it's ok to use `error` here, because we just proved that the contract
          -- can be parsed+typechecked.
          either (error . pretty) snd $
            readContract
              metadataRegistryContractPath
              $(embedStringFile metadataRegistryContractPath)
        |]
  )

----------------------------------------------------------------------------
-- TZIP-16 Metadata
----------------------------------------------------------------------------

metadataMap :: MetadataMap BigMap
metadataMap = BigMap $ Map.fromList
  -- One might reasonable expect that the URI would be stored as packed Michelson strings,
  -- but the TZIP-16 spec is explicit about that not being the case.
  --
  -- > Unless otherwise-specified, the encoding of the values must be the direct stream
  -- > of bytes of the data being stored. (...)
  -- > There is no implicit conversion to Michelson's binary format (PACK) nor
  -- > quoting mechanism.
  --
  -- See: <https://gitlab.com/tzip/tzip/-/blob/eb1da57684599a266334a73babd7ba82dbbbce66/proposals/tzip-16/tzip-16.md#contract-storage>
  --
  -- So, instead, we encode it as UTF-8 byte sequences.
  [ (mempty, encodeUtf8 @Text "tezos-storage:metadataJSON")
  , ([mt|metadataJSON|], BSL.toStrict (J.encode metadataJSON))
  ]

metadataJSON :: Metadata (ToT Storage)
metadataJSON =
  Metadata
    { mName = Just "stablecoin"
    , mDescription = Nothing
    , mVersion = Just (toText $ showVersion version)
    , mLicense = Just License { lName = "MIT", lDetails = Nothing }
    , mAuthors =
        [ "Serokell <https://serokell.io/>"
        , "TQ Tezos <https://tqtezos.com/>"
        ]
    , mHomepage = Just "https://github.com/tqtezos/stablecoin/"
    , mSource = Just Source
        { sLocation = "https://github.com/tqtezos/stablecoin/tree/v" <> toText (showVersion version) <> "/ligo/stablecoin"
        , sTools = [ "ligo " ] -- TODO: add ligo version
        }
    , mInterfaces = [ "TZIP-12", "TZIP-17" ]
    , mErrors =
        [ mkError [mt|FA2_TOKEN_UNDEFINED|]        [mt|One of the specified `token_id`s is not defined (i.e. not zero)|]
        , mkError [mt|FA2_INSUFFICIENT_BALANCE|]   [mt|Cannot debit from a wallet because of excessive amount of tokens|]
        , mkError [mt|FA2_NOT_OPERATOR|]           [mt|A transfer is initiated neither by the token owner nor a permitted operator|]
        , mkError [mt|XTZ_RECEIVED|]               [mt|Contract received a non-zero amount of tokens and should not proceed any further|]
        , mkError [mt|NOT_CONTRACT_OWNER|]         [mt|Authorized sender is not contract owner|]
        , mkError [mt|NOT_PENDING_OWNER|]          [mt|Authorized sender is not current contract pending owner|]
        , mkError [mt|NO_PENDING_OWNER_SET|]       [mt|Thrown when trying to authorize as pending owner whilst is not set for a contract|]
        , mkError [mt|NOT_PAUSER|]                 [mt|Authorized sender is not contract pauser|]
        , mkError [mt|NOT_MASTER_MINTER|]          [mt|Authorized sender is not master minter|]
        , mkError [mt|NOT_MINTER|]                 [mt|Sender is not registered as minter|]
        , mkError [mt|CONTRACT_PAUSED|]            [mt|Operation cannot be performed during contract pause|]
        , mkError [mt|CONTRACT_NOT_PAUSED|]        [mt|Operation cannot be peformed if the contract is not paused|]
        , mkError [mt|NOT_TOKEN_OWNER|]            [mt|Trying to configure operators for a different wallet which sender does not own|]
        , mkError [mt|CURRENT_ALLOWANCE_REQUIRED|] [mt|In `configure_minter` the caller wrongly expects the address to be not a minter|]
        , mkError [mt|ALLOWANCE_MISMATCH|]         [mt|In `configure_minter` both allowances are not `None`, but different|]
        , mkError [mt|ADDR_NOT_MINTER|]            [mt|An attempt is made to modify minter data of an address that's not a minter|]
        , mkError [mt|ALLOWANCE_EXCEEDED|]         [mt|Thrown when trying to mint tokens more than currently allowed for an address|]
        , mkError [mt|BAD_TRANSFERLIST|]           [mt|Given address is a not a smart contract complying with the transferlist interface|]
        , mkError [mt|MINTER_LIMIT_REACHED|]       [mt|Cannot add new minter because the number of minters is already at the limit.|]
        , mkError [mt|MISSIGNED|]                  [mt|The signature used to create a permit was invalid.|]
        , mkError [mt|EXPIRED_PERMIT|]             [mt|The sender tried to access an entrypoint for which a permit was found, but it was expired.|]
        , mkError [mt|NOT_PERMIT_ISSUER|]          [mt|The sender tried to revoke a permit that wasn't theirs and no permit was issued to allow this call.|]
        ]
    , mViews =
        [ getDefaultExpiryView
        , getCounterView
        ]
    }
  where
    mkError :: MText -> MText -> Error
    mkError err expansion =
      Error
        { eError = toExpression (toVal err)
        , eExpansion = toExpression (toVal expansion)
        , eLanguages = ["en"]
        }

getDefaultExpiryView :: TZ.View (ToT Storage)
getDefaultExpiryView =
  TZ.View
    { vName = "GetDefaultExpiry"
    , vDescription = Just "Access the contract's default expiry in seconds"
    , vPure = True
    , vImplementations = one $
        VIMichelsonStorageView $ SomeMichelsonStorageView $
          mkMichelsonStorageView @Storage @() [] $
            L.car # L.toField #sDefaultExpiry
    }

getCounterView :: TZ.View (ToT Storage)
getCounterView =
  TZ.View
    { vName = "GetCounter"
    , vDescription = Just "Access the current permit counter"
    , vPure = True
    , vImplementations = one $
        VIMichelsonStorageView $ SomeMichelsonStorageView $
          mkMichelsonStorageView @Storage @() [] $
            L.car # L.toField #sPermitCounter
    }

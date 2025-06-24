// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import { GameType, OutputRoot, Claim, GameStatus, Hash } from "../../lib/optimism/packages/contracts-bedrock/src/dispute/lib/Types.sol";

// Interfaces
import { ISemver } from "../../lib/optimism/packages/contracts-bedrock/interfaces/universal/ISemver.sol";
import { IFaultDisputeGame } from "../../lib/optimism/packages/contracts-bedrock/interfaces/dispute/IFaultDisputeGame.sol";
import { IDisputeGame } from "../../lib/optimism/packages/contracts-bedrock/interfaces/dispute/IDisputeGame.sol";

// Contracts
import { MinimalDisputeGameFactory } from "./MinimalDisputeGameFactory.sol";

/// @title MinimalAnchorRegistry
/// @notice Stores the latest finalized FaultDisputeGame as an "anchor" root so that
///         new games can start from a recent state.  Does NOT depend on OptimismPortal.
contract MinimalAnchorRegistry is ISemver {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event AnchorUpdated(IFaultDisputeGame indexed game);

    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    error InvalidAnchorGame();

    /*//////////////////////////////////////////////////////////////////////////
                                    IMMUTABLES
    //////////////////////////////////////////////////////////////////////////*/

    MinimalDisputeGameFactory public immutable disputeGameFactory;
    uint256 public immutable FINALITY_DELAY_SECONDS;

    /*//////////////////////////////////////////////////////////////////////////
                                    STATE
    //////////////////////////////////////////////////////////////////////////*/

    // The game that backs the current anchor state
    IFaultDisputeGame public anchorGame;

    // Initial anchor root (genesis value)
    OutputRoot internal startingAnchorRoot;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        MinimalDisputeGameFactory _factory,
        uint256 _finalityDelaySeconds,
        OutputRoot memory _startingAnchorRoot
    ) {
        disputeGameFactory       = _factory;
        FINALITY_DELAY_SECONDS   = _finalityDelaySeconds;
        startingAnchorRoot       = _startingAnchorRoot;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    SEMVER
    //////////////////////////////////////////////////////////////////////////*/

    string public constant version = "0.1.0";

    /*//////////////////////////////////////////////////////////////////////////
                               ANCHOR ROOT QUERIES
    //////////////////////////////////////////////////////////////////////////*/

    function getAnchorRoot() public view returns (Hash root, uint256 l2BlockNumber) {
        if (address(anchorGame) == address(0)) {
            return (startingAnchorRoot.root, startingAnchorRoot.l2BlockNumber);
        }
        return (Hash.wrap(anchorGame.rootClaim().raw()), anchorGame.l2BlockNumber());
    }
    
    /// @notice Determines whether a game is registered in the DisputeGameFactory.
    /// @param _game The game to check.
    /// @return Whether the game is factory registered.
    function isGameRegistered(IDisputeGame _game) public view returns (bool) {
        // Grab the game and game data.
        (GameType gameType, Claim rootClaim, bytes memory extraData) = _game.gameData();

        // Grab the verified address of the game based on the game data.
        (IDisputeGame _factoryRegisteredGame,) =
            disputeGameFactory.games({ _gameType: gameType, _rootClaim: rootClaim, _extraData: extraData });

        // Return whether the game is factory registered.
        return address(_factoryRegisteredGame) == address(_game);
    }
    
    function isGameProper(IDisputeGame _game) public view returns (bool) {
        // Must be registered in the DisputeGameFactory.
        if (!isGameRegistered(_game)) {
            return false;
        }
        
        return true;
    }

    function isGameResolved(IDisputeGame _game) public view returns (bool) {
        return _game.resolvedAt().raw() != 0 && (_game.status() == GameStatus.DEFENDER_WINS || _game.status() == GameStatus.CHALLENGER_WINS);
    }

    function isGameFinalized(IDisputeGame _game) public view returns (bool) {
        if (!isGameResolved(_game)) return false;
        return block.timestamp - _game.resolvedAt().raw() > FINALITY_DELAY_SECONDS;
    }

    function isGameClaimValid(IDisputeGame _game) public view returns (bool) {
        if (!isGameProper(_game)) return false;
        if (!isGameFinalized(_game)) return false;
        if (_game.status() != GameStatus.DEFENDER_WINS) return false;
        return true;
    }

    /*//////////////////////////////////////////////////////////////////////////
                               ANCHOR UPDATE
    //////////////////////////////////////////////////////////////////////////*/

    function setAnchorState(IDisputeGame _game) external {
        IFaultDisputeGame game = IFaultDisputeGame(address(_game));
        if (!isGameClaimValid(game)) revert InvalidAnchorGame();

        ( , uint256 currentBlockNumber) = getAnchorRoot();
        if (game.l2BlockNumber() <= currentBlockNumber) revert InvalidAnchorGame();

        anchorGame = game;
        emit AnchorUpdated(game);
    }
} 